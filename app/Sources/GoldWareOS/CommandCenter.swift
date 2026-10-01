import Foundation

/// Keeps the local GoldWare OS server (server/goldware_server.py) running for the dashboard window and
/// captures. A server someone else started is used as is; one this app started is stopped when the app quits.
final class CommandCenter {
    let port: Int
    private var process: Process?

    /// The port comes from the config (GOLDWARE_PORT overrides), like the server's own.
    init(port: Int = GWConfig.port) { self.port = port }
    private(set) var startedHere = false

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/")! }

    func isUp() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/work"))
        req.timeoutInterval = 1.5
        return ((try? await URLSession.shared.data(for: req))?.1 as? HTTPURLResponse)?.statusCode == 200
    }

    /// Returns nil when the server is reachable, or a reason it is not.
    func ensureRunning(root: URL?, log: URL) async -> String? {
        if await isUp() { return nil }
        guard let root else { return "GoldWare OS could not find its folder. Set GOLDWARE_ROOT or run it from the repo." }
        if let p = process, p.isRunning { return await waitUntilUp() ? nil : "The server is not answering yet." }

        guard let p = run(["python3", "server/goldware_server.py"], in: root, log: log, wait: false) else {
            return "The server could not be launched. See server.log in the data folder."
        }
        process = p
        startedHere = true
        return await waitUntilUp() ? nil : "The server did not start. See server.log in the \(GWConfig.name) data folder."
    }

    private func waitUntilUp() async -> Bool {
        for _ in 0..<60 {
            if await isUp() { return true }
            if let p = process, !p.isRunning { return false }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    @discardableResult
    private func run(_ args: [String], in dir: URL, log: URL, wait: Bool) -> Process? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        p.currentDirectoryURL = dir
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        if let h = try? FileHandle(forWritingTo: log) {
            h.seekToEndOfFile()
            h.write("\n[\(Date())] \(args.joined(separator: " "))\n".data(using: .utf8)!)
            p.standardOutput = h
            p.standardError = h
        }
        do { try p.run() } catch { return nil }
        if wait { p.waitUntilExit() }
        return p
    }

    func stopIfStartedHere() {
        guard startedHere, let p = process, p.isRunning else { return }
        p.terminate()
    }
}
