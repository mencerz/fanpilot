import AppKit
import Foundation
import os
import Observation

@MainActor
@Observable
final class FanMonitor {
    var snapshot: ThermalSnapshot = .unavailable
    private(set) var mode: FanMode = .system
    var manualPercent: Double = 50
    var curve = FanCurve()
    var autopilot = ThermalAutopilot()
    private(set) var lastError: String?
    let control = FanControlService()
    let history: HistoryStore
    private(set) var targetRPMByFan: [Int: Int] = [:]
    private(set) var lastTargetAppliedAt: Date?
    /// The last percentage the helper actually accepted, as opposed to the
    /// value the slider or the autopilot asked for.
    private(set) var appliedPercent: Double?
    /// The mode the user asked for while the helper is still answering. The SMC
    /// refuses to hand over a fan intermittently, so a rejected switch keeps
    /// retrying for a few seconds instead of snapping back at the first no.
    private(set) var pendingMode: FanMode?
    private var pendingDeadline: Date?
    /// Bumped whenever a request is cancelled or completed, so a reply that
    /// arrives after the deadline cannot force the fans behind the user's back.
    private var pendingGeneration = 0
    private var pendingFailure: String?
    private let engageTimeout: TimeInterval = 10
    private(set) var system = SystemMetrics()

    private let log = Logger(subsystem: "com.oleksii.baliuk.fanpilot.app", category: "monitor")
    private let hardware: HardwareMonitoring
    private let systemReader = SystemMetricsReader()
    private let defaults: UserDefaults
    private var isLoaded = false
    private var timer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var suspendedMode: FanMode?
    private var isApplying = false
    private(set) var isSleeping = false
    /// Set when the helper did not confirm the hand-back, so it can be retried
    /// instead of the UI quietly claiming macOS is in charge.
    private(set) var awaitingSystemRestore = false

    private let sensorErrorMessage = "SMC did not return any readings. Access is restricted on some Apple Silicon models."

    enum HiddenRefreshPolicy: String, CaseIterable, Identifiable, Sendable {
        case always, slow, paused

        var id: Self { self }
        var title: String {
            switch self {
            case .always: "Keep refreshing"
            case .slow: "Refresh slowly"
            case .paused: "Pause"
            }
        }
    }

    static let selectableRefreshIntervals: [TimeInterval] = [1, 2, 5, 10, 30]

    var refreshInterval: TimeInterval = 2 {
        didSet {
            guard isLoaded, refreshInterval != oldValue else { return }
            defaults.set(refreshInterval, forKey: "monitor.refreshInterval")
            restartTimer()
        }
    }

    var hiddenRefreshPolicy: HiddenRefreshPolicy = .always {
        didSet {
            guard isLoaded, hiddenRefreshPolicy != oldValue else { return }
            defaults.set(hiddenRefreshPolicy.rawValue, forKey: "monitor.hiddenRefreshPolicy")
            refresh(force: true)
        }
    }

    /// How old a reading may be and still be worth showing in the menu bar.
    private let staleAfter: TimeInterval = 60
    private let slowInterval: TimeInterval = 30
    /// The helper hands the fans back to macOS after six seconds without a
    /// heartbeat, so an active control loop cannot tick slower than this.
    private let controlInterval: TimeInterval = 2
    /// Timers fire a hair early or late; without this a 2 s poll would skip
    /// every other beat.
    private let schedulingTolerance: TimeInterval = 0.25
    private var popoverIsVisible = false
    private var lastSampleAt: Date?

    init(
        hardware: HardwareMonitoring? = nil,
        history: HistoryStore? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.hardware = hardware ?? SMCClient() ?? UnavailableHardware()
        self.history = history ?? HistoryStore()
        self.defaults = defaults
        loadProfileSettings()
        isLoaded = true
        refresh()
        Task { await control.refreshStatus() }
        observeSystemEvents()
        restartTimer()
    }

    private func restartTimer() {
        timer?.invalidate()
        // An open popover, a slider drag or a live resize puts the main run
        // loop into event tracking mode, where a default-mode timer stops
        // firing. That would starve the helper of heartbeats and its watchdog
        // would hand the fans back to macOS mid-session.
        // The tick is fixed at a second and the sampling decision lives in
        // shouldSample(): a coarser tick would round a 5 s interval up to 6 s,
        // and the wake itself costs nothing next to reading the SMC.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    var menuTitle: String {
        // A paused monitor must not keep showing a number that stopped being
        // true minutes ago.
        if let temperature = snapshot.temperature,
           Date().timeIntervalSince(snapshot.capturedAt) < staleAfter {
            return "\(Int(temperature.rounded()))°C"
        }
        return "FanPilot"
    }

    func setPopoverVisible(_ visible: Bool) {
        popoverIsVisible = visible
        if visible { refresh(force: true) }
    }

    var isInterfaceVisible: Bool {
        if popoverIsVisible { return true }
        return ["main", "history", "com_apple_SwiftUI_Settings"].contains { id in
            guard let window = WindowPresenter.window(with: id) else { return false }
            return window.isVisible && !window.isMiniaturized
        }
    }

    var hasFanReadings: Bool { !snapshot.fans.isEmpty }
    /// A fanless Mac — the Airs — has nothing to control no matter how healthy
    /// the helper is, so the whole control surface stays out of the way there.
    var isFanControlAvailable: Bool { control.isReady && hasFanReadings }

    var isMonitoringOnly: Bool {
        !hasFanReadings && snapshot.temperature != nil
    }

    var targetPercent: Double {
        switch mode {
        case .system: return 0
        case .automatic: return autopilot.currentPercent
        case .manual: return manualPercent
        }
    }

    var autoStatusText: String { autopilot.phase.rawValue }

    /// Percentages are positions inside the firmware's own range, not a share
    /// of the maximum, so the resulting RPM has to be spelled out.
    func targetRPM(forPercent percent: Double) -> Int? {
        guard let fan = snapshot.fans.first else { return nil }
        return fan.minimumRPM + Int((Double(fan.maximumRPM - fan.minimumRPM) * percent / 100).rounded())
    }

    var fanRangeText: String? {
        guard let fan = snapshot.fans.first else { return nil }
        return "\(fan.minimumRPM.formatted())–\(fan.maximumRPM.formatted()) RPM"
    }

    func refresh(force: Bool = false) {
        guard force || shouldSample() else { return }
        lastSampleAt = .now
        snapshot = hardware.readSnapshot()
        system = systemReader.read()
        updateSensorError()

        if let requested = pendingMode, requested != .system, mode == .system {
            continuePendingSwitch(requested)
        } else if mode == .system {
            if case .failed = control.state { Task { await control.recoverIfNeeded() } }
        } else if !control.isReady {
            returnToSystem(reason: "Fan control returned to macOS because the helper connection was lost.")
            return
        } else if snapshot.fans.isEmpty {
            returnToSystem(reason: "Fan control stopped because the fan sensors stopped responding.")
            return
        } else if mode == .automatic, !snapshotIsSafeForAutomaticControl {
            returnToSystem(reason: "Automatic control stopped because sensor data became unavailable or invalid.")
            return
        } else {
            // Re-applying, rather than only sending a heartbeat, re-asserts
            // manual mode if the SMC or the helper watchdog already handed the
            // fans back to macOS while FanPilot still thought it was in charge.
            scheduleApply(for: mode)
        }

        history.record(
            snapshot: snapshot,
            mode: mode,
            targetPercent: mode == .system ? nil : appliedPercent,
            thermalPressure: system.thermalPressure,
            eCoreMHz: system.eCoreMHz.map { Int($0.rounded()) },
            pCoreMHz: system.pCoreMHz.map { Int($0.rounded()) }
        )
    }

    func selectMode(_ newMode: FanMode) {
        // Returning to System must always be possible, even mid-attempt.
        if newMode == .system { cancelPendingSwitch() } else if pendingMode != nil { return }
        // Every refusal below has to leave the pending state clean, or the
        // picker locks up: refresh() only ever revisits a pending request while
        // the app is in System mode.
        defer { if pendingMode != nil, mode != .system { cancelPendingSwitch() } }
        guard newMode == .system || hasFanReadings else {
            mode = .system
            lastError = "Fan control is unavailable because no fan sensors were detected."
            return
        }
        guard newMode == .system || isFanControlAvailable else {
            mode = .system
            lastError = "Fan control requires the privileged helper. macOS remains in control."
            return
        }
        // Only taking control from macOS is an operation with a retry window;
        // moving between Auto and Manual either applies at once or falls back,
        // and giving control back is the fail-safe that is never gated.
        if newMode != .system, mode == .system {
            pendingMode = newMode
            pendingDeadline = Date().addingTimeInterval(engageTimeout)
            pendingFailure = nil
        }
        Task {
            if newMode == .system {
                switch await control.setSystemMode() {
                case .success:
                    mode = .system
                    autopilot.reset(to: curve.minimumPercent)
                    clearControlState()
                    lastError = nil
                case .failure(let error):
                    // The user asked macOS to take over; leaving the mode as it
                    // was would have the control loop re-force the fans on the
                    // next tick. The request is retried instead.
                    mode = .system
                    autopilot.reset(to: curve.minimumPercent)
                    clearControlState()
                    awaitingSystemRestore = true
                    lastError = "macOS has not confirmed it is back in control of the fans: \(error.localizedDescription)"
                }
            } else {
                if newMode == .automatic {
                    guard snapshotIsSafeForAutomaticControl else {
                        cancelPendingSwitch()
                        lastError = "Automatic control requires fresh, plausible temperature and fan readings."
                        return
                    }
                    autopilot.reset(to: curve.minimumPercent)
                }
                guard !isApplying else {
                    cancelPendingSwitch()
                    lastError = "Fan control is busy. Try again in a moment."
                    return
                }
                let generation = pendingGeneration
                guard await applyTarget(for: newMode, isEngaging: true) else { return }
                guard generation == pendingGeneration else {
                    requestSystemMode()
                    return
                }
                finishPendingSwitch(to: newMode)
                history.record(
                    snapshot: snapshot,
                    mode: newMode,
                    targetPercent: appliedPercent,
                    thermalPressure: system.thermalPressure,
                    eCoreMHz: system.eCoreMHz.map { Int($0.rounded()) },
                    pCoreMHz: system.pCoreMHz.map { Int($0.rounded()) },
                    force: true
                )
            }
        }
    }

    private func finishPendingSwitch(to newMode: FanMode) {
        mode = newMode
        cancelPendingSwitch()
    }

    private func cancelPendingSwitch() {
        pendingMode = nil
        pendingDeadline = nil
        pendingFailure = nil
        pendingGeneration &+= 1
    }

    /// Retries the switch the user asked for until the helper accepts it or the
    /// window closes; the fans are untouched until one attempt fully succeeds.
    private func continuePendingSwitch(_ requested: FanMode) {
        guard let deadline = pendingDeadline else { return }
        guard Date() < deadline else {
            let reason = pendingFailure ?? "The SMC did not accept fan control."
            cancelPendingSwitch()
            lastError = "Could not switch to \(requested.rawValue): \(reason)"
            return
        }
        let generation = pendingGeneration
        Task {
            if await applyTarget(for: requested, isEngaging: true) {
                guard generation == pendingGeneration else {
                    requestSystemMode()
                    return
                }
                finishPendingSwitch(to: requested)
                history.record(
                    snapshot: snapshot,
                    mode: requested,
                    targetPercent: appliedPercent,
                    thermalPressure: system.thermalPressure,
                    eCoreMHz: system.eCoreMHz.map { Int($0.rounded()) },
                    pCoreMHz: system.pCoreMHz.map { Int($0.rounded()) },
                    force: true
                )
                lastError = nil
            }
        }
    }

    func updateManualTarget() {
        guard mode == .manual else { return }
        scheduleApply(for: .manual)
    }

    func saveProfileSettings() {
        defaults.set(curve.coolTemperature, forKey: "profile.coolTemperature")
        defaults.set(curve.hotTemperature, forKey: "profile.hotTemperature")
        defaults.set(autopilot.hysteresis, forKey: "profile.hysteresis")
        defaults.set(autopilot.cooldownDuration, forKey: "profile.cooldownDuration")
    }

    private func scheduleApply(for requestedMode: FanMode) {
        guard !isApplying else { return }
        Task { await applyTarget(for: requestedMode) }
    }

    @discardableResult
    private func applyTarget(for requestedMode: FanMode, isEngaging: Bool = false) async -> Bool {
        guard !isApplying, control.isReady, !snapshot.fans.isEmpty else { return false }
        isApplying = true
        defer { isApplying = false }

        let percentage: Double
        if requestedMode == .manual {
            percentage = manualPercent
        } else {
            guard let temperature = snapshot.temperature else { return false }
            percentage = autopilot.target(temperature: temperature, at: snapshot.capturedAt, curve: curve)
        }

        var targetChanged = false
        for fan in snapshot.fans {
            let target = fan.minimumRPM + Int(
                (Double(fan.maximumRPM - fan.minimumRPM) * percentage / 100).rounded()
            )
            switch await control.setTargetRPM(fan: fan.id, rpm: target) {
            case .success(let applied):
                targetChanged = targetChanged || targetRPMByFan[fan.id] != applied
                targetRPMByFan[fan.id] = applied
            case .failure(let error):
                // Nothing was handed over yet, so a rejected first attempt is
                // not a loss of control — it is worth retrying.
                if isEngaging, targetRPMByFan.isEmpty {
                    pendingFailure = error.localizedDescription
                    return false
                }
                requestSystemMode()
                mode = .system
                autopilot.reset(to: curve.minimumPercent)
                clearControlState()
                lastError = "Fan control returned to macOS: \(error.localizedDescription)"
                return false
            }
        }
        if appliedPercent == nil {
            log.notice("Fan control active in \(requestedMode.rawValue, privacy: .public) mode at \(Int(percentage), privacy: .public)%")
        }
        appliedPercent = percentage
        if targetChanged || lastTargetAppliedAt == nil {
            lastTargetAppliedAt = .now
        }
        if lastError != sensorErrorMessage { lastError = nil }
        control.sendHeartbeat()
        return true
    }

    /// Fan control never coasts: the autopilot needs fresh readings and the
    /// helper drops back to macOS without heartbeats, so only a System-mode
    /// monitor may be throttled, and only while nothing is on screen.
    private func shouldSample() -> Bool {
        guard let last = lastSampleAt else { return true }
        let elapsed = Date().timeIntervalSince(last)

        guard mode == .system else {
            return elapsed >= min(refreshInterval, controlInterval) - schedulingTolerance
        }
        if hiddenRefreshPolicy != .always, !isInterfaceVisible {
            if hiddenRefreshPolicy == .paused { return false }
            return elapsed >= max(slowInterval, refreshInterval) - schedulingTolerance
        }
        return elapsed >= refreshInterval - schedulingTolerance
    }

    /// Sensor errors track the current reading; control errors stay on screen
    /// until the user acts or control is working again, instead of being wiped
    /// by the next refresh two seconds later.
    private func updateSensorError() {
        if snapshot.temperature == nil && snapshot.fans.isEmpty {
            lastError = sensorErrorMessage
        } else if lastError == sensorErrorMessage {
            lastError = nil
        }
    }

    private func clearControlState() {
        targetRPMByFan.removeAll()
        lastTargetAppliedAt = nil
        appliedPercent = nil
    }

    private var snapshotIsSafeForAutomaticControl: Bool {
        guard let temperature = snapshot.temperature,
              temperature.isFinite,
              (0...120).contains(temperature),
              Date().timeIntervalSince(snapshot.capturedAt) < 6,
              !snapshot.fans.isEmpty else { return false }
        return snapshot.fans.allSatisfy {
            $0.minimumRPM > 0 && $0.maximumRPM >= $0.minimumRPM && $0.currentRPM >= 0
        }
    }

    private func observeSystemEvents() {
        // Workspace notifications and the app's own termination notice come
        // from different centres; both are removed again in stop().
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.prepareForSleep() }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.restoreAfterWake() }
        })
        workspaceObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.mode != .system { self.control.setSystemModeSynchronously() }
                self.stop()
            }
        })
    }

    private func prepareForSleep() {
        guard !isSleeping else { return }
        isSleeping = true
        suspendedMode = mode == .system ? nil : mode
        mode = .system
        autopilot.reset(to: curve.minimumPercent)
        clearControlState()
        Task {
            if case .failure(let error) = await control.setSystemMode() {
                lastError = "Could not confirm System mode before sleep: \(error.localizedDescription)"
            }
        }
    }

    private func restoreAfterWake() async {
        guard isSleeping else { return }
        isSleeping = false
        guard let requestedMode = suspendedMode else { return }
        suspendedMode = nil

        try? await Task.sleep(for: .seconds(2))
        snapshot = hardware.readSnapshot()
        await control.refreshStatus()
        guard control.isReady,
              requestedMode != .automatic || snapshotIsSafeForAutomaticControl else {
            lastError = "FanPilot stayed in System mode after wake because control could not be safely restored."
            return
        }

        if requestedMode == .automatic {
            autopilot.reset(to: curve.minimumPercent)
        }
        cancelPendingSwitch()
        if await applyTarget(for: requestedMode) {
            mode = requestedMode
        }
    }

    private func returnToSystem(reason: String) {
        log.notice("Returning to System mode: \(reason, privacy: .public)")
        mode = .system
        autopilot.reset(to: curve.minimumPercent)
        clearControlState()
        lastError = reason
        requestSystemMode()
        history.record(
            snapshot: snapshot,
            mode: .system,
            targetPercent: nil,
            thermalPressure: system.thermalPressure,
            eCoreMHz: system.eCoreMHz.map { Int($0.rounded()) },
            pCoreMHz: system.pCoreMHz.map { Int($0.rounded()) },
            force: true
        )
    }

    /// The helper can refuse or be unreachable; until it confirms, the app says
    /// so and keeps asking rather than assuming the fans are free.
    private func requestSystemMode() {
        awaitingSystemRestore = true
        Task {
            switch await control.setSystemMode() {
            case .success:
                awaitingSystemRestore = false
            case .failure(let error):
                lastError = "macOS has not confirmed it is back in control of the fans: \(error.localizedDescription)"
            }
        }
    }

    /// Invalidates the timer and drops the workspace observers. The app calls
    /// this on termination; tests call it so a monitor does not outlive them.
    func stop() {
        timer?.invalidate()
        timer = nil
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        workspaceObservers.removeAll()
    }

    private func loadProfileSettings() {
        if defaults.object(forKey: "profile.coolTemperature") != nil {
            curve.coolTemperature = defaults.double(forKey: "profile.coolTemperature")
        }
        if defaults.object(forKey: "profile.hotTemperature") != nil {
            curve.hotTemperature = defaults.double(forKey: "profile.hotTemperature")
        }
        if defaults.object(forKey: "profile.hysteresis") != nil {
            autopilot.hysteresis = defaults.double(forKey: "profile.hysteresis")
        }
        if defaults.object(forKey: "profile.cooldownDuration") != nil {
            autopilot.cooldownDuration = defaults.double(forKey: "profile.cooldownDuration")
        }
        if defaults.object(forKey: "monitor.refreshInterval") != nil {
            let stored = defaults.double(forKey: "monitor.refreshInterval")
            refreshInterval = Self.selectableRefreshIntervals
                .min { abs($0 - stored) < abs($1 - stored) } ?? 2
        }
        if let raw = defaults.string(forKey: "monitor.hiddenRefreshPolicy"),
           let policy = HiddenRefreshPolicy(rawValue: raw) {
            hiddenRefreshPolicy = policy
        }
    }
}

private struct UnavailableHardware: HardwareMonitoring {
    func readSnapshot() -> ThermalSnapshot { .unavailable }
}
