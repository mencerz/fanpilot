import Foundation
import os
import Observation
import ServiceManagement
import FanPilotShared

@MainActor
@Observable
final class FanControlService {
    enum State: Equatable {
        case notPackaged
        case notRegistered
        case requiresApproval
        case connecting
        case ready
        case failed(String)
    }

    private let log = Logger(subsystem: fanPilotAppIdentifier, category: "control")
    private(set) var state: State = .notPackaged {
        didSet {
            guard state != oldValue else { return }
            log.notice("Helper state: \(String(describing: oldValue), privacy: .public) -> \(String(describing: self.state), privacy: .public)")
        }
    }
    private var connection: NSXPCConnection?
    /// Bumped on every disconnect so a reply belonging to a connection that has
    /// already been torn down cannot overwrite the state of its replacement.
    private var epoch = 0
    private var lastRecoveryAttempt: Date?
    private var removedLegacyHelpers = false

    /// Timeouts exist so a wedged helper can never hang the caller, but they
    /// must stay above the helper's own work: taking a fan off the thermal
    /// manager can legitimately need a few seconds of retries, while returning
    /// control to macOS is a single write.
    private let targetTimeout: TimeInterval = 12
    private let commandTimeout: TimeInterval = 5
    private let connectTimeout: TimeInterval = 10
    private let recoveryInterval: TimeInterval = 30

    var isReady: Bool { state == .ready }

    var statusText: String {
        switch state {
        case .notPackaged: "Requires the FanPilot app bundle"
        case .notRegistered: "Not installed"
        case .requiresApproval: "Approval required in System Settings"
        case .connecting: "Connecting…"
        case .ready: "Installed and connected"
        case .failed(let message): message
        }
    }

    func refreshStatus() async {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            state = .notPackaged
            disconnect()
            return
        }
        removeLegacyHelpers()

        switch SMAppService.daemon(plistName: fanPilotHelperPlistName).status {
        case .enabled:
            state = .connecting
            await connect()
        case .requiresApproval:
            state = .requiresApproval
            disconnect()
        case .notRegistered:
            state = .notRegistered
            disconnect()
        case .notFound:
            if embeddedHelperPlistExists {
                state = .notRegistered
            } else {
                state = .failed("Fan control helper is missing from the app.")
            }
            disconnect()
        @unknown default:
            state = .failed("Unknown helper status.")
            disconnect()
        }
    }

    func enable() async {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            state = .notPackaged
            return
        }
        log.notice("Enable requested")
        var registrationError: Error?
        do {
            try SMAppService.daemon(plistName: fanPilotHelperPlistName).register()
        } catch {
            // register() throws when the daemon is already registered, which is
            // not a failure — the status check below decides what is true.
            registrationError = error
            log.notice("register() said: \(error.localizedDescription, privacy: .public)")
        }
        await refreshStatus()
        if state == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        } else if !isReady, let registrationError {
            state = .failed(registrationError.localizedDescription)
        }
    }

    /// Boots the running daemon out and registers it again. This is the only
    /// way to pick up a rebuilt helper binary without a reboot or sudo, because
    /// launchd keeps the current process alive as long as it holds the service.
    func reinstall() async {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            state = .notPackaged
            return
        }
        log.notice("Reinstalling helper")
        disconnect()
        let service = SMAppService.daemon(plistName: fanPilotHelperPlistName)
        do {
            try await service.unregister()
        } catch {
            log.error("unregister() said: \(error.localizedDescription, privacy: .public)")
        }
        // Background Task Management applies the removal asynchronously, and a
        // register() issued before it settles is refused with "Operation not
        // permitted" even though the reinstall then completes anyway.
        for _ in 0..<20 where service.status == .enabled {
            try? await Task.sleep(for: .milliseconds(150))
        }
        await enable()
        if !isReady {
            try? await Task.sleep(for: .milliseconds(500))
            await enable()
        }
    }

    /// Reconnects after the helper was interrupted, restarted or updated,
    /// without making the user press Enable again.
    func recoverIfNeeded() async {
        guard case .failed = state else { return }
        if let last = lastRecoveryAttempt, Date().timeIntervalSince(last) < recoveryInterval { return }
        lastRecoveryAttempt = .now
        await refreshStatus()
    }

    func setSystemMode() async -> Result<Void, ControlError> {
        await call(timeout: commandTimeout) { proxy, finish in
            proxy.setSystemMode { success, message in
                finish(success ? .success(()) : .failure(.helper(message)))
            }
        }
    }

    func setTargetRPM(fan: Int, rpm: Int) async -> Result<Int, ControlError> {
        await call(timeout: targetTimeout) { proxy, finish in
            proxy.setTargetRPM(fan: fan, rpm: rpm) { success, applied, message in
                finish(success ? .success(applied) : .failure(.helper(message)))
            }
        }
    }

    func sendHeartbeat() {
        remoteProxy()?.heartbeat { _ in }
    }

    /// Termination does not wait for async work, so the last hand-back to macOS
    /// has to be a blocking call rather than a Task nobody will run.
    func setSystemModeSynchronously(timeout: TimeInterval = 2) {
        guard let connection else { return }
        let done = DispatchSemaphore(value: 0)
        let onError: @Sendable (any Error) -> Void = { _ in done.signal() }
        let proxy = connection.synchronousRemoteObjectProxyWithErrorHandler(onError) as? FanPilotHelperProtocol
        proxy?.setSystemMode { _, _ in done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }

    private func connect() async {
        disconnect()
        let newConnection = NSXPCConnection(
            machServiceName: fanPilotHelperMachService,
            options: .privileged
        )
        newConnection.remoteObjectInterface = NSXPCInterface(with: FanPilotHelperProtocol.self)
        let helperBinary = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/FanPilotHelper")
        guard let requirement = fanPilotCodeRequirement(identifier: fanPilotHelperIdentifier, pinnedTo: helperBinary) else {
            state = .failed("The helper in this app bundle could not be verified.")
            return
        }
        newConnection.setCodeSigningRequirement(requirement)
        newConnection.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.state = .failed("Fan control helper was interrupted.") }
        }
        newConnection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.state = .failed("Fan control helper disconnected.") }
        }
        newConnection.resume()
        connection = newConnection

        let attempt = epoch
        let result: Result<Void, ControlError> = await call(timeout: connectTimeout) { proxy, finish in
            proxy.status { ready, message in
                finish(ready ? .success(()) : .failure(.helper(message ?? "Helper did not become ready.")))
            }
        }
        guard attempt == epoch else { return }
        switch result {
        case .success: state = .ready
        case .failure(let error):
            // An unsigned build pins the peer by code hash, so a helper left
            // running from an older build no longer matches after a rebuild.
            state = .failed(error.localizedDescription + " Use Reinstall Helper after rebuilding.")
        }
    }

    /// Every helper call funnels through here so that exactly one of the reply
    /// block, the proxy error handler or the timeout resumes the continuation.
    private func call<T: Sendable>(
        timeout: TimeInterval,
        _ body: @escaping @Sendable (FanPilotHelperProtocol, @escaping @Sendable (Result<T, ControlError>) -> Void) -> Void
    ) async -> Result<T, ControlError> {
        guard let connection else { return .failure(.notConnected) }
        let issuedAt = epoch
        let result: Result<T, ControlError> = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            // XPC invokes this from its own queue. Declared inline it would
            // inherit MainActor isolation and trip the executor assertion, so
            // it is explicitly Sendable and hops back deliberately.
            let onError: @Sendable (any Error) -> Void = { error in
                once.finish(.failure(.transport(error.localizedDescription)))
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler(onError) as? FanPilotHelperProtocol
            guard let proxy else {
                once.finish(.failure(.notConnected))
                return
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                once.finish(.failure(.timedOut))
            }
            body(proxy) { once.finish($0) }
        }
        if case .failure(let error) = result {
            log.error("Helper call failed: \(error.localizedDescription, privacy: .public)")
            if error.breaksConnection, issuedAt == epoch { state = .failed(error.localizedDescription) }
        }
        return result
    }

    private func remoteProxy() -> FanPilotHelperProtocol? {
        // Per-call handlers outlive disconnect(), so this one carries the epoch
        // it was made for; without it a stale failure knocks out the healthy
        // connection that replaced it.
        let issuedAt = epoch
        let onError: @Sendable (any Error) -> Void = { [weak self] error in
            Task { @MainActor in
                guard let self, issuedAt == self.epoch else { return }
                self.state = .failed(error.localizedDescription)
            }
        }
        return connection?.remoteObjectProxyWithErrorHandler(onError) as? FanPilotHelperProtocol
    }

    private func disconnect() {
        epoch &+= 1
        connection?.interruptionHandler = nil
        connection?.invalidationHandler = nil
        connection?.invalidate()
        connection = nil
    }

    /// Daemons stay registered under their own label, so a renamed helper would
    /// otherwise leave a root job from an older build running forever.
    private func removeLegacyHelpers() {
        guard !removedLegacyHelpers else { return }
        removedLegacyHelpers = true
        for plistName in legacyFanPilotHelperPlistNames where plistName != fanPilotHelperPlistName {
            let service = SMAppService.daemon(plistName: plistName)
            guard service.status != .notFound else { continue }
            try? service.unregister()
        }
    }

    private var embeddedHelperPlistExists: Bool {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons", isDirectory: true)
            .appendingPathComponent(fanPilotHelperPlistName)
        return FileManager.default.fileExists(atPath: url.path)
    }
}

enum ControlError: LocalizedError, Sendable {
    case notConnected
    case timedOut
    case transport(String)
    case helper(String?)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Fan control helper is not connected."
        case .timedOut: "Fan control helper did not answer in time."
        case .transport(let message): message
        case .helper(let message): message ?? "Fan control command failed."
        }
    }

    /// Helper-side refusals leave the connection usable; transport failures do not.
    var breaksConnection: Bool {
        switch self {
        case .helper: false
        case .notConnected, .timedOut, .transport: true
        }
    }
}

private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<T, ControlError>, Never>?

    init(_ continuation: CheckedContinuation<Result<T, ControlError>, Never>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<T, ControlError>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: result)
    }
}
