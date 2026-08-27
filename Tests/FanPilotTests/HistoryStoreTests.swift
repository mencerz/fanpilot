import Foundation
import Testing
@testable import FanPilot

/// Tests must never write into the domain the app or another test run reads.
func isolatedDefaults() -> UserDefaults {
    UserDefaults(suiteName: "FanPilotTests-\(UUID().uuidString)") ?? .standard
}

@Test @MainActor
func historyCoalescesPersistsAndReloadsSamples() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("FanPilotTests-\(UUID().uuidString)", isDirectory: true)
    let url = directory.appendingPathComponent("history.json")
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = HistoryStore(storageURL: url, defaults: isolatedDefaults())
    let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 100)
    let fan = FanReading(id: 0, name: "Fan", currentRPM: 2_500, minimumRPM: 2_000, maximumRPM: 6_000)

    store.record(
        snapshot: ThermalSnapshot(temperature: 55, fans: [fan], capturedAt: start),
        mode: .automatic,
        targetPercent: 50
    )
    store.record(
        snapshot: ThermalSnapshot(temperature: 56, fans: [fan], capturedAt: start.addingTimeInterval(5)),
        mode: .automatic,
        targetPercent: 52
    )
    store.record(
        snapshot: ThermalSnapshot(temperature: 57, fans: [fan], capturedAt: start.addingTimeInterval(11)),
        mode: .automatic,
        targetPercent: 54,
        force: true
    )

    #expect(store.samples.count == 2)
    let reloaded = HistoryStore(storageURL: url, defaults: isolatedDefaults())
    #expect(reloaded.samples == store.samples)
}

@Test @MainActor
func historyWrittenBeforeThermalPressureStillDecodes() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("FanPilotTests-\(UUID().uuidString)", isDirectory: true)
    let url = directory.appendingPathComponent("history.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    // Exactly what earlier builds wrote: no thermalPressure key at all.
    let legacy = """
    [{"capturedAt":\(Date().timeIntervalSince1970 - 30),"temperature":55.5,"fanRPM":[2500],"mode":"System"}]
    """
    try Data(legacy.utf8).write(to: url)

    // A stored "paused" flag must not let init persist over the file it is
    // about to read.
    let defaults = isolatedDefaults()
    defaults.set(false, forKey: "history.isRecording")
    let store = HistoryStore(storageURL: url, defaults: defaults)
    #expect(store.samples.count == 1)
    #expect(store.samples.first?.thermalPressure == nil)
    #expect(store.storageError == nil)
}

@Test @MainActor
func pausedRecordingKeepsHistoryUntouched() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("FanPilotTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = HistoryStore(
        storageURL: directory.appendingPathComponent("history.json"),
        defaults: isolatedDefaults()
    )
    store.isRecording = false
    store.record(
        snapshot: ThermalSnapshot(temperature: 55, fans: [], capturedAt: .now),
        mode: .system,
        targetPercent: nil,
        force: true
    )
    #expect(store.samples.isEmpty)
}
