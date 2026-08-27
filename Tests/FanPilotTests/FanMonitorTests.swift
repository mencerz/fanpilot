import Foundation
import Testing
@testable import FanPilot

private final class StubHardware: HardwareMonitoring, @unchecked Sendable {
    var snapshot: ThermalSnapshot

    init(snapshot: ThermalSnapshot) { self.snapshot = snapshot }
    func readSnapshot() -> ThermalSnapshot { snapshot }
}

@MainActor
private func makeMonitor(_ hardware: StubHardware) -> (FanMonitor, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("FanPilotTests-\(UUID().uuidString)", isDirectory: true)
    let defaults = isolatedDefaults()
    let monitor = FanMonitor(
        hardware: hardware,
        history: HistoryStore(storageURL: directory.appendingPathComponent("history.json"), defaults: defaults),
        defaults: defaults
    )
    return (monitor, directory)
}

private func healthySnapshot(temperature: Double = 55) -> ThermalSnapshot {
    ThermalSnapshot(
        temperature: temperature,
        fans: [FanReading(id: 0, name: "Fan", currentRPM: 2_400, minimumRPM: 2_317, maximumRPM: 6_550)],
        capturedAt: .now
    )
}

@Test @MainActor
func monitorRefusesFanControlWithoutHelper() {
    let (monitor, directory) = makeMonitor(StubHardware(snapshot: healthySnapshot()))
    defer {
        monitor.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    monitor.selectMode(.manual)

    #expect(monitor.mode == .system)
    #expect(monitor.lastError != nil)
    #expect(monitor.appliedPercent == nil)
}

@Test @MainActor
func sensorErrorClearsOnceReadingsReturnButSurvivesEachRefresh() {
    let hardware = StubHardware(snapshot: ThermalSnapshot(temperature: nil, fans: [], capturedAt: .now))
    let (monitor, directory) = makeMonitor(hardware)
    defer {
        monitor.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    #expect(monitor.lastError != nil)
    monitor.refresh(force: true)
    #expect(monitor.lastError != nil)

    hardware.snapshot = healthySnapshot()
    monitor.refresh(force: true)
    #expect(monitor.lastError == nil)
}

@Test
func systemMetricsStayWithinPlausibleRanges() async throws {
    let reader = SystemMetricsReader()
    _ = reader.read() // primes the CPU tick delta and starts the disk read
    var metrics = reader.read()

    // Free space is measured off the main thread, so it lands a moment later.
    for _ in 0..<20 where metrics.diskFreeBytes == 0 {
        try await Task.sleep(for: .milliseconds(100))
        metrics = reader.read()
    }

    #expect(metrics.memoryTotalBytes > 0)
    #expect(metrics.memoryUsedBytes > 0)
    #expect(metrics.memoryUsedBytes < metrics.memoryTotalBytes)
    #expect((0...1).contains(metrics.memoryUsage))
    #expect((0...1).contains(metrics.cpuUsage))
    #expect((0...1).contains(metrics.diskUsage))
    #expect(metrics.diskFreeBytes > 0)
    if let gpu = metrics.gpuUsage { #expect((0...1).contains(gpu)) }
}

@Test @MainActor
func pausedPolicyStopsSamplingWhileNothingIsOnScreen() {
    let hardware = StubHardware(snapshot: healthySnapshot(temperature: 55))
    let (monitor, directory) = makeMonitor(hardware)
    defer {
        monitor.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    monitor.hiddenRefreshPolicy = .paused
    hardware.snapshot = healthySnapshot(temperature: 91)
    monitor.refresh()
    #expect(monitor.snapshot.temperature == 55)

    // Opening the popover has to produce fresh data immediately.
    monitor.setPopoverVisible(true)
    #expect(monitor.snapshot.temperature == 91)
}

@Test @MainActor
func refreshIntervalThrottlesSampling() {
    let hardware = StubHardware(snapshot: healthySnapshot(temperature: 55))
    let (monitor, directory) = makeMonitor(hardware)
    defer {
        monitor.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    monitor.refreshInterval = 30
    hardware.snapshot = healthySnapshot(temperature: 91)
    monitor.refresh()
    #expect(monitor.snapshot.temperature == 55)

    monitor.refresh(force: true)
    #expect(monitor.snapshot.temperature == 91)
}

@Test @MainActor
func systemModeIsAlwaysReachableWhileASwitchIsPending() {
    let (monitor, directory) = makeMonitor(StubHardware(snapshot: healthySnapshot()))
    defer {
        monitor.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    // Without a helper the switch is refused outright, but the escape hatch
    // back to System must never be blocked by a pending request.
    monitor.selectMode(.manual)
    monitor.selectMode(.system)

    #expect(monitor.mode == .system)
    #expect(monitor.pendingMode == nil)
}

// IOReport is unexported API. Where it is missing the test is skipped rather
// than silently passing, so a real regression cannot hide behind an early exit.
@Test(.enabled(if: CPUFrequencyReader() != nil))
func cpuFrequencyMatchesTheHardwareCeiling() async throws {
    let reader = try #require(CPUFrequencyReader())
    _ = reader.read() // the first sample only primes the delta
    try await Task.sleep(for: .milliseconds(300))
    let clusters = reader.read()

    let performance = try #require(clusters.first { $0.name == "PCPU" })
    #expect(performance.maximumMegahertz > 1_000)
    #expect(performance.megahertz > 0)
    #expect(performance.megahertz <= performance.maximumMegahertz)
    #expect((0...1).contains(performance.loadRatio))
}
