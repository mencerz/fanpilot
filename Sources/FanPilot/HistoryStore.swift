import Foundation
import Observation
import FanPilotShared

struct HistorySample: Codable, Equatable, Identifiable, Sendable {
    let capturedAt: Date
    let temperature: Double?
    let fanRPM: [Int]
    let targetPercent: Double?
    let mode: FanMode
    /// Optional so histories written before thermal pressure was recorded
    /// still decode.
    var thermalPressure: ThermalPressure?
    var eCoreMHz: Int?
    var pCoreMHz: Int?

    var id: Date { capturedAt }
}

@MainActor
@Observable
final class HistoryStore {
    static let selectableIntervals: [TimeInterval] = [5, 10, 30, 60, 300]

    private(set) var samples: [HistorySample] = []
    private(set) var storageError: String?

    var isRecording = true {
        didSet {
            // Assignments in init run in initialization phase two, where
            // observers already fire. Without this guard, restoring a stored
            // "paused" value would persist the still-empty sample list over the
            // history file before it was ever read.
            guard isLoaded, isRecording != oldValue else { return }
            defaults.set(isRecording, forKey: Keys.isRecording)
            // Pausing should not lose what was collected since the last write.
            if !isRecording { persist() }
        }
    }

    var sampleInterval: TimeInterval = 10 {
        didSet {
            guard isLoaded, sampleInterval != oldValue else { return }
            defaults.set(sampleInterval, forKey: Keys.sampleInterval)
        }
    }

    private let storageURL: URL
    private let defaults: UserDefaults
    private var isLoaded = false
    private let retention: TimeInterval = 7 * 24 * 60 * 60
    private let persistenceInterval: TimeInterval = 60
    private var lastPersistUptime: TimeInterval?
    /// Wall clock can jump; the recording cadence is measured against uptime so
    /// a backwards correction cannot silently stop recording.
    private var lastRecordUptime: TimeInterval?
    private let maximumSamples = 120_000
    private let persistQueue = DispatchQueue(label: "\(fanPilotAppIdentifier).history", qos: .utility)

    private enum Keys {
        static let isRecording = "history.isRecording"
        static let sampleInterval = "history.sampleInterval"
    }

    init(storageURL: URL? = nil, defaults: UserDefaults = .standard) {
        self.storageURL = storageURL ?? Self.defaultStorageURL
        self.defaults = defaults
        if defaults.object(forKey: Keys.isRecording) != nil {
            isRecording = defaults.bool(forKey: Keys.isRecording)
        }
        if defaults.object(forKey: Keys.sampleInterval) != nil {
            sampleInterval = Self.nearestSelectableInterval(to: defaults.double(forKey: Keys.sampleInterval))
        }
        load()
        isLoaded = true
    }

    var intervalTitle: String {
        sampleInterval < 60
            ? "\(Int(sampleInterval)) sec"
            : "\(Int(sampleInterval / 60)) min"
    }

    private static func nearestSelectableInterval(to value: TimeInterval) -> TimeInterval {
        selectableIntervals.min { abs($0 - value) < abs($1 - value) } ?? 10
    }

    func record(
        snapshot: ThermalSnapshot,
        mode: FanMode,
        targetPercent: Double?,
        thermalPressure: ThermalPressure? = nil,
        eCoreMHz: Int? = nil,
        pCoreMHz: Int? = nil,
        force: Bool = false
    ) {
        guard isRecording else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        if !force, let last = lastRecordUptime, uptime - last < sampleInterval { return }
        lastRecordUptime = uptime

        let sample = HistorySample(
            capturedAt: snapshot.capturedAt,
            temperature: snapshot.temperature,
            fanRPM: snapshot.fans.map(\.currentRPM),
            targetPercent: targetPercent,
            mode: mode,
            thermalPressure: thermalPressure,
            eCoreMHz: eCoreMHz,
            pCoreMHz: pCoreMHz
        )
        // A forced record can land on the same timestamp as the periodic one;
        // two samples sharing an id make SwiftUI charts drop or duplicate marks.
        if samples.last?.capturedAt == sample.capturedAt {
            samples[samples.count - 1] = sample
        } else {
            samples.append(sample)
        }
        prune(relativeTo: snapshot.capturedAt)

        // Uptime again, not wall clock: after a backward correction a date
        // based comparison stays negative and nothing would ever be written.
        if force || lastPersistUptime.map({ uptime - $0 >= persistenceInterval }) != false {
            persist()
            lastPersistUptime = uptime
        }
    }

    func samples(since date: Date) -> [HistorySample] {
        samples.filter { $0.capturedAt >= date }
    }

    /// Tail scan for the popover sparkline: it redraws every two seconds and
    /// must not walk a week of samples to do it.
    func recentSamples(limit: Int, maximumAge: TimeInterval = 6 * 60 * 60) -> [HistorySample] {
        let cutoff = Date().addingTimeInterval(-maximumAge)
        return samples.suffix(limit).filter { $0.capturedAt >= cutoff }
    }

    func clear() {
        samples.removeAll()
        persist()
    }

    /// Encoding a week of samples and writing them out takes long enough to
    /// stutter the interface, so it happens off the main actor.
    func persist() {
        let snapshot = samples
        let url = storageURL
        persistQueue.async { [weak self] in
            var failure: String?
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try JSONEncoder.fanPilot.encode(snapshot).write(to: url, options: .atomic)
            } catch {
                failure = "History could not be saved: \(error.localizedDescription)"
            }
            Task { @MainActor in self?.storageError = failure }
        }
    }

    /// Waits for any queued write. Used by tests and before reading the file back.
    func flush() {
        persistQueue.sync {}
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            samples = try JSONDecoder.fanPilot.decode(
                [HistorySample].self,
                from: Data(contentsOf: storageURL)
            )
            prune(relativeTo: .now)
        } catch {
            // The next record() would persist over the unreadable file and take
            // the week with it, so it is moved aside instead.
            let quarantine = storageURL.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: quarantine)
            try? FileManager.default.moveItem(at: storageURL, to: quarantine)
            storageError = "History could not be read and was kept as \(quarantine.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func prune(relativeTo date: Date) {
        // Measured from the newest sample as well as from now: if the clock is
        // set back, the stored samples are "in the future" and pruning against
        // the wrong now would discard them.
        let reference = max(date, samples.last?.capturedAt ?? date)
        samples.removeAll { $0.capturedAt < reference.addingTimeInterval(-retention) }
        if samples.count > maximumSamples {
            samples.removeFirst(samples.count - maximumSamples)
        }
    }

    private static var defaultStorageURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("FanPilot", isDirectory: true)
            .appendingPathComponent("history.json")
    }
}

private extension JSONEncoder {
    static var fanPilot: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }
}

private extension JSONDecoder {
    static var fanPilot: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
