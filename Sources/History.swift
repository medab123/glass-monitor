import Foundation
import SQLite3

struct HistoryPoint: Identifiable {
    let date: Date
    let cpu: Double
    let memory: Double
    let swap: UInt64
    var id: Date { date }
}

/// One app's usage at a recorded minute, or averaged over a range.
struct HistoryApp: Identifiable {
    let id: String
    let name: String
    let bundlePath: String?
    let cpu: Double
    let memBytes: UInt64
}

enum HistoryRange: Int, CaseIterable, Identifiable {
    case hour = 3_600, sixHours = 21_600, day = 86_400, week = 604_800

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .hour: "1h"
        case .sixHours: "6h"
        case .day: "24h"
        case .week: "7d"
        }
    }
}

/// A week of per-minute system and per-app usage in SQLite, so you can look back at "why was it slow at 3pm".
/// All database work runs on one serial queue.
final class HistoryStore {
    static let retention: TimeInterval = 7 * 86_400
    /// Points per chart; longer ranges are averaged into buckets.
    private static let chartPoints = 240

    private let queue = DispatchQueue(label: "glassmonitor.history", qos: .utility)
    private var db: OpaquePointer?
    private var lastPrune = Date.distantPast

    init() {
        queue.async { self.open() }
    }

    private func open() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GlassMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard sqlite3_open(folder.appendingPathComponent("history.sqlite").path, &db) == SQLITE_OK else { db = nil; return }
        exec("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS samples (ts INTEGER PRIMARY KEY, cpu REAL, memory REAL, swap INTEGER);
            CREATE TABLE IF NOT EXISTS apps (ts INTEGER, key TEXT, name TEXT, bundle TEXT, cpu REAL, mem INTEGER);
            CREATE INDEX IF NOT EXISTS apps_ts ON apps (ts);
            """)
    }

    func record(at date: Date, cpu: Double, memory: Double, swap: UInt64, apps: [HistoryApp]) {
        queue.async {
            guard self.db != nil else { return }
            let ts = Int64(date.timeIntervalSince1970)
            self.exec("BEGIN")
            self.run("INSERT OR REPLACE INTO samples VALUES (?, ?, ?, ?)", [ts, cpu, memory, Int64(swap)])
            for app in apps {
                self.run("INSERT INTO apps VALUES (?, ?, ?, ?, ?, ?)",
                         [ts, app.id, app.name, app.bundlePath, app.cpu, Int64(app.memBytes)])
            }
            self.exec("COMMIT")
            if date.timeIntervalSince(self.lastPrune) > 3_600 {
                self.lastPrune = date
                let cutoff = ts - Int64(Self.retention)
                self.run("DELETE FROM samples WHERE ts < ?", [cutoff])
                self.run("DELETE FROM apps WHERE ts < ?", [cutoff])
            }
        }
    }

    func points(_ range: HistoryRange, completion: @escaping ([HistoryPoint]) -> Void) {
        let bucket = Int64(max(60, range.rawValue / Self.chartPoints))
        let since = Int64(Date().timeIntervalSince1970) - Int64(range.rawValue)
        fetch("""
            SELECT (ts / ?1) * ?1 AS t, avg(cpu), avg(memory), max(swap) FROM samples
            WHERE ts >= ?2 GROUP BY t ORDER BY t
            """, [bucket, since], completion: completion) { row in
            HistoryPoint(date: Date(timeIntervalSince1970: Double(sqlite3_column_int64(row, 0))),
                         cpu: sqlite3_column_double(row, 1), memory: sqlite3_column_double(row, 2),
                         swap: UInt64(max(0, sqlite3_column_int64(row, 3))))
        }
    }

    /// The apps recorded at the minute nearest to `date`.
    func apps(at date: Date, completion: @escaping ([HistoryApp]) -> Void) {
        let ts = Int64(date.timeIntervalSince1970)
        fetch("""
            SELECT key, name, bundle, cpu, mem FROM apps
            WHERE ts = (SELECT ts FROM samples ORDER BY abs(ts - ?1) LIMIT 1)
            ORDER BY cpu DESC
            """, [ts], completion: completion, map: Self.app)
    }

    /// Average CPU (over every recorded minute, idle ones counting as 0) and peak memory per app across a range.
    func summary(_ range: HistoryRange, completion: @escaping ([HistoryApp]) -> Void) {
        let since = Int64(Date().timeIntervalSince1970) - Int64(range.rawValue)
        fetch("""
            SELECT key, max(name), max(bundle),
                   sum(cpu) / (SELECT max(count(*), 1) FROM samples WHERE ts >= ?1), max(mem)
            FROM apps WHERE ts >= ?1 GROUP BY key ORDER BY 4 DESC LIMIT 20
            """, [since], completion: completion, map: Self.app)
    }

    private static func app(_ row: OpaquePointer) -> HistoryApp {
        HistoryApp(id: text(row, 0) ?? "", name: text(row, 1) ?? "?", bundlePath: text(row, 2),
                   cpu: sqlite3_column_double(row, 3), memBytes: UInt64(max(0, sqlite3_column_int64(row, 4))))
    }

    // MARK: SQLite helpers (queue only)

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func text(_ row: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(row, column).map { String(cString: $0) }
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func prepare(_ sql: String, _ values: [Any?]) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case let v as Int64: sqlite3_bind_int64(statement, index, v)
            case let v as Double: sqlite3_bind_double(statement, index, v)
            case let v as String: sqlite3_bind_text(statement, index, v, -1, Self.transient)
            default: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    private func run(_ sql: String, _ values: [Any?]) {
        guard let statement = prepare(sql, values) else { return }
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    private func fetch<T>(_ sql: String, _ values: [Any?], completion: @escaping ([T]) -> Void,
                          map: @escaping (OpaquePointer) -> T) {
        queue.async {
            var rows: [T] = []
            if self.db != nil, let statement = self.prepare(sql, values) {
                while sqlite3_step(statement) == SQLITE_ROW { rows.append(map(statement)) }
                sqlite3_finalize(statement)
            }
            DispatchQueue.main.async { completion(rows) }
        }
    }
}

/// State for the History tab, kept apart from `Monitor` so hovering the chart only redraws this tab.
final class Timeline: ObservableObject {
    let store = HistoryStore()

    @Published var range = HistoryRange.day { didSet { reload() } }
    @Published private(set) var points: [HistoryPoint] = []
    @Published private(set) var apps: [HistoryApp] = []
    /// The minute being inspected: the hovered one, else the clicked (pinned) one; nil shows the range summary.
    @Published private(set) var selected: Date?
    @Published private(set) var pinned: Date?
    private var hovered: Date?

    func reload() {
        store.points(range) { [weak self] in self?.points = $0 }
        loadApps()
    }

    func hover(_ date: Date?) {
        hovered = date.map(Self.minute)
        updateSelection()
    }

    func togglePin() {
        pinned = pinned == nil ? hovered : nil
        updateSelection()
    }

    private func updateSelection() {
        let next = hovered ?? pinned
        guard next != selected else { return }
        selected = next
        loadApps()
    }

    private func loadApps() {
        let selection = selected
        let done: ([HistoryApp]) -> Void = { [weak self] apps in
            if self?.selected == selection { self?.apps = apps }
        }
        if let selection { store.apps(at: selection, completion: done) } else { store.summary(range, completion: done) }
    }

    private static func minute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }
}
