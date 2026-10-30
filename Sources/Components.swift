import SwiftUI
import AppKit

// MARK: - Formatting

func level(_ v: Double) -> Color {
    v < 0.6 ? .green : v < 0.85 ? .orange : .red
}

private let byteFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.countStyle = .memory
    f.allowsNonnumericFormatting = false
    return f
}()

/// Clamps to a range that converts to Int safely (NaN/inf/negative/huge would trap).
private func safe(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 9e18) : 0 }

func bytes(_ b: Double) -> String { byteFormatter.string(fromByteCount: Int64(safe(b))) }
func rate(_ b: Double) -> String { bytes(b) + "/s" }
func percent(_ v: Double) -> String { "\(Int(safe(v * 100).rounded()))%" }
func gigabytes(_ b: UInt64) -> String { String(format: "%.1fG", Double(b) / 1_073_741_824) }

/// Compact form for the pill, e.g. "830K", "1.2M".
func shortBytes(_ value: Double) -> String {
    let b = safe(value)
    return switch b {
    case ..<1_000: "\(Int(b))B"
    case ..<1_000_000: "\(Int(b / 1_000))K"
    case ..<1_000_000_000: String(format: "%.1fM", b / 1_000_000)
    default: String(format: "%.1fG", b / 1_000_000_000)
    }
}

// MARK: - Small views

struct Sparkline: Shape {
    var values: [Double]   // 0...1
    var capacity: Int
    var closed = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1, capacity > 1 else { return path }
        let step = rect.width / CGFloat(capacity - 1)
        let start = rect.width - step * CGFloat(values.count - 1)
        for (i, v) in values.enumerated() {
            let pt = CGPoint(x: start + step * CGFloat(i), y: rect.height * (1 - CGFloat(min(max(v, 0), 1))))
            i == 0 ? path.move(to: pt) : path.addLine(to: pt)
        }
        if closed {
            path.addLine(to: CGPoint(x: rect.width, y: rect.height))
            path.addLine(to: CGPoint(x: start, y: rect.height))
            path.closeSubpath()
        }
        return path
    }
}

struct Ring: View {
    let value: Double
    var color: Color?

    var body: some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.15), lineWidth: 2.5)
            Circle().trim(from: 0, to: max(value, 0.001))
                .stroke(color ?? level(value), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 13, height: 13)
    }
}

struct MetricChip: View {
    let label: String
    var ring: Double?
    var color: Color?
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            if let ring { Ring(value: ring, color: color) }
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .lineLimit(1)
        .fixedSize()
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let tint: Color
    let history: [Double]
    let capacity: Int
    /// For rate series: scale the graph to its own peak, but never below this floor.
    var autoScaleFloor: Double?
    let lines: [String]

    private var normalized: [Double] {
        guard let floor = autoScaleFloor else { return history }
        let peak = max(history.max() ?? 0, floor)
        return history.map { $0 / peak }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 16, weight: .bold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            ZStack {
                Sparkline(values: normalized, capacity: capacity, closed: true)
                    .fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                Sparkline(values: normalized, capacity: capacity).stroke(tint, lineWidth: 1.5)
            }
            .frame(height: 22)
            ForEach(lines, id: \.self) {
                Text($0).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct PillButton: View {
    let title: String
    /// nil = neutral.
    var color: Color?
    let action: () -> Void

    init(_ title: String, _ color: Color? = nil, action: @escaping () -> Void) {
        self.title = title
        self.color = color
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .foregroundStyle(color == nil ? Color.primary : .white)
                .background(color ?? Color.primary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct ProcessIcon: View {
    let bundlePath: String?
    let user: String
    var symbol: String?

    var body: some View {
        if let bundlePath {
            Image(nsImage: Icons.app(bundlePath)).resizable().interpolation(.high).frame(width: 22, height: 22)
        } else {
            Image(systemName: symbol ?? (user == "root" || user.hasPrefix("_") ? "gearshape.2.fill" : "terminal.fill"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 4)
    }
}

/// A list row: icon, title + subtitle, and trailing content that knows whether the row is hovered.
struct HoverRow<Trailing: View>: View {
    var leading: CGFloat = 8
    let icon: AnyView
    let title: String
    let subtitle: String
    @ViewBuilder let trailing: (Bool) -> Trailing
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(subtitle).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing(hovering)
        }
        .padding(.leading, leading)
        .padding(.trailing, 8)
        .frame(height: 36)
        .background(hovering ? Color.primary.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}
