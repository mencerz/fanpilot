import Foundation

enum FanMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case system = "System"
    case automatic = "Auto"
    case manual = "Manual"

    var id: Self { self }
}

struct FanReading: Identifiable, Equatable {
    let id: Int
    let name: String
    let currentRPM: Int
    let minimumRPM: Int
    let maximumRPM: Int
}

struct ThermalSnapshot: Equatable {
    var temperature: Double?
    var fans: [FanReading]
    var capturedAt: Date

    static let unavailable = ThermalSnapshot(
        temperature: nil,
        fans: [],
        capturedAt: .now
    )
}

struct FanCurve: Equatable {
    var coolTemperature: Double = 45
    var hotTemperature: Double = 80
    var minimumPercent: Double = 25
    var maximumPercent: Double = 100

    func percentage(at temperature: Double) -> Double {
        guard hotTemperature > coolTemperature else { return maximumPercent }
        let progress = (temperature - coolTemperature) / (hotTemperature - coolTemperature)
        return min(max(minimumPercent + progress * (maximumPercent - minimumPercent), minimumPercent), maximumPercent)
    }
}

struct ThermalAutopilot: Equatable {
    enum Phase: String, Equatable {
        case monitoring = "Monitoring"
        case cooling = "Cooling"
        case cooldown = "Cooldown"
    }

    var hysteresis: Double = 3
    var cooldownDuration: TimeInterval = 60
    var rampUpPerSecond: Double = 40
    var rampDownPerSecond: Double = 2.5
    var predictionSeconds: TimeInterval = 12

    private(set) var phase: Phase = .monitoring
    private(set) var currentPercent: Double = 25
    private(set) var predictedTemperature: Double?

    private var isActive = false
    private var lastTemperature: Double?
    private var lastSampleDate: Date?
    private var lastDemandDate: Date?

    mutating func target(temperature: Double, at now: Date, curve: FanCurve) -> Double {
        let elapsed = lastSampleDate.map { min(max(now.timeIntervalSince($0), 0.1), 10) } ?? 2
        let riseRate = lastTemperature.map { max(0, min((temperature - $0) / elapsed, 1.5)) } ?? 0
        let predicted = min(temperature + riseRate * predictionSeconds, curve.hotTemperature)
        predictedTemperature = predicted

        if predicted >= curve.coolTemperature {
            isActive = true
            phase = .cooling
            lastDemandDate = now
        } else if isActive {
            let cooldownElapsed = lastDemandDate.map { now.timeIntervalSince($0) } ?? cooldownDuration
            if cooldownElapsed < cooldownDuration {
                phase = .cooldown
            } else if predicted <= curve.coolTemperature - hysteresis {
                isActive = false
                phase = .monitoring
            } else {
                phase = .cooling
            }
        } else {
            phase = .monitoring
        }

        var requested = isActive ? curve.percentage(at: predicted) : curve.minimumPercent
        if phase == .cooldown {
            requested = max(requested, currentPercent)
        }

        let limit = requested >= currentPercent
            ? rampUpPerSecond * elapsed
            : rampDownPerSecond * elapsed
        if requested > currentPercent {
            currentPercent = min(requested, currentPercent + limit)
        } else {
            currentPercent = max(requested, currentPercent - limit)
        }
        currentPercent = min(max(currentPercent, curve.minimumPercent), curve.maximumPercent)
        lastTemperature = temperature
        lastSampleDate = now
        return currentPercent
    }

    mutating func reset(to minimumPercent: Double) {
        phase = .monitoring
        currentPercent = minimumPercent
        predictedTemperature = nil
        isActive = false
        lastTemperature = nil
        lastSampleDate = nil
        lastDemandDate = nil
    }
}
