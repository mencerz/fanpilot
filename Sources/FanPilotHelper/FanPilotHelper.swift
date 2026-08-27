import Foundation
import os
import FanPilotShared

final class FanPilotHelper: NSObject, FanPilotHelperProtocol, NSXPCListenerDelegate, @unchecked Sendable {
    private let log = Logger(subsystem: fanPilotHelperIdentifier, category: "helper")
    private let writer = SMCWriter()
    /// Ownership and queue depth are guarded by a lock rather than by the SMC
    /// queue itself: an unauthorised or excessive call has to be rejected
    /// before it can occupy the queue the watchdog also runs on.
    private let gate = NSLock()
    private var owner: ObjectIdentifier?
    private var queuedOperations = 0
    private let maximumQueuedOperations = 4
    private let queue = DispatchQueue(label: "\(fanPilotHelperIdentifier).smc")
    private var lastHeartbeat = Date()
    private var powerMonitor: SystemPowerMonitor?
    /// Resolved once at start-up, from our own location rather than from
    /// anything a caller says: the listener callback can run concurrently, and
    /// a lazy var would race there.
    private let peerRequirement: String?

    override init() {
        let executable = Bundle.main.executableURL?.resolvingSymlinksInPath()
        let appBundle = executable?
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        peerRequirement = fanPilotCodeRequirement(identifier: fanPilotAppIdentifier, pinnedTo: appBundle)
        super.init()
        queue.async { [writer, log] in
            guard let writer else {
                log.error("Unable to open AppleSMC")
                return
            }
            writer.recoverFromPreviousSession()
        }
        powerMonitor = SystemPowerMonitor { [weak self] in
            _ = self?.queue.sync {
                self?.writer?.restoreSystemControl()
            }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while let self {
                Thread.sleep(forTimeInterval: 2)
                self.queue.async {
                    if Date().timeIntervalSince(self.lastHeartbeat) > 6,
                       !(self.writer?.touchedFans.isEmpty ?? true) {
                        self.log.notice("Heartbeat timed out, returning fan control to macOS")
                        _ = self.clearOwner()
                        self.writer?.restoreSystemControl()
                    }
                }
            }
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let requirement = peerRequirement else {
            log.error("Refusing connection: the peer app could not be pinned")
            return false
        }
        connection.setCodeSigningRequirement(requirement)
        let identity = ObjectIdentifier(connection)
        connection.invalidationHandler = { [weak self] in
            guard let helper = self, helper.clearOwner(matching: identity) else { return }
            helper.queue.async {
                helper.log.notice("Controlling client disconnected, returning fan control to macOS")
                helper.writer?.restoreSystemControl()
            }
        }
        connection.exportedInterface = NSXPCInterface(with: FanPilotHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func status(reply: @escaping @Sendable (Bool, String?) -> Void) {
        queue.async { [writer] in
            reply(writer != nil, writer == nil ? "Unable to open AppleSMC." : nil)
        }
    }

    func setSystemMode(reply: @escaping @Sendable (Bool, String?) -> Void) {
        let caller = NSXPCConnection.current().map(ObjectIdentifier.init)
        gate.lock()
        let isOwner = owner == nil || owner == caller
        if isOwner { owner = nil }
        gate.unlock()
        guard isOwner else {
            reply(false, "Another FanPilot session is controlling the fans.")
            return
        }
        queue.async { [weak self] in
            guard let self, let writer = self.writer else { reply(false, "Unable to open AppleSMC."); return }
            let success = writer.restoreSystemControl()
            self.log.notice("System mode requested by the app: \(success, privacy: .public)")
            reply(success, success ? nil : "SMC did not confirm System mode.")
        }
    }

    func setTargetRPM(fan: Int, rpm: Int, reply: @escaping @Sendable (Bool, Int, String?) -> Void) {
        let caller = NSXPCConnection.current().map(ObjectIdentifier.init)
        switch claim(for: caller) {
        case .rejected(let reason):
            reply(false, 0, reason)
            return
        case .accepted:
            break
        }
        queue.async { [weak self] in
            guard let self else { reply(false, 0, "Helper is shutting down."); return }
            defer { self.release() }
            guard let writer = self.writer else { reply(false, 0, "Unable to open AppleSMC."); return }
            self.lastHeartbeat = .now
            switch writer.setTargetRPM(fan: fan, requestedRPM: rpm) {
            case .success(let applied): reply(true, applied, nil)
            case .failure(let error): reply(false, 0, error.localizedDescription)
            }
        }
    }

    func heartbeat(reply: @escaping @Sendable (Bool) -> Void) {
        let caller = NSXPCConnection.current().map(ObjectIdentifier.init)
        gate.lock()
        let isOwner = owner == nil || owner == caller
        gate.unlock()
        guard isOwner else { reply(false); return }
        // Deliberately not on the SMC queue: a heartbeat must not wait behind
        // a fan write, or a slow write would starve the very watchdog it feeds.
        queue.async { [weak self] in
            self?.lastHeartbeat = .now
            reply(true)
        }
    }

    private enum Claim {
        case accepted
        case rejected(String)
    }

    private func claim(for caller: ObjectIdentifier?) -> Claim {
        gate.lock()
        defer { gate.unlock() }
        guard owner == nil || owner == caller else {
            return .rejected("Another FanPilot session is controlling the fans.")
        }
        guard queuedOperations < maximumQueuedOperations else {
            return .rejected("Fan control is busy.")
        }
        owner = caller
        queuedOperations += 1
        return .accepted
    }

    private func release() {
        gate.lock()
        queuedOperations = max(queuedOperations - 1, 0)
        gate.unlock()
    }

    private func clearOwner(matching identity: ObjectIdentifier? = nil) -> Bool {
        gate.lock()
        defer { gate.unlock() }
        if let identity, owner != identity { return false }
        owner = nil
        return true
    }
}

@main
struct FanPilotHelperMain {
    static func main() {
        let helper = FanPilotHelper()
        let listener = NSXPCListener(machServiceName: fanPilotHelperMachService)
        listener.delegate = helper
        listener.resume()
        RunLoop.current.run()
    }
}
