import AppKit

struct RowMetrics {
    var cpu: Double
    var mem: UInt64
    var disk: Double?
    var net: Double?
    /// macOS "Energy Impact" (the Energy tab of Activity Monitor); only sampled while the Energy tab is open.
    var energy: Double?
    /// Memory macOS compressed or moved to swap (footprint not resident in RAM); nil for other users' processes.
    var compressed: UInt64?
}

/// What an interpreter (Python, Node, PHP…), Claude Code or an emulator is actually running,
/// so a row reads "scrape.py" instead of "Python".
struct ScriptInfo: Equatable {
    let title: String
    /// The remaining arguments, which tell several runs of the same script apart.
    let arguments: String
    /// Working directory, "~/…".
    let folder: String?

    var key: String { "\(title) \(arguments)|\(folder ?? "")" }
    var subtitle: String { [arguments, folder ?? ""].filter { !$0.isEmpty }.joined(separator: " · ") }
}

struct ProcInfo: Identifiable {
    let id: pid_t
    let name: String
    let user: String
    let cpu: Double
    /// Memory footprint (Activity Monitor's "Memory", including compressed and swapped memory) when readable,
    /// otherwise resident size.
    let memBytes: UInt64
    var compressed: UInt64?
    /// Bytes/s; nil when macOS doesn't let us read it (other users' processes) or on the first sample.
    var diskRate: Double?
    var netRate: Double?
    var energy: Double?
    let appName: String?
    let bundlePath: String?
    var script: ScriptInfo?

    /// Each script run is its own group, so two scrapers don't merge into one "Python" row.
    var groupKey: String { script.map { "script:\($0.key)" } ?? bundlePath ?? "proc:\(name)" }
    var displayName: String { script?.title ?? name }
    var metrics: RowMetrics {
        RowMetrics(cpu: cpu, mem: memBytes, disk: diskRate, net: netRate, energy: energy, compressed: compressed)
    }
}

/// All processes belonging to one app bundle (e.g. Chrome and its helpers), or sharing a name.
struct AppGroup: Identifiable {
    let id: String
    let processes: [ProcInfo]
    let metrics: RowMetrics

    init(id: String, processes: [ProcInfo]) {
        self.id = id
        self.processes = processes
        metrics = processes.reduce(into: RowMetrics(cpu: 0, mem: 0)) { total, p in
            total.cpu += p.cpu
            total.mem += p.memBytes
            if let d = p.diskRate { total.disk = (total.disk ?? 0) + d }
            if let n = p.netRate { total.net = (total.net ?? 0) + n }
            if let e = p.energy { total.energy = (total.energy ?? 0) + e }
            if let c = p.compressed { total.compressed = (total.compressed ?? 0) + c }
        }
    }

    var name: String { processes.first.map { $0.script?.title ?? $0.appName ?? $0.name } ?? "?" }
    var script: ScriptInfo? { processes.first?.script }
    var bundlePath: String? { processes.first?.bundlePath }
    var user: String { processes.first?.user ?? "" }
}

enum ProcessList {
    static let protectedNames: Set<String> = ["kernel_task", "launchd", "WindowServer", "loginwindow"]

    static func isProtected(_ p: ProcInfo) -> Bool {
        protectedNames.contains(p.name) || p.id == getpid()
    }

    /// The outermost .app bundle a process runs from, so "Google Chrome Helper" resolves to Google Chrome.
    static func identity(of pid: pid_t) -> (appName: String?, bundlePath: String?) {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return (nil, nil) }
        let path = String(cString: buffer)
        guard let range = path.range(of: ".app/") else { return (nil, nil) }
        let bundle = String(path[..<range.lowerBound]) + ".app"
        return (FileManager.default.displayName(atPath: bundle), bundle)
    }

    /// Disk bytes read + written, memory footprint and resident size; nil without permission (other users' processes).
    /// Footprint − resident is the memory macOS compressed or swapped out: it matches `top`'s CMPRS column
    /// without the second of CPU a `top` run costs.
    static func usage(of pid: pid_t) -> (disk: UInt64, footprint: UInt64, resident: UInt64)? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        // Wrapping add: some processes report garbage counters near UInt64.max, and a plain + traps.
        return (info.ri_diskio_bytesread &+ info.ri_diskio_byteswritten, info.ri_phys_footprint, info.ri_resident_size)
    }

    private static let interpreters: Set<String> = ["node", "php", "ruby", "perl", "bun", "deno"]
    /// Interpreter flags that take a value, so the value isn't mistaken for the script.
    private static let flagsWithValue: Set<String> = ["-W", "-X", "-r", "--require", "--import", "--loader", "-d"]

    /// The script an interpreter runs (with its arguments and folder), Claude Code's project folder,
    /// or the Android emulator's device name. nil for everything else. Reads the process's own arguments,
    /// so it only works for your processes.
    static func script(of pid: pid_t, name: String) -> ScriptInfo? {
        let lower = name.lowercased()
        let isClaude = name == "claude" // the Claude Code CLI; the desktop app is "Claude"
        let isEmulator = lower.hasPrefix("qemu-system")
        guard isClaude || isEmulator || lower.hasPrefix("python") || interpreters.contains(lower),
              let args = arguments(of: pid) else { return nil }
        let folder = workingDirectory(of: pid).map { ($0 as NSString).abbreviatingWithTildeInPath }

        if isClaude { return ScriptInfo(title: "Claude Code", arguments: "", folder: folder) }
        if isEmulator {
            guard let i = args.firstIndex(of: "-avd"), i + 1 < args.count else { return nil }
            return ScriptInfo(title: "Android Emulator", arguments: args[i + 1], folder: nil)
        }

        var rest = args.dropFirst()
        var title: String?
        while let token = rest.popFirst() {
            if token == "-m", let module = rest.popFirst() { title = module; break }
            if token == "-c" || token == "-e" { title = "\(name) \(token)"; rest = []; break }
            if flagsWithValue.contains(token) { _ = rest.popFirst(); continue }
            if token.hasPrefix("-") { continue }
            title = (token as NSString).lastPathComponent
            break
        }
        guard var shown = title else { return nil }
        // `php artisan queue:work` reads better with the command in the title.
        if shown == "artisan", let command = rest.popFirst() { shown += " \(command)" }
        return ScriptInfo(title: shown, arguments: String(rest.joined(separator: " ").prefix(120)), folder: folder)
    }

    /// argv via KERN_PROCARGS2: an argc int, the executable path, padding, then the arguments.
    private static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 } // executable path
        while index < size, buffer[index] == 0 { index += 1 } // padding
        var args: [String] = []
        while args.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }

    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty || path == "/" ? nil : path
    }
}

/// Main-thread icon cache keyed by bundle path.
enum Icons {
    private static var cache: [String: NSImage] = [:]

    static func app(_ bundlePath: String) -> NSImage {
        if let cached = cache[bundlePath] { return cached }
        let image = NSWorkspace.shared.icon(forFile: bundlePath)
        cache[bundlePath] = image
        return image
    }
}

/// Samples the process table off the main thread, turning cumulative disk/network counters into rates.
final class ProcessSampler {
    private let queue = DispatchQueue(label: "glassmonitor.sampler", qos: .utility)
    private var identities: [pid_t: (appName: String?, bundlePath: String?, script: ScriptInfo?)] = [:]
    private var lastDisk: [pid_t: UInt64] = [:]
    private var lastDiskTime: Date?
    private var lastNet: [pid_t: UInt64] = [:]
    private var lastNetTime: Date?
    /// `top` takes a second and real CPU, so energy figures are reused for a few seconds between runs.
    private var energyCache: (at: Date, values: [pid_t: Double])?

    func sample(network: Bool, energy: Bool, completion: @escaping ([ProcInfo]) -> Void) {
        queue.async {
            let list = self.collect(network: network, energy: energy)
            DispatchQueue.main.async { completion(list) }
        }
    }

    private func collect(network: Bool, energy: Bool) -> [ProcInfo] {
        let now = Date()
        let diskInterval = lastDiskTime.map { now.timeIntervalSince($0) }
        let netTotals = network ? nettop() : [:]
        var energyImpact: [pid_t: Double] = [:]
        if energy {
            if let cache = energyCache, now.timeIntervalSince(cache.at) < 6 {
                energyImpact = cache.values
            } else {
                energyImpact = energyImpacts()
                energyCache = (now, energyImpact)
            }
        }
        let netInterval = network ? lastNetTime.map { now.timeIntervalSince($0) } : nil

        var disk: [pid_t: UInt64] = [:]
        var result: [ProcInfo] = []
        for row in ps() {
            let identity = identities[row.pid] ?? {
                let app = ProcessList.identity(of: row.pid)
                return (app.appName, app.bundlePath, ProcessList.script(of: row.pid, name: row.name))
            }()
            identities[row.pid] = identity

            let usage = ProcessList.usage(of: row.pid)
            var diskRate: Double?
            if let total = usage?.disk {
                disk[row.pid] = total
                if let dt = diskInterval, let previous = lastDisk[row.pid] {
                    diskRate = Double(total &- previous) / dt
                    if total < previous { diskRate = 0 }
                }
            }

            var netRate: Double?
            if let dt = netInterval {
                let total = netTotals[row.pid] ?? 0
                let previous = lastNet[row.pid] ?? total
                netRate = total >= previous ? Double(total - previous) / dt : 0
            }

            result.append(ProcInfo(id: row.pid, name: row.name, user: row.user, cpu: row.cpu,
                                   memBytes: usage?.footprint ?? row.mem,
                                   compressed: usage.map { $0.footprint > $0.resident ? $0.footprint - $0.resident : 0 },
                                   diskRate: diskRate, netRate: netRate,
                                   energy: energy ? energyImpact[row.pid] ?? 0 : nil,
                                   appName: identity.appName, bundlePath: identity.bundlePath, script: identity.script))
        }

        lastDisk = disk
        lastDiskTime = now
        if network {
            lastNet = netTotals
            lastNetTime = now
        } else {
            lastNetTime = nil
        }
        let live = Set(result.map(\.id))
        identities = identities.filter { live.contains($0.key) }
        return result
    }

    private func ps() -> [(pid: pid_t, cpu: Double, mem: UInt64, user: String, name: String)] {
        Shell.run("/bin/ps", ["-Aco", "pid=,pcpu=,rss=,user=,comm="]).output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count == 5, let pid = Int32(parts[0]), pid > 1,
                  let cpu = Double(parts[1]), let rssKB = UInt64(parts[2]) else { return nil }
            return (pid, cpu, rssKB * 1024, String(parts[3]), parts[4].trimmingCharacters(in: .whitespaces))
        }
    }

    /// Per-process energy impact from `top` (the same figure as Activity Monitor). The first `top` sample has no
    /// rates yet, so take two samples a second apart and read the second table.
    private func energyImpacts() -> [pid_t: Double] {
        let output = Shell.run("/usr/bin/top", ["-l", "2", "-s", "1", "-n", "400", "-o", "power", "-stats", "pid,power"]).output
        guard let table = output.components(separatedBy: "PID").last else { return [:] }
        var result: [pid_t: Double] = [:]
        for line in table.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let pid = Int32(parts[0]), let power = Double(parts[1]) else { continue }
            result[pid] = power
        }
        return result
    }

    /// Per-process bytes in + out from `nettop`, keyed by pid ("name.pid,in,out," lines).
    private func nettop() -> [pid_t: UInt64] {
        let output = Shell.run("/usr/bin/nettop", ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"]).output
        var totals: [pid_t: UInt64] = [:]
        for line in output.split(separator: "\n").dropFirst() {
            let columns = line.split(separator: ",", omittingEmptySubsequences: false)
            guard columns.count >= 3, let dot = columns[0].lastIndex(of: "."),
                  let pid = Int32(columns[0][columns[0].index(after: dot)...]) else { continue }
            totals[pid, default: 0] &+= (UInt64(columns[1]) ?? 0) &+ (UInt64(columns[2]) ?? 0)
        }
        return totals
    }
}
