import Foundation

extension SMC {
    /// Every key name the SMC has (about 3,600 on an M5 Pro; ~70 ms, so scan once and cache).
    public func allKeys() -> [String] {
        guard let b = bytes("#KEY"), b.count == 4 else { return [] }
        let n = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
        return (0..<min(n, 10_000)).compactMap { key(at: $0) }
    }
}

/// Temperatures grouped the way the open-source Stats app reads Apple silicon:
/// Tp* CPU cores, Tg* GPU, Tm* memory, TH* the SSD, TB* the battery.
public enum Temps {
    public static let groups: [(name: String, prefix: String)] = [
        ("CPU", "Tp"), ("GPU", "Tg"), ("MEMORY", "Tm"), ("SSD", "TH"), ("BATTERY", "TB")]

    public struct Group: Equatable {
        public var name: String, average: Double, hottest: Double, sensors: Int
    }

    /// Which keys belong to which group; anything else is left out.
    public static func keysByGroup(_ keys: [String]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for k in keys where k.count == 4 {
            if let g = groups.first(where: { k.hasPrefix($0.prefix) }) { out[g.name, default: []].append(k) }
        }
        return out
    }

    /// Plausible readings only (a sleeping sensor reads 0 or junk), averaged per group, in display order.
    public static func summarize(_ values: [String: [Double]]) -> [Group] {
        groups.compactMap { g in
            let v = (values[g.name] ?? []).filter { $0 > 1 && $0 < 130 }
            guard !v.isEmpty else { return nil }
            return Group(name: g.name, average: v.reduce(0, +) / Double(v.count), hottest: v.max() ?? 0, sensors: v.count)
        }
    }
}

/// Reads the grouped temperatures; the key scan happens on the first read.
public final class TempReader {
    let smc: SMC
    var keys: [String: [String]]?
    public init?() { guard let s = SMC() else { return nil }; smc = s }

    public func read() -> [Temps.Group] {
        if keys == nil {
            // Every CPU sensor (its hottest core matters); a spread of six for the big GPU and memory sets,
            // since each read costs ~0.2 ms and their sensors sit within a degree of each other.
            keys = Temps.keysByGroup(smc.allKeys().filter { $0.hasPrefix("T") }).mapValues { ks in
                guard ks.count > 6, !ks.first!.hasPrefix("Tp") else { return ks }
                return (0..<6).map { ks[$0 * ks.count / 6] }
            }
        }
        var values: [String: [Double]] = [:]
        for (g, ks) in keys ?? [:] { values[g] = ks.compactMap { smc.number($0) } }
        return Temps.summarize(values)
    }
}
