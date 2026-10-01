import Foundation

/// Spoken commands for the terminals, matched on the raw words like Let's work:
/// "Finish up" types a wrap-up request into every running Hermes, "Lock up" closes every terminal
/// except the ones with an agent working right now,
/// "Clear out" closes the Hermes chats nobody has written in yet.
enum TerminalCommands {
    /// The normalized words a clip may be addressed with: the assistant name and its wake aliases,
    /// lowercase letters and spaces only.
    static func addressNames() -> [String] {
        let c = GWConfig.current
        var names = [c.assistantName] + c.wakeAliases
        names += c.wakePhrase.split(separator: " ").map(String.init).filter { !["hey", "okay", "ok"].contains($0.lowercased()) }
        var seen = Set<String>(), out: [String] = []
        for n in names {
            let w = normalize(n)
            if !w.isEmpty, seen.insert(w).inserted { out.append(w) }
        }
        return out
    }

    static func normalize(_ spoken: String) -> String {
        spoken.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: #"[^a-z ]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// True when the whole clip is `phrase` (a regex over normalized words), optionally with
    /// "hey/okay" and the assistant's name around it, so a task that mentions the words stays a task.
    static func matchesPhrase(_ spoken: String, _ phrase: String, names: [String]? = nil) -> Bool {
        let s = normalize(spoken)
        let alt = (names ?? addressNames()).map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let name = alt.isEmpty ? "" : "(" + alt + ")"
        let pre = alt.isEmpty ? "" : "(" + name + " )?"
        let post = alt.isEmpty ? "" : "( " + name + ")?"
        if s.range(of: #"^((hey|okay|ok) )?"# + pre + phrase + post + "$", options: .regularExpression) != nil { return true }
        // Same, after dropping everything up to the wake phrase ("so yeah, hey GoldWare, lock up").
        let stripped = normalize(WakeWord.stripWake(spoken))
        return stripped != s && stripped.range(of: "^" + phrase + "$", options: .regularExpression) != nil
    }

    // MARK: Finish up

    static let finishPrompt = "Finish up this session and commit anything that needs to be committed."
    /// `/queue` so a Hermes that is mid-answer takes it next instead of being interrupted; an idle one runs it now.
    static var finishLine: String { "/queue " + finishPrompt }

    static func matchesFinishUp(_ spoken: String) -> Bool { matchesPhrase(spoken, "(finish up|finished up|finishing up)") }

    /// Terminal devices (like "/dev/ttys002") that have an interactive Hermes chat running.
    /// `ps` output is passed in so the self-test can feed its own.
    static func hermesTTYs(psOutput: String? = nil) -> [String] {
        let text = psOutput ?? run("/bin/ps", ["-axo", "tty=,args="]).out
        var ttys: [String] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0].hasPrefix("ttys") else { continue }
            let args = String(parts[1])
            guard args.contains("hermes_cli.main"), !args.contains(" gateway") else { continue }
            let tty = "/dev/" + parts[0]
            if !ttys.contains(tty) { ttys.append(tty) }
        }
        return ttys
    }

    /// Types the line into each tab or session whose tty is listed, in iTerm and Terminal, then a
    /// separate Return after a pause (text and Return sent together can land before the prompt is ready).
    /// Only apps already running are touched.
    static func finishScript(ttys: [String]) -> String {
        let list = "{" + ttys.map { "\"\($0)\"" }.joined(separator: ", ") + "}"
        let line = finishLine.replacingOccurrences(of: "\"", with: "\\\"")
        return """
        set targets to \(list)
        set sent to 0
        if application "iTerm" is running then
          tell application "iTerm"
            repeat with w in windows
              repeat with t in tabs of w
                repeat with s in sessions of t
                  if targets contains (tty of s) then
                    tell s to write text "\(line)" newline no
                    delay 0.4
                    tell s to write text ""
                    set sent to sent + 1
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
                if targets contains (tty of t) then
                  do script "\(line)" in t
                  delay 0.4
                  do script "" in t
                  set sent to sent + 1
                end if
              end repeat
            end repeat
          end tell
        end if
        return sent
        """
    }

    /// Returns (terminals reached, error text).
    static func finishUp() -> (Int, String?) {
        let ttys = hermesTTYs()
        guard !ttys.isEmpty else { return (0, "No Hermes terminals are running") }
        let r = run("/usr/bin/osascript", ["-e", finishScript(ttys: ttys)])
        return r.status == 0 ? (Int(r.out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0, nil) : (0, friendly(r.err))
    }

    // MARK: Lock up

    static func matchesLockUp(_ spoken: String) -> Bool { matchesPhrase(spoken, "(lock up|lockup|locking up)") }

    /// Lists the ttys of every iTerm session and Terminal tab (apps that are not running are left alone).
    static let listScript = """
        set out to {}
        if application "iTerm" is running then
          tell application "iTerm" to repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                set end of out to (tty of s)
              end repeat
            end repeat
          end repeat
        end if
        if application "Terminal" is running then
          tell application "Terminal" to repeat with w in windows
            repeat with t in tabs of w
              set end of out to (tty of t)
            end repeat
          end repeat
        end if
        set AppleScript's text item delimiters to linefeed
        return out as text
        """

    /// Terminals ("/dev/ttys002") with an agent mid-task: a Hermes chat holding an unexpired turn
    /// lease, or Claude Code / Codex using CPU (its spinner redraws while it works). An idle agent at
    /// its prompt is stagnant and not listed. `chats` maps "ttys002" to its Hermes session ids.
    static func busyTTYs(chats: [String: [String]], leased: Set<String>, cli: [(tty: String, name: String, cpu: Double)]) -> Set<String> {
        var out = Set<String>()
        for (tty, ids) in chats where ids.contains(where: leased.contains) { out.insert("/dev/" + tty) }
        for p in cli where p.tty.hasPrefix("ttys") && ["claude", "codex"].contains(p.name) && p.cpu >= cliBusyCPU {
            out.insert("/dev/" + p.tty)
        }
        return out
    }

    /// %CPU at which a Claude Code or Codex process counts as working (the Office uses 5; lower to spare more).
    static let cliBusyCPU = 3.0

    /// Hermes sessions mid-task, read-only from state.db: the chat holds an unexpired turn lease, or a
    /// helper it spawned (any depth) is still open and wrote in the last 10 minutes (an agent waiting on
    /// background helpers is not idle). nil when the read fails, so Lock up stops instead of guessing.
    static func leasedSessions(_ ids: [String]) -> Set<String>? {
        guard !ids.isEmpty else { return [] }
        let db = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/state.db").path
        let list = ids.filter { $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } }.map { "'\($0)'" }.joined(separator: ",")
        let r = run("/usr/bin/sqlite3", ["-readonly", "-cmd", ".timeout 2000", db,
            """
            WITH RECURSIVE kids(root, id, depth) AS (
              SELECT id, id, 0 FROM sessions WHERE id IN (\(list))
              UNION ALL SELECT k.root, s.id, k.depth + 1 FROM sessions s JOIN kids k ON s.parent_session_id = k.id WHERE k.depth < 4)
            SELECT DISTINCT k.root FROM kids k WHERE
              EXISTS (SELECT 1 FROM session_turn_leases l WHERE l.conversation_id = k.id AND l.expires_at > strftime('%s','now'))
              OR (k.depth > 0 AND (SELECT ended_at FROM sessions WHERE id = k.id) IS NULL
                  AND EXISTS (SELECT 1 FROM messages m WHERE m.session_id = k.id AND m.timestamp > strftime('%s','now') - 600))
            UNION SELECT conversation_id FROM session_turn_leases WHERE expires_at > strftime('%s','now') AND conversation_id IN (\(list))
            """])
        guard r.status == 0 else { return nil }
        return Set(r.out.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) })
    }

    /// Claude Code and Codex processes on a terminal, with their %CPU.
    static func cliAgents(psOutput: String? = nil) -> [(tty: String, name: String, cpu: Double)] {
        let text = psOutput ?? run("/bin/ps", ["-axo", "tty=,pcpu=,comm="]).out
        return text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, let cpu = Double(f[1]) else { return nil }
            return (String(f[0]), (String(f[2]) as NSString).lastPathComponent, cpu)
        }
    }

    /// Closes every stagnant terminal: plain shells, finished commands, and agents idle at their prompt.
    /// Terminals with an agent mid-task are left alone. Hangs up each closed terminal's processes (what
    /// "Terminate" does; Hermes saves its session as it goes), closes it, and quits an app only when it
    /// has no windows left. Returns (closed, kept working, error text).
    static func lockUp(dryRun: Bool = false) -> (Int, Int, String?) {
        let list = run("/usr/bin/osascript", ["-e", listScript])
        guard list.status == 0 else { return (0, 0, friendly(list.err)) }
        let all = list.out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("/dev/tty") }
        let chats = hermesChatsByTTY()
        guard let leased = leasedSessions(chats.values.flatMap { $0 }) else {
            return (0, 0, "Couldn't tell which agents are working, so nothing was closed")
        }
        let busy = busyTTYs(chats: chats, leased: leased, cli: cliAgents())
        let targets = all.filter { !busy.contains($0) }
        let kept = all.count - targets.count
        if dryRun || targets.isEmpty { return (targets.count, kept, nil) }
        hangUp(targets)
        let c = run("/usr/bin/osascript", ["-e", closeScript(ttys: targets)])
        return (targets.count, kept, c.status == 0 ? nil : friendly(c.err))
    }

    // MARK: Clear out

    static func matchesClearOut(_ spoken: String) -> Bool { matchesPhrase(spoken, "(clear out|clearout|clearing out|cleared out)") }

    /// The example prompts Hermes shows grey in an empty input box. A terminal's text contents carry no
    /// colour, so a prompt line holding exactly one of these still counts as nothing typed.
    static let fallbackPlaceholders = ["Ask anything, or type / for commands…", "Summarize what's in this folder",
        "Draft a reply to the last email in my inbox", "Plan a feature, then build it step by step",
        "Find and fix a failing test", "Research this topic and write me a brief", "What changed in this repo recently?",
        "Turn these notes into a to-do list", "Explain this error and how to fix it",
        "Set a reminder or schedule a recurring task", "Type / to browse commands, or Ctrl+P for the palette"]

    /// Read from Hermes's own locale file so new examples are picked up; the list above if it is missing.
    static func placeholders(yaml: String? = nil) -> [String] {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/hermes-agent/locales/en.yaml").path
        guard let text = yaml ?? (try? String(contentsOfFile: path, encoding: .utf8)),
              let start = text.range(of: "\n  placeholder:\n") else { return fallbackPlaceholders }
        var out: [String] = []
        for line in text[start.upperBound...].split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix("    "), let q = line.firstIndex(of: "\""), line.hasSuffix("\"") else { break }
            out.append(String(line[line.index(after: q)..<line.index(before: line.endIndex)]))
        }
        return out.isEmpty ? fallbackPlaceholders : out
    }

    /// True when the last "❯" prompt line on a Hermes screen has nothing typed (empty or a grey example).
    static func promptIsEmpty(_ screen: String, placeholders: [String]) -> Bool {
        guard let line = screen.split(separator: "\n").last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("❯") }) else { return false }
        let typed = line.trimmingCharacters(in: .whitespaces).dropFirst().trimmingCharacters(in: .whitespaces)
        return typed.isEmpty || placeholders.contains(typed)
    }

    /// The Hermes terminals nobody has written in: every chat on the tty has no user message yet
    /// (`userMessages` lacks it or holds 0; a brand-new chat has no row at all) and nothing is typed at
    /// its prompt. `chats` maps "ttys002" to its Hermes session ids; `screens` maps "/dev/ttys002" to
    /// the visible text. A terminal without Hermes, or whose screen can't be read, is never chosen.
    static func emptyTTYs(chats: [String: [String]], userMessages: [String: Int], screens: [String: String],
                          placeholders: [String]) -> [String] {
        chats.keys.sorted().compactMap { name in
            let tty = "/dev/" + name
            guard let ids = chats[name], !ids.isEmpty, ids.allSatisfy({ (userMessages[$0] ?? 0) == 0 }),
                  let screen = screens[tty], promptIsEmpty(screen, placeholders: placeholders) else { return nil }
            return tty
        }
    }

    /// Each live Hermes chat's tty ("ttys002") and its session ids, from Hermes's liveness registry.
    static func hermesChatsByTTY() -> [String: [String]] {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes")
        let reg = (try? Data(contentsOf: home.appendingPathComponent("runtime/active_sessions.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let entries = (reg?["entries"] as? [[String: Any]] ?? []).compactMap { e -> (String, Int32)? in
            guard let sid = e["session_id"] as? String, let pid = (e["pid"] as? NSNumber)?.int32Value else { return nil }
            return (sid, pid)
        }
        guard !entries.isEmpty else { return [:] }
        var ttyOf: [Int32: String] = [:]
        for line in run("/bin/ps", ["-o", "pid=,tty=", "-p", entries.map { "\($0.1)" }.joined(separator: ",")]).out.split(separator: "\n") {
            let f = line.split(separator: " ")
            if f.count == 2, let pid = Int32(f[0]), f[1].hasPrefix("ttys") { ttyOf[pid] = String(f[1]) }
        }
        var out: [String: [String]] = [:]
        for (sid, pid) in entries { if let t = ttyOf[pid] { out[t, default: []].append(sid) } }
        return out
    }

    /// User messages per session, read-only from state.db. Sessions with none are simply absent.
    /// nil when the read fails (no Hermes database, locked, bad output), so Clear out stops instead of guessing.
    static func userMessageCounts(_ ids: [String]) -> [String: Int]? {
        guard !ids.isEmpty else { return [:] }
        let db = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/state.db").path
        let list = ids.filter { $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } }.map { "'\($0)'" }.joined(separator: ",")
        let r = run("/usr/bin/sqlite3", ["-readonly", db,
            "SELECT session_id, count(*) FROM messages WHERE role = 'user' AND session_id IN (\(list)) GROUP BY session_id"])
        guard r.status == 0 else { return nil }
        var out: [String: Int] = [:]
        for line in r.out.split(separator: "\n") {
            let f = line.split(separator: "|")
            if f.count == 2, let n = Int(f[1]) { out[String(f[0])] = n }
        }
        return out
    }

    /// The visible text of each listed iTerm session and Terminal tab, keyed by tty.
    static func screensScript(ttys: [String]) -> String {
        let list = "{" + ttys.map { "\"\($0)\"" }.joined(separator: ", ") + "}"
        return """
        set targets to \(list)
        set out to ""
        set sep to (ASCII character 30)
        if application "iTerm" is running then
          tell application "iTerm" to repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if targets contains (tty of s) then set out to out & (tty of s) & linefeed & (contents of s) & sep
              end repeat
            end repeat
          end repeat
        end if
        if application "Terminal" is running then
          tell application "Terminal" to repeat with w in windows
            repeat with t in tabs of w
              if targets contains (tty of t) then set out to out & (tty of t) & linefeed & (contents of t) & sep
            end repeat
          end repeat
        end if
        return out
        """
    }

    /// Closes the listed iTerm sessions and Terminal windows (whose processes are already gone, so
    /// nothing asks to terminate), then quits an app only if it has no windows left.
    static func closeScript(ttys: [String]) -> String {
        let list = "{" + ttys.map { "\"\($0)\"" }.joined(separator: ", ") + "}"
        return """
        set targets to \(list)
        if application "iTerm" is running then
          tell application "iTerm"
            set victims to {}
            repeat with w in windows
              repeat with t in tabs of w
                repeat with s in sessions of t
                  if targets contains (tty of s) then set end of victims to contents of s
                end repeat
              end repeat
            end repeat
            repeat with s in victims
              try
                close s
              end try
            end repeat
            if (count of windows) = 0 then quit
          end tell
        end if
        if application "Terminal" is running then
          tell application "Terminal"
            set victims to {}
            repeat with w in windows
              set unused to true
              repeat with t in tabs of w
                if not (targets contains (tty of t)) then set unused to false
              end repeat
              if unused then set end of victims to contents of w
            end repeat
            repeat with w in victims
              try
                close w
              end try
            end repeat
            if (count of windows) = 0 then quit
          end tell
        end if
        """
    }

    /// Closes every Hermes terminal nobody has written in. Returns (closed, other terminals left, error).
    static func clearOut(dryRun: Bool = false) -> (Int, Int, String?) {
        let list = run("/usr/bin/osascript", ["-e", listScript])
        guard list.status == 0 else { return (0, 0, friendly(list.err)) }
        let all = list.out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("/dev/tty") }
        let chats = hermesChatsByTTY().filter { all.contains("/dev/" + $0.key) }
        guard !chats.isEmpty else { return (0, all.count, nil) }
        let scr = run("/usr/bin/osascript", ["-e", screensScript(ttys: chats.keys.map { "/dev/" + $0 })])
        guard scr.status == 0 else { return (0, all.count, friendly(scr.err)) }
        var screens: [String: String] = [:]
        for chunk in scr.out.split(separator: "\u{1E}") {
            let parts = chunk.trimmingCharacters(in: .newlines).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { screens[String(parts[0])] = String(parts[1]) }
        }
        guard let counts = userMessageCounts(chats.values.flatMap { $0 }) else {
            return (0, all.count, "Couldn't read the Hermes chats, so nothing was closed")
        }
        let empty = emptyTTYs(chats: chats, userMessages: counts, screens: screens, placeholders: placeholders())
        if dryRun || empty.isEmpty { return (empty.count, all.count - empty.count, nil) }
        hangUp(empty)
        let c = run("/usr/bin/osascript", ["-e", closeScript(ttys: empty)])
        return (empty.count, all.count - empty.count, c.status == 0 ? nil : friendly(c.err))
    }

    /// HUP every process on these terminals (what "Terminate" does), then TERM, then KILL anything left.
    static func hangUp(_ ttys: [String]) {
        let names = ttys.map { String($0.dropFirst("/dev/".count)) }
        for signal in ["HUP", "TERM", "KILL"] {
            let pids = pidsOn(names)
            if pids.isEmpty { break }
            _ = run("/bin/kill", ["-" + signal] + pids.map(String.init))
            Thread.sleep(forTimeInterval: 0.8)
        }
    }

    // MARK: Helpers

    /// Processes on these ttys ("ttys002"), except the `login` that owns each one (the terminal app
    /// tears that down itself). `pgrep -t` matches nothing on macOS, so this reads `ps -t`.
    static func pidsOn(_ ttys: [String], psOutput: String? = nil) -> [Int32] {
        guard !ttys.isEmpty else { return [] }
        let text = psOutput ?? run("/bin/ps", ["-t", ttys.joined(separator: ","), "-o", "pid=,comm="]).out
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let pid = Int32(parts[0]), !parts[1].hasSuffix("/login") else { return nil }
            return pid
        }
    }

    static func friendly(_ err: String) -> String {
        err.contains("-1743") ? "Allow \(GWConfig.name) to control iTerm and Terminal in System Settings > Privacy > Automation"
                              : err.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let o = Pipe(), e = Pipe()
        p.standardOutput = o
        p.standardError = e
        do { try p.run() } catch { return (1, "", error.localizedDescription) }
        let out = String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: e.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return (p.terminationStatus, out, err)
    }
}
