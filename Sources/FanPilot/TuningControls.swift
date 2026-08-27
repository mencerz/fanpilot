import SwiftUI

/// Shared by Settings and the History window so the two cannot drift apart,
/// and so each control explains itself in one place.
struct AutopilotTuningControls: View {
    @Bindable var monitor: FanMonitor

    var body: some View {
        Group {
            LabeledContent("Ramp-up starts", value: "\(Int(monitor.curve.coolTemperature))°C")
            Slider(value: $monitor.curve.coolTemperature, in: 35...65, step: 1)
                .onChange(of: monitor.curve.coolTemperature) { monitor.saveProfileSettings() }
                .help("Below this temperature the fan stays at its minimum speed.")

            LabeledContent("Maximum speed", value: "\(Int(monitor.curve.hotTemperature))°C")
            Slider(value: $monitor.curve.hotTemperature, in: 65...95, step: 1)
                .onChange(of: monitor.curve.hotTemperature) { monitor.saveProfileSettings() }
                .help("At this temperature the fan is driven at 100%.")

            LabeledContent("Hysteresis", value: "\(Int(monitor.autopilot.hysteresis))°C")
            Slider(value: $monitor.autopilot.hysteresis, in: 1...8, step: 1)
                .onChange(of: monitor.autopilot.hysteresis) { monitor.saveProfileSettings() }
                .help(hysteresisExplanation)
            Text(hysteresisExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Cooldown", value: "\(Int(monitor.autopilot.cooldownDuration)) sec")
            Slider(value: $monitor.autopilot.cooldownDuration, in: 30...180, step: 15)
                .onChange(of: monitor.autopilot.cooldownDuration) { monitor.saveProfileSettings() }
                .help("Elevated fan speed is held this long after the temperature falls.")
        }
    }

    private var hysteresisExplanation: String {
        let calmDown = Int(monitor.curve.coolTemperature - monitor.autopilot.hysteresis)
        return "The gap between speeding up and calming down: the fan ramps up at "
            + "\(Int(monitor.curve.coolTemperature))°C but only settles back below \(calmDown)°C, "
            + "so it cannot oscillate around a single threshold."
    }
}
