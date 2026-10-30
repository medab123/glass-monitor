import SwiftUI
import AppKit

struct RootView: View {
    static let pillHeight: CGFloat = 38
    static let alertHeight: CGFloat = 52
    static let expandedSize = CGSize(width: 500, height: 744)

    static func pillWidth(_ items: [PillItem]) -> CGFloat {
        46 + items.reduce(0) { $0 + $1.width } + CGFloat(items.count) * 10
    }

    /// Single source of truth for the panel size; the window controller resizes the panel to match.
    static func size(expanded: Bool, alert: Bool, items: [PillItem]) -> CGSize {
        let pill = pillWidth(items)
        let extra = alert ? alertHeight : 0
        return expanded
            ? CGSize(width: max(expandedSize.width, pill), height: expandedSize.height + extra)
            : CGSize(width: max(pill, alert ? 420 : 0), height: pillHeight + extra)
    }

    @ObservedObject var m: Monitor
    @ObservedObject var prefs = Prefs.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            if let alert = m.alert {
                AlertBanner(alert: alert, m: m).transition(.opacity)
            }
            if m.expanded {
                details
                    .frame(width: Self.size(expanded: true, alert: false, items: prefs.pillItems).width)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: -10)).animation(.smooth(duration: 0.35).delay(0.08)),
                        removal: .opacity.animation(.easeIn(duration: 0.12))))
            }
        }
        // Fill the window: the controller animates its frame, and the glass follows it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: m.expanded ? 24 : 19, style: .continuous))
        .animation(.smooth(duration: 0.35), value: m.expanded)
        .contextMenu { SettingsMenu(m: m) }
    }

    // MARK: Pill

    private var header: some View {
        HStack(spacing: 10) {
            ForEach(prefs.pillItems) { chip($0).frame(width: $0.width, alignment: .leading) }
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(m.expanded ? 180 : 0))
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: Self.pillHeight)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.25)) { m.expanded.toggle() } }
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { _ in m.onDrag?() }
            .onEnded { _ in m.onDragEnd?() })
        .help("Click to expand · drag to move · ⌥⌘M")
    }

    @ViewBuilder
    private func chip(_ item: PillItem) -> some View {
        switch item {
        case .cpu: MetricChip(label: "CPU", ring: m.cpu, text: percent(m.cpu))
        case .gpu: MetricChip(label: "GPU", ring: m.gpu ?? 0, text: m.gpu.map(percent) ?? "—")
        case .ram: MetricChip(label: "RAM", ring: m.memFraction, color: m.pressure.color, text: percent(m.memFraction))
        case .swap: MetricChip(label: "SWAP", ring: m.swapLevel, color: m.swapColor, text: gigabytes(m.swapUsed))
        case .disk: MetricChip(label: "DISK", ring: m.diskFraction, text: percent(m.diskFraction))
        case .net: MetricChip(label: "NET", text: "↓\(shortBytes(m.netIn)) ↑\(shortBytes(m.netOut))")
        }
    }

    // MARK: Expanded

    private var details: some View {
        VStack(spacing: 10) {
            statusStrip
            tiles
            TabBar(m: m)
            Group {
                switch m.tab {
                case .history: HistoryView(t: m.timeline)
                case .dev: DevView(m: m)
                case .clean: CleanView(m: m)
                default: ProcessListView(m: m)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            footer
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    private var statusStrip: some View {
        HStack(spacing: 12) {
            status(m.pressure.color, "circle.fill", "Memory pressure: \(m.pressure.title)")
            status(m.thermal.color, "thermometer.medium", m.thermal.title)
            if let power = m.power {
                status(.secondary, power.onBattery ? "battery.75percent" : "powerplug.fill", powerText(power))
            }
            Spacer(minLength: 0)
            historyToggle
        }
        .font(.system(size: 10.5, weight: .medium))
    }

    private func status(_ color: Color, _ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: symbol == "circle.fill" ? 6 : 10)).foregroundStyle(color)
            Text(text).foregroundStyle(.secondary)
        }
        .lineLimit(1)
    }

    private func powerText(_ p: PowerInfo) -> String {
        let battery = p.percent.map { " · \($0)%" } ?? ""
        if p.onBattery { return String(format: "%.1f W", p.watts) + battery }
        return (p.charging ? "Charging" : "On power") + battery
    }

    private var historyToggle: some View {
        HStack(spacing: 0) {
            ForEach([false, true], id: \.self) { long in
                Button {
                    withAnimation(.smooth(duration: 0.3)) { prefs.longHistory = long }
                } label: {
                    Text(long ? "1h" : "1m")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .foregroundStyle(prefs.longHistory == long ? Color.primary : Color.secondary)
                        .background(prefs.longHistory == long ? Color.primary.opacity(0.14) : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(.primary.opacity(0.06), in: Capsule())
        .help("Graph history: last minute or last hour")
    }

    private var tiles: some View {
        let long = prefs.longHistory
        let capacity = long ? Series.hourLength : Series.minuteLength
        let gpuHistory = m.history.gpu.values(long: long)
        return Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                MetricTile(title: "CPU", value: percent(m.cpu), tint: level(m.cpu),
                           history: m.history.cpu.values(long: long), capacity: capacity,
                           lines: ["User \(percent(m.cpuUser))", "System \(percent(m.cpuSystem))"])
                MetricTile(title: "GPU", value: m.gpu.map(percent) ?? "—", tint: level(m.gpu ?? 0),
                           history: gpuHistory, capacity: capacity,
                           lines: ["Graphics, video & ML", "Peak \(percent(gpuHistory.max() ?? 0))"])
                MetricTile(title: "MEMORY", value: percent(m.memFraction), tint: m.pressure.color,
                           history: m.history.memory.values(long: long), capacity: capacity,
                           lines: ["\(bytes(Double(m.memUsed))) of \(bytes(Double(m.memTotal)))",
                                   "Pressure: \(m.pressure.title)"])
            }
            GridRow {
                MetricTile(title: "SWAP", value: m.swapUsed == 0 ? "None" : bytes(Double(m.swapUsed)), tint: m.swapColor,
                           history: m.history.swap.values(long: long), capacity: capacity,
                           lines: [m.swapTotal == 0 ? "Not swapping" : "of \(bytes(Double(m.swapTotal))) file",
                                   "Compressed \(bytes(Double(m.memCompressed)))"])
                MetricTile(title: "DISK", value: rate(m.readRate + m.writeRate), tint: .blue,
                           history: m.history.io.values(long: long), capacity: capacity, autoScaleFloor: 1_000_000,
                           lines: ["↓\(rate(m.readRate)) ↑\(rate(m.writeRate))",
                                   "\(bytes(Double(m.diskTotal - m.diskUsed))) free · \(percent(m.diskFraction)) full"])
                MetricTile(title: "NETWORK", value: rate(m.netIn + m.netOut), tint: .teal,
                           history: m.history.network.values(long: long), capacity: capacity, autoScaleFloor: 100_000,
                           lines: ["↓ \(rate(m.netIn))", "↑ \(rate(m.netOut))"])
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(m.message ?? "⌥⌘M toggles · drag to move · right-click for settings")
                .font(.system(size: 10))
                .foregroundStyle(m.message == nil ? .secondary : .primary)
                .lineLimit(1)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: m.message)
            Spacer(minLength: 4)
            Menu {
                ForEach(SystemAction.allCases) { action in
                    Button { m.run(action) } label: {
                        Label(action.title + (action.needsAdmin ? "…" : ""), systemImage: action.symbol)
                    }
                }
                Divider()
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                } label: {
                    Label("Open Activity Monitor", systemImage: "chart.bar.xaxis")
                }
            } label: {
                Label("Tools", systemImage: "wrench.and.screwdriver.fill").font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

struct AlertBanner: View {
    let alert: MonitorAlert
    @ObservedObject var m: Monitor

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(alert.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                Text(alert.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let name = alert.processName, alert.pid != nil {
                PillButton("Quit", .red) { m.quitAlertProcess() }
                PillButton("Ignore") { m.ignore(processName: name) }
            } else {
                PillButton("Show") { m.showMemory() }
            }
            Button { m.dismissAlert() } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: RootView.alertHeight - 8)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
    }
}

struct SettingsMenu: View {
    @ObservedObject var m: Monitor
    @ObservedObject var prefs = Prefs.shared

    var body: some View {
        Menu("Show in Pill") {
            ForEach(PillItem.allCases) { item in
                Toggle(item.title, isOn: Binding(get: { prefs.pillItems.contains(item) }, set: { _ in prefs.toggle(item) }))
            }
        }
        Picker("Opacity", selection: $prefs.opacity) {
            Text("100%").tag(1.0)
            Text("85%").tag(0.85)
            Text("70%").tag(0.7)
            Text("50%").tag(0.5)
        }
        Toggle("Click-Through (hold ⌥ to interact)", isOn: $prefs.clickThrough)
        Toggle("Hide in Full-Screen Apps", isOn: $prefs.hideInFullScreen)
        Toggle("Hide from Screen Sharing & Recordings", isOn: $prefs.hideFromSharing)
        Toggle("Runaway CPU & Memory Leak Alerts", isOn: $prefs.alertsEnabled)
        Toggle("Open at Login", isOn: Binding(get: { LoginItem.isEnabled }, set: { LoginItem.setEnabled($0) }))
        Divider()
        Menu("Move to Screen") {
            ForEach(NSScreen.screens, id: \.localizedName) { screen in
                Button(screen.localizedName) {
                    m.screenName = screen.localizedName
                    m.onSnapToCorner?()
                }
            }
        }
        Button("Snap to Top-Right") { m.onSnapToCorner?() }
        Divider()
        Button("Toggle Panel  (⌥⌘M)") { withAnimation(.snappy(duration: 0.25)) { m.expanded.toggle() } }
        Button("Quit Glass Monitor") { NSApp.terminate(nil) }
    }
}
