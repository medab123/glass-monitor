import AppKit

enum Shell {
    /// Runs a tool and returns its exit status and stdout (stderr is discarded).
    @discardableResult
    static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        task.environment = [
            "LC_ALL": "C",
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Runs a fixed shell command as root via the standard macOS admin password dialog.
    /// Main thread only (NSAppleScript). Returns false if the user cancels or it fails.
    static func admin(_ command: String) -> Bool {
        NSApp.activate()
        var error: NSDictionary?
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
        return error == nil
    }
}

/// One-click fixes offered in the Tools menu. Commands are fixed strings, never built from input.
enum SystemAction: CaseIterable, Identifiable {
    case purge, spotlight, dns, finder, dock

    var id: Self { self }

    var title: String {
        switch self {
        case .purge: "Free Up Memory"
        case .spotlight: "Restart Spotlight Indexing"
        case .dns: "Flush DNS Cache"
        case .finder: "Restart Finder"
        case .dock: "Restart Dock"
        }
    }

    var symbol: String {
        switch self {
        case .purge: "memorychip"
        case .spotlight: "magnifyingglass"
        case .dns: "network"
        case .finder: "folder"
        case .dock: "dock.rectangle"
        }
    }

    var command: String {
        switch self {
        case .purge: "/usr/sbin/purge"
        case .spotlight: "/usr/bin/killall mds mds_stores"
        case .dns: "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder"
        case .finder: "/usr/bin/killall Finder"
        case .dock: "/usr/bin/killall Dock"
        }
    }

    var needsAdmin: Bool { self == .purge || self == .spotlight || self == .dns }

    var doneMessage: String {
        switch self {
        case .purge: "Freed cached memory"
        case .spotlight: "Spotlight restarted — it will re-index in the background"
        case .dns: "DNS cache flushed"
        case .finder: "Finder restarted"
        case .dock: "Dock restarted"
        }
    }
}
