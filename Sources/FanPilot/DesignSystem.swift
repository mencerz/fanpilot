import SwiftUI

enum FPLayout {
    static let popoverWidth: CGFloat = 344
    static let outer: CGFloat = 16
    static let section: CGFloat = 16
    static let item: CGFloat = 8
    static let compact: CGFloat = 4
    static let cornerRadius: CGFloat = 10
}

enum FPThermalLevel {
    case normal, attention, critical, unavailable

    init(temperature: Double?) {
        guard let temperature else { self = .unavailable; return }
        if temperature >= 85 { self = .critical }
        else if temperature >= 70 { self = .attention }
        else { self = .normal }
    }

    var color: Color {
        switch self {
        case .normal: .primary
        case .attention: .orange
        case .critical: .red
        case .unavailable: .secondary
        }
    }
}

struct FPPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: FPLayout.item) { content }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: FPLayout.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: FPLayout.cornerRadius)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
    }
}

struct FPStatusDot: View {
    let mode: FanMode
    var isAvailable = true

    var body: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }

    private var statusColor: Color {
        guard isAvailable else { return .secondary }
        return mode == .system ? .green : mode == .automatic ? Color.accentColor : .orange
    }
}

/// Compact ring gauge for a 0...1 system reading. The percentage sits inside
/// the ring and the label carries the meaning, so colour stays decorative
/// until the reading is high enough to matter.
struct FPRing: View {
    let title: String
    let value: Double
    var caption: String?
    var diameter: CGFloat = 52
    var onHover: ((Bool) -> Void)?

    private var clamped: Double { min(max(value, 0), 1) }

    private var tint: Color {
        if clamped >= 0.9 { return .red }
        if clamped >= 0.75 { return .orange }
        return .accentColor
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: max(clamped, 0.001))
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.35), value: clamped)
                Text("\(Int((clamped * 100).rounded()))")
                    .font(.title3.weight(.semibold).monospacedDigit())
            }
            .frame(width: diameter, height: diameter)
            .padding(.bottom, 6)
            Text(title)
                .font(.subheadline.weight(.medium))
            if let caption {
                Text(caption)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // Traffic can jump from kilobytes to gigabytes, so the
                    // caption shrinks rather than clipping mid-number.
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { onHover?($0) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(Int((clamped * 100).rounded())) percent\(caption.map { ", \($0)" } ?? "")")
    }
}

/// Segmented mode control with room for an icon and an in-flight indicator —
/// switching modes talks to the SMC and can take seconds, which a stock
/// segmented picker gives no way to show.
struct FPModePicker: View {
    let selection: FanMode
    var pending: FanMode?
    let action: (FanMode) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(FanMode.allCases) { mode in
                Button { action(mode) } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            Image(systemName: icon(for: mode))
                                .font(.system(size: 14, weight: .medium))
                                .opacity(pending == mode ? 0 : 1)
                            if pending == mode {
                                ProgressView().controlSize(.small)
                            }
                        }
                        .frame(height: 18)
                        Text(mode.rawValue)
                            .font(.caption2.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(mode == selection ? Color.accentColor : Color.clear)
                    }
                    .foregroundStyle(mode == selection ? Color.white : Color.primary)
                    .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                // Handing control back is the fail-safe: it stays clickable
                // even while another switch is still being negotiated.
                .disabled(pending != nil && mode != .system)
                .accessibilityLabel("\(mode.rawValue) mode")
                .accessibilityAddTraits(mode == selection ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .animation(.easeOut(duration: 0.18), value: selection)
    }

    private func icon(for mode: FanMode) -> String {
        switch mode {
        case .system: "checkmark.shield"
        case .automatic: "wand.and.stars"
        case .manual: "slider.horizontal.3"
        }
    }
}
