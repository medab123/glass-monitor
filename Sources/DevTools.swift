import AppKit

// MARK: - Docker

struct DockerContainer: Identifiable {
    let id: String
    let name: String
    let image: String
    let running: Bool
    let status: String
    let project: String
    /// Compose project folder, used to match containers to a Laravel project.
    let workingDir: String
    var cpu = ""
    var memory = ""
}

enum DockerState {
    case loading
    case unavailable(String)
    case ready([DockerContainer])
}

enum Docker {
    static let binary = [
        "/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    static func state() -> DockerState {
        guard let binary else { return .unavailable("Docker isn't installed") }
        let format = "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.State}}\t{{.Status}}\t{{.Label \"com.docker.compose.project\"}}\t{{.Label \"com.docker.compose.project.working_dir\"}}"
        let ps = Shell.run(binary, ["ps", "-a", "--format", format])
        guard ps.status == 0 else { return .unavailable("Docker isn't running") }

        var containers = ps.output.split(separator: "\n").compactMap { line -> DockerContainer? in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 7 else { return nil }
            return DockerContainer(id: f[0], name: f[1], image: f[2], running: f[3] == "running", status: f[4],
                                   project: f[5], workingDir: f[6])
        }

        if containers.contains(where: \.running) {
            let stats = Shell.run(binary, ["stats", "--no-stream", "--format", "{{.ID}}\t{{.CPUPerc}}\t{{.MemUsage}}"]).output
            var byID: [String: (String, String)] = [:]
            for line in stats.split(separator: "\n") {
                let f = line.split(separator: "\t").map(String.init)
                if f.count >= 3 { byID[f[0]] = (f[1], f[2].components(separatedBy: " / ").first ?? f[2]) }
            }
            for i in containers.indices {
                if let s = byID[containers[i].id] { (containers[i].cpu, containers[i].memory) = s }
            }
        }

        return .ready(containers.sorted {
            ($0.running ? 0 : 1, $0.project, $0.name) < ($1.running ? 0 : 1, $1.project, $1.name)
        })
    }

    /// start / stop / restart a container by ID.
    static func perform(_ action: String, _ id: String) -> Bool {
        guard let binary else { return false }
        return Shell.run(binary, [action, id]).status == 0
    }
}

// MARK: - Laravel projects

struct LaravelProject: Identifiable {
    let id: String
    var name: String { (id as NSString).lastPathComponent }
    /// ERROR or worse in the last 24 hours; `truncated` means only the newest part of a huge log was read.
    let errors: Int
    let truncated: Bool
    let lastError: String?
    let lastErrorDate: Date?
    /// The log holding the newest error (or the newest log).
    let logPath: String?

    func containers(in docker: DockerState) -> [DockerContainer] {
        guard case .ready(let all) = docker else { return [] }
        return all.filter { $0.workingDir == id || $0.workingDir.hasPrefix(id + "/") }
    }
}

enum Laravel {
    private static let roots = ["Documents", "Projects", "Developer", "Sites", "code", "dev", "src", "Herd"]
    /// Tail read per log; enough for a day of a busy app without reading 200 MB logs whole.
    private static let tailBytes = 4 << 20

    /// Folders containing an `artisan` file.
    static func projects() -> [String] {
        let home = NSHomeDirectory()
        let existing = roots.map { (home as NSString).appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return [] }
        return Shell.run("/usr/bin/find", existing + [
            "-maxdepth", "6", "(", "-name", "node_modules", "-o", "-name", "vendor", "-o", "-name", ".git",
            "-o", "-name", "Library", "-o", "-name", "storage", ")", "-prune", "-o", "-type", "f", "-name", "artisan", "-print",
        ]).output.split(separator: "\n").map { (String($0) as NSString).deletingLastPathComponent }
    }

    /// Errors logged in the last 24 hours across the project's storage/logs (and per-channel subfolders).
    static func scan(_ project: String) -> LaravelProject {
        let folder = URL(fileURLWithPath: project).appendingPathComponent("storage/logs")
        let since = Date().addingTimeInterval(-86_400)
        var logs: [(path: String, modified: Date)] = []
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        while let url = enumerator?.nextObject() as? URL {
            if enumerator?.level ?? 0 >= 2 { enumerator?.skipDescendants() }
            guard url.pathExtension == "log",
                  let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified >= since else { continue }
            logs.append((url.path, modified))
        }

        var errors = 0, truncated = false
        var last: (message: String, date: Date, path: String)?
        for log in logs {
            let result = countErrors(in: log.path, since: since)
            errors += result.count
            truncated = truncated || result.truncated
            if let l = result.last, l.date > (last?.date ?? .distantPast) { last = (l.message, l.date, log.path) }
        }
        return LaravelProject(id: project, errors: errors, truncated: truncated, lastError: last?.message,
                              lastErrorDate: last?.date, logPath: last?.path ?? logs.max { $0.modified < $1.modified }?.path)
    }

    private static func countErrors(in path: String, since: Date) -> (count: Int, truncated: Bool, last: (message: String, date: Date)?) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return (0, false, nil) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return (0, false, nil) }

        var count = 0, sawOld = false
        var last: (String, Date)?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let entry = errorEntry(line) else { continue }
            if entry.date < since { sawOld = true; continue }
            count += 1
            last = (entry.message, entry.date)
        }
        // Only the newest part was read and nothing in it predates the window: older errors may be missing.
        return (count, start > 0 && !sawOld && count > 0, last)
    }

    /// An ERROR-or-worse line in Laravel's line format or a JSON (Monolog / ECS) format; nil for anything else.
    private static func errorEntry(_ line: Substring) -> (date: Date, message: String)? {
        if line.hasPrefix("[") {
            guard let level = lineLevels.first(where: { line.prefix(80).contains($0) }),
                  let date = timestamp(line), let range = line.range(of: level) else { return nil }
            return (date, String(line[range.upperBound...].trimmingCharacters(in: .whitespaces).prefix(160)))
        }
        guard line.hasPrefix("{"), jsonLevels.contains(where: { line.contains($0) }),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let level = (object["log.level"] ?? object["level_name"]) as? String,
              errorNames.contains(level.uppercased()),
              let stamp = (object["@timestamp"] ?? object["datetime"]) as? String,
              let date = isoFormatter.date(from: stamp) ?? isoFormatterNoFraction.date(from: stamp) else { return nil }
        return (date, String(((object["message"] as? String) ?? level).prefix(160)))
    }

    private static let errorNames: Set<String> = ["ERROR", "CRITICAL", "ALERT", "EMERGENCY"]
    private static let lineLevels = errorNames.map { ".\($0):" }
    private static let jsonLevels = errorNames.map { "\"\($0)\"" } + errorNames.map { "\"\($0.lowercased())\"" }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoFormatterNoFraction = ISO8601DateFormatter()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// "[2026-10-28 17:40:10]" (Laravel default, app timezone — assumed UTC) or "[2026-10-28T17:40:10.0167+00:00]".
    private static func timestamp(_ line: Substring) -> Date? {
        guard line.count > 21 else { return nil }
        let body = line.dropFirst()
        let stamp = String(body.prefix(19)).replacingOccurrences(of: "T", with: " ")
        guard var date = formatter.date(from: stamp) else { return nil }
        let rest = body.dropFirst(19).prefix { $0 != "]" }
        if let sign = rest.firstIndex(where: { $0 == "+" || $0 == "-" }) {
            let parts = rest[rest.index(after: sign)...].split(separator: ":")
            if parts.count == 2, let h = Double(parts[0]), let m = Double(parts[1]) {
                date.addTimeInterval((rest[sign] == "+" ? -1 : 1) * (h * 3_600 + m * 60))
            }
        }
        return date
    }
}

// MARK: - Listening servers

struct ListeningServer: Identifiable {
    let id: pid_t
    let name: String
    let ports: [Int]
    let appName: String?
    let bundlePath: String?
}

enum Servers {
    /// Your processes with listening TCP sockets (lsof only sees the current user's without root).
    static func listening() -> [ListeningServer] {
        let output = Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"]).output
        var found: [pid_t: (name: String, ports: Set<Int>)] = [:]
        var pid: pid_t = 0
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = line.dropFirst()
            switch tag {
            case "p": pid = Int32(value) ?? 0
            case "c": found[pid] = (String(value), found[pid]?.ports ?? [])
            case "n": if let port = value.split(separator: ":").last.flatMap({ Int($0) }) { found[pid]?.ports.insert(port) }
            default: break
            }
        }
        return found.map { pid, entry in
            let identity = ProcessList.identity(of: pid)
            return ListeningServer(id: pid, name: entry.name, ports: entry.ports.sorted(),
                                   appName: identity.appName, bundlePath: identity.bundlePath)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Disk cleanup

struct CleanItem: Identifiable {
    enum Action {
        /// Move everything inside these folders to the Trash (the folders themselves stay).
        case trashContents([String])
        /// Move these folders to the Trash.
        case trashItems([String])
        case command(String, [String])
        case reveal(String)
    }

    let id: String
    let title: String
    let detail: String
    let symbol: String
    let action: Action
    var sizeText: String?
    var size: Int64 = 0

    var actionTitle: String {
        switch action {
        case .trashContents, .trashItems: "Move to Trash"
        case .command: "Run"
        case .reveal: "Show"
        }
    }
}

enum Cleaner {
    private static let home = NSHomeDirectory()
    private static func path(_ relative: String) -> String { (home as NSString).appendingPathComponent(relative) }
    private static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    /// Regenerable developer caches that tend to grow huge. Only ones present on this Mac are listed.
    static func items() -> [CleanItem] {
        var items: [CleanItem] = []
        func folder(_ id: String, _ title: String, _ detail: String, _ symbol: String, _ relatives: [String]) {
            let paths = relatives.map(path).filter(exists)
            if !paths.isEmpty {
                items.append(CleanItem(id: id, title: title, detail: detail, symbol: symbol, action: .trashContents(paths)))
            }
        }
        folder("derived", "Xcode DerivedData", "Build caches — Xcode rebuilds them", "hammer",
               ["Library/Developer/Xcode/DerivedData"])
        folder("devicesupport", "iOS Device Support", "Debug symbols, re-created when a device connects", "iphone",
               ["Library/Developer/Xcode/iOS DeviceSupport"])
        folder("simcaches", "Simulator Caches", "Re-created by the iOS Simulator", "ipad.and.iphone",
               ["Library/Developer/CoreSimulator/Caches"])
        if exists("/usr/bin/xcrun"), exists(path("Library/Developer/CoreSimulator/Devices")) {
            items.append(CleanItem(id: "simunavailable", title: "Unavailable Simulators",
                                   detail: "Simulators for iOS versions you no longer have", symbol: "xmark.app",
                                   action: .command("/usr/bin/xcrun", ["simctl", "delete", "unavailable"]), sizeText: "—"))
        }
        folder("homebrew", "Homebrew Downloads", "Cached bottles and installers", "mug", ["Library/Caches/Homebrew"])
        folder("npm", "npm Cache", "Re-downloaded on the next install", "shippingbox", [".npm/_cacache"])
        folder("yarn", "Yarn Cache", "Re-downloaded on the next install", "shippingbox", ["Library/Caches/Yarn"])
        folder("pnpm", "pnpm Store", "Re-downloaded on the next install", "shippingbox", ["Library/pnpm/store"])
        folder("composer", "Composer Cache", "PHP packages, re-downloaded when needed", "shippingbox",
               ["Library/Caches/composer", ".composer/cache", ".cache/composer"])
        folder("pip", "pip Cache", "Python packages, re-downloaded when needed", "shippingbox", ["Library/Caches/pip"])
        if let docker = Docker.binary {
            // Deliberately not `system prune`: that would also delete stopped containers (e.g. compose stacks).
            items.append(CleanItem(id: "docker", title: "Docker Images & Build Cache",
                                   detail: "Unused images and build cache — keeps all containers and volumes",
                                   symbol: "cube.box",
                                   action: .command("/bin/sh", ["-c", "\"$0\" image prune -af && \"$0\" builder prune -af", docker])))
        }
        if exists(path("Library/Developer/Xcode/Archives")) {
            items.append(CleanItem(id: "archives", title: "Xcode Archives", detail: "Your archived builds — review before deleting",
                                   symbol: "archivebox", action: .reveal(path("Library/Developer/Xcode/Archives"))))
        }
        items.append(CleanItem(id: "trash", title: "Trash", detail: "Empty it in Finder to actually free the space",
                               symbol: "trash", action: .reveal(path(".Trash"))))
        return items
    }

    /// Fills in sizeText/size. Slow (du), call off the main thread.
    static func measure(_ item: CleanItem) -> CleanItem {
        var item = item
        switch item.action {
        case .trashContents(let paths), .trashItems(let paths):
            item.size = size(of: paths)
            item.sizeText = item.size > 0 ? bytes(Double(item.size)) : "Empty"
        case .reveal(let path):
            item.size = size(of: [path])
            item.sizeText = item.size > 0 ? bytes(Double(item.size)) : "—"
        case .command where item.id == "docker":
            item.size = dockerReclaimable() ?? 0
            item.sizeText = item.size > 0 ? bytes(Double(item.size)) : "Nothing to free"
        case .command:
            break
        }
        return item
    }

    /// Performs the clean-up. Off the main thread. Returns a status message.
    static func perform(_ item: CleanItem) -> String {
        switch item.action {
        case .trashContents(let folders):
            let children = folders.flatMap { folder in
                ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
                    .map { (folder as NSString).appendingPathComponent($0) }
            }
            return trash(children, label: item.title)
        case .trashItems(let paths):
            return trash(paths, label: item.title)
        case .command(let tool, let arguments):
            return Shell.run(tool, arguments).status == 0 ? "\(item.title): done" : "\(item.title): failed"
        case .reveal(let path):
            DispatchQueue.main.async { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            return ""
        }
    }

    /// node_modules folders under common project locations, biggest first.
    static func nodeModules() -> [CleanItem] {
        let roots = ["Documents", "Projects", "Developer", "Sites", "code", "dev", "src"].map(path).filter(exists)
        guard !roots.isEmpty else { return [] }
        let found = Shell.run("/usr/bin/find", roots + [
            "-maxdepth", "7", "(", "-name", ".git", "-o", "-name", "vendor", "-o", "-name", "Library", ")", "-prune",
            "-o", "-type", "d", "-name", "node_modules", "-print", "-prune",
        ]).output.split(separator: "\n").map(String.init)
        guard !found.isEmpty else { return [] }

        var sizes: [String: Int64] = [:]
        for line in Shell.run("/usr/bin/du", ["-sk"] + found).output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            if parts.count == 2, let kb = Int64(parts[0]) { sizes[String(parts[1])] = kb * 1024 }
        }
        return found.map { folder in
            let project = ((folder as NSString).deletingLastPathComponent as NSString)
            let size = sizes[folder] ?? 0
            return CleanItem(id: folder, title: project.lastPathComponent,
                             detail: (project as String).replacingOccurrences(of: home, with: "~"),
                             symbol: "folder", action: .trashItems([folder]), sizeText: bytes(Double(size)), size: size)
        }
        .sorted { $0.size > $1.size }
    }

    private static func size(of paths: [String]) -> Int64 {
        Shell.run("/usr/bin/du", ["-sk"] + paths).output.split(separator: "\n").reduce(0) { total, line in
            total + (Int64(line.split(separator: "\t").first ?? "") ?? 0) * 1024
        }
    }

    /// Reclaimable bytes for unused images + build cache, from `docker system df` (decimal units, e.g. "29.04GB (60%)").
    private static func dockerReclaimable() -> Int64? {
        guard let docker = Docker.binary else { return nil }
        let result = Shell.run(docker, ["system", "df", "--format", "{{.Type}}\t{{.Reclaimable}}"])
        guard result.status == 0 else { return nil }
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        return result.output.split(separator: "\n").reduce(Int64(0)) { total, line in
            let f = line.split(separator: "\t").map(String.init)
            guard f.count == 2, f[0] == "Images" || f[0] == "Build Cache",
                  let amount = f[1].components(separatedBy: " ").first,
                  let unit = units.first(where: { amount.hasSuffix($0.0) }),
                  let value = Double(amount.dropLast(unit.0.count)) else { return total }
            return total + Int64(value * unit.1)
        }
    }

    private static func trash(_ paths: [String], label: String) -> String {
        var failed = 0
        for path in paths {
            do { try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) } catch { failed += 1 }
        }
        return failed == 0 ? "\(label) moved to the Trash" : "\(label): \(failed) item(s) couldn't be moved"
    }
}
