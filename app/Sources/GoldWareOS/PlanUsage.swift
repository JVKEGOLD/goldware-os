import Foundation

/// Claude and Codex subscription limits, read with the sign-ins Claude Code and Codex already keep on this Mac.
/// ponytail: both endpoints are the ones the official CLIs use and are undocumented; if a shape changes the card
/// says "Couldn't read" instead of guessing. GoldWare never refreshes a token itself (that would rotate the CLI's own
/// sign-in), so an expired one asks you to open the CLI once.
enum PlanUsage {
    struct Window: Equatable { var label: String; var percent: Double; var resets: Date? }
    struct Plan: Equatable { var name: String; var windows: [Window] = []; var error: String? }

    static let claudePage = URL(string: "https://claude.ai/settings/usage")!
    static let codexPage = URL(string: "https://chatgpt.com/codex/settings/usage")!

    static func fetchAll() async -> [Plan] {
        async let c = claude()
        async let x = codex()
        return await [c, x]
    }

    // MARK: Claude

    static func claude() async -> Plan {
        guard let token = claudeToken() else { return Plan(name: "Claude", error: "Not signed in to Claude Code") }
        var r = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 15)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        r.setValue("claude-code/2.1", forHTTPHeaderField: "User-Agent")
        return await get(r, name: "Claude", cli: "Claude Code", parse: parseClaude)
    }

    static func parseClaude(_ data: Data) -> [Window]? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let windows = [("5H", "five_hour"), ("WEEK", "seven_day")].compactMap { label, key -> Window? in
            guard let w = j[key] as? [String: Any], let p = w["utilization"] as? Double else { return nil }
            return Window(label: label, percent: p, resets: (w["resets_at"] as? String).flatMap(isoDate))
        }
        return windows.isEmpty ? nil : windows
    }

    /// Claude Code keeps its sign-in in ~/.claude/.credentials.json, or in the Keychain on older setups.
    private static func claudeToken() -> String? {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        let data = (try? Data(contentsOf: file)) ?? run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
        let j = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return (j?["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String
    }

    // MARK: Codex

    static func codex() async -> Plan {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: file),
              let tokens = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String else { return Plan(name: "Codex", error: "Not signed in to Codex") }
        var r = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!, timeoutInterval: 15)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let account = tokens["account_id"] as? String { r.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id") }
        r.setValue("codex_cli_rs", forHTTPHeaderField: "User-Agent")
        return await get(r, name: "Codex", cli: "Codex", parse: parseCodex)
    }

    static func parseCodex(_ data: Data) -> [Window]? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limit = j["rate_limit"] as? [String: Any] else { return nil }
        let windows = ["primary_window", "secondary_window"].compactMap { key -> Window? in
            guard let w = limit[key] as? [String: Any], let p = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            let secs = (w["limit_window_seconds"] as? NSNumber)?.intValue ?? 0
            let label = secs >= 86_400 * 6 ? "WEEK" : secs > 0 ? "\(max(1, secs / 3600))H" : "LIMIT"
            return Window(label: label, percent: p, resets: (w["reset_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
        }
        return windows.isEmpty ? nil : windows.sorted { $0.label != "WEEK" && $1.label == "WEEK" }
    }

    // MARK: Shared

    private static func get(_ r: URLRequest, name: String, cli: String, parse: (Data) -> [Window]?) async -> Plan {
        guard let (data, resp) = try? await URLSession.shared.data(for: r) else { return Plan(name: name, error: "Offline") }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { return Plan(name: name, error: "Sign-in expired · open \(cli) once") }
        guard code == 200, let w = parse(data) else { return Plan(name: name, error: "Couldn't read usage (\(code))") }
        return Plan(name: name, windows: w)
    }

    static func isoDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// "3:00 PM" within a day, otherwise "Sat 1 PM".
    static func resetText(_ d: Date?, now: Date = Date()) -> String {
        guard let d else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = d.timeIntervalSince(now) < 86_400 ? "h:mm a" : "EEE h a"
        return f.string(from: d)
    }

    private static func run(_ path: String, _ args: [String]) -> Data? {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }
}
