import AppKit
import Charts
import SwiftUI

struct FanMenuView: View {
    @Bindable var monitor: FanMonitor
    /// Only the menu bar popover offers to open the standalone window; inside
    /// that window the action would point at itself.
    var showsWindowAction = false
    @Environment(\.openWindow) private var openWindow
    @State private var hoveredRing: String?

    var body: some View {
        VStack(alignment: .leading, spacing: FPLayout.section) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("FanPilot").font(.title3.weight(.semibold))
                    HStack(spacing: 6) {
                        FPStatusDot(mode: monitor.mode, isAvailable: monitor.snapshot.temperature != nil || monitor.hasFanReadings)
                        Text(statusText)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                temperatureBadge
            }

            temperaturePanel
            systemPanel

            if monitor.snapshot.fans.isEmpty {
                FPPanel {
                    Label("Fan data unavailable", systemImage: "fanblades")
                        .font(.body.weight(.medium))
                    Text("This Mac did not expose fan sensors. Fan control is unavailable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                FPPanel {
                    ForEach(Array(monitor.snapshot.fans.enumerated()), id: \.element.id) { index, fan in
                        if index > 0 { Divider() }
                        fanRow(fan)
                    }
                }
            }

            if monitor.isFanControlAvailable {
                FPModePicker(
                    selection: monitor.mode,
                    pending: monitor.pendingMode
                ) { monitor.selectMode($0) }

                if monitor.mode == .manual {
                    FPPanel {
                        LabeledContent("Target speed") {
                            Text(monitor.targetRPM(forPercent: monitor.manualPercent)
                                    .map { "\($0.formatted()) RPM" } ?? "—")
                                .font(.body.weight(.semibold).monospacedDigit())
                        }
                        Slider(value: $monitor.manualPercent, in: 0...100, step: 1)
                            .onChange(of: monitor.manualPercent) { monitor.updateManualTarget() }
                        Text("\(Int(monitor.manualPercent))% of \(monitor.fanRangeText ?? "the firmware range") — 0% is the lowest speed the firmware allows, never a stopped fan.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if monitor.mode == .automatic {
                    FPPanel {
                        LabeledContent("Profile") { Text("Balanced") }
                        LabeledContent("Status") { Text(monitor.autoStatusText) }
                        LabeledContent("Calculated target") {
                            Text(monitor.targetRPM(forPercent: monitor.targetPercent)
                                    .map { "\($0.formatted()) RPM · \(Int(monitor.targetPercent))%" }
                                 ?? "\(Int(monitor.targetPercent))%")
                                .monospacedDigit()
                        }
                    }
                } else {
                    Label("macOS is managing cooling", systemImage: "checkmark.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if monitor.hasFanReadings {
                FPPanel {
                    LabeledContent("Cooling control") { Text("macOS") }
                    LabeledContent("Helper") { Text(monitor.control.statusText) }
                    Text(helperHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        switch monitor.control.recommendedAction {
                        case .enable:
                            Button("Enable Fan Control…") {
                                Task { await monitor.control.enable() }
                            }
                        case .reinstall:
                            Button("Reinstall Helper") {
                                Task { await monitor.control.reinstall() }
                            }
                            Button("Install Again") {
                                Task { await monitor.control.enable() }
                            }
                            .buttonStyle(.link)
                        case .none:
                            Button("Enable Fan Control…") {
                                Task { await monitor.control.enable() }
                            }
                            .disabled(true)
                        }
                    }
                    .disabled(monitor.control.state == .connecting)
                }
            } else {
                Label("macOS is managing cooling", systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = monitor.lastError, monitor.hasFanReadings {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                // SettingsLink opens the scene but, like any window an accessory
                // app opens from a popover, it lands behind the active app.
                SettingsLink { Label("Settings", systemImage: "gear") }
                    .simultaneousGesture(TapGesture().onEnded {
                        WindowPresenter.bringToFront(id: "com_apple_SwiftUI_Settings")
                    })
                Button {
                    openWindow(id: "history")
                    WindowPresenter.bringToFront(id: "history")
                } label: {
                    Label("History", systemImage: "chart.xyaxis.line")
                }
                if showsWindowAction {
                    Button {
                        if WindowPresenter.window(with: "main") == nil {
                            openWindow(id: "main")
                        }
                        WindowPresenter.bringToFront(id: "main")
                    } label: {
                        Label("Window", systemImage: "macwindow")
                    }
                    .help("Open FanPilot in a standalone window")
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.plain)
        }
        .padding(FPLayout.outer)
    }

    // `history` is a let on the monitor, so key-path bindings cannot reach
    // through it; these forward to the store directly.
    private var recordingBinding: Binding<Bool> {
        Binding(get: { monitor.history.isRecording }, set: { monitor.history.isRecording = $0 })
    }

    private var systemPanel: some View {
        FPPanel {
            HStack(alignment: .top, spacing: 4) {
                FPRing(title: "CPU", value: monitor.system.cpuUsage, caption: cpuCaption) {
                    hoveredRing = $0 ? "CPU" : nil
                }
                FPRing(title: "RAM", value: monitor.system.memoryUsage, caption: memoryCaption) {
                    hoveredRing = $0 ? "RAM" : nil
                }
                if let gpu = monitor.system.gpuUsage {
                    FPRing(title: "GPU", value: gpu, caption: "shared") {
                        hoveredRing = $0 ? "GPU" : nil
                    }
                }
                FPRing(title: "Disk", value: monitor.system.diskUsage, caption: diskCaption) {
                    hoveredRing = $0 ? "Disk" : nil
                }
                FPRing(
                    title: "Net",
                    value: networkFill,
                    caption: networkUnit,
                    valueText: networkAmount,
                    meaning: .activity
                ) { hoveredRing = $0 ? "Net" : nil }
            }
            // A single detail line beats five tooltips: no hover delay, no
            // popovers covering the rings, and the row height never jumps.
            Text(ringDetail)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.12), value: hoveredRing)
        }
    }

    private var ringDetail: String {
        let system = monitor.system
        switch hoveredRing {
        case "CPU":
            guard let performance = system.pCoreMHz, let ceiling = system.pCoreMaxMHz, ceiling > 0 else {
                return "\(ProcessInfo.processInfo.activeProcessorCount) cores, \(Int(system.cpuUsage * 100))% busy"
            }
            let efficiency = system.eCoreMHz.map { String(format: " · E-cores %.2f GHz", $0 / 1000) } ?? ""
            return String(format: "P-cores %.2f of %.2f GHz", performance / 1000, ceiling / 1000) + efficiency
        case "RAM":
            let swap = system.swapUsedBytes > 0
                ? " · swap \(compactBytes(Int64(system.swapUsedBytes), binary: true))"
                : ""
            return "\(compactBytes(Int64(system.memoryUsedBytes), binary: true)) used of \(compactBytes(Int64(system.memoryTotalBytes), binary: true))" + swap
        case "GPU":
            return "\(Int((system.gpuUsage ?? 0) * 100))% device utilisation"
        case "Disk":
            let used = max(system.diskTotalBytes - system.diskFreeBytes, 0)
            return "\(compactBytes(used)) used of \(compactBytes(system.diskTotalBytes)) · \(compactBytes(system.diskFreeBytes)) free"
        case "Net":
            return "\(compactBytes(Int64(system.networkBytesPerMinute))) in the last minute · busiest \(compactBytes(Int64(system.networkPeakBytesPerMinute)))"
        default:
            return "Point at a ring for details"
        }
    }

    // Captions share a narrow column, so each one carries a single number and
    // the ring itself carries the proportion.
    private var memoryCaption: String {
        "\(compactBytes(Int64(monitor.system.memoryUsedBytes), binary: true)) used"
    }

    /// One value, at most one decimal, unit picked so it always fits the column.
    /// Memory is counted in binary units the way macOS reports it (24 GB of RAM
    /// is 25.77 decimal GB); storage and traffic stay decimal, like Finder.
    private func compactBytes(_ bytes: Int64, binary: Bool = false) -> String {
        let step: Double = binary ? 1024 : 1000
        let units: [(threshold: Double, suffix: String)] = [
            (pow(step, 4), "TB"), (pow(step, 3), "GB"), (pow(step, 2), "MB"), (step, "KB")
        ]
        let value = Double(max(bytes, 0))
        for unit in units where value >= unit.threshold {
            let scaled = value / unit.threshold
            return scaled >= 10
                ? String(format: "%.0f %@", scaled, unit.suffix)
                : String(format: "%.1f %@", scaled, unit.suffix)
        }
        return "\(Int(value)) B"
    }

    private var cpuCaption: String {
        guard let megahertz = monitor.system.pCoreMHz, megahertz > 0 else {
            return "\(ProcessInfo.processInfo.activeProcessorCount) cores"
        }
        return String(format: "%.2f GHz", megahertz / 1000)
    }

    private var diskCaption: String {
        "\(compactBytes(monitor.system.diskFreeBytes)) free"
    }

    // Throughput has no percentage to report, so the ring shows the figure
    // itself and the caption carries the unit.
    private var networkAmount: String {
        compactBytes(Int64(monitor.system.networkBytesPerMinute))
            .split(separator: " ").first.map(String.init) ?? "0"
    }

    private var networkUnit: String {
        let unit = compactBytes(Int64(monitor.system.networkBytesPerMinute))
            .split(separator: " ").last.map(String.init) ?? "B"
        return "\(unit) / min"
    }

    /// Traffic has no ceiling, so the ring is filled against the busiest minute
    /// seen so far — a relative sense of activity, never an alarm.
    private var networkFill: Double {
        let peak = max(monitor.system.networkPeakBytesPerMinute, 5 * 1024 * 1024)
        return min(Double(monitor.system.networkBytesPerMinute) / Double(peak), 1)
    }

    private var temperaturePanel: some View {
        FPPanel {
            HStack(spacing: 8) {
                Text("Temperature").font(.caption.weight(.medium))
                Spacer()
                Text(trendSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Toggle("Record history", isOn: recordingBinding)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help(monitor.history.isRecording
                          ? "Recording every \(monitor.history.intervalTitle)"
                          : "History recording is paused")
            }
            trendChart
        }
    }

    @ViewBuilder
    private var trendChart: some View {
        let samples = monitor.history.recentSamples(limit: 90).filter { $0.temperature != nil }
        if samples.count < 2 {
            Text(monitor.history.isRecording
                 ? "Collecting temperature history…"
                 : "Recording is paused.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        } else {
            let domain = trendDomain(for: samples)
            Chart(samples) { sample in
                if let temperature = sample.temperature {
                    AreaMark(
                        x: .value("Time", sample.capturedAt),
                        yStart: .value("Floor", domain.lowerBound),
                        yEnd: .value("Temperature", temperature)
                    )
                    .foregroundStyle(.linearGradient(
                        colors: [trendColor.opacity(0.30), trendColor.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    LineMark(
                        x: .value("Time", sample.capturedAt),
                        y: .value("Temperature", temperature)
                    )
                    .foregroundStyle(trendColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.catmullRom)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: domain)
            .frame(height: 46)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Temperature trend, \(trendSummary)")
        }
    }

    private func trendDomain(for samples: [HistorySample]) -> ClosedRange<Double> {
        let values = samples.compactMap(\.temperature)
        let lowest = (values.min() ?? 30) - 1
        let highest = (values.max() ?? 60) + 1
        // A flat line should read as flat, not as amplified noise.
        return lowest...max(highest, lowest + 6)
    }

    private var trendColor: Color {
        switch FPThermalLevel(temperature: monitor.snapshot.temperature) {
        case .critical: .red
        case .attention: .orange
        default: .accentColor
        }
    }

    private var trendSummary: String {
        guard monitor.history.isRecording else { return "Paused" }
        let values = monitor.history.recentSamples(limit: 90).compactMap(\.temperature)
        guard let low = values.min(), let high = values.max() else { return "—" }
        return "\(Int(low.rounded()))–\(Int(high.rounded()))°"
    }

    private var helperHint: String {
        switch monitor.control.recommendedAction {
        case .enable: "Fan control will be available after the privileged helper is installed."
        case .reinstall: "The helper is installed but unreachable — reinstalling restarts it. This is expected after rebuilding the app."
        case .none: "Fan control will be available after the privileged helper is installed."
        }
    }

    private var statusText: String {
        if monitor.snapshot.temperature == nil && !monitor.hasFanReadings {
            return "Monitoring unavailable"
        }
        return monitor.mode == .system ? "Managed by macOS" : "Mode: \(monitor.mode.rawValue)"
    }

    private var temperatureBadge: some View {
        let level = FPThermalLevel(temperature: monitor.snapshot.temperature)
        return Text(monitor.snapshot.temperature.map { "\(Int($0))°C" } ?? "—")
            .font(.title2.weight(.semibold).monospacedDigit())
            .foregroundStyle(level.color)
            .accessibilityLabel(monitor.snapshot.temperature.map { "Temperature, \(Int($0)) degrees Celsius" } ?? "Temperature unavailable")
    }

    private func fanRow(_ fan: FanReading) -> some View {
        VStack(spacing: 6) {
            HStack {
                Label(fan.name, systemImage: "fanblades")
                    .font(.body.weight(.medium))
                Spacer()
                Text("\(fan.currentRPM)")
                    .font(.body.weight(.semibold).monospacedDigit())
                Text("RPM").font(.caption).foregroundStyle(.secondary)
            }
            ProgressView(value: fanProgress(fan))
                .progressViewStyle(.linear)
            HStack {
                Text("\(fan.minimumRPM)")
                Spacer()
                Text("\(fan.maximumRPM)")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(fan.name), \(fan.currentRPM) revolutions per minute")
    }

    private func fanProgress(_ fan: FanReading) -> Double {
        let range = max(fan.maximumRPM - fan.minimumRPM, 1)
        return min(max(Double(fan.currentRPM - fan.minimumRPM) / Double(range), 0), 1)
    }
}

struct SettingsView: View {
    @Bindable var monitor: FanMonitor

    private var recordingBinding: Binding<Bool> {
        Binding(get: { monitor.history.isRecording }, set: { monitor.history.isRecording = $0 })
    }

    private var intervalBinding: Binding<TimeInterval> {
        Binding(get: { monitor.history.sampleInterval }, set: { monitor.history.sampleInterval = $0 })
    }

    var body: some View {
        Form {
            Section("Temperature curve") {
                AutopilotTuningControls(monitor: monitor)
            }
            Section("Monitoring") {
                Picker("Refresh every", selection: $monitor.refreshInterval) {
                    ForEach(FanMonitor.selectableRefreshIntervals, id: \.self) { interval in
                        Text("\(Int(interval)) sec").tag(interval)
                    }
                }
                Picker("When hidden", selection: $monitor.hiddenRefreshPolicy) {
                    ForEach(FanMonitor.HiddenRefreshPolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                Text("Both apply only while macOS is managing cooling. In Auto or Manual mode FanPilot refreshes at least every two seconds, because the helper returns the fans to macOS without a heartbeat. History cannot be finer than the refresh interval.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("History") {
                Toggle("Record history", isOn: recordingBinding)
                Picker("Write every", selection: intervalBinding) {
                    ForEach(HistoryStore.selectableIntervals, id: \.self) { interval in
                        Text(interval < 60 ? "\(Int(interval)) sec" : "\(Int(interval / 60)) min")
                            .tag(interval)
                    }
                }
                .disabled(!monitor.history.isRecording)
                LabeledContent("Stored samples", value: "\(monitor.history.samples.count)")
            }
            Section("Safety") {
                Text("Fan control always returns to macOS when FanPilot quits.")
                    .foregroundStyle(.secondary)
            }
            Section("Fan control helper") {
                LabeledContent("Status", value: monitor.control.statusText)
                HStack {
                    if !monitor.control.isReady {
                        Button("Enable Fan Control…") {
                            Task { await monitor.control.enable() }
                        }
                    }
                    Button("Reinstall Helper") {
                        Task { await monitor.control.reinstall() }
                    }
                    .help("Unregisters and registers the daemon again, so a rebuilt helper is picked up")
                }
                .disabled(monitor.control.state == .connecting)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
