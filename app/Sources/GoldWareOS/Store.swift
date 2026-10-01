import Foundation
import SQLite3

struct Dictation {
    var id: Int64 = 0
    var createdAt: Date
    var appName: String?
    var appBundle: String?
    var durationSec: Double
    var audioPath: String
    var rawText: String
    var finalText: String
    var asrMs: Int
    var cleanupMs: Int
    var cleanupModel: String?
    var mode: String = "dictate"      // dictate | assistant
    var action: String?               // what the assistant did: task, draft, note, queued, failed
    var actionRef: String?            // request id or draft path
    var summary: String?
}

struct OutboxItem {
    let id: Int64
    let payload: String
    let title: String
}

/// Local SQLite log of every dictation. This is the "we own the data" part.
final class Store {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() {
        sqlite3_open(Paths.database.path, &db)
        exec("""
        CREATE TABLE IF NOT EXISTS dictations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at REAL NOT NULL,
            app_name TEXT,
            app_bundle TEXT,
            duration_sec REAL,
            audio_path TEXT,
            raw_text TEXT,
            final_text TEXT,
            asr_ms INTEGER,
            cleanup_ms INTEGER,
            cleanup_model TEXT
        )
        """)
        // Added in v0.2. ALTER fails harmlessly when the column already exists.
        for column in ["mode TEXT DEFAULT 'dictate'", "action TEXT", "action_ref TEXT", "summary TEXT"] {
            exec("ALTER TABLE dictations ADD COLUMN \(column)")
        }
        exec("""
        CREATE TABLE IF NOT EXISTS outbox (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at REAL NOT NULL,
            title TEXT,
            payload TEXT NOT NULL,
            state TEXT NOT NULL DEFAULT 'pending'
        )
        """)
    }

    func enqueue(payload: [String: Any], title: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO outbox (created_at, title, payload) VALUES (?,?,?)", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        bind(stmt, 2, title)
        bind(stmt, 3, json)
        sqlite3_step(stmt)
    }

    func pendingOutbox() -> [OutboxItem] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, payload, title FROM outbox WHERE state = 'pending' ORDER BY id", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var items: [OutboxItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            items.append(OutboxItem(id: sqlite3_column_int64(stmt, 0), payload: text(stmt, 1) ?? "", title: text(stmt, 2) ?? ""))
        }
        return items
    }

    /// Removes a capture that has not reached your tasks yet. True if one was found.
    func cancelQueued(requestID: String) -> Bool {
        guard let item = pendingOutbox().first(where: { $0.payload.contains(requestID) }) else { return false }
        markOutbox(id: item.id, state: "cancelled")
        return true
    }

    func markOutbox(id: Int64, state: String) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE outbox SET state = ? WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, state)
        sqlite3_bind_int64(stmt, 2, id)
        sqlite3_step(stmt)
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    @discardableResult
    func insert(_ d: Dictation) -> Int64 {
        let sql = "INSERT INTO dictations (created_at, app_name, app_bundle, duration_sec, audio_path, raw_text, final_text, asr_ms, cleanup_ms, cleanup_model, mode, action, action_ref, summary) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, d.createdAt.timeIntervalSince1970)
        bind(stmt, 2, d.appName)
        bind(stmt, 3, d.appBundle)
        sqlite3_bind_double(stmt, 4, d.durationSec)
        bind(stmt, 5, d.audioPath)
        bind(stmt, 6, d.rawText)
        bind(stmt, 7, d.finalText)
        sqlite3_bind_int(stmt, 8, Int32(d.asrMs))
        sqlite3_bind_int(stmt, 9, Int32(d.cleanupMs))
        bind(stmt, 10, d.cleanupModel)
        bind(stmt, 11, d.mode)
        bind(stmt, 12, d.action)
        bind(stmt, 13, d.actionRef)
        bind(stmt, 14, d.summary)
        sqlite3_step(stmt)
        return sqlite3_last_insert_rowid(db)
    }

    func recent(limit: Int, mode: String? = nil) -> [Dictation] {
        let filter = mode == nil ? "" : "WHERE mode = ?"
        let sql = "SELECT id, created_at, app_name, app_bundle, duration_sec, audio_path, raw_text, final_text, asr_ms, cleanup_ms, cleanup_model, mode, action, action_ref, summary FROM dictations \(filter) ORDER BY id DESC LIMIT ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        if let mode {
            bind(stmt, 1, mode)
            sqlite3_bind_int(stmt, 2, Int32(limit))
        } else {
            sqlite3_bind_int(stmt, 1, Int32(limit))
        }
        var rows: [Dictation] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(Dictation(
                id: sqlite3_column_int64(stmt, 0),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                appName: text(stmt, 2),
                appBundle: text(stmt, 3),
                durationSec: sqlite3_column_double(stmt, 4),
                audioPath: text(stmt, 5) ?? "",
                rawText: text(stmt, 6) ?? "",
                finalText: text(stmt, 7) ?? "",
                asrMs: Int(sqlite3_column_int(stmt, 8)),
                cleanupMs: Int(sqlite3_column_int(stmt, 9)),
                cleanupModel: text(stmt, 10),
                mode: text(stmt, 11) ?? "dictate",
                action: text(stmt, 12),
                actionRef: text(stmt, 13),
                summary: text(stmt, 14)
            ))
        }
        return rows
    }

    /// Today's dictation and GoldWare counts, plus the latest thing GoldWare did today.
    func today() -> (dictations: Int, captures: Int, last: String?) {
        let start = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        var stmt: OpaquePointer?
        let sql = "SELECT mode, COUNT(*) FROM dictations WHERE created_at >= ? GROUP BY mode"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (0, 0, nil) }
        sqlite3_bind_double(stmt, 1, start)
        var dictations = 0, captures = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let n = Int(sqlite3_column_int(stmt, 1))
            if text(stmt, 0) == "assistant" { captures = n } else { dictations += n }
        }
        sqlite3_finalize(stmt)
        let last = recent(limit: 1, mode: "assistant").first.flatMap { $0.createdAt.timeIntervalSince1970 >= start ? $0.summary : nil }
        return (dictations, captures, last)
    }

    /// Counts only, for the dashboard's Voice tab. No transcript text leaves this database.
    func writeStats() {
        let weekStart = Date().addingTimeInterval(-7 * 86_400)
        let rows = recent(limit: 100_000)
        let week = rows.filter { $0.createdAt >= weekStart }
        func words(_ list: [Dictation]) -> Int {
            list.filter { $0.mode == "dictate" }.reduce(0) { $0 + $1.finalText.split(whereSeparator: \.isWhitespace).count }
        }
        let weekDictations = week.filter { $0.mode == "dictate" }
        let speaking = weekDictations.reduce(0) { $0 + $1.durationSec } / 60
        let weekWords = words(week)
        var assistant: [String: Int] = [:]
        for d in week where d.mode == "assistant" { assistant[d.action ?? "other", default: 0] += 1 }
        let json: [String: Any] = [
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "week": [
                "dictations": weekDictations.count,
                "words": weekWords,
                "speaking_minutes": (speaking * 10).rounded() / 10,
                // Typing at about 40 words a minute, minus the time spent talking.
                "minutes_saved": max(0, ((Double(weekWords) / 40 - speaking) * 10).rounded() / 10),
                "assistant": assistant,
            ],
            "all_time": ["dictations": rows.filter { $0.mode == "dictate" }.count, "words": words(rows),
                         "assistant": rows.filter { $0.mode == "assistant" }.count],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Paths.dataDir.appendingPathComponent("stats.json"))
        }
    }

    func stats() -> (count: Int, words: Int) {
        let rows = recent(limit: 100_000)
        let words = rows.reduce(0) { $0 + $1.finalText.split(whereSeparator: \.isWhitespace).count }
        return (rows.count, words)
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(stmt, index, value, -1, transient) } else { sqlite3_bind_null(stmt, index) }
    }

    private func text(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }
}
