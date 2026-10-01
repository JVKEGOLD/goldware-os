import Foundation

/// Finds the GoldWare OS checkout that holds goldware.json, server/ and data/.
struct VaultContext {
    let root: String

    static let empty = VaultContext(root: "")

    /// GOLDWARE_ROOT, or the checkout this app was built in.
    /// Deliberately never a saved setting or a folder in the home directory.
    static func resolveRoot() -> URL? {
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["GOLDWARE_ROOT"] { candidates.append(env) }
        // build.sh stamps the checkout path into the bundle, so a copy in /Applications finds it.
        if let stamp = Bundle.main.url(forResource: "goldware-root", withExtension: "txt"),
           let path = try? String(contentsOf: stamp, encoding: .utf8) {
            candidates.append(path.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // build/GoldWareOS.app -> app -> GoldWare-OS
        let bundle = Bundle.main.bundleURL
        candidates.append(bundle.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path)
        // .build/release/GoldWareOS -> app -> GoldWare-OS
        candidates.append(URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path)
        return candidates.map { URL(fileURLWithPath: $0) }.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("goldware.default.json").path)
        }
    }

    static func load() -> VaultContext {
        VaultContext(root: resolveRoot()?.path ?? "")
    }
}
