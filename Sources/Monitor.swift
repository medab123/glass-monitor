import AppKit
import SwiftUI
import Combine

enum ListTab: String, CaseIterable, Identifiable {
    case cpu, memory, disk, network, energy, history, dev, clean

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .network: "Network"
        case .energy: "Energy"
        case .history: "History"
        case .dev: "Dev"
        case .clean: "Clean"
        }
    }

    var isProcessMetric: Bool { self != .history && self != .dev && self != .clean }
}

enum GraphRange: String, CaseIterable, Identifiable {
    case m30, h2, h12, d1

    static let points = 150

    var id: String { rawValue }

    var label: String {
        switch self {
        case .m30: "30m"
        case .h2: "2h"
        case .h12: "12h"
        case .d1: "1d"
        }
    }

    var title: String {
        switch self {
        case .m30: "last 30 minutes"
        case .h2: "last 2 hours"
        case .h12: "last 12 hours"
        case .d1: "last day"
        }
    }

    /// 150 × bucket × 1.5 s = the window length (12 s, 48 s, 4.8 min and 9.6 min per point).
    var bucket: Int {
        switch self {
        case .m30: 8
        case .h2: 32
        case .h12: 192
        case .d1: 384
        }
    }

    var index: Int { Self.allCases.firstIndex(of: self)! }
}

/// One averaged series per history range, fed with 1.5 s samples.
/// Saved to disk so the long ranges survive restarts; time the app wasn't running is stored as NaN (a gap in the graph).
struct Series: Codable {
    private var points = [[Double]](repeating: [], count: GraphRange.allCases.count)
    private var sums = [Double](repeating: 0, count: GraphRange.allCases.count)
    private var counts = [Int](repeating: 0, count: GraphRange.allCases.count)
    /// Per point, the label given with its highest sample, e.g. the app using the most CPU at the peak ("" = none).
    private var labels = [[String]](repeating: [], count: GraphRange.allCases.count)
    private var peaks = [Double](repeating: -.infinity, count: GraphRange.allCases.count)
    private var peakLabels = [String](repeating: "", count: GraphRange.allCases.count)

    /// `weight` = how many 1.5 s samples this one stands for (2 for a 3 s collapsed tick).
    mutating func add(_ value: Double, label: String? = nil, weight: Int = 1) {
        for range in GraphRange.allCases {
            let i = range.index
            sums[i] += value * Double(weight)
            counts[i] += weight
            if let label, value >= peaks[i] {
                peaks[i] = value
                peakLabels[i] = label
            }
            guard counts[i] >= range.bucket else { continue }
            append(sums[i] / Double(counts[i]), label: peakLabels[i], at: i)
            resetBucket(i)
        }
    }

    private mutating func append(_ value: Double, label: String, at i: Int) {
        points[i].append(value)
        labels[i].append(label)
        if points[i].count > GraphRange.points {
            points[i].removeFirst(points[i].count - GraphRange.points)
        }
        if labels[i].count > points[i].count { labels[i].removeFirst(labels[i].count - points[i].count) }
    }

    private mutating func resetBucket(_ i: Int) {
        sums[i] = 0
        counts[i] = 0
        peaks[i] = -.infinity
        peakLabels[i] = ""
    }

    /// Accounts for time the app wasn't sampling: whole missing points become NaN gaps and the partial bucket is dropped.
    mutating func skip(seconds: Double) {
        for range in GraphRange.allCases {
            let i = range.index
            let missing = Int(seconds / (Double(range.bucket) * 1.5))
            guard missing > 0 else { continue }
            for _ in 0..<min(missing, GraphRange.points) { append(.nan, label: "", at: i) }
            resetBucket(i)
        }
    }

    /// Completed points plus the bucket still filling, so the newest point moves live.
    func values(_ range: GraphRange) -> [Double] {
        let i = range.index
        guard counts[i] > 0 else { return points[i] }
        return Array((points[i] + [sums[i] / Double(counts[i])]).suffix(GraphRange.points))
    }

    /// Labels aligned one-to-one with `values(range)`.
    func labels(_ range: GraphRange) -> [String] {
        let i = range.index
        var result = labels[i]
        if result.count < points[i].count { result.insert(contentsOf: Array(repeating: "", count: points[i].count - result.count), at: 0) }
        guard counts[i] > 0 else { return result }
        return Array((result + [peakLabels[i]]).suffix(GraphRange.points))
    }
}

struct Histories: Codable {
    var cpu = Series(), gpu = Series(), memory = Series(), swap = Series(), io = Series(), network = Series()

    /// Next to the 7-day history database. Builds before the merge kept it in "Glass Monitor/history.json"; move it once.
    private static var file: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("GlassMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("graphs.json")
        let legacyDir = support.appendingPathComponent("Glass Monitor", isDirectory: true)
        let legacy = legacyDir.appendingPathComponent("history.json")
        if !FileManager.default.fileExists(atPath: file.path), FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: file)
            try? FileManager.default.removeItem(at: legacyDir)
        }
        return file
    }

    private struct Saved: Codable {
        let savedAt: Date
        let histories: Histories
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        guard let data = try? encoder.encode(Saved(savedAt: Date(), histories: self)) else { return }
        try? data.write(to: Self.file, options: .atomic)
    }

    /// The saved history, with the time since it was saved turned into gaps.
    static func load() -> Histories {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        guard let data = try? Data(contentsOf: file),
              let saved = try? decoder.decode(Saved.self, from: data) else { return Histories() }
        var h = saved.histories
        let gap = max(Date().timeIntervalSince(saved.savedAt), 0)
        for path in [\Histories.cpu, \.gpu, \.memory, \.swap, \.io, \.network] as [WritableKeyPath<Histories, Series>] {
            h[keyPath: path].skip(seconds: gap)
        }
        return h
    }
}

final class Monitor: ObservableObject {
    /// Swap is "bad" in absolute terms, not as a share of its dynamically growing file.
    static let swapScale = 8.0 * 1_073_741_824

    let prefs = Prefs.shared

    // Wired up by the window controller.
    var onDrag: (() -> Void)?
    var onDragEnd: (() -> Void)?
    var onSnapToCorner: (() -> Void)?
    var onShutDown: (() -> Void)?
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
    @Published private(set) var history = Histories.load()
    /// Glass Monitor's own CPU (share of one core, helpers included) and memory footprint.
    @Published private(set) var selfCPU = 0.0
    @Published private(set) var selfMemory: UInt64 = 0
    /// Read only while the Network tab is open.
    @Published private(set) var wifi: WiFiInfo?
    @Published private(set) var wiredIP: String?

    // MARK: Panel state
    @Published var expanded = false {
        didSet {
            confirmKey = nil
            adminKey = nil
            guard expanded != oldValue else { return }
            scheduleTimer()
            if expanded {
                refreshTab()
            } else {
                // Hand the panel's freed memory (views, icons, chart data) back to macOS instead of keeping it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { malloc_zone_pressure_relief(nil, 0) }
            }
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
    /// Docker's VM, Android emulators and other VMs; updated while the Dev tab is open.
    @Published private(set) var machines: [VirtualMachine] = []
    @Published private(set) var dockerLimits: (memory: UInt64, cpus: Int)?
    @Published private(set) var dockerSwitching = false
    /// nil until scanned from the Clean tab.
    @Published private(set) var startupItems: [StartupItem]?
    @Published private(set) var scanningStartup = false
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

    let bootTime = SystemStats.bootTime()
    var uptime: TimeInterval { bootTime.map { Date().timeIntervalSince($0) } ?? 0 }
    /// Up for 2+ days with swap at a quarter of RAM (at least 4 GB): swap only shrinks again after a restart.
    var restartAdvised: Bool {
        uptime >= 2 * 86_400 && Double(swapUsed) >= max(4 * 1_073_741_824, Double(memTotal) / 4)
    }
    var focusOn: Bool { prefs.focusQuit != nil }
    var dockerDesktopRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Docker.desktopBundleID).isEmpty
    }

    private var processes: [ProcInfo] = []
    private let sampler = ProcessSampler()
    private let runaway = RunawayDetector()
    private let leaks = LeakDetector()
    let timeline = Timeline()
    /// Sums over the current minute, averaged into one history row.
    /// Time-weighted sums over the current minute, averaged into one history row.
    private var minute = (cpu: 0.0, memory: 0.0, seconds: 0.0)
    private var lastLaravelScan = Date.distantPast
    private var lastPressureAlert = Date.distantPast
    private var lastPressureWarning = Date.distantPast
    private var pressureWarningSince: Date?
    private var lastDiskAlert = Date.distantPast
    private var lastSelf: (cpuTime: Double, at: Date)?
    /// The app using the most CPU / memory in the latest process sample, stored with each graph point.
    private var cpuCulprit: String?
    private var memoryCulprit: String?
    /// SMC access is created off the main thread (key discovery takes ≈0.4 s); nil until ready.
    private var smc: SMCSensors?
    private let sensorQueue = DispatchQueue(label: "glassmonitor.sensors", qos: .utility)
    /// Threshold alerts that may fire again (re-armed once the value drops back).
    private var armedThresholds: Set<String> = ["ram", "swap", "disk", "temp"]
    private var lastTicks: CPUTicks?
    private var lastIO: (read: UInt64, write: UInt64)?
    private var lastNet: (received: UInt64, sent: UInt64)?
    private var lastSample = Date()
    /// When each periodic job last ran (see `due`).
    private var lastRun: [Job: Date] = [:]
    private enum Job { case disk, power, sensors, selfUsage, network, saveGraphs, advice, battery, processes, dev }
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
        scheduleTimer()
    }

    /// Collapsed, only the pill is on screen, so it refreshes every 3 s; the open panel every 2 s (each refresh
    /// redraws the whole panel, ≈2.5% CPU at 1.5 s).
    private var interval: TimeInterval { expanded ? 2 : 3 }

    private func scheduleTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        // Lets macOS batch this wake-up with others (less CPU wake-ups, less energy).
        timer.tolerance = interval / 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// True (and restarts the clock) when `job` hasn't run for `seconds`.
    private func due(_ job: Job, every seconds: TimeInterval, _ now: Date) -> Bool {
        if let last = lastRun[job], now.timeIntervalSince(last) < seconds - 0.2 { return false }
        lastRun[job] = now
        return true
    }

    /// Temperatures are only read when something shows or uses them.
    private var needsSensors: Bool { expanded || prefs.pillItems.contains(.temp) || prefs.tempAlert > 0 }

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
        if due(.disk, every: 30, now) {
            (diskUsed, diskTotal) = SystemStats.disk()
            checkDiskSpace()
        }
        // Things only the open panel shows are refreshed less often while collapsed.
        if due(.selfUsage, every: expanded ? 6 : 60, now) { measureSelf(now) }
        if expanded && tab == .network && due(.network, every: 6, now) { readNetwork() }
        if due(.saveGraphs, every: 300, now) { history.save() }
        if due(.power, every: expanded ? 6 : 30, now) {
            power = SystemStats.power()
            checkThresholds()
        }
        if needsSensors && due(.sensors, every: 6, now) { readSensors() }
        if due(.advice, every: 60, now) {
            checkRestartAdvice()
            checkWeeklyReport()
        }
        // Battery wear changes over weeks.
        if power != nil && due(.battery, every: 1_800, now) { refreshBatteryHealth() }

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

        // Graph points average 1.5 s samples; a longer tick counts as several. One publish for all six series.
        let weight = max(1, Int((dt / 1.5).rounded()))
        var graphs = history
        graphs.cpu.add(cpu, label: cpuCulprit, weight: weight)
        graphs.gpu.add(gpu ?? 0, weight: weight)
        graphs.memory.add(memFraction, label: memoryCulprit, weight: weight)
        graphs.swap.add(swapLevel, weight: weight)
        graphs.io.add(readRate + writeRate, weight: weight)
        graphs.network.add(netIn + netOut, weight: weight)
        history = graphs

        checkPressure()

        minute.cpu += cpu * dt
        minute.memory += memFraction * dt
        minute.seconds += dt
        // One history row a minute, using the latest process sample.
        if minute.seconds >= 60 { recordMinute() }

        // The process list is the biggest job (ps + one syscall per process): every 4 s while a process tab is
        // open, otherwise only as often as the alerts and the minute history need it.
        let showingProcesses = expanded && tab.isProcessMetric
        if due(.processes, every: showingProcesses ? 4 : prefs.alertsEnabled ? 15 : 60, now) { sampleProcesses() }
        // Docker CLI calls cost real CPU (`docker stats` especially).
        if expanded && tab == .dev && due(.dev, every: 10, now) { refreshDev() }
    }

    private func refreshTab() {
        guard expanded else { return }
        switch tab {
        case .dev: refreshDev()
        case .clean:
            if cleanItems.isEmpty { scanClean() }
            if startupItems == nil { scanStartup() }
        case .history: timeline.reload()
        case .network:
            readNetwork()
            sampleProcesses()
        default: sampleProcesses()
        }
    }

    private func measureSelf(_ now: Date) {
        let usage = SystemStats.selfUsage()
        selfMemory = usage.memory
        if let last = lastSelf, usage.cpuTime >= last.cpuTime {
            selfCPU = (usage.cpuTime - last.cpuTime) / max(now.timeIntervalSince(last.at), 0.1)
        }
        lastSelf = (usage.cpuTime, now)
    }

    private func readNetwork() {
        guard busy.insert("network").inserted else { return }
        DispatchQueue.global(qos: .utility).async {
            let wifi = NetworkInfo.wifi()
            let wired = wifi == nil ? NetworkInfo.wiredIP(excluding: NetworkInfo.wifiInterfaceName()) : nil
            DispatchQueue.main.async {
                self.busy.remove("network")
                if self.wifi != wifi { self.wifi = wifi }
                if self.wiredIP != wired { self.wiredIP = wired }
            }
        }
    }

    func saveHistory() { history.save() }

    private func sampleProcesses() {
        guard busy.insert("ps").inserted else { return }
        sampler.sample(network: expanded && tab == .network, energy: expanded && tab == .energy) { [weak self] list in
            guard let self else { return }
            busy.remove("ps")
            processes = list
            updateRows()
            updateCulprits()
            if expanded && tab == .dev {
                let docker = dockerDesktopRunning
                machines = list.compactMap { VirtualMachine($0, dockerRunning: docker) }.sorted { $0.memory > $1.memory }
            }
            if prefs.alertsEnabled, let p = runaway.evaluate(list) {
                raise(MonitorAlert(title: "\(p.appName ?? p.name) is using \(Int(p.cpu))% CPU",
                                   detail: "\(p.name) (PID \(p.id)) has been busy for over 2 minutes",
                                   pid: p.id, processName: p.name))
            }
        }
    }

    private func recordMinute() {
        let seconds = max(minute.seconds, 1)
        let groups = Dictionary(grouping: processes, by: \.groupKey).map { AppGroup(id: $0.key, processes: $0.value) }
        let kept = Set(groups.sorted { $0.metrics.cpu > $1.metrics.cpu }.prefix(10).map(\.id))
            .union(groups.sorted { $0.metrics.mem > $1.metrics.mem }.prefix(10).map(\.id))
        let apps = groups.filter { kept.contains($0.id) }.map {
            HistoryApp(id: $0.id, name: $0.name, bundlePath: $0.bundlePath, cpu: $0.metrics.cpu, memBytes: $0.metrics.mem)
        }
        timeline.store.record(at: Date(), cpu: minute.cpu / seconds, memory: minute.memory / seconds, swap: swapUsed, apps: apps)
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
        case .energy: x.energy ?? 0
        default: x.cpu
        }
    }

    private var appGroups: [AppGroup] {
        Dictionary(grouping: processes, by: \.groupKey).map { AppGroup(id: $0.key, processes: $0.value) }
    }

    private func updateCulprits() {
        let groups = appGroups
        cpuCulprit = groups.max { $0.metrics.cpu < $1.metrics.cpu }
            .map { "\($0.name) · \(String(format: "%.0f", $0.metrics.cpu))% CPU" }
        memoryCulprit = groups.max { $0.metrics.mem < $1.metrics.mem }
            .map { "\($0.name) · \(bytes(Double($0.metrics.mem)))" }
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
        let now = Date()
        pressureWarningSince = pressure == .normal ? nil : (pressureWarningSince ?? now)
        guard prefs.alertsEnabled else { return }
        // Only group the process list when an alert actually fires; this runs every tick.
        func biggestText() -> String? {
            appGroups.max { $0.metrics.mem < $1.metrics.mem }
                .map { "Biggest: \($0.name) · \(bytes(Double($0.metrics.mem)))" }
        }

        if pressure == .critical, now.timeIntervalSince(lastPressureAlert) > 600 {
            lastPressureAlert = now
            raise(MonitorAlert(title: "Memory pressure is critical",
                               detail: biggestText() ?? "Close some apps to free memory",
                               pid: nil, processName: nil))
        } else if pressure == .warning, let since = pressureWarningSince, now.timeIntervalSince(since) >= 180,
                  now.timeIntervalSince(lastPressureWarning) > 3600, now.timeIntervalSince(lastPressureAlert) > 600 {
            // Earlier heads-up: pressure has stayed at "warning" for 3 minutes (at most once an hour).
            lastPressureWarning = now
            let swap = swapUsed > 0 ? " · swap \(bytes(Double(swapUsed)))" : ""
            raise(MonitorAlert(title: "Memory is getting tight",
                               detail: (biggestText() ?? "Close some apps to free memory") + swap,
                               pid: nil, processName: nil))
        }
    }

    /// Warns when the startup disk drops below 15 GB free (at most every 6 hours).
    private func checkDiskSpace() {
        let free = diskTotal - diskUsed
        guard prefs.alertsEnabled, diskTotal > 1, free < 15 * 1_073_741_824,
              Date().timeIntervalSince(lastDiskAlert) > 6 * 3600 else { return }
        lastDiskAlert = Date()
        raise(MonitorAlert(title: "Disk almost full · \(bytes(Double(max(free, 0)))) free",
                           detail: "Clear caches and old project files in the Clean tab",
                           pid: nil, processName: nil, tab: .clean))
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
        // Only the weekly report leads to History; open it on the week.
        if target == .history { timeline.range = .week }
        dismissAlert()
    }

    /// At most once a day, while `restartAdvised` holds.
    private func checkRestartAdvice() {
        let defaults = UserDefaults.standard
        guard prefs.alertsEnabled, restartAdvised,
              Date().timeIntervalSince(defaults.object(forKey: "lastRestartAdvice") as? Date ?? .distantPast) > 86_400
        else { return }
        defaults.set(Date(), forKey: "lastRestartAdvice")
        raise(MonitorAlert(title: "Restart recommended · swap is \(bytes(Double(swapUsed)))",
                           detail: "Up \(duration(uptime)) — a restart clears swap and the Mac will feel faster again",
                           pid: nil, processName: nil, tab: .memory))
    }

    /// Mondays from 9:00, once a week: last week's numbers as a notification.
    private func checkWeeklyReport() {
        let defaults = UserDefaults.standard
        let now = Date()
        guard prefs.alertsEnabled else { return }
        guard let last = defaults.object(forKey: "lastWeeklyReport") as? Date else {
            defaults.set(now, forKey: "lastWeeklyReport") // first run: start counting from today
            return
        }
        let calendar = Calendar.current
        guard now.timeIntervalSince(last) >= 6 * 86_400, calendar.component(.weekday, from: now) == 2,
              calendar.component(.hour, from: now) >= 9 else { return }
        defaults.set(now, forKey: "lastWeeklyReport")
        timeline.store.weeklyReport { [weak self] report in
            guard let self, let report else { return }
            raise(MonitorAlert(title: "Your Mac last week", detail: report.headline, pid: nil, processName: nil, tab: .history))
        }
    }

    // MARK: Focus mode

    /// Apps that can be picked for Focus Mode: running regular apps plus ones already picked, by name.
    func focusCandidates() -> [(id: String, name: String)] {
        let me = Bundle.main.bundleIdentifier
        var names: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let id = app.bundleIdentifier, id != me, id != "com.apple.finder" { names[id] = app.localizedName ?? id }
        }
        for id in prefs.focusApps where names[id] == nil {
            names[id] = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                .map { FileManager.default.displayName(atPath: $0.path) } ?? id
        }
        return names.map { (id: $0.key, name: $0.value) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func toggleFocusApp(_ id: String) {
        if let i = prefs.focusApps.firstIndex(of: id) { prefs.focusApps.remove(at: i) } else { prefs.focusApps.append(id) }
    }

    /// On: quits the picked apps (normally, so they can ask to save) and remembers which ones were running.
    /// Off: reopens those in the background.
    func toggleFocus() {
        if let quit = prefs.focusQuit {
            for id in quit {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            }
            prefs.focusQuit = nil
            flash(quit.isEmpty ? "Focus Mode off" : "Focus Mode off — reopening \(quit.count) app(s)")
        } else {
            let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier.map(prefs.focusApps.contains) ?? false }
            apps.forEach { $0.terminate() }
            prefs.focusQuit = apps.compactMap(\.bundleIdentifier)
            flash(apps.isEmpty ? "Focus Mode on — none of its apps were running"
                               : "Focus Mode on — quit " + apps.compactMap(\.localizedName).joined(separator: ", "))
        }
    }

    // MARK: Dev

    func refreshDev() {
        guard busy.insert("dev").inserted else { return }
        let needLimits = dockerLimits == nil
        DispatchQueue.global(qos: .utility).async {
            let state = Docker.state()
            let servers = Servers.listening()
            var limits: (memory: UInt64, cpus: Int)?
            if needLimits, case .ready = state { limits = Docker.limits() }
            DispatchQueue.main.async {
                self.docker = state
                self.servers = servers
                if case .ready = state { if let limits { self.dockerLimits = limits } } else { self.dockerLimits = nil }
                self.busy.remove("dev")
            }
        }
        sampleProcesses()
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

    /// "Pause Docker": stops Docker Desktop and its VM (containers stop too); "Start Docker" brings it back.
    func setDocker(running: Bool) {
        guard !dockerSwitching else { return }
        confirmKey = nil
        dockerSwitching = true
        flash(running ? "Starting Docker…" : "Stopping Docker and its VM…")
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Docker.setDesktopRunning(running)
            DispatchQueue.main.async {
                self.dockerSwitching = false
                self.dockerLimits = nil
                self.flash(ok ? (running ? "Docker is starting" : "Docker stopped — its VM memory is free again")
                              : "Couldn't \(running ? "start" : "stop") Docker")
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

    func scanStartup() {
        guard busy.insert("startup").inserted else { return }
        scanningStartup = true
        DispatchQueue.global(qos: .utility).async {
            let items = StartupItems.scan()
            DispatchQueue.main.async {
                self.startupItems = items
                self.scanningStartup = false
                self.busy.remove("startup")
            }
        }
    }

    func setStartup(_ item: StartupItem, enabled: Bool) {
        confirmKey = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = enabled ? StartupItems.enable(item) : StartupItems.disable(item)
            DispatchQueue.main.async {
                self.flash(ok ? "\(item.title) \(enabled ? "enabled" : "disabled")" : "\(item.title): change cancelled or failed")
                self.scanStartup()
            }
        }
    }

    /// The latest sample of a process, for showing what a startup item costs.
    func process(_ pid: pid_t) -> ProcInfo? { processes.first { $0.id == pid } }

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
