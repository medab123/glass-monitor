import Foundation
import UserNotifications

struct MonitorAlert: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
    /// Set for runaway-process alerts, which offer Quit / Ignore.
    let pid: pid_t?
    let processName: String?
}

/// Flags a process that stays above 80% CPU for 2 minutes. Each process is reported once per busy streak.
final class RunawayDetector {
    private static let busyThreshold = 80.0
    private static let calmThreshold = 50.0
    private static let duration: TimeInterval = 120

    private var busySince: [pid_t: Date] = [:]
    private var reported = Set<pid_t>()
    private var ignored = Set(UserDefaults.standard.stringArray(forKey: "ignoredRunaways") ?? []) {
        didSet { UserDefaults.standard.set(Array(ignored), forKey: "ignoredRunaways") }
    }

    func ignore(_ name: String) { ignored.insert(name) }
    func isIgnored(_ name: String) -> Bool { ignored.contains(name) }

    func evaluate(_ processes: [ProcInfo]) -> ProcInfo? {
        let now = Date()
        var found: ProcInfo?
        for p in processes {
            if p.cpu >= Self.busyThreshold, !ignored.contains(p.name), !ProcessList.isProtected(p) {
                let since = busySince[p.id] ?? now
                busySince[p.id] = since
                if found == nil, !reported.contains(p.id), now.timeIntervalSince(since) >= Self.duration {
                    reported.insert(p.id)
                    found = p
                }
            } else if p.cpu < Self.calmThreshold {
                busySince[p.id] = nil
                reported.remove(p.id)
            }
        }
        let live = Set(processes.map(\.id))
        busySince = busySince.filter { live.contains($0.key) }
        reported.formIntersection(live)
        return found
    }
}

/// Flags a process whose memory keeps climbing for an hour: it grows by 500 MB and 50%, and every
/// 10-minute average is at least the one before. Fed one sample per minute.
final class LeakDetector {
    private static let window = 60
    private static let blocks = 6
    private static let minGrowth = Double(500 << 20)

    private var series: [pid_t: (name: String, mem: [UInt64])] = [:]
    /// Memory at the time of reporting; reported again only after dropping 20% below it.
    private var reported: [pid_t: UInt64] = [:]

    func evaluate(_ processes: [ProcInfo], isIgnored: (String) -> Bool) -> (process: ProcInfo, from: UInt64)? {
        var found: (ProcInfo, UInt64)?
        for p in processes {
            var entry: (name: String, mem: [UInt64]) = series[p.id].flatMap { $0.name == p.name ? $0 : nil } ?? (p.name, [])
            entry.mem.append(p.memBytes)
            if entry.mem.count > Self.window { entry.mem.removeFirst() }
            series[p.id] = entry

            if let at = reported[p.id] {
                if Double(p.memBytes) < Double(at) * 0.8 { reported[p.id] = nil }
                continue
            }
            guard found == nil, entry.mem.count == Self.window, !isIgnored(p.name), !ProcessList.isProtected(p) else { continue }
            let size = Self.window / Self.blocks
            let averages = stride(from: 0, to: Self.window, by: size).map { start in
                Double(entry.mem[start..<start + size].reduce(0, +)) / Double(size)
            }
            guard let first = averages.first, let last = averages.last else { continue }
            let rising = zip(averages, averages.dropFirst()).allSatisfy { $1 >= $0 * 0.99 }
            if rising, last - first >= Self.minGrowth, last >= first * 1.5 {
                reported[p.id] = p.memBytes
                found = (p, UInt64(first))
            }
        }
        let live = Set(processes.map(\.id))
        series = series.filter { live.contains($0.key) }
        reported = reported.filter { live.contains($0.key) }
        return found
    }
}

/// macOS notifications with Quit / Ignore actions for runaway processes.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onQuit: ((pid_t) -> Void)?
    var onIgnore: ((String) -> Void)?
    var onOpen: (() -> Void)?

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let quit = UNNotificationAction(identifier: "QUIT", title: "Quit Process", options: [.destructive])
        let ignore = UNNotificationAction(identifier: "IGNORE", title: "Ignore This Process")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "RUNAWAY", actions: [quit, ignore], intentIdentifiers: []),
        ])
    }

    func post(_ alert: MonitorAlert) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.detail
        content.sound = .default
        if let pid = alert.pid, let name = alert.processName {
            content.categoryIdentifier = "RUNAWAY"
            content.userInfo = ["pid": Int(pid), "name": name]
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: alert.id.uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let pid = (info["pid"] as? Int).map { pid_t($0) }
        let name = info["name"] as? String
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            switch action {
            case "QUIT": if let pid { self.onQuit?(pid) }
            case "IGNORE": if let name { self.onIgnore?(name) }
            default: self.onOpen?()
            }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
