import Foundation

/// Settings from goldware.json (or goldware.default.json when the live file is missing or invalid).
struct GWSettings {
    var assistantName = "GoldWare"
    var wakePhrase = "Hey GoldWare"
    var wakeAliases: [String] = []
    var accentColor = "#C9A24A"
    var port = 4188
    var localModel = "gemma4:e4b"
    var whisperModel = "ggml-small.en-q5_1.bin"
    /// How long Ollama keeps the model in RAM after a request ("5m", "0", "-1" for forever).
    var keepAlive = "5m"
    /// Why the live file was not used, for the UI. nil when everything is fine.
    var error: String?
    var source = "defaults"

    /// Parses a config document. Unknown or missing fields keep their defaults; bad types throw.
    static func parse(_ data: Data) throws -> GWSettings {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EngineError.message("The config is not a JSON object")
        }
        var s = GWSettings()
        if let v = obj["assistantName"] {
            guard let n = (v as? String)?.trimmingCharacters(in: .whitespaces), (1...24).contains(n.count) else {
                throw EngineError.message("assistantName must be 1 to 24 characters")
            }
            s.assistantName = n
        }
        if let v = obj["wakePhrase"] {
            guard let p = (v as? String)?.trimmingCharacters(in: .whitespaces), !p.isEmpty else {
                throw EngineError.message("wakePhrase must be a non-empty string")
            }
            s.wakePhrase = p
        }
        if let v = obj["wakeAliases"] {
            guard let a = v as? [String] else { throw EngineError.message("wakeAliases must be a list of strings") }
            s.wakeAliases = a.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let v = obj["accentColor"] {
            guard let c = v as? String, c.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else {
                throw EngineError.message("accentColor must look like #C9A24A")
            }
            s.accentColor = c
        }
        if let v = obj["port"] {
            guard let p = v as? Int, (1024...65535).contains(p) else { throw EngineError.message("port must be a number from 1024 to 65535") }
            s.port = p
        }
        if let m = obj["models"] as? [String: Any] {
            if let l = m["local"] as? String, !l.isEmpty { s.localModel = l }
            if let w = m["whisper"] as? String, !w.isEmpty { s.whisperModel = w }
            if let k = m["keepAlive"] as? String, k.range(of: "^-?[0-9]+[smh]?$", options: .regularExpression) != nil { s.keepAlive = k }
        }
        return s
    }
}

enum GWConfig {
    private static let lock = NSLock()
    private static var cached: GWSettings?

    static var current: GWSettings {
        lock.lock(); defer { lock.unlock() }
        if let c = cached { return c }
        let c = load()
        cached = c
        return c
    }

    /// Re-reads the config files; call after the user saves settings.
    @discardableResult
    static func reload() -> GWSettings {
        lock.lock(); defer { lock.unlock() }
        let c = load()
        cached = c
        return c
    }

    /// Replaces the cached settings. For tests.
    static func inject(_ s: GWSettings?) {
        lock.lock(); defer { lock.unlock() }
        cached = s
    }

    static var name: String { current.assistantName }
    static var upperName: String { current.assistantName.uppercased() }
    static var wakePhrase: String { current.wakePhrase }
    static var error: String? { current.error }
    static var keepAlive: String { current.keepAlive }
    /// GOLDWARE_PORT wins over the config, like the server's own.
    static var port: Int { Int(ProcessInfo.processInfo.environment["GOLDWARE_PORT"] ?? "") ?? current.port }

    private static func load() -> GWSettings {
        guard let root = VaultContext.resolveRoot() else { return GWSettings() }
        var problem: String?
        let live = root.appendingPathComponent("goldware.json")
        if let data = try? Data(contentsOf: live) {
            do {
                var s = try GWSettings.parse(data)
                s.source = "goldware.json"
                return s
            } catch {
                problem = "goldware.json is invalid (\(error.localizedDescription)). Using the defaults."
            }
        }
        let def = root.appendingPathComponent("goldware.default.json")
        var s = ((try? Data(contentsOf: def)).flatMap { try? GWSettings.parse($0) }) ?? GWSettings()
        s.source = "default"
        s.error = problem
        return s
    }
}
