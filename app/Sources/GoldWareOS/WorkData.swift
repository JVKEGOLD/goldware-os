import AppKit
import EventKit
import SQLite3

/// The control center's Work card: what needs you, today's calendar, running agents, uncommitted
/// work in this repo, and local models. Everything is read locally while the panel is open.
enum WorkTab: Int, CaseIterable {
    case needs, today, agents, repo, models
    var label: String { ["Needs you", "Today", "Agents", "Repo", "Models"][rawValue] }
}

struct WorkRow: Equatable {
    enum Tone { case normal, gold, red, dim }
    enum Open: Equatable { case none, tasks, file(String), folder(String), tty(String), calendar }
    enum Act: Equatable { case unload(String), restartWhisper }
    var icon: String
    var title: String
    var sub: String
    var meta = ""
    var tone = Tone.normal
    var live = false
    var open = Open.none
    var action: String? = nil
    var act: Act? = nil
    var files: [String] = []
}

struct WorkSnapshot {
    enum Calendar { case unknown, needsAccess, denied, ready }
    var loaded = false
    var needs: [WorkRow] = [], needsCount = 0, serverOffline = false
    var today: [WorkRow] = [], calendar = Calendar.unknown
    var agents: [WorkRow] = []
    var repo: [WorkRow] = [], repoChanged = 0, repoSummary = ""
    var models: [WorkRow] = [], modelsSummary = ""

    func rows(_ t: WorkTab) -> [WorkRow] { [needs, today, agents, repo, models][t.rawValue] }

    /// The small count next to a tab name, or nil.
    func badge(_ t: WorkTab) -> String? {
        let n: Int
        switch t {
        case .needs: n = needsCount
        case .agents: n = agents.count
        case .repo: n = repoChanged
        case .today, .models: return nil
        }
        return n > 0 ? "\(n)" : nil
    }
}

enum WorkData {
    static func load(agenda: Agenda, root: URL?, now: Date = Date()) -> WorkSnapshot {
        var s = WorkSnapshot(loaded: true)
        let ps = TerminalCommands.run("/bin/ps", ["-axo", "pid=,tty=,etime=,rss=,comm="]).out
        let procs = parsePS(ps)
        (s.needs, s.needsCount) = needsYou(agenda: agenda, drafts: root.map { drafts(root: $0, now: now) } ?? [])
        s.serverOffline = agenda.error != nil
        (s.calendar, s.today) = calendar(now: now)
        s.agents = agents(procs: procs, now: now)
        if let root { (s.repo, s.repoChanged, s.repoSummary) = repo(root: root, now: now) }
        (s.models, s.modelsSummary) = models(procs: procs, now: now)
        return s
    }

    // MARK: Needs you

    struct Draft { var path: String; var title: String; var to: String; var modified: Date }

    /// A draft still waits on you unless its status line says it went out or was replaced.
    static func draftIsPending(_ text: String) -> Bool {
        let head = text.prefix(1500).lowercased()
        guard let r = head.range(of: "status:") else { return false }
        var line = String(head[r.lowerBound...].prefix { $0 != "\n" && $0 != ")" })
        // "Not sent" and "not published yet" still wait on you.
        line = line.replacingOccurrences(of: #"not (yet )?(been )?(sent|published|posted|submitted|delivered)"#, with: "", options: .regularExpression)
        let closed = ["sent", "supersede", "submitted", "delivered", "published", "posted", "cancel", "not needed", "done", "complete"]
        return !closed.contains { line.contains($0) }
    }

    /// "# Draft reply to Sam: port back (status: ...)" -> "Draft reply to Sam: port back".
    static func draftTitle(_ text: String, fallback: String) -> String {
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("# ") }) else { return fallback }
        var t = String(line.dropFirst(2))
        if let p = t.range(of: " (status", options: .caseInsensitive) { t = String(t[..<p.lowerBound]) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Pending drafts from the last two weeks in <root>/data/drafts, newest first. Older ones are history, not a queue.
    static func drafts(root: URL, now: Date) -> [Draft] {
        let fm = FileManager.default
        var out: [Draft] = []
        let dir = (ProcessInfo.processInfo.environment["GOLDWARE_DATA_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? root.appendingPathComponent("data")).appendingPathComponent("drafts")
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".md") {
            let url = dir.appendingPathComponent(name)
            guard let m = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(m) < 14 * 86_400,
                  let h = try? FileHandle(forReadingFrom: url) else { continue }
            let text = String(decoding: h.readData(ofLength: 4096), as: UTF8.self)
            try? h.close()
            guard draftIsPending(text) else { continue }
            let to = text.split(separator: "\n").first { $0.hasPrefix("To: ") }.map { String($0.dropFirst(4)) } ?? ""
            out.append(Draft(path: url.path, title: draftTitle(text, fallback: name), to: to, modified: m))
        }
        return out.sorted { $0.modified > $1.modified }
    }

    /// Words that identify a draft or task ("tls", "certificate", "reply"), for spotting the same item twice.
    static func keywords(_ s: String) -> Set<String> {
        let stop: Set<String> = ["the", "and", "for", "with", "about", "draft", "from", "your", "this", "that", "send", "text", "email"]
        return Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 && !stop.contains($0) && !$0.allSatisfy(\.isNumber) })
    }

    static func needsYou(agenda: Agenda, drafts: [Draft], now: Date = Date()) -> (rows: [WorkRow], count: Int) {
        var ranked: [(rank: Int, row: WorkRow)] = []
        let pri = { (p: String?) in ["high": 0, "medium": 1][p ?? ""] ?? 2 }
        let tasks = agenda.due + agenda.focus + agenda.approvals
        // A draft that a task already tracks (two shared words) shows once, as the task.
        let drafts = drafts.filter { d in
            let words = keywords((d.path as NSString).lastPathComponent)
            return !tasks.contains { words.intersection(keywords($0.title)).count >= 2 }
        }
        for d in drafts {
            ranked.append((0, WorkRow(icon: "text.bubble", title: d.title, sub: "\(d.to.isEmpty ? "Draft" : d.to) · \(ago(now.timeIntervalSince(d.modified))) ago",
                                      meta: "DRAFT", tone: .gold, open: .file(d.path))))
        }
        for t in agenda.due {
            let overdue = (t.dueOn ?? "") < agenda.today
            ranked.append((overdue ? 1 : 2, WorkRow(icon: "calendar.badge.exclamationmark", title: t.title,
                          sub: "Tasks", meta: overdue ? "OVERDUE" : "DUE", tone: overdue ? .red : .gold, open: .tasks)))
        }
        for t in agenda.focus {
            ranked.append((3 + pri(t.priority), WorkRow(icon: "scope", title: t.title, sub: "Focus today",
                                                        meta: "TODAY", open: .tasks)))
        }
        for t in agenda.approvals where !agenda.focus.contains(where: { $0.id == t.id }) {
            ranked.append((6 + pri(t.priority), WorkRow(icon: "checkmark.seal", title: t.title, sub: "Waiting on your yes",
                                                        meta: "APPROVE", open: .tasks)))
        }
        let rows = ranked.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }.map(\.element.row)
        return (rows, rows.count)
    }

    // MARK: Today

    static var store = EKEventStore()

    static func calendar(now: Date) -> (WorkSnapshot.Calendar, [WorkRow]) {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: break
        case .notDetermined: return (.needsAccess, [])
        default: return (.denied, [])
        }
        let cal = Foundation.Calendar.current
        let end = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: now))!
        let events = store.events(matching: store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: end, calendars: nil))
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US")
        time.dateFormat = "h:mm"
        let ampm = DateFormatter()
        ampm.locale = Locale(identifier: "en_US")
        ampm.dateFormat = "h:mm a"
        let rows = events.prefix(8).map { e -> WorkRow in
            let isNow = e.startDate <= now
            let tomorrow = !cal.isDate(e.startDate, inSameDayAs: now)
            let meta = isNow ? "NOW" : tomorrow ? "TOMORROW" : "IN \(ago(e.startDate.timeIntervalSince(now)).uppercased())"
            let place = [e.calendar?.title, e.location].compactMap { $0?.isEmpty == false ? $0 : nil }.first ?? ""
            return WorkRow(icon: "calendar", title: e.title ?? "Busy",
                           sub: "\(time.string(from: e.startDate)) – \(ampm.string(from: e.endDate))" + (place.isEmpty ? "" : " · \(place)"),
                           meta: meta, tone: isNow ? .gold : tomorrow ? .dim : .normal, live: isNow, open: .calendar)
        }
        return (.ready, Array(rows))
    }

    static func requestCalendar(_ done: @escaping () -> Void) {
        store.requestFullAccessToEvents { _, _ in
            store = EKEventStore()
            DispatchQueue.main.async(execute: done)
        }
    }

    // MARK: Agents

    struct Proc: Equatable { var pid: Int32; var tty: String; var seconds: Int; var rss: Double; var name: String }

    /// `ps -axo pid=,tty=,etime=,rss=,comm=`; comm is last and may contain spaces.
    static func parsePS(_ text: String) -> [Proc] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard f.count == 5, let pid = Int32(f[0]), let rss = Double(f[3]) else { return nil }
            return Proc(pid: pid, tty: String(f[1]), seconds: etime(String(f[2])), rss: rss * 1024,
                        name: (String(f[4]) as NSString).lastPathComponent)
        }
    }

    /// ps elapsed time, "[[dd-]hh:]mm:ss", in seconds.
    static func etime(_ s: String) -> Int {
        let dayParts = s.split(separator: "-")
        let days = dayParts.count == 2 ? Int(dayParts[0]) ?? 0 : 0
        let clock = (dayParts.last ?? "").split(separator: ":").compactMap { Int($0) }
        return days * 86_400 + clock.reduce(0) { $0 * 60 + $1 }
    }

    /// "claude-opus-5-5" -> "Opus 5.5"; other names pass through.
    static func prettyModel(_ m: String) -> String {
        guard m.hasPrefix("claude-") else { return m }
        let parts = m.dropFirst(7).split(separator: "-")
        guard let family = parts.first else { return m }
        let version = parts.dropFirst().filter { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
        return family.capitalized + (version.isEmpty ? "" : " " + version)
    }

    struct Session { var title: String; var model: String; var messages: Int; var last: Double }

    static func agents(procs: [Proc], now: Date) -> [WorkRow] {
        let byPID = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let hermesHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes")
        var rows: [WorkRow] = []
        // Hermes chats: its own liveness registry, then titles and turn leases from state.db (read-only).
        let reg = (try? Data(contentsOf: hermesHome.appendingPathComponent("runtime/active_sessions.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let entries = (reg?["entries"] as? [[String: Any]] ?? []).compactMap { e -> (String, Proc)? in
            guard let sid = e["session_id"] as? String, let pid = (e["pid"] as? NSNumber)?.int32Value,
                  let p = byPID[pid], p.tty != "??" else { return nil }
            return (sid, p)
        }
        let (sessions, busy) = hermesState(hermesHome.appendingPathComponent("state.db").path, ids: entries.map(\.0), now: now)
        for (sid, p) in entries.sorted(by: { (sessions[$0.0]?.last ?? 0) > (sessions[$1.0]?.last ?? 0) }) {
            let s = sessions[sid]
            let working = busy.contains(sid)
            let idle = s.map { now.timeIntervalSince1970 - $0.last } ?? Double(p.seconds)
            var sub = ["Hermes", s.map { prettyModel($0.model) }].compactMap { $0 }.filter { !$0.isEmpty }
            if let n = s?.messages, n > 0 { sub.append("\(n) messages") }
            rows.append(WorkRow(icon: "sparkle", title: s?.title.isEmpty == false ? s!.title : "New chat", sub: sub.joined(separator: " · "),
                                meta: working ? "WORKING" : "IDLE \(ago(idle).uppercased())", tone: working ? .gold : .normal,
                                live: working, open: .tty("/dev/" + p.tty)))
        }
        for p in procs where p.tty != "??" && ["claude", "codex"].contains(p.name) {
            rows.append(WorkRow(icon: p.name == "claude" ? "asterisk" : "terminal", title: p.name == "claude" ? "Claude Code" : "Codex",
                                sub: "Terminal \(p.tty)", meta: ago(Double(p.seconds)).uppercased(), open: .tty("/dev/" + p.tty)))
        }
        return rows
    }

    private static func hermesState(_ path: String, ids: [String], now: Date) -> ([String: Session], Set<String>) {
        var db: OpaquePointer?
        guard !ids.isEmpty, sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return ([:], []) }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 300)
        let marks = ids.map { _ in "?" }.joined(separator: ",")
        var out: [String: Session] = [:]
        var busy = Set<String>()
        func query(_ sql: String, bind: (OpaquePointer?) -> Void, row: (OpaquePointer?) -> Void) {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(st) }
            bind(st)
            while sqlite3_step(st) == SQLITE_ROW { row(st) }
        }
        let text = { (st: OpaquePointer?, i: Int32) in sqlite3_column_text(st, i).map { String(cString: $0) } ?? "" }
        let bindIDs = { (st: OpaquePointer?) in
            for (i, id) in ids.enumerated() { sqlite3_bind_text(st, Int32(i + 1), id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        }
        query("""
            SELECT s.id, coalesce(s.title, ''), coalesce(s.model, ''), s.message_count,
                   coalesce((SELECT max(timestamp) FROM messages m WHERE m.session_id = s.id), s.started_at)
            FROM sessions s WHERE s.id IN (\(marks))
            """, bind: bindIDs) { st in
            out[text(st, 0)] = Session(title: text(st, 1), model: text(st, 2), messages: Int(sqlite3_column_int(st, 3)),
                                       last: sqlite3_column_double(st, 4))
        }
        query("SELECT conversation_id FROM session_turn_leases WHERE expires_at > ? AND conversation_id IN (\(marks))",
              bind: { st in
                  sqlite3_bind_double(st, 1, now.timeIntervalSince1970)
                  for (i, id) in ids.enumerated() { sqlite3_bind_text(st, Int32(i + 2), id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
              }) { st in busy.insert(text(st, 0)) }
        return (out, busy)
    }

    /// Brings the iTerm session (or Terminal tab) on this tty to the front. Apps that are not running are left alone.
    static func focus(tty: String) {
        let script = """
        if application "iTerm" is running then
          tell application "iTerm"
            repeat with w in windows
              repeat with t in tabs of w
                repeat with s in sessions of t
                  if tty of s is "\(tty)" then
                    select w
                    tell t to select
                    tell s to select
                    activate
                    return
                  end if
                end repeat
              end repeat
            end repeat
          end tell
        end if
        if application "Terminal" is running then
          tell application "Terminal"
            repeat with w in windows
              repeat with t in tabs of w
                if tty of t is "\(tty)" then
                  set selected tab of w to t
                  set index of w to 1
                  activate
                  return
                end if
              end repeat
            end repeat
          end tell
        end if
        """
        DispatchQueue.global(qos: .userInitiated).async { _ = TerminalCommands.run("/usr/bin/osascript", ["-e", script]) }
    }

    // MARK: Repo

    /// `git status --porcelain` lines grouped by area: the first two folders, or the top folder.
    static func groupStatus(_ porcelain: String) -> [(area: String, changed: Int, added: Int, files: [String])] {
        var groups: [String: (Int, Int)] = [:]
        var files: [String: [String]] = [:]
        var order: [String] = []
        for line in porcelain.split(separator: "\n") where line.count > 3 {
            let code = line.prefix(2)
            var path = String(line.dropFirst(3))
            if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let parts = path.split(separator: "/")
            let area = parts.count > 2 && ["app", "server", "tests", "docs"].contains(parts[0])
                ? parts.prefix(2).joined(separator: "/") : parts.count > 1 ? String(parts[0]) : "Top level"
            if groups[area] == nil { order.append(area); groups[area] = (0, 0) }
            groups[area]!.0 += 1
            let new = code == "??" || code.contains("A")
            if new { groups[area]!.1 += 1 }
            let prefix = area == "Top level" ? "" : area + "/"
            let rel = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
            files[area, default: []].append((new ? "+ " : "~ ") + rel.replacingOccurrences(of: "Sources/GoldWareOS/", with: ""))
        }
        return order.map { ($0, groups[$0]!.0, groups[$0]!.1, files[$0] ?? []) }.sorted { $0.changed > $1.changed }
    }

    static func repo(root: URL, now: Date) -> ([WorkRow], Int, String) {
        let git = { (args: [String]) in TerminalCommands.run("/usr/bin/git", ["-C", root.path] + args).out }
        let groups = groupStatus(git(["status", "--porcelain=v1", "-uall"]))
        let branch = git(["rev-parse", "--abbrev-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let last = Double(git(["log", "-1", "--format=%ct"]).trimmingCharacters(in: .whitespacesAndNewlines)).map { now.timeIntervalSince1970 - $0 }
        let total = groups.reduce(0) { $0 + $1.changed }
        let rows = groups.map { g -> WorkRow in
            let edited = g.changed - g.added
            let sub = [edited > 0 ? "\(edited) edited" : nil, g.added > 0 ? "\(g.added) new" : nil].compactMap { $0 }.joined(separator: " · ")
            return WorkRow(icon: g.area == "Top level" ? "doc" : "folder", title: g.area, sub: sub, meta: "\(g.changed)",
                           open: .folder(g.area == "Top level" ? root.path : root.appendingPathComponent(g.area).path), files: g.files)
        }
        let summary = "\(branch.isEmpty ? GWConfig.name : branch) · last commit \(last.map { ago($0) + " ago" } ?? "unknown")"
        return (rows, total, summary)
    }

    // MARK: Models

    static func models(procs: [Proc], now: Date) -> ([WorkRow], String) {
        var rows: [WorkRow] = []
        var total = 0.0
        // Ollama: loaded models from its API; memory from the llama-server holding each model's blob.
        let llama = procs.filter { $0.name == "llama-server" }
        let args = llama.isEmpty ? "" : TerminalCommands.run("/bin/ps", ["-o", "pid=,args=", "-p", llama.map { "\($0.pid)" }.joined(separator: ",")]).out
        var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/ps")!, timeoutInterval: 1.5)
        req.httpMethod = "GET"
        let loaded = syncGet(req).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["models"] as? [[String: Any]]
        // Ollama's digest names the manifest while the server's --model names the weights blob, so they
        // rarely match: pair by digest when they do, otherwise in order (one model usually means one server).
        var claimed = Set<Int32>()
        var servers: [String: Proc] = [:]
        for m in loaded ?? [] {
            let digest = m["digest"] as? String ?? "\u{0}"
            if let p = llama.first(where: { p in args.split(separator: "\n").contains { $0.contains("\(p.pid) ") && $0.contains(digest) } }) {
                servers[m["name"] as? String ?? ""] = p; claimed.insert(p.pid)
            }
        }
        var spare = llama.filter { !claimed.contains($0.pid) }
        for m in loaded ?? [] where servers[m["name"] as? String ?? ""] == nil && !spare.isEmpty {
            let p = spare.removeFirst()
            servers[m["name"] as? String ?? ""] = p; claimed.insert(p.pid)
        }
        for m in loaded ?? [] {
            let name = m["name"] as? String ?? "model"
            let server = servers[name]
            let mem = server?.rss ?? (m["size_vram"] as? NSNumber)?.doubleValue ?? 0
            total += mem
            let until = (m["expires_at"] as? String).flatMap(PlanUsage.isoDate)
            let params = (m["details"] as? [String: Any])?["parameter_size"] as? String
            rows.append(WorkRow(icon: "cpu", title: name,
                                sub: ["Ollama", params, until.map { "unloads in \(ago($0.timeIntervalSince(now)))" }].compactMap { $0 }.joined(separator: " · "),
                                meta: gb(mem), tone: mem > 8 * 1_073_741_824 ? .gold : .normal, action: "Unload", act: .unload(name)))
        }
        for p in llama where !claimed.contains(p.pid) {
            total += p.rss
            rows.append(WorkRow(icon: "cpu", title: "llama-server", sub: "Ollama · model not listed", meta: gb(p.rss)))
        }
        if loaded == nil, llama.isEmpty {
            rows.append(WorkRow(icon: "cpu", title: "Ollama", sub: "Not running", meta: "OFF", tone: .dim))
        } else if loaded?.isEmpty == true, llama.isEmpty {
            rows.append(WorkRow(icon: "cpu", title: "Ollama", sub: "Running · no model loaded", meta: "IDLE", tone: .dim))
        }
        if let w = procs.first(where: { $0.name == "whisper-server" }) {
            total += w.rss
            rows.append(WorkRow(icon: "waveform", title: "Whisper", sub: "\(GWConfig.name) Voice speech · up \(ago(Double(w.seconds)))",
                                meta: gb(w.rss), action: "Restart", act: .restartWhisper))
        } else {
            rows.append(WorkRow(icon: "waveform", title: "Whisper", sub: "\(GWConfig.name) Voice speech · not running", meta: "OFF", tone: .red,
                                action: "Start", act: .restartWhisper))
        }
        let ram = Double(ProcessInfo.processInfo.physicalMemory)
        return (rows, "Models hold \(gb(total)) of \(gb(ram))")
    }

    static func unload(_ model: String, done: @escaping () -> Void) {
        var r = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/generate")!, timeoutInterval: 10)
        r.httpMethod = "POST"
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": 0])
        URLSession.shared.dataTask(with: r) { _, _, _ in DispatchQueue.main.async(execute: done) }.resume()
    }

    // MARK: Helpers

    /// 45 -> "45s", 720 -> "12m", 7200 -> "2h", 3 days -> "3d".
    static func ago(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }

    static func gb(_ bytes: Double) -> String {
        bytes >= 1_073_741_824 ? String(format: "%.1f GB", bytes / 1_073_741_824) : String(format: "%.0f MB", bytes / 1_048_576)
    }

    private static func syncGet(_ r: URLRequest) -> Data? {
        let done = DispatchSemaphore(value: 0)
        var out: Data?
        URLSession.shared.dataTask(with: r) { d, resp, _ in
            if (resp as? HTTPURLResponse)?.statusCode == 200 { out = d }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 2)
        return out
    }
}
