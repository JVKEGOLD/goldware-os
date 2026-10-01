import Foundation

/// Spoken commands for the terminals, matched on the raw words:
/// "Finish up" types a wrap-up request into every running Hermes, "Lock up" closes every terminal.
enum TerminalCommands {
    /// True when the whole clip is `phrase` (a regex over normalized words), optionally
    /// preceded by the wake phrase, so a task that mentions the words stays a task.
    static func matchesPhrase(_ spoken: String, _ phrase: String) -> Bool {
        let s = WakeWord.stripWake(spoken).lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: #"[^a-z ]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return s.range(of: #"^"# + phrase + #"$"#,
                       options: .regularExpression) != nil
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

    /// Quits both apps. Their processes are already gone, so neither asks to terminate anything.
    static let quitScript = """
        if application "iTerm" is running then tell application "iTerm" to quit
        if application "Terminal" is running then tell application "Terminal" to quit
        """

    /// Answers "terminate running processes?" the way closing a window does: hang up every process on
    /// each terminal (Hermes saves its session as it goes), escalate for anything that ignores it,
    /// then quit the apps. Returns (terminals closed, error text).
    static func lockUp(dryRun: Bool = false) -> (Int, String?) {
        let list = run("/usr/bin/osascript", ["-e", listScript])
        guard list.status == 0 else { return (0, friendly(list.err)) }
        let ttys = list.out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("/dev/tty") }
        if dryRun { return (ttys.count, nil) }
        let names = ttys.map { String($0.dropFirst("/dev/".count)) }
        for signal in ["HUP", "TERM", "KILL"] {
            let pids = pidsOn(names)
            if pids.isEmpty { break }
            _ = run("/bin/kill", ["-" + signal] + pids.map(String.init))
            Thread.sleep(forTimeInterval: 0.8)
        }
        let q = run("/usr/bin/osascript", ["-e", quitScript])
        return (ttys.count, q.status == 0 ? nil : friendly(q.err))
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
