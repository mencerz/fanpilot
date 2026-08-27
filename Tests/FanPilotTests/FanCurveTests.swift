import Foundation
import Testing
@testable import FanPilot

@Test func fanCurveClampsAndInterpolates() {
    let curve = FanCurve(coolTemperature: 40, hotTemperature: 80, minimumPercent: 20, maximumPercent: 100)
    #expect(curve.percentage(at: 20) == 20)
    #expect(curve.percentage(at: 60) == 60)
    #expect(curve.percentage(at: 100) == 100)
}

@Test func autopilotPredictsARisingTemperature() {
    let curve = FanCurve(coolTemperature: 45, hotTemperature: 80, minimumPercent: 25, maximumPercent: 100)
    var autopilot = ThermalAutopilot()
    let start = Date(timeIntervalSince1970: 1_000)

    #expect(autopilot.target(temperature: 40, at: start, curve: curve) == 25)
    let target = autopilot.target(temperature: 44, at: start.addingTimeInterval(2), curve: curve)

    #expect(autopilot.phase == .cooling)
    #expect(autopilot.predictedTemperature == 62)
    #expect(target > curve.minimumPercent)
}

@Test func autopilotHoldsSpeedDuringCooldownThenRampsDown() {
    let curve = FanCurve(coolTemperature: 45, hotTemperature: 80, minimumPercent: 25, maximumPercent: 100)
    var autopilot = ThermalAutopilot()
    autopilot.cooldownDuration = 60
    let start = Date(timeIntervalSince1970: 2_000)

    let hotTarget = autopilot.target(temperature: 80, at: start, curve: curve)
    let cooldownTarget = autopilot.target(temperature: 40, at: start.addingTimeInterval(30), curve: curve)
    let laterTarget = autopilot.target(temperature: 40, at: start.addingTimeInterval(70), curve: curve)

    #expect(hotTarget == 100)
    #expect(cooldownTarget == hotTarget)
    #expect(autopilot.phase == .monitoring)
    #expect(laterTarget < cooldownTarget)
    #expect(laterTarget >= curve.minimumPercent)
}
