import Foundation

/// A launch agent or daemon from the standard folders: what starts in the background at login or boot.
/// (Apps added under System Settings → Login Items aren't listed; macOS has no public API for them.)
struct StartupItem: Identifiable {
    enum Scope {
        /// ~/Library/LaunchAgents: runs as you, at login.
        case user
        /// /Library/LaunchAgents: runs as each user, at login.
        case allUsers
        /// /Library/LaunchDaemons: runs as root, at boot.
        case system

        var title: String {
            switch self {
            case .user: "Your login agent"
            case .allUsers: "Login agent for all users"
            case .system: "System daemon"
            }
        }
    }

    /// The launchd label.
    let id: String
    let plist: String
    let program: String?
    let scope: Scope
    let disabled: Bool
    let pid: pid_t?
    let bundlePath: String?

    var domain: String { scope == .system ? "system" : "gui/\(getuid())" }
    var isGlassMonitor: Bool { id == LoginItem.label }

    /// The app it belongs to, else the label (program names are often generic, like `open` or `sh`).
    var title: String { bundlePath.map { FileManager.default.displayName(atPath: $0) } ?? id }
}

enum StartupItems {
    private static let folders: [(path: String, scope: StartupItem.Scope)] = [
        ((NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents"), .user),
        ("/Library/LaunchAgents", .allUsers),
        ("/Library/LaunchDaemons", .system),
    ]

    /// Slow-ish (one `launchctl print` per daemon): call off the main thread.
    static func scan() -> [StartupItem] {
        let userDomain = "gui/\(getuid())"
        let disabledUser = disabledLabels(in: userDomain)
        let disabledSystem = disabledLabels(in: "system")
        let runningUser = runningJobs()

        var items: [StartupItem] = []
        for folder in folders {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for file in files where file.hasSuffix(".plist") {
                let path = (folder.path as NSString).appendingPathComponent(file)
                guard let plist = NSDictionary(contentsOfFile: path) as? [String: Any],
                      let label = plist["Label"] as? String else { continue }
                let arguments = plist["ProgramArguments"] as? [String] ?? []
                let program = plist["Program"] as? String ?? arguments.first
                let system = folder.scope == .system
                let disabled = (system ? disabledSystem : disabledUser)[label] ?? (plist["Disabled"] as? Bool ?? false)
                items.append(StartupItem(id: label, plist: path, program: program, scope: folder.scope, disabled: disabled,
                                         pid: system ? systemPID(label) : runningUser[label],
                                         // e.g. `open -a "/Applications/Free Download Manager.app/…"`
                                         bundlePath: ([program].compactMap { $0 } + arguments).lazy.compactMap(outermostBundle).first))
            }
        }
        return items.sorted { ($0.pid == nil ? 1 : 0, $0.title.lowercased()) < ($1.pid == nil ? 1 : 0, $1.title.lowercased()) }
    }

    /// Stops it now and keeps it from starting again; system daemons ask for an admin password.
    static func disable(_ item: StartupItem) -> Bool {
        let target = "\(item.domain)/\(item.id)"
        if item.scope == .system {
            return Shell.admin("/bin/launchctl disable '\(target)'; /bin/launchctl bootout '\(target)' || true")
        }
        guard Shell.run("/bin/launchctl", ["disable", target]).status == 0 else { return false }
        _ = Shell.run("/bin/launchctl", ["bootout", target])
        return true
    }

    /// Allows it again and starts it.
    static func enable(_ item: StartupItem) -> Bool {
        let target = "\(item.domain)/\(item.id)"
        if item.scope == .system {
            return Shell.admin("/bin/launchctl enable '\(target)'; /bin/launchctl bootstrap system '\(item.plist)' || true")
        }
        guard Shell.run("/bin/launchctl", ["enable", target]).status == 0 else { return false }
        _ = Shell.run("/bin/launchctl", ["bootstrap", item.domain, item.plist])
        return true
    }

    /// `"label" => disabled` / `=> enabled` lines (older macOS: `=> true` / `=> false`).
    private static func disabledLabels(in domain: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for line in Shell.run("/bin/launchctl", ["print-disabled", domain]).output.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            result[label] = value == "disabled" || value == "true"
        }
        return result
    }

    /// Your jobs that are running, label → pid, from `launchctl list` ("PID Status Label", "-" when not running).
    private static func runningJobs() -> [String: pid_t] {
        var result: [String: pid_t] = [:]
        for line in Shell.run("/bin/launchctl", ["list"]).output.split(separator: "\n").dropFirst() {
            let columns = line.split(separator: "\t")
            if columns.count == 3, let pid = pid_t(columns[0]) { result[String(columns[2])] = pid }
        }
        return result
    }

    private static func systemPID(_ label: String) -> pid_t? {
        let output = Shell.run("/bin/launchctl", ["print", "system/\(label)"]).output
        guard let line = output.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("pid = ") })
        else { return nil }
        return pid_t(line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? "")
    }

    private static func outermostBundle(_ path: String) -> String? {
        if path.hasSuffix(".app") { return path }
        return path.range(of: ".app/").map { String(path[..<$0.lowerBound]) + ".app" }
    }
}
