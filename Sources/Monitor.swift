import AppKit
import SwiftUI
import Combine

enum ListTab: String, CaseIterable, Identifiable {
    case cpu, memory, disk, network, history, dev, clean

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .network: "Network"
        case .history: "History"
        case .dev: "Dev"
        case .clean: "Clean"
        }
    }

    var isProcessMetric: Bool { self != .history && self != .dev && self != .clean }
}

/// A one-minute series (1.5 s samples) plus a one-hour series (averages of 15 samples).
struct Series {
    static let minuteLength = 40
    static let hourLength = 160
    private static let bucketSize = 15

    private(set) var minute: [Double] = []
    private(set) var hour: [Double] = []
    private var bucket: [Double] = []

    mutating func add(_ value: Double) {
        minute.append(value)
        if minute.count > Self.minuteLength { minute.removeFirst() }
        bucket.append(value)
        if bucket.count == Self.bucketSize {
            hour.append(bucket.reduce(0, +) / Double(bucket.count))
            if hour.count > Self.hourLength { hour.removeFirst() }
            bucket.removeAll(keepingCapacity: true)
        }
    }

    func values(long: Bool) -> [Double] { long ? hour : minute }
}

struct Histories {
    var cpu = Series(), gpu = Series(), memory = Series(), swap = Series(), io = Series(), network = Series()
}

final class Monitor: ObservableObject {
    /// Swap is "bad" in absolute terms, not as a share of its dynamically growing file.
    static let swapScale = 8.0 * 1_073_741_824

    let prefs = Prefs.shared

    // Wired up by the window controller.
    var onDrag: (() -> Void)?
    var onDragEnd: (() -> Void)?
    var onSnapToCorner: (() -> Void)?
    var onAlert: ((MonitorAlert) -> Void)?

    @Published var screenName = UserDefaults.standard.string(forKey: "screenName") {
        didSet { UserDefaults.standard.set(screenName, forKey: "screenName") }
    }

    // MARK: Live system stats
    @Published private(set) var cpu = 0.0
    @Published private(set) var cpuUser = 0.0
    @Published private(set) var cpuSystem = 0.0
    @Published private(set) var gpu: Double?
    @Published private(set) var memUsed: UInt64 = 0
    @Published private(set) var memTotal: UInt64 = 1
    @Published private(set) var memCompressed: UInt64 = 0
    @Published private(set) var swapUsed: UInt64 = 0
    @Published private(set) var swapTotal: UInt64 = 0
    @Published private(set) var pressure = MemoryPressure.normal
    @Published private(set) var thermal = ProcessInfo.ThermalState.nominal
    @Published private(set) var power: PowerInfo?
    @Published private(set) var battery: BatteryHealth?
    @Published private(set) var sensors = SensorReading()
    @Published private(set) var diskUsed: Int64 = 0
    @Published private(set) var diskTotal: Int64 = 1
    @Published private(set) var readRate = 0.0
    @Published private(set) var writeRate = 0.0
    @Published private(set) var netIn = 0.0
    @Published private(set) var netOut = 0.0
    @Published private(set) var history = Histories()

    // MARK: Panel state
    @Published var expanded = false {
        didSet {
            confirmKey = nil
            adminKey = nil
            if expanded { refreshTab() }
        }
    }
    @Published var tab = ListTab.cpu {
        didSet {
            confirmKey = nil
            updateRows()
            refreshTab()
        }
    }
    @Published private(set) var topProcesses: [ProcInfo] = []
    @Published private(set) var topGroups: [AppGroup] = []
    @Published private(set) var openGroups = Set<String>()
    @Published private(set) var docker = DockerState.loading
    @Published private(set) var servers: [ListeningServer] = []
    /// nil until the first scan.
    @Published private(set) var laravel: [LaravelProject]?
    @Published private(set) var scanningLaravel = false
    @Published private(set) var cleanItems: [CleanItem] = []
    @Published private(set) var nodeModules: [CleanItem]?
    @Published private(set) var scanningClean = false
    @Published private(set) var scanningProjects = false
    @Published var confirmKey: String?
    @Published var adminKey: String?
    @Published private(set) var message: String?
    @Published private(set) var alert: MonitorAlert?

    var memFraction: Double { Double(memUsed) / Double(memTotal) }
    var diskFraction: Double { Double(diskUsed) / Double(max(diskTotal, 1)) }
    var swapLevel: Double { min(1, Double(swapUsed) / Self.swapScale) }
    var swapColor: Color { swapUsed < 512 << 20 ? .green : swapUsed < 3 << 30 ? .orange : .red }

    private var processes: [ProcInfo] = []
    private let sampler = ProcessSampler()
    private let runaway = RunawayDetector()
    private let leaks = LeakDetector()
    let timeline = Timeline()
    /// Sums over the current minute, averaged into one history row.
    private var minute = (cpu: 0.0, memory: 0.0, samples: 0)
    private var lastLaravelScan = Date.distantPast
    private var lastPressureAlert = Date.distantPast
    /// SMC access is created off the main thread (key discovery takes ≈0.4 s); nil until ready.
    private var smc: SMCSensors?
    private let sensorQueue = DispatchQueue(label: "glassmonitor.sensors", qos: .utility)
    /// Threshold alerts that may fire again (re-armed once the value drops back).
    private var armedThresholds: Set<String> = ["ram", "swap", "disk", "temp"]
    private var lastTicks: CPUTicks?
    private var lastIO: (read: UInt64, write: UInt64)?
    private var lastNet: (received: UInt64, sent: UInt64)?
    private var lastSample = Date()
    private var tickCount = 0
    private var timer: Timer?
    /// Background jobs in flight (main-thread only), so slow tools never pile up.
    private var busy = Set<String>()
    private var cancellables = Set<AnyCancellable>()

    init() {
        prefs.$groupByApp.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateRows() }
        }.store(in: &cancellables)
    }

    func start() {
        sensorQueue.async {
            let smc = SMCSensors()
            DispatchQueue.main.async {
                self.smc = smc
                self.readSensors()
            }
        }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    // MARK: Sampling

    private func tick() {
        let now = Date()
        let dt = max(now.timeIntervalSince(lastSample), 0.1)
        lastSample = now

        if let ticks = SystemStats.cpuTicks() {
            if let last = lastTicks, ticks.total > last.total {
                let total = Double(ticks.total - last.total)
                cpuUser = Double((ticks.user + ticks.nice) - (last.user + last.nice)) / total
                cpuSystem = Double(ticks.system - last.system) / total
                cpu = min(1, cpuUser + cpuSystem)
            }
            lastTicks = ticks
        }

        let mem = SystemStats.memory()
        (memUsed, memTotal, memCompressed) = (mem.used, max(mem.total, 1), mem.compressed)
        (swapUsed, swapTotal) = (mem.swapUsed, mem.swapTotal)
        pressure = SystemStats.memoryPressure()
        thermal = ProcessInfo.processInfo.thermalState
        gpu = SystemStats.gpuUtilization()
        // Free space is costly to compute (purgeable space accounting) and changes slowly.
        if tickCount % 20 == 0 { (diskUsed, diskTotal) = SystemStats.disk() }
        if tickCount % 4 == 0 {
            power = SystemStats.power()
            readSensors()
            checkThresholds()
        }
        // Battery wear changes over weeks; refresh every 30 minutes.
        if tickCount % 1_200 == 0 && power != nil { refreshBatteryHealth() }

        let io = SystemStats.diskIOBytes()
        // Counters drop when a disk or disk image is detached; skip that sample instead of wrapping around.
        if let last = lastIO, io.read >= last.read, io.write >= last.write {
            readRate = Double(io.read - last.read) / dt
            writeRate = Double(io.write - last.write) / dt
        }
        lastIO = io

        let net = SystemStats.networkBytes()
        if let last = lastNet, net.received >= last.received, net.sent >= last.sent {
            netIn = Double(net.received - last.received) / dt
            netOut = Double(net.sent - last.sent) / dt
        }
        lastNet = net

        history.cpu.add(cpu)
        history.gpu.add(gpu ?? 0)
        history.memory.add(memFraction)
        history.swap.add(swapLevel)
        history.io.add(readRate + writeRate)
        history.network.add(netIn + netOut)

        checkPressure()

        minute.cpu += cpu
        minute.memory += memFraction
        minute.samples += 1
        // One history row a minute (40 × 1.5 s), using the process list sampled just before.
        if minute.samples >= 40 { recordMinute() }

        let showingProcesses = expanded && tab.isProcessMetric
        if showingProcesses ? tickCount % 2 == 0 : (prefs.alertsEnabled && tickCount % 4 == 0) || minute.samples == 38 {
            sampleProcesses()
        }
        if expanded && tab == .dev && tickCount % 4 == 0 { refreshDev() }
        tickCount += 1
    }

    private func refreshTab() {
        guard expanded else { return }
        switch tab {
        case .dev: refreshDev()
        case .clean: if cleanItems.isEmpty { scanClean() }
        case .history: timeline.reload()
        default: sampleProcesses()
        }
    }

    private func sampleProcesses() {
        guard busy.insert("ps").inserted else { return }
        sampler.sample(network: expanded && tab == .network) { [weak self] list in
            guard let self else { return }
            busy.remove("ps")
            processes = list
            updateRows()
            if prefs.alertsEnabled, let p = runaway.evaluate(list) {
                raise(MonitorAlert(title: "\(p.appName ?? p.name) is using \(Int(p.cpu))% CPU",
                                   detail: "\(p.name) (PID \(p.id)) has been busy for over 2 minutes",
                                   pid: p.id, processName: p.name))
            }
        }
    }

    private func recordMinute() {
        let samples = Double(minute.samples)
        let groups = Dictionary(grouping: processes, by: \.groupKey).map { AppGroup(id: $0.key, processes: $0.value) }
        let kept = Set(groups.sorted { $0.metrics.cpu > $1.metrics.cpu }.prefix(10).map(\.id))
            .union(groups.sorted { $0.metrics.mem > $1.metrics.mem }.prefix(10).map(\.id))
        let apps = groups.filter { kept.contains($0.id) }.map {
            HistoryApp(id: $0.id, name: $0.name, bundlePath: $0.bundlePath, cpu: $0.metrics.cpu, memBytes: $0.metrics.mem)
        }
        timeline.store.record(at: Date(), cpu: minute.cpu / samples, memory: minute.memory / samples, swap: swapUsed, apps: apps)
        minute = (0, 0, 0)
        if expanded && tab == .history && timeline.selected == nil { timeline.reload() }

        if prefs.alertsEnabled, let leak = leaks.evaluate(processes, isIgnored: runaway.isIgnored) {
            let p = leak.process
            raise(MonitorAlert(title: "\(p.appName ?? p.name) keeps using more memory",
                               detail: "\(p.name) (PID \(p.id)) grew from \(bytes(Double(leak.from))) to \(bytes(Double(p.memBytes))) in an hour",
                               pid: p.id, processName: p.name))
        }
    }

    private func sortValue(_ x: RowMetrics) -> Double {
        switch tab {
        case .memory: Double(x.mem)
        case .disk: x.disk ?? 0
        case .network: x.net ?? 0
        default: x.cpu
        }
    }

    private func updateRows() {
        guard tab.isProcessMetric else { return }
        let ranked = processes.sorted { sortValue($0.metrics) > sortValue($1.metrics) }
        topProcesses = Array(ranked.prefix(14))
        topGroups = Array(Dictionary(grouping: ranked, by: \.groupKey)
            .map { AppGroup(id: $0.key, processes: $0.value) }
            .sorted { sortValue($0.metrics) > sortValue($1.metrics) }
            .prefix(14))
    }

    func toggleGroup(_ id: String) {
        if openGroups.contains(id) { openGroups.remove(id) } else { openGroups.insert(id) }
    }

    // MARK: Killing

    func kill(_ p: ProcInfo, force: Bool) {
        kill(pid: p.id, name: p.name, force: force, key: "p:\(p.id)")
    }

    func kill(pid: pid_t, name: String, force: Bool, key: String) {
        confirmKey = nil
        if Darwin.kill(pid, force ? SIGKILL : SIGTERM) == 0 {
            flash("\(force ? "Force killed" : "Quit") \(name)")
            processes.removeAll { $0.id == pid }
            servers.removeAll { $0.id == pid }
            updateRows()
            refreshSoon()
        } else if errno == EPERM {
            adminKey = key
            flash("\(name) belongs to another user — needs admin")
        } else {
            flash("Couldn't kill \(name): \(String(cString: strerror(errno)))")
        }
    }

    func kill(group: AppGroup, force: Bool) {
        confirmKey = nil
        let failed = group.processes.filter { Darwin.kill($0.id, force ? SIGKILL : SIGTERM) != 0 }.count
        flash(failed == 0 ? "\(force ? "Force killed" : "Quit") \(group.name)"
                          : "\(group.name): \(failed) process(es) need admin — expand to kill them")
        refreshSoon()
    }

    /// Asks macOS for an admin password (system dialog) and force-kills the process.
    func adminKill(pid: pid_t, name: String) {
        adminKey = nil
        flash(Shell.admin("/bin/kill -9 \(pid)") ? "Force killed \(name)" : "Admin kill cancelled")
        refreshSoon()
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            tab == .dev ? refreshDev() : sampleProcesses()
        }
    }

    // MARK: Sensors

    private func readSensors() {
        guard let smc, busy.insert("sensors").inserted else { return }
        sensorQueue.async {
            let reading = smc.read()
            DispatchQueue.main.async {
                self.busy.remove("sensors")
                if self.sensors != reading { self.sensors = reading }
            }
        }
    }

    private func refreshBatteryHealth() {
        DispatchQueue.global(qos: .background).async {
            let health = SystemStats.batteryHealth()
            DispatchQueue.main.async { self.battery = health }
        }
    }

    // MARK: Alerts

    /// User-set limits from the "Alert When" menu. Each fires once, then re-arms after the value drops back.
    private func checkThresholds() {
        guard prefs.alertsEnabled else { return }
        let gib = 1_073_741_824.0
        threshold("ram", value: memFraction, limit: prefs.ramAlert, rearmBelow: prefs.ramAlert - 0.05, tab: .memory) {
            ("Memory is \(percent(self.memFraction)) full", "\(bytes(Double(self.memUsed))) of \(bytes(Double(self.memTotal))) used")
        }
        threshold("swap", value: Double(swapUsed) / gib, limit: prefs.swapAlertGB, rearmBelow: prefs.swapAlertGB - 1, tab: .memory) {
            ("Swap reached \(bytes(Double(self.swapUsed)))", "The Mac is short of memory and writing it to disk — close some apps")
        }
        threshold("disk", value: diskFraction, limit: prefs.diskAlert, rearmBelow: prefs.diskAlert - 0.02, tab: .clean) {
            ("Disk is \(percent(self.diskFraction)) full",
             "\(bytes(Double(self.diskTotal - self.diskUsed))) free — the Clean tab can free space")
        }
        if let cpu = sensors.cpu {
            threshold("temp", value: cpu, limit: prefs.tempAlert, rearmBelow: prefs.tempAlert - 10, tab: .cpu) {
                ("CPU is at \(Int(cpu))°C", "macOS slows the Mac down when it runs this hot — check the CPU tab")
            }
        }
    }

    private func threshold(_ key: String, value: Double, limit: Double, rearmBelow: Double, tab: ListTab,
                           message: () -> (title: String, detail: String)) {
        guard limit > 0 else { return }
        if value >= limit, armedThresholds.remove(key) != nil {
            let text = message()
            raise(MonitorAlert(title: text.title, detail: text.detail, pid: nil, processName: nil, tab: tab))
        } else if value < rearmBelow {
            armedThresholds.insert(key)
        }
    }

    private func checkPressure() {
        guard prefs.alertsEnabled, pressure == .critical, Date().timeIntervalSince(lastPressureAlert) > 600 else { return }
        lastPressureAlert = Date()
        let biggest = Dictionary(grouping: processes, by: \.groupKey)
            .map { AppGroup(id: $0.key, processes: $0.value) }
            .max { $0.metrics.mem < $1.metrics.mem }
        raise(MonitorAlert(title: "Memory pressure is critical",
                           detail: biggest.map { "Biggest: \($0.name) · \(bytes(Double($0.metrics.mem)))" }
                               ?? "Close some apps to free memory",
                           pid: nil, processName: nil))
    }

    private func raise(_ newAlert: MonitorAlert) {
        withAnimation(.smooth(duration: 0.35)) { alert = newAlert }
        onAlert?(newAlert)
    }

    /// Debug aid: `--test-alert` shows a sample banner.
    func showTestAlert() {
        raise(MonitorAlert(title: "Python is using 97% CPU", detail: "Python (PID 1234) has been busy for over 2 minutes",
                           pid: 1234, processName: "Python"))
    }

    func dismissAlert() {
        withAnimation(.smooth(duration: 0.3)) { alert = nil }
    }

    func quitAlertProcess() {
        guard let a = alert, let pid = a.pid else { return }
        kill(pid: pid, name: a.processName ?? "process", force: false, key: "alert")
        dismissAlert()
    }

    func ignore(processName: String) {
        runaway.ignore(processName)
        flash("Won't alert about \(processName) again")
        if alert?.processName == processName { dismissAlert() }
    }

    func show(_ target: ListTab) {
        withAnimation(.snappy(duration: 0.25)) { expanded = true }
        tab = target
        dismissAlert()
    }

    // MARK: Dev

    func refreshDev() {
        guard busy.insert("dev").inserted else { return }
        DispatchQueue.global(qos: .utility).async {
            let state = Docker.state()
            let servers = Servers.listening()
            DispatchQueue.main.async {
                self.docker = state
                self.servers = servers
                self.busy.remove("dev")
            }
        }
        if Date().timeIntervalSince(lastLaravelScan) > 300 { scanLaravel() }
    }

    func scanLaravel() {
        guard busy.insert("laravel").inserted else { return }
        scanningLaravel = true
        lastLaravelScan = Date()
        DispatchQueue.global(qos: .utility).async {
            let projects = Laravel.projects().map(Laravel.scan)
                .sorted { ($0.errors, $1.name) > ($1.errors, $0.name) }
            DispatchQueue.main.async {
                self.laravel = projects
                self.scanningLaravel = false
                self.busy.remove("laravel")
            }
        }
    }

    func openLog(_ project: LaravelProject) {
        let path = project.logPath ?? (project.id as NSString).appendingPathComponent("storage/logs")
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func restartContainers(_ project: LaravelProject) {
        let containers = project.containers(in: docker).filter(\.running)
        guard !containers.isEmpty else { return }
        flash("Restarting \(project.name) containers…")
        DispatchQueue.global(qos: .userInitiated).async {
            let failed = containers.filter { !Docker.perform("restart", $0.id) }.count
            DispatchQueue.main.async {
                self.flash(failed == 0 ? "\(project.name): containers restarted" : "\(project.name): \(failed) restart(s) failed")
                self.refreshDev()
            }
        }
    }

    func dockerAction(_ action: String, _ container: DockerContainer) {
        confirmKey = nil
        flash("\(action.capitalized)ing \(container.name)…")
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Docker.perform(action, container.id)
            DispatchQueue.main.async {
                self.flash(ok ? "\(container.name): \(action) done" : "\(container.name): \(action) failed")
                self.refreshDev()
            }
        }
    }

    func open(port: Int) {
        if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
    }

    // MARK: Clean

    func scanClean() {
        guard busy.insert("clean").inserted else { return }
        scanningClean = true
        let items = Cleaner.items()
        cleanItems = items
        DispatchQueue.global(qos: .utility).async {
            let measured = items.map(Cleaner.measure)
            DispatchQueue.main.async {
                self.cleanItems = measured
                self.scanningClean = false
                self.busy.remove("clean")
            }
        }
    }

    func scanProjects() {
        guard busy.insert("projects").inserted else { return }
        scanningProjects = true
        DispatchQueue.global(qos: .utility).async {
            let found = Cleaner.nodeModules()
            DispatchQueue.main.async {
                self.nodeModules = found
                self.scanningProjects = false
                self.busy.remove("projects")
            }
        }
    }

    func clean(_ item: CleanItem) {
        confirmKey = nil
        if case .reveal = item.action { _ = Cleaner.perform(item); return }
        flash("Cleaning \(item.title)…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Cleaner.perform(item)
            DispatchQueue.main.async {
                self.flash(result)
                self.nodeModules?.removeAll { $0.id == item.id }
                self.scanClean()
            }
        }
    }

    // MARK: Tools

    func run(_ action: SystemAction) {
        let ok = action.needsAdmin ? Shell.admin(action.command) : Shell.run("/bin/sh", ["-c", action.command]).status == 0
        flash(ok ? action.doneMessage : "\(action.title) cancelled")
    }

    private func flash(_ text: String) {
        guard !text.isEmpty else { return }
        message = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.message == text { self?.message = nil }
        }
    }
}
