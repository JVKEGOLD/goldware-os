import AppKit
import SMCKit

/// The control center's Fans card: reads RPM straight from the SMC (no root needed) and sets
/// speeds through GoldWare OS's fan helper daemon (root), which only accepts FanCommand words.
/// Manual speeds hold only while GoldWare OS is running: it pings the helper every 5 s and the
/// helper returns the fans to Apple's control when the pings stop or the socket closes.
final class FanControl {
    static let shared = FanControl()

    enum Mode: Equatable { case auto, max, percent(Int) }
    /// What GoldWare OS asked for; auto until it sets something.
    private(set) var mode: Mode = .auto
    private(set) var lastError: String?
    var socketPath = FanHelper.socket
    private lazy var reader = SMCFans()
    private var fd: Int32 = -1
    private var pinger: Timer?
    private let queue = DispatchQueue(label: "goldware.fans")

    func read() -> [FanReading] { reader?.read() ?? [] }

    /// Grouped temperatures; call off the main thread (the first call scans the SMC's keys).
    private lazy var tempReader = TempReader()
    private let tempLock = NSLock()
    func temps() -> [Temps.Group] {
        tempLock.lock(); defer { tempLock.unlock() }
        return tempReader?.read() ?? []
    }

    var helperInstalled: Bool { FileManager.default.fileExists(atPath: FanHelper.plist) }

    /// Another fan app fights over the same keys; the card says so.
    var otherControllerRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.crystalidea.macsfancontrol" }
    }

    /// The helper's version, or nil when it does not answer (not installed, or stopped).
    func helperVersion() -> String? {
        guard let r = queue.sync(execute: { send("version") }), r.hasPrefix("ok ") else { return nil }
        return String(r.dropFirst(3))
    }

    func set(_ m: Mode, done: @escaping (Bool) -> Void = { _ in }) {
        let cmd: String
        switch m {
        case .auto: cmd = "auto"
        case .max: cmd = "max"
        case .percent(let p): cmd = "set \(max(0, min(100, p)))"
        }
        queue.async {
            let r = self.send(cmd)
            DispatchQueue.main.async {
                let ok = r == "ok"
                if ok { self.mode = m; self.lastError = nil } else { self.lastError = r.map { String($0.dropFirst(4)) } ?? "Helper not answering" }
                self.updatePinger()
                done(ok)
            }
        }
    }

    /// Pings keep a manual speed alive; the timer only runs while one is set.
    private func updatePinger() {
        pinger?.invalidate(); pinger = nil
        guard mode != .auto else { return }
        pinger = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                if self.send("ping") != "ok" {
                    // The helper restarted or vanished: its own rule already put the fans on auto.
                    DispatchQueue.main.async { self.mode = .auto; self.updatePinger() }
                }
            }
        }
    }

    /// Quitting closes the socket, which already restores auto; saying it explicitly is quicker.
    func applicationWillTerminate() {
        guard mode != .auto else { return }
        queue.sync { _ = send("auto") }
    }

    // MARK: Socket (always on `queue`)

    /// One line out, one line back, on the persistent connection (reconnecting once if it dropped).
    private func send(_ line: String) -> String? {
        for _ in 0..<2 {
            if fd < 0 { fd = Self.connect(socketPath) }
            guard fd >= 0 else { return nil }
            if let r = Self.exchange(fd, line) { return r }
            close(fd); fd = -1
        }
        return nil
    }

    func disconnectForTest() { queue.sync { if fd >= 0 { close(fd); fd = -1 }; mode = .auto; pinger?.invalidate(); pinger = nil } }

    static func connect(_ path: String) -> Int32 {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return -1 }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(s); return -1 }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in for (i, b) in bytes.enumerated() { buf[i] = b } }
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if r != 0 { close(s); return -1 }
        return s
    }

    static func exchange(_ fd: Int32, _ line: String) -> String? {
        let out = Array((line + "\n").utf8)
        guard Darwin.write(fd, out, out.count) == out.count else { return nil }
        var reply: [UInt8] = []
        var b: UInt8 = 0
        while reply.count < 128 {
            guard Darwin.read(fd, &b, 1) == 1 else { return nil }
            if b == 10 { return String(decoding: reply, as: UTF8.self) }
            reply.append(b)
        }
        return nil
    }

    // MARK: Install (one administrator prompt)

    /// Copies the helper out of the app bundle into a root-owned place and loads it as a
    /// LaunchDaemon. The copy matters: the bundle is writable by the user, the installed one is not.
    func install(done: @escaping (String?) -> Void) {
        guard let src = Bundle.main.url(forResource: "GoldWareFanHelper", withExtension: nil)?.path else {
            done("The helper isn't in this build of GoldWare OS"); return
        }
        let script = Self.installScript(source: src, uid: getuid())
        let osa = "do shell script \(Self.appleScriptString(script)) with administrator privileges"
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", osa]
            let err = Pipe(); p.standardError = err
            do { try p.run() } catch { DispatchQueue.main.async { done("Couldn't start the installer") }; return }
            p.waitUntilExit()
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            DispatchQueue.main.async {
                if p.terminationStatus == 0 { self.queue.async { if self.fd >= 0 { close(self.fd); self.fd = -1 } }; done(nil) }
                else { done(msg.contains("-128") ? "Cancelled" : "Install failed") }
            }
        }
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func launchdPlist(uid: uid_t) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>\(FanHelper.label)</string>
          <key>ProgramArguments</key><array><string>\(FanHelper.binary)</string><string>--uid</string><string>\(uid)</string></array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
        </dict></plist>
        """
    }

    /// The shell run as root: install the binary and plist root-owned, then (re)load the daemon.
    static func installScript(source: String, uid: uid_t) -> String {
        let plist = launchdPlist(uid: uid)
        return [
            "set -e",
            "launchctl bootout system/\(FanHelper.label) 2>/dev/null || true",
            "mkdir -p /Library/PrivilegedHelperTools",
            "install -o root -g wheel -m 755 \(shellQuote(source)) \(shellQuote(FanHelper.binary))",
            "printf '%s\\n' \(shellQuote(plist)) > \(shellQuote(FanHelper.plist))",
            "chown root:wheel \(shellQuote(FanHelper.plist))",
            "chmod 644 \(shellQuote(FanHelper.plist))",
            "launchctl bootstrap system \(shellQuote(FanHelper.plist))",
        ].joined(separator: "\n")
    }
}
