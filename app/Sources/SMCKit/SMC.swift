import Foundation
import IOKit

/// The Mac's System Management Controller, through the AppleSMC user client.
/// Anyone may read; writing (fan mode and target) needs root, which is why the
/// fan helper daemon exists.
public final class SMC {
    // C layout of SMCKeyData_t (80 bytes). KeyInfo carries explicit tail padding:
    // Swift packs the next field into a struct's padding, C does not.
    struct KeyInfo { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var attr: UInt8 = 0; var p1: UInt8 = 0; var p2: UInt8 = 0; var p3: UInt8 = 0 }
    struct KeyData {
        var key: UInt32 = 0
        var vers = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt16(0))
        var plimit = (UInt16(0), UInt16(0), UInt32(0), UInt32(0), UInt32(0))
        var info = KeyInfo()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }
    static let readKey: UInt8 = 5, writeKey: UInt8 = 6, keyInfo: UInt8 = 9

    private var conn: io_connect_t = 0

    public init?() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
    }
    deinit { IOServiceClose(conn) }

    static func code(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    private func call(_ input: inout KeyData) -> Bool {
        var out = KeyData()
        var size = MemoryLayout<KeyData>.stride
        let r = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<KeyData>.stride, &out, &size)
        input = out
        return r == kIOReturnSuccess && out.result == 0
    }

    /// A key's size and type never change, so each is asked once.
    private var infoCache: [UInt32: (size: Int, type: String)] = [:]

    public func info(_ key: String) -> (size: Int, type: String)? {
        let code = Self.code(key)
        if let c = infoCache[code] { return c }
        var d = KeyData(); d.key = code; d.data8 = Self.keyInfo
        guard call(&d) else { return nil }
        let t = d.info.dataType
        let type = String(bytes: [24, 16, 8, 0].map { UInt8((t >> $0) & 0xff) }, encoding: .ascii) ?? "?"
        infoCache[code] = (Int(d.info.dataSize), type)
        return (Int(d.info.dataSize), type)
    }

    public func bytes(_ key: String) -> [UInt8]? {
        guard let i = info(key) else { return nil }
        return read(key, i)
    }

    private func read(_ key: String, _ i: (size: Int, type: String)) -> [UInt8]? {
        guard i.size <= 32 else { return nil }
        var d = KeyData(); d.key = Self.code(key); d.info.dataSize = UInt32(i.size); d.data8 = Self.readKey
        guard call(&d) else { return nil }
        return withUnsafeBytes(of: d.bytes) { Array($0.prefix(i.size)) }
    }

    /// Numbers in the formats fan keys use: flt (Apple silicon), fpe2 (Intel), ui8, ui16.
    public func number(_ key: String) -> Double? {
        guard let i = info(key), let b = read(key, i) else { return nil }
        switch (i.type, b.count) {
        case ("flt ", 4): return Double(b.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        case ("fpe2", 2): return Double((UInt16(b[0]) << 8 | UInt16(b[1]))) / 4
        case ("ui8 ", 1): return Double(b[0])
        case ("ui16", 2): return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        default: return nil
        }
    }

    /// The key name at an index (data8 8 = key from index), for listing what the SMC has.
    public func key(at index: Int) -> String? {
        var d = KeyData(); d.data8 = 8; d.data32 = UInt32(index)
        guard call(&d) else { return nil }
        let k = d.key
        return String(bytes: [24, 16, 8, 0].map { UInt8((k >> $0) & 0xff) }, encoding: .ascii)
    }

    public func write(_ key: String, _ value: [UInt8]) -> Bool {
        guard let i = info(key), i.size == value.count else { return false }
        var d = KeyData(); d.key = Self.code(key); d.info.dataSize = UInt32(i.size); d.data8 = Self.writeKey
        withUnsafeMutableBytes(of: &d.bytes) { buf in for (n, v) in value.enumerated() { buf[n] = v } }
        return call(&d)
    }

    /// Writes a number in the key's own format.
    public func write(_ key: String, number v: Double) -> Bool {
        guard let i = info(key) else { return false }
        switch i.type {
        case "flt ": return write(key, withUnsafeBytes(of: Float(v)) { Array($0) })
        case "fpe2": let n = UInt16(max(0, min(16383, v * 4))); return write(key, [UInt8(n >> 8), UInt8(n & 0xff)])
        case "ui8 ": return write(key, [UInt8(max(0, min(255, v)))])
        default: return false
        }
    }
}

public struct FanReading: Equatable {
    public var actual: Double, min: Double, max: Double, target: Double
    public var manual: Bool
    public init(actual: Double, min: Double, max: Double, target: Double, manual: Bool) {
        self.actual = actual; self.min = min; self.max = max; self.target = target; self.manual = manual
    }
}

/// What the helper drives. The real one is the SMC; tests use a fake that records writes.
public protocol FanHardware: AnyObject {
    func read() -> [FanReading]
    func setManual(_ fan: Int, rpm: Double) -> Bool
    func setAuto(_ fan: Int) -> Bool
}

public final class SMCFans: FanHardware {
    let smc: SMC
    public init?() { guard let s = SMC() else { return nil }; smc = s }

    /// Apple silicon names the mode key F0md; Intel used F0Md.
    func modeKey(_ i: Int) -> String { smc.info("F\(i)md") != nil ? "F\(i)md" : "F\(i)Md" }

    public func read() -> [FanReading] {
        let n = Int(smc.number("FNum") ?? 0)
        return (0..<min(n, 8)).compactMap { i in
            guard let a = smc.number("F\(i)Ac"), let lo = smc.number("F\(i)Mn"), let hi = smc.number("F\(i)Mx") else { return nil }
            return FanReading(actual: a, min: lo, max: hi, target: smc.number("F\(i)Tg") ?? a,
                              manual: (smc.number(modeKey(i)) ?? 0) != 0)
        }
    }

    public func setManual(_ i: Int, rpm: Double) -> Bool {
        // Some models need the test-mode unlock first; this Mac (M5 Pro) has no Ftst key.
        if smc.info("Ftst") != nil { _ = smc.write("Ftst", [1]) }
        let mode = smc.write(modeKey(i), number: 1)
        return smc.write("F\(i)Tg", number: rpm) && mode
    }

    public func setAuto(_ i: Int) -> Bool {
        let ok = smc.write(modeKey(i), number: 0)
        if i == (Int(smc.number("FNum") ?? 1) - 1), smc.info("Ftst") != nil { _ = smc.write("Ftst", [0]) }
        return ok
    }
}
