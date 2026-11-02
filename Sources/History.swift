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

/// A week in numbers, for the History tab and the Monday notification.
struct WeeklyReport {
    /// Minutes the app recorded (it records nothing while the Mac sleeps or the app is quit).
    let minutes: Int
    let averageCPU: Double
    let averageMemory: Double
    let peakSwap: UInt64
    /// Start of the hour with the highest average CPU.
    let busiestHour: Date?
    /// Average CPU over the recorded minutes.
    let topCPU: [HistoryApp]
    /// Average memory while running.
    let topMemory: [HistoryApp]

    /// One line for a notification, e.g. "CPU 34% · memory 82% · swap peak 18 GB · Biggest: Chrome 3.1 GB".
    var headline: String {
        var parts = ["CPU \(percent(averageCPU))", "memory \(percent(averageMemory))"]
        if peakSwap > 0 { parts.append("swap peak \(bytes(Double(peakSwap)))") }
        let biggest = topMemory.prefix(2).map { "\($0.name) \(bytes(Double($0.memBytes)))" }
        if !biggest.isEmpty { parts.append("Biggest: " + biggest.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
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
        // Incremental auto-vacuum lets pruning give space back to the disk (applies to new files, or after VACUUM).
        exec("""
            PRAGMA auto_vacuum = INCREMENTAL;
            PRAGMA journal_mode = WAL;
            PRAGMA journal_size_limit = 1048576;
            CREATE TABLE IF NOT EXISTS samples (ts INTEGER PRIMARY KEY, cpu REAL, memory REAL, swap INTEGER);
            CREATE TABLE IF NOT EXISTS app_names (id INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE, name TEXT, bundle TEXT);
            CREATE TABLE IF NOT EXISTS app_usage (ts INTEGER NOT NULL, app INTEGER NOT NULL, cpu REAL, mem INTEGER,
                                                  PRIMARY KEY (ts, app)) WITHOUT ROWID;
            """)
        if tableExists("apps") { migrateApps() }
        // Readers keep querying `apps`; names and paths are stored once in app_names instead of on every row.
        exec("""
            CREATE VIEW IF NOT EXISTS apps AS
            SELECT u.ts AS ts, n.key AS key, n.name AS name, n.bundle AS bundle, u.cpu AS cpu, u.mem AS mem
            FROM app_usage u JOIN app_names n ON n.id = u.app;
            """)
    }

    private func tableExists(_ name: String) -> Bool {
        !rows("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1", [name]) { _ in true }.isEmpty
    }

    /// Builds before 1.1 stored key, name and bundle path on every row (~150 bytes); move them to app_names.
    private func migrateApps() {
        exec("""
            BEGIN;
            INSERT OR IGNORE INTO app_names (key, name, bundle) SELECT key, max(name), max(bundle) FROM apps GROUP BY key;
            INSERT OR REPLACE INTO app_usage
                SELECT a.ts, n.id, max(a.cpu), max(a.mem) FROM apps a JOIN app_names n ON n.key = a.key GROUP BY a.ts, n.id;
            DROP TABLE apps;
            COMMIT;
            VACUUM;
            PRAGMA wal_checkpoint(TRUNCATE);
            """)
    }

    func record(at date: Date, cpu: Double, memory: Double, swap: UInt64, apps: [HistoryApp]) {
        queue.async {
            guard self.db != nil else { return }
            let ts = Int64(date.timeIntervalSince1970)
            self.exec("BEGIN")
            self.run("INSERT OR REPLACE INTO samples VALUES (?, ?, ?, ?)", [ts, cpu, memory, Int64(swap)])
            for app in apps {
                // Only writes the name row when it's new or changed.
                self.run("""
                    INSERT INTO app_names (key, name, bundle) VALUES (?1, ?2, ?3) ON CONFLICT (key) DO UPDATE
                    SET name = excluded.name, bundle = excluded.bundle
                    WHERE name IS NOT excluded.name OR bundle IS NOT excluded.bundle
                    """, [app.id, app.name, app.bundlePath])
                self.run("INSERT OR REPLACE INTO app_usage SELECT ?1, id, ?2, ?3 FROM app_names WHERE key = ?4",
                         [ts, app.cpu, Int64(app.memBytes), app.id])
            }
            self.exec("COMMIT")
            if date.timeIntervalSince(self.lastPrune) > 3_600 {
                self.lastPrune = date
                let cutoff = ts - Int64(Self.retention)
                self.run("DELETE FROM samples WHERE ts < ?", [cutoff])
                self.run("DELETE FROM app_usage WHERE ts < ?", [cutoff])
                self.exec("DELETE FROM app_names WHERE id NOT IN (SELECT DISTINCT app FROM app_usage)")
                self.exec("PRAGMA incremental_vacuum; PRAGMA wal_checkpoint(TRUNCATE)")
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

    /// The last 7 days; nil until at least an hour has been recorded.
    func weeklyReport(completion: @escaping (WeeklyReport?) -> Void) {
        let since = Int64(Date().timeIntervalSince1970) - Int64(HistoryRange.week.rawValue)
        queue.async {
            let totals = self.rows("SELECT count(*), avg(cpu), avg(memory), max(swap) FROM samples WHERE ts >= ?1", [since]) {
                (Int(sqlite3_column_int64($0, 0)), sqlite3_column_double($0, 1), sqlite3_column_double($0, 2),
                 UInt64(max(0, sqlite3_column_int64($0, 3))))
            }.first
            guard let totals, totals.0 >= 60 else { return DispatchQueue.main.async { completion(nil) } }
            let busiest = self.rows("""
                SELECT (ts / 3600) * 3600 AS h FROM samples WHERE ts >= ?1
                GROUP BY h HAVING count(*) >= 30 ORDER BY avg(cpu) DESC LIMIT 1
                """, [since]) { Date(timeIntervalSince1970: Double(sqlite3_column_int64($0, 0))) }.first
            let topCPU = self.rows("""
                SELECT key, max(name), max(bundle), sum(cpu) / ?2, avg(mem)
                FROM apps WHERE ts >= ?1 GROUP BY key ORDER BY 4 DESC LIMIT 3
                """, [since, Double(totals.0)], map: Self.app)
            // Only apps seen in at least a tenth of the minutes, so a one-off spike doesn't top the list.
            let topMemory = self.rows("""
                SELECT key, max(name), max(bundle), sum(cpu) / ?2, avg(mem)
                FROM apps WHERE ts >= ?1 GROUP BY key HAVING count(*) >= ?3 ORDER BY 5 DESC LIMIT 3
                """, [since, Double(totals.0), Int64(totals.0 / 10)], map: Self.app)
            let report = WeeklyReport(minutes: totals.0, averageCPU: totals.1, averageMemory: totals.2, peakSwap: totals.3,
                                      busiestHour: busiest, topCPU: topCPU, topMemory: topMemory)
            DispatchQueue.main.async { completion(report) }
        }
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

    private func rows<T>(_ sql: String, _ values: [Any?], map: (OpaquePointer) -> T) -> [T] {
        var rows: [T] = []
        if db != nil, let statement = prepare(sql, values) {
            while sqlite3_step(statement) == SQLITE_ROW { rows.append(map(statement)) }
            sqlite3_finalize(statement)
        }
        return rows
    }

    private func fetch<T>(_ sql: String, _ values: [Any?], completion: @escaping ([T]) -> Void,
                          map: @escaping (OpaquePointer) -> T) {
        queue.async {
            let rows = self.rows(sql, values, map: map)
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
    /// Loaded while the 7-day range is shown.
    @Published private(set) var report: WeeklyReport?
    private var hovered: Date?

    func reload() {
        store.points(range) { [weak self] in self?.points = $0 }
        loadApps()
        if range == .week { store.weeklyReport { [weak self] in self?.report = $0 } }
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
