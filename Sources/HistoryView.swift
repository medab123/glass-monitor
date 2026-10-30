import SwiftUI
import Charts

/// "Why was my Mac slow?": a week of CPU / memory, and the apps using them at any recorded minute.
struct HistoryView: View {
    @ObservedObject var t: Timeline
    @State private var sortByMemory = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                legend("CPU", .blue)
                legend("Memory", .purple)
                Spacer()
                rangePicker
            }
            .padding(.horizontal, 8)

            if t.points.count < 2 {
                Text("Recording one sample a minute — history appears here within a few minutes.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                chart.frame(height: 130).padding(.horizontal, 8)
            }

            HStack(spacing: 8) {
                Text(caption).foregroundStyle(.primary).lineLimit(1)
                if t.pinned != nil {
                    Button { t.togglePin() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Unpin")
                }
                Spacer()
                sortButton("CPU", memory: false).frame(width: Columns.primary, alignment: .trailing)
                sortButton(t.selected == nil ? "PEAK MEM" : "MEMORY", memory: true).frame(width: 64, alignment: .trailing)
            }
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 2)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(sortedApps) { appRow($0) }
                }
            }
            .scrollIndicators(.never)
        }
    }

    private var sortedApps: [HistoryApp] {
        sortByMemory ? t.apps.sorted { $0.memBytes > $1.memBytes } : t.apps
    }

    private var caption: String {
        guard let selected = t.selected else {
            return "LAST \(t.range.title.uppercased()) AVERAGE · HOVER GRAPH, CLICK TO PIN"
        }
        let style: Date.FormatStyle = Calendar.current.isDateInToday(selected)
            ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated).hour().minute()
        return "AT \(selected.formatted(style).uppercased())\(t.pinned != nil && t.pinned == selected ? " · PINNED" : "")"
    }

    private var chart: some View {
        Chart {
            ForEach(t.points) { p in
                AreaMark(x: .value("Time", p.date), y: .value("CPU", p.cpu * 100))
                    .foregroundStyle(LinearGradient(colors: [.blue.opacity(0.35), .blue.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", p.date), y: .value("Percent", p.cpu * 100), series: .value("Metric", "CPU"))
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", p.date), y: .value("Percent", p.memory * 100), series: .value("Metric", "Memory"))
                    .foregroundStyle(.purple)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
            }
            if let selected = t.selected {
                RuleMark(x: .value("Selected", selected))
                    .foregroundStyle(.primary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: t.pinned == selected ? [] : [3, 3]))
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine().foregroundStyle(.primary.opacity(0.1))
                AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%").font(.system(size: 8.5)) }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine().foregroundStyle(.primary.opacity(0.06))
                AxisValueLabel(format: t.range == .week ? .dateTime.weekday(.abbreviated) : .dateTime.hour().minute())
                    .font(.system(size: 8.5))
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let frame = proxy.plotFrame else { return }
                            t.hover(proxy.value(atX: location.x - geo[frame].origin.x, as: Date.self))
                        case .ended:
                            t.hover(nil)
                        }
                    }
                    .onTapGesture { t.togglePin() }
            }
        }
    }

    private var rangePicker: some View {
        HStack(spacing: 0) {
            ForEach(HistoryRange.allCases) { range in
                Button { t.range = range } label: {
                    Text(range.title)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .foregroundStyle(t.range == range ? Color.primary : Color.secondary)
                        .background(t.range == range ? Color.primary.opacity(0.14) : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(.primary.opacity(0.06), in: Capsule())
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        }
    }

    private func sortButton(_ title: String, memory: Bool) -> some View {
        Button { sortByMemory = memory } label: {
            HStack(spacing: 2) {
                Text(title)
                if sortByMemory == memory { Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)) }
            }
            .foregroundStyle(sortByMemory == memory ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    private func appRow(_ app: HistoryApp) -> some View {
        HoverRow(icon: AnyView(ProcessIcon(bundlePath: app.bundlePath, user: "")), title: app.name,
                 subtitle: app.bundlePath == nil ? "Background process" : "App") { _ in
            HStack(spacing: 8) {
                Text(String(format: "%.1f%%", app.cpu))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .frame(width: Columns.primary, alignment: .trailing)
                Text(bytes(Double(app.memBytes)))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
            }
            .monospacedDigit()
        }
    }
}
