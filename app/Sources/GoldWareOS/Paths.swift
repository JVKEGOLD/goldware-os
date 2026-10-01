import Foundation

/// Everything personal lives outside the repo, in Application Support.
enum Paths {
    static let dataDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // GOLDWARE_DATA keeps test runs out of the real history and capture queue.
        let dir = ProcessInfo.processInfo.environment["GOLDWARE_DATA"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? base.appendingPathComponent("GoldWare OS", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let audioDir: URL = {
        let dir = dataDir.appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let database = dataDir.appendingPathComponent("history.sqlite")
    static let historyPage = dataDir.appendingPathComponent("history.html")
    static let vocabulary = dataDir.appendingPathComponent("vocabulary.txt")
    static var whisperModel: URL { dataDir.appendingPathComponent("models/\(GWConfig.current.whisperModel)") }

    /// whisper-server from Homebrew, or the first one found on PATH. nil when missing.
    static var whisperServerBinary: String? {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin"]
        dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return dirs.map { $0 + "/whisper-server" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// User-editable list of names and terms. Fed to Whisper as a spelling hint
/// and to the cleanup model as a glossary.
enum Vocabulary {
    static let seed = """
    # One term per line. Lines starting with # are ignored.
    # These spellings are passed to the speech engine and the cleanup model.
    GoldWare
    Ollama
    Whisper
    Claude
    Codex
    """

    static func load() -> [String] { loadOwn() }

    /// Adds names learned from your edits to the end of vocabulary.txt, once each.
    static func addLearned(_ terms: [String]) {
        var text = (try? String(contentsOf: Paths.vocabulary, encoding: .utf8)) ?? seed
        let have = Set(loadOwn().map { $0.lowercased() })
        let new = terms.filter { !have.contains($0.lowercased()) }
        guard !new.isEmpty else { return }
        if !text.contains("# Learned from your edits") { text += (text.hasSuffix("\n") ? "" : "\n") + "\n# Learned from your edits\n" }
        text += new.joined(separator: "\n") + "\n"
        try? text.write(to: Paths.vocabulary, atomically: true, encoding: .utf8)
    }

    private static func loadOwn() -> [String] {
        if !FileManager.default.fileExists(atPath: Paths.vocabulary.path) {
            try? seed.write(to: Paths.vocabulary, atomically: true, encoding: .utf8)
        }
        let text = (try? String(contentsOf: Paths.vocabulary, encoding: .utf8)) ?? seed
        return text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}
