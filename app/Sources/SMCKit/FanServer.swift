import Foundation

/// The fan helper: a tiny root daemon on a Unix socket that only takes these words.
public enum FanHelper {
    public static let label = "io.goldware.os.fanhelper"
    public static let socket = "/var/run/io.goldware.os.fanhelper.sock"
    public static let binary = "/Library/PrivilegedHelperTools/io.goldware.os.fanhelper"
    public static let plist = "/Library/LaunchDaemons/io.goldware.os.fanhelper.plist"
    /// Present while the helper holds the fans in manual, so a restarted helper puts them back.
    public static let marker = "/var/run/io.goldware.os.fanhelper.manual"
    /// Bump when the protocol or helper changes; the app offers "Update helper" on a mismatch.
    public static let version = "1"
    /// Manual speeds last only while GoldWare OS keeps pinging; silence or a closed socket means auto.
    public static let lease: Double = 20
}

public enum FanCommand: Equatable {
    case ping, version, status, auto, max, set(Int)

    /// Exact words only: "ping", "version", "status", "auto", "max", "set N" with N in 0...100.
    public init?(line raw: String) {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        guard line.count <= 16 else { return nil }
        switch line {
        case "ping": self = .ping
        case "version": self = .version
        case "status": self = .status
        case "auto": self = .auto
        case "max": self = .max
        default:
            let parts = line.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == "set", parts[1].count <= 3,
                  parts[1].allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(parts[1]), (0...100).contains(n) else { return nil }
            self = .set(n)
        }
    }

    public var isManual: Bool { if case .set = self { return true }; return self == .max }
}

public enum FanMath {
    /// A percent of each fan's own range, clamped to its min and max.
    public static func rpm(percent: Int, min lo: Double, max hi: Double) -> Double {
        let p = Double(Swift.max(0, Swift.min(100, percent))) / 100
        return (lo + (hi - lo) * p).rounded()
    }
    public static func percent(rpm: Double, min lo: Double, max hi: Double) -> Int {
        guard hi > lo else { return 0 }
        return Int((Swift.max(0, Swift.min(1, (rpm - lo) / (hi - lo))) * 100).rounded())
    }
}

/// The daemon's state, separate from the socket so it can be tested with a fake clock and fake fans.
public final class FanState {
    let hw: FanHardware
    let markerPath: String?
    public private(set) var manual: FanCommand?
    public private(set) var owner: Int?
    var expires: Double = 0
    let lock = NSLock()

    public init(hardware: FanHardware, markerPath: String? = nil) { hw = hardware; self.markerPath = markerPath }

    /// Handles one command from client `id`; returns the reply line.
    public func handle(_ cmd: FanCommand, from id: Int, now: Double) -> String {
        lock.lock(); defer { lock.unlock() }
        if id == owner { expires = now + FanHelper.lease }
        switch cmd {
        case .ping: return "ok"
        case .version: return "ok \(FanHelper.version)"
        case .status:
            switch manual {
            case .max?: return "ok max"
            case .set(let n)?: return "ok set \(n)"
            default: return "ok auto"
            }
        case .auto:
            return restore() ? "ok" : "err write failed"
        case .max, .set:
            let fans = hw.read()
            guard !fans.isEmpty else { return "err no fans" }
            var ok = true
            for (i, f) in fans.enumerated() {
                let rpm = cmd == .max ? f.max : { if case .set(let n) = cmd { return FanMath.rpm(percent: n, min: f.min, max: f.max) }; return f.min }()
                ok = hw.setManual(i, rpm: rpm) && ok
            }
            manual = cmd; owner = id; expires = now + FanHelper.lease
            if let m = markerPath { FileManager.default.createFile(atPath: m, contents: Data("\(id)".utf8)) }
            return ok ? "ok" : "err write failed"
        }
    }

    /// Back to Apple's control. Callers hold the lock.
    @discardableResult func restore() -> Bool {
        var ok = true
        for i in hw.read().indices { ok = hw.setAuto(i) && ok }
        manual = nil; owner = nil
        if let m = markerPath { try? FileManager.default.removeItem(atPath: m) }
        return ok
    }

    /// The owner's socket closed (GoldWare OS quit or crashed).
    public func disconnected(_ id: Int) {
        lock.lock(); defer { lock.unlock() }
        if id == owner { restore() }
    }

    /// Once a second: a lease that ran out (GoldWare OS hung) goes back to auto.
    public func tick(now: Double) {
        lock.lock(); defer { lock.unlock() }
        if manual != nil, now > expires { restore() }
    }

    /// At start: if a previous run left the fans manual (marker present), put them back.
    public func recoverIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        if let m = markerPath, FileManager.default.fileExists(atPath: m) { restore() }
    }

    public func shutdown() {
        lock.lock(); defer { lock.unlock() }
        if manual != nil { restore() }
    }
}

/// The socket side: accepts local connections from one uid, one line per command.
public final class FanServer {
    let state: FanState
    let path: String
    let allowedUID: uid_t
    var listenFD: Int32 = -1
    var nextID = 0

    public init(state: FanState, socketPath: String, allowedUID: uid_t) {
        self.state = state; path = socketPath; self.allowedUID = allowedUID
    }

    public func start() throws {
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in for (i, b) in bytes.enumerated() { buf[i] = b } }
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard r == 0 else { throw POSIXError(.EADDRINUSE) }
        // Anyone may connect; each connection is checked by its peer uid below.
        chmod(path, 0o666)
        guard listen(listenFD, 4) == 0 else { throw POSIXError(.EIO) }
        Thread.detachNewThread { [self] in acceptLoop() }
        Thread.detachNewThread { [self] in
            while true { sleep(1); state.tick(now: Date().timeIntervalSince1970) }
        }
    }

    public func stop() { close(listenFD); unlink(path) }

    func acceptLoop() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { if errno == EINTR { continue }; return }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == allowedUID || uid == 0 else { close(fd); continue }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            nextID += 1
            let id = nextID
            Thread.detachNewThread { [self] in serve(fd, id: id) }
        }
    }

    func serve(_ fd: Int32, id: Int) {
        defer { close(fd); state.disconnected(id) }
        var buf = [UInt8](repeating: 0, count: 64)
        var line: [UInt8] = []
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { return }
            for b in buf[0..<n] {
                if b == 10 {
                    let text = String(decoding: line, as: UTF8.self)
                    line.removeAll()
                    let reply = FanCommand(line: text).map { state.handle($0, from: id, now: Date().timeIntervalSince1970) } ?? "err unknown command"
                    let out = Array((reply + "\n").utf8)
                    if write(fd, out, out.count) < 0 { return }
                } else {
                    line.append(b)
                    if line.count > 32 { return }   // not one of ours
                }
            }
        }
    }
}
