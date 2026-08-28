import Charts
import SwiftUI

struct HistoryView: View {
    @Bindable var monitor: FanMonitor
    @State private var range: HistoryRange = .oneHour
    @State private var confirmsClear = false
    /// One cursor drives both charts, so the temperature and the fan reading
    /// under the pointer always belong to the same moment.
    @State private var hoveredDate: Date?

    var body: some View {
        let samples = monitor.history.samples(since: Date().addingTimeInterval(-range.duration))
        let hovered = hoveredDate.flatMap { nearestSample(to: $0, in: samples) }

        let timeline = timeline(for: samples)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                diagnostics
                charts(samples: samples, hovered: hovered, timeline: timeline)
                tuning
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(
            "Clear all locally stored history?",
            isPresented: $confirmsClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) { monitor.history.clear() }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("History & Diagnostics")
                    .font(.title2.weight(.semibold))
                Text("Stored locally on this Mac for seven days")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Range", selection: $range) {
                ForEach(HistoryRange.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 320)
        }
    }

    private var diagnostics: some View {
        FPPanel {
            Text("Live Diagnostics")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                diagnosticRow("Sensors", sensorDiagnostic)
                diagnosticRow("Fan response", fanResponseDiagnostic)
                diagnosticRow("Control helper", monitor.control.statusText)
                diagnosticRow("Active controller", monitor.mode == .system ? "macOS" : "FanPilot · \(monitor.mode.rawValue)")
                diagnosticRow("Recording", monitor.history.isRecording ? "Every \(monitor.history.intervalTitle)" : "Paused")
                diagnosticRow("Thermal pressure", monitor.system.thermalPressure.title)
            }
            if let storageError = monitor.history.storageError {
                Label(storageError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Every chart is pinned to this, because each one otherwise derives its
    /// own scale from its own marks: frequency data starts a sample later than
    /// temperature, the fan series can be absent entirely, and the pressure
    /// bands extend past the final sample on two charts out of three. The
    /// cursors would then sit at the same instant but at different x positions.
    private func timeline(for samples: [HistorySample]) -> ClosedRange<Date> {
        guard let first = samples.first?.capturedAt, let last = samples.last?.capturedAt else {
            let now = Date()
            return now.addingTimeInterval(-60)...now
        }
        return first...last.addingTimeInterval(bandPadding)
    }

    private var bandPadding: TimeInterval { max(monitor.history.sampleInterval, 5) }

    @ViewBuilder
    private func charts(
        samples: [HistorySample],
        hovered: HistorySample?,
        timeline: ClosedRange<Date>
    ) -> some View {
        if samples.isEmpty {
            ContentUnavailableView(
                "No History Yet",
                systemImage: "chart.xyaxis.line",
                description: Text(monitor.history.isRecording
                                  ? "FanPilot adds a reading every \(monitor.history.intervalTitle)."
                                  : "Recording is paused. Turn it on to collect history.")
            )
            .frame(height: 240)
        } else {
            temperatureChart(samples: samples, hovered: hovered, timeline: timeline)
            frequencyChart(samples: samples, hovered: hovered, timeline: timeline)
            if samples.contains(where: { !$0.fanRPM.isEmpty }) {
                fanChart(samples: samples, hovered: hovered, timeline: timeline)
            }
        }
    }

    private func temperatureChart(
        samples: [HistorySample],
        hovered: HistorySample?,
        timeline: ClosedRange<Date>
    ) -> some View {
        let values = samples.compactMap(\.temperature)
        let domain = temperatureDomain(for: values)
        return FPPanel {
            HStack {
                Text("Temperature").font(.headline)
                Spacer()
                if let hovered, let temperature = hovered.temperature {
                    Text("\(timeText(hovered.capturedAt)) · \(format(temperature))°C")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            statRow([
                Stat(label: "Lowest", value: values.min().map { "\(format($0))°" } ?? "—"),
                Stat(label: "Average", value: average(values).map { "\(format($0))°" } ?? "—"),
                Stat(label: "Peak", value: values.max().map { "\(format($0))°" } ?? "—",
                     tint: FPThermalLevel(temperature: values.max()).color),
                Stat(label: "Now", value: monitor.snapshot.temperature.map { "\(format($0))°" } ?? "—")
            ])

            Text(pressureSummary(for: samples))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Chart {
                // Drawn first so the pressure bands sit behind the curve.
                ForEach(pressureRuns(in: samples)) { run in
                    RectangleMark(
                        xStart: .value("From", run.start),
                        xEnd: .value("To", run.end)
                    )
                    .foregroundStyle(color(for: run.level).opacity(0.16))
                }
                ForEach(samples) { sample in
                    if let temperature = sample.temperature {
                        AreaMark(
                            x: .value("Time", sample.capturedAt),
                            yStart: .value("Baseline", domain.lowerBound),
                            yEnd: .value("Temperature", temperature)
                        )
                        .foregroundStyle(.linearGradient(
                            colors: [.blue.opacity(0.22), .blue.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                        LineMark(
                            x: .value("Time", sample.capturedAt),
                            y: .value("Temperature", temperature)
                        )
                        .foregroundStyle(.blue)
                        .interpolationMethod(.catmullRom)
                    }
                }
                if let hovered, let temperature = hovered.temperature {
                    cursor(at: hovered.capturedAt) {
                        readout(time: hovered.capturedAt, lines: ["\(format(temperature))°C"])
                    }
                    PointMark(
                        x: .value("Time", hovered.capturedAt),
                        y: .value("Temperature", temperature)
                    )
                    .foregroundStyle(.blue)
                    .symbolSize(70)
                }
            }
            .chartXScale(domain: timeline)
            .chartYScale(domain: domain)
            .chartYAxisLabel("°C")
            .frame(height: 190)
            .chartOverlay { proxy in hoverCatcher(proxy) }
        }
    }

    @ViewBuilder
    private func frequencyChart(
        samples: [HistorySample],
        hovered: HistorySample?,
        timeline: ClosedRange<Date>
    ) -> some View {
        let performance = samples.compactMap(\.pCoreMHz)
        if performance.isEmpty {
            EmptyView()
        } else {
            let ceiling = monitor.system.pCoreMaxMHz ?? Double(performance.max() ?? 0)
            FPPanel {
                HStack {
                    Text("CPU Frequency").font(.headline)
                    Spacer()
                    if let hovered, let clock = hovered.pCoreMHz {
                        Text("\(timeText(hovered.capturedAt)) · P \(clock) MHz"
                             + (hovered.eCoreMHz.map { " · E \($0) MHz" } ?? ""))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                statRow([
                    Stat(label: "Lowest", value: performance.min().map { "\($0) MHz" } ?? "—"),
                    Stat(label: "Average", value: "\(performance.reduce(0, +) / performance.count) MHz"),
                    Stat(label: "Peak", value: performance.max().map { "\($0) MHz" } ?? "—"),
                    Stat(label: "Ceiling", value: ceiling > 0 ? "\(Int(ceiling)) MHz" : "—")
                ])

                Text("Average clock while each cluster was running, from the DVFS state residencies the system publishes. The ceiling is this Mac's own maximum P-core state.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Chart {
                    ForEach(pressureRuns(in: samples)) { run in
                        RectangleMark(
                            xStart: .value("From", run.start),
                            xEnd: .value("To", run.end)
                        )
                        .foregroundStyle(color(for: run.level).opacity(0.16))
                    }
                    if ceiling > 0 {
                        RuleMark(y: .value("Ceiling", ceiling))
                            .foregroundStyle(Color.secondary.opacity(0.35))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                    ForEach(samples) { sample in
                        if let clock = sample.pCoreMHz {
                            LineMark(
                                x: .value("Time", sample.capturedAt),
                                y: .value("MHz", clock),
                                series: .value("Cluster", "P-cores")
                            )
                            .foregroundStyle(by: .value("Cluster", "P-cores"))
                            .interpolationMethod(.catmullRom)
                        }
                        if let clock = sample.eCoreMHz {
                            LineMark(
                                x: .value("Time", sample.capturedAt),
                                y: .value("MHz", clock),
                                series: .value("Cluster", "E-cores")
                            )
                            .foregroundStyle(by: .value("Cluster", "E-cores"))
                            .interpolationMethod(.catmullRom)
                        }
                    }
                    if let hovered, let clock = hovered.pCoreMHz {
                        cursor(at: hovered.capturedAt) {
                            readout(
                                time: hovered.capturedAt,
                                lines: ["P \(clock) MHz"] + (hovered.eCoreMHz.map { ["E \($0) MHz"] } ?? [])
                            )
                        }
                        PointMark(x: .value("Time", hovered.capturedAt), y: .value("MHz", clock))
                            .foregroundStyle(by: .value("Cluster", "P-cores"))
                            .symbolSize(70)
                        if let eClock = hovered.eCoreMHz {
                            PointMark(x: .value("Time", hovered.capturedAt), y: .value("MHz", eClock))
                                .foregroundStyle(by: .value("Cluster", "E-cores"))
                                .symbolSize(70)
                        }
                    }
                }
                .chartXScale(domain: timeline)
                .chartYAxisLabel("MHz")
                .frame(height: 190)
                .chartOverlay { proxy in hoverCatcher(proxy) }
            }
        }
    }

    private func fanChart(
        samples: [HistorySample],
        hovered: HistorySample?,
        timeline: ClosedRange<Date>
    ) -> some View {
        let values = samples.flatMap(\.fanRPM)
        return FPPanel {
            HStack {
                Text("Fan Speed").font(.headline)
                Spacer()
                if let hovered, !hovered.fanRPM.isEmpty {
                    Text("\(timeText(hovered.capturedAt)) · \(hovered.fanRPM.map(String.init).joined(separator: " / ")) RPM")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            statRow([
                Stat(label: "Lowest", value: values.min().map(String.init).map { "\($0) RPM" } ?? "—"),
                Stat(label: "Average", value: values.isEmpty ? "—" : "\(values.reduce(0, +) / values.count) RPM"),
                Stat(label: "Peak", value: values.max().map(String.init).map { "\($0) RPM" } ?? "—"),
                Stat(label: "Now", value: monitor.snapshot.fans.first.map { "\($0.currentRPM) RPM" } ?? "—")
            ])

            Chart {
                ForEach(samples) { sample in
                    ForEach(Array(sample.fanRPM.enumerated()), id: \.offset) { fan, rpm in
                        LineMark(
                            x: .value("Time", sample.capturedAt),
                            y: .value("RPM", rpm),
                            series: .value("Fan", fan)
                        )
                        .foregroundStyle(by: .value("Fan", "Fan \(fan + 1)"))
                    }
                }
                if let target = averageCurrentTargetRPM {
                    RuleMark(y: .value("Current target", target))
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("Target \(target)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.orange)
                        }
                }
                if let hovered, !hovered.fanRPM.isEmpty {
                    cursor(at: hovered.capturedAt) {
                        readout(
                            time: hovered.capturedAt,
                            lines: hovered.fanRPM.enumerated().map { "Fan \($0.offset + 1): \($0.element) RPM" }
                        )
                    }
                    ForEach(Array(hovered.fanRPM.enumerated()), id: \.offset) { fan, rpm in
                        PointMark(
                            x: .value("Time", hovered.capturedAt),
                            y: .value("RPM", rpm)
                        )
                        .foregroundStyle(by: .value("Fan", "Fan \(fan + 1)"))
                        .symbolSize(70)
                    }
                }
            }
            .chartXScale(domain: timeline)
            .chartYAxisLabel("RPM")
            .frame(height: 190)
            .chartOverlay { proxy in hoverCatcher(proxy) }
        }
    }

    private func cursor<Content: View>(
        at date: Date,
        @ViewBuilder label: @escaping () -> Content
    ) -> some ChartContent {
        RuleMark(x: .value("Time", date))
            .foregroundStyle(Color.secondary.opacity(0.55))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .annotation(
                position: .top,
                spacing: 4,
                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
            ) {
                label()
            }
    }

    private func readout(time: Date, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(timeText(time))
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(lines, id: \.self) { line in
                Text(line).font(.caption2.weight(.medium).monospacedDigit())
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
    }

    private func hoverCatcher(_ proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        guard let plotFrame = proxy.plotFrame else {
                            hoveredDate = nil
                            return
                        }
                        let origin = geometry[plotFrame].origin
                        hoveredDate = proxy.value(atX: location.x - origin.x, as: Date.self)
                    case .ended:
                        hoveredDate = nil
                    }
                }
        }
    }

    /// Samples are appended in order, so the cursor can binary search instead of
    /// scanning a week of readings on every pointer move.
    private func nearestSample(to date: Date, in samples: [HistorySample]) -> HistorySample? {
        guard !samples.isEmpty else { return nil }
        var low = 0
        var high = samples.count - 1
        while low < high {
            let middle = (low + high) / 2
            if samples[middle].capturedAt < date { low = middle + 1 } else { high = middle }
        }
        let candidate = samples[low]
        guard low > 0 else { return candidate }
        let previous = samples[low - 1]
        return abs(previous.capturedAt.timeIntervalSince(date)) < abs(candidate.capturedAt.timeIntervalSince(date))
            ? previous
            : candidate
    }

    private struct Stat: Identifiable {
        let label: String
        let value: String
        var tint: Color = .primary
        var id: String { label }
    }

    private func statRow(_ stats: [Stat]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(stats) { stat in
                VStack(alignment: .leading, spacing: 2) {
                    Text(stat.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(stat.value)
                        .font(.body.weight(.semibold).monospacedDigit())
                        .foregroundStyle(stat.tint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private struct PressureRun: Identifiable {
        let level: ThermalPressure
        let start: Date
        let end: Date
        var id: Date { start }
        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    /// Apple Silicon reports no frequencies, only this four level pressure
    /// signal, so the chart shows where the system said it was struggling.
    private func pressureRuns(in samples: [HistorySample]) -> [PressureRun] {
        let padding = bandPadding
        var runs: [PressureRun] = []
        var open: (level: ThermalPressure, start: Date, end: Date)?

        for sample in samples {
            let level = sample.thermalPressure ?? .nominal
            if var current = open, current.level == level {
                current.end = sample.capturedAt
                open = current
            } else {
                if let current = open, current.level != .nominal {
                    runs.append(PressureRun(
                        level: current.level,
                        start: current.start,
                        end: max(current.end + padding, sample.capturedAt)
                    ))
                }
                open = (level, sample.capturedAt, sample.capturedAt)
            }
        }
        if let current = open, current.level != .nominal {
            runs.append(PressureRun(level: current.level, start: current.start, end: current.end + padding))
        }
        return runs
    }

    private func color(for level: ThermalPressure) -> Color {
        switch level {
        case .nominal: .clear
        case .fair: .yellow
        case .serious: .orange
        case .critical: .red
        }
    }

    private func pressureSummary(for samples: [HistorySample]) -> String {
        let runs = pressureRuns(in: samples)
        let saturated = saturatedMinutes(in: samples)

        guard !runs.isEmpty else {
            return saturated > 0
                ? "No thermal pressure reported, but cooling was saturated for \(saturated) min."
                : "No thermal pressure reported in this range."
        }
        let parts = ThermalPressure.allCases.compactMap { level -> String? in
            let seconds = runs.filter { $0.level == level }.reduce(0) { $0 + $1.duration }
            guard seconds > 0 else { return nil }
            return "\(max(1, Int(seconds / 60))) min \(level.title.lowercased())"
        }
        let pressure = "Thermal pressure: " + parts.joined(separator: " · ")
        return saturated > 0 ? pressure + " · cooling saturated \(saturated) min" : pressure
    }

    /// The fan pinned at its maximum while the temperature stays above the
    /// curve's top: past this point no fan setting helps, only less load.
    private func saturatedMinutes(in samples: [HistorySample]) -> Int {
        guard let maximumRPM = monitor.snapshot.fans.map(\.maximumRPM).max(), maximumRPM > 0 else { return 0 }
        let ceiling = Int(Double(maximumRPM) * 0.95)
        let qualifying = samples.filter { sample in
            guard let temperature = sample.temperature, temperature >= monitor.curve.hotTemperature else { return false }
            return (sample.fanRPM.max() ?? 0) >= ceiling
        }
        guard !qualifying.isEmpty else { return 0 }
        return max(1, Int((Double(qualifying.count) * monitor.history.sampleInterval / 60).rounded()))
    }

    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).fontWeight(.medium)
        }
    }

    private func timeText(_ date: Date) -> String {
        date.formatted(date: range.duration > 24 * 60 * 60 ? .abbreviated : .omitted, time: .standard)
    }

    private func format(_ value: Double) -> String { "\(Int(value.rounded()))" }

    private func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private var sensorDiagnostic: String {
        let age = Date().timeIntervalSince(monitor.snapshot.capturedAt)
        guard monitor.snapshot.temperature != nil, !monitor.snapshot.fans.isEmpty else { return "Unavailable" }
        return age < 6 ? "Fresh · \(Int(max(age, 0))) sec ago" : "Stale · \(Int(age)) sec ago"
    }

    private var fanResponseDiagnostic: String {
        guard monitor.mode != .system else { return "Not requested · managed by macOS" }
        guard let appliedAt = monitor.lastTargetAppliedAt else { return "Waiting for a target" }
        if Date().timeIntervalSince(appliedAt) < 8 { return "Adjusting" }
        let misses = monitor.snapshot.fans.compactMap { fan -> Int? in
            guard let target = monitor.targetRPMByFan[fan.id] else { return nil }
            let tolerance = max(250, Int(Double(target) * 0.10))
            return abs(fan.currentRPM - target) > tolerance ? fan.id : nil
        }
        return misses.isEmpty ? "Target reached" : "Target not reached · check Fan \((misses.first ?? 0) + 1)"
    }

    private var averageCurrentTargetRPM: Int? {
        guard !monitor.targetRPMByFan.isEmpty else { return nil }
        return monitor.targetRPMByFan.values.reduce(0, +) / monitor.targetRPMByFan.count
    }

    private func temperatureDomain(for values: [Double]) -> ClosedRange<Double> {
        let minimum = max(0, (values.min() ?? 30) - 5)
        let maximum = min(120, (values.max() ?? 90) + 5)
        return minimum...max(minimum + 10, maximum)
    }

    private var tuning: some View {
        FPPanel {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Autopilot Tuning").font(.headline)
                    Text("Changes apply immediately to the Balanced profile.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(monitor.curve.coolTemperature))–\(Int(monitor.curve.hotTemperature))°C")
                    .font(.body.weight(.medium).monospacedDigit())
            }

            AutopilotTuningControls(monitor: monitor)

            Divider()
            HStack(alignment: .top) {
                Label(tuningRecommendation, systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if shouldOfferSaferCurve {
                    Button("Apply Safer Curve") {
                        monitor.curve.hotTemperature = max(
                            monitor.curve.coolTemperature + 10,
                            monitor.curve.hotTemperature - 5
                        )
                        monitor.saveProfileSettings()
                    }
                }
                Button("Clear History", role: .destructive) { confirmsClear = true }
            }
        }
    }

    private var observedPeak: Double {
        monitor.history
            .samples(since: Date().addingTimeInterval(-range.duration))
            .compactMap(\.temperature)
            .max() ?? 0
    }

    private var shouldOfferSaferCurve: Bool {
        observedPeak > monitor.curve.hotTemperature + 3
    }

    private var tuningRecommendation: String {
        let rangeSamples = monitor.history.samples(since: Date().addingTimeInterval(-range.duration))
        let saturated = saturatedMinutes(in: rangeSamples)
        if saturated > 0 {
            return "Cooling was saturated for \(saturated) min: the fan sat at its maximum while the temperature stayed above \(Int(monitor.curve.hotTemperature))°C. Before that point a lower ramp-up threshold helps; past it only less load does."
        }
        if shouldOfferSaferCurve {
            return "Observed temperature exceeded the maximum-speed point. A lower upper threshold may cool the Mac earlier."
        }
        return "The current curve is consistent with the temperatures in this range."
    }
}

private enum HistoryRange: String, CaseIterable, Identifiable {
    case fifteenMinutes, oneHour, sixHours, oneDay, sevenDays

    var id: Self { self }
    var title: String {
        switch self {
        case .fifteenMinutes: "15m"
        case .oneHour: "1h"
        case .sixHours: "6h"
        case .oneDay: "24h"
        case .sevenDays: "7d"
        }
    }
    var duration: TimeInterval {
        switch self {
        case .fifteenMinutes: 15 * 60
        case .oneHour: 60 * 60
        case .sixHours: 6 * 60 * 60
        case .oneDay: 24 * 60 * 60
        case .sevenDays: 7 * 24 * 60 * 60
        }
    }
}
