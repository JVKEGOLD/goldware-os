import AppKit

/// "Let's work": one terminal window per quadrant, each running the command from goldware.json
/// (`letsWork.command`, Hermes on its default model, switchable with /model; set it to "" for a plain shell). Matched on the spoken words locally (no model
/// call), so it is fast and never fires on a task that merely mentions it.
enum LetsWork {
    /// What to run, which terminal app, and which iTerm profile (empty means iTerm's default).
    /// The out-of-the-box command: a Hermes agent on Hermes's default model (setup makes that Claude
    /// Opus 5.5 or GPT 5.5). No -m or --provider, so /model can still switch to any other model.
    static let defaultCommand = "hermes"

    /// These defaults also apply when goldware.json has no `letsWork` (a config made before it
    /// existed), so an older install gets the GoldWare profile and Hermes, not a plain default shell.
    struct Settings: Equatable {
        var command = LetsWork.defaultCommand
        var terminal = "iTerm"
        var profile = "GoldWare"
    }

    static var settings: Settings { GWConfig.current.letsWork }

    /// True only when the whole clip is the phrase ("Let's work!", "Hey GoldWare, let's work").
    static func matches(_ spoken: String, names: [String]? = nil) -> Bool {
        TerminalCommands.matchesPhrase(spoken, "(lets work|let us work|lets works|let work)", names: names)
    }

    /// Terminal bounds for quadrants 1 to 4 as {left, top, right, bottom}, top-left origin.
    static func bounds() -> [[Int]] {
        let top = NSScreen.screens[0].frame.maxY
        return (1...4).map { q in
            let r = QuadrantTarget.cg(QuadrantTarget.rect(q), top: top)
            return [Int(r.minX), Int(r.minY), Int(r.maxX), Int(r.maxY)]
        }
    }

    /// Escapes text for an AppleScript string literal.
    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The AppleScript that opens the four iTerm windows. A cold start of iTerm opens its own
    /// default-profile window first: that one is closed once ours are up, so no stray fifth window
    /// is left behind.
    static func script(settings: Settings? = nil, bounds b: [[Int]]? = nil) -> String {
        let s = settings ?? Self.settings
        let lines = (b ?? bounds()).map { b in
            // A named profile that iTerm does not have (setup not run, or deleted) falls back to the default one.
            var l = s.profile.isEmpty
                ? "  set w to (create window with default profile)"
                : "  try\n    set w to (create window with profile \(quoted(s.profile)))\n  on error\n    set w to (create window with default profile)\n  end try"
            l += "\n  set bounds of w to {\(b.map(String.init).joined(separator: ", "))}"
            if !s.command.isEmpty { l += "\n  tell current session of w to write text \(quoted(s.command))" }
            return l
        }
        return """
        set wasRunning to application "iTerm" is running
        tell application "iTerm"
          activate
          set strays to {}
          if not wasRunning then
            repeat 50 times
              if (count of windows) > 0 then exit repeat
              delay 0.1
            end repeat
            -- iTerm 3.7.3 segfaults if a new pane is queried for accessibility before it has drawn,
            -- which a cold start plus four quick windows triggers. Let its own window draw a prompt first.
            repeat 50 times
              try
                if (contents of current session of first window) is not "" then exit repeat
              end try
              delay 0.1
            end repeat
            delay 0.5
            set strays to windows
          end if

        """ + lines.joined(separator: "\n") + """


          repeat with s in strays
            close s
          end repeat
        end tell

        """
    }

    /// Runs `script()` (built on the main thread, it reads the screens) through osascript, off the
    /// main thread. Returns nil or the error text.
    static func open(_ script: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return error.localizedDescription }
        p.waitUntilExit()
        guard p.terminationStatus != 0 else { return nil }
        let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.contains("-1743") ? "Allow \(GWConfig.name) to control iTerm in System Settings > Privacy > Automation"
                                      : text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
