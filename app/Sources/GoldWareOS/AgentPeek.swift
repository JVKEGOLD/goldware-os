import AppKit
import JavaScriptCore

/// The Office's agents shown on the resting indicator as their pixel characters, each with a small
/// status mark: working (a spinning ring), ready (green dot), or has a question (gold "?" that hops).
/// Read from the local server's `/api/office/agents`, the same feed the dashboard Office uses.
struct AgentPeek: Equatable {
    enum State: Int, Equatable { case question = 0, working = 1, ready = 2 }
    var id: String
    var name: String
    var title: String
    var tty: String
    var state: State

    /// Same rule as the Office's `lineActivity`: busy activity or a lease is working, a real question
    /// (closing question or clarify) is a question, anything else at rest is ready.
    static func state(activity: String, working: Bool, tool: String?, question: Bool) -> State {
        let rest = ["your_turn", "idle", "asleep"].contains(activity)
        if working || !rest { return .working }
        return question || tool == "clarify" ? .question : .ready
    }

    static let maxShown = 6

    /// Questions first (they need you), then working, then ready; arrival order inside each group.
    static func ordered(_ agents: [AgentPeek]) -> [AgentPeek] {
        agents.enumerated().sorted { ($0.element.state.rawValue, $0.offset) < ($1.element.state.rawValue, $1.offset) }.map(\.element)
    }

    static func parse(_ data: Data) -> [AgentPeek]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["agents"] as? [[String: Any]] else { return nil }
        return ordered(list.compactMap { a in
            guard let id = a["id"] as? String else { return nil }
            let closing = a["closing"] as? [String: Any]
            let s = state(activity: a["activity"] as? String ?? "", working: a["working"] as? Bool ?? false,
                          tool: a["tool"] as? String, question: closing?["question"] as? Bool ?? false)
            return AgentPeek(id: id, name: a["name"] as? String ?? "Agent", title: a["title"] as? String ?? "",
                             tty: a["tty"] as? String ?? "", state: s)
        })
    }

    var label: String { ["Has a question", "Working", "Ready"][state.rawValue] }
    var tooltip: String { "\(name) · \(label)" + (title.isEmpty ? "" : "\n\(title)") }

    // MARK: Drawing

    static let slot: CGFloat = 43

    private static var sprites: [String: NSImage] = [:]
    private static var cast: (names: [String], looks: [String: (pal: [Character: NSColor], rows: [String])])?
    private static var castStamp = ""

    /// The Office cast, run from `dashboard/office-cast.js` and then the user's git-ignored
    /// `custom/office-cast.js` in JavaScriptCore, so the pill draws exactly what the Office draws,
    /// customised looks included. Each row is the left half, mirrored to make the full width.
    static func loadCast(builtIn: String, custom: String?) -> (names: [String], looks: [String: (pal: [Character: NSColor], rows: [String])]) {
        guard let ctx = JSContext() else { return ([], [:]) }
        ctx.evaluateScript("var window = this; var document = undefined;")
        ctx.evaluateScript(builtIn)
        if let custom, !custom.isEmpty {
            ctx.evaluateScript(custom)
            ctx.exception = nil   // a broken custom file keeps the built-in looks, like the Office
        }
        guard let oc = ctx.objectForKeyedSubscript("OfficeCast"), !oc.isUndefined,
              let names = oc.objectForKeyedSubscript("names")?.toArray() as? [String] else { return ([], [:]) }
        var looks: [String: (pal: [Character: NSColor], rows: [String])] = [:]
        for name in names {
            guard let d = oc.invokeMethod("data", withArguments: [name])?.toDictionary(),
                  let palText = d["pal"] as? [String: Any], let rows = d["rows"] as? [String], !rows.isEmpty else { continue }
            var pal: [Character: NSColor] = [:]
            for (k, v) in palText {
                guard let key = k.first, let hex = v as? String, let col = color(hex) else { continue }
                pal[key] = col
            }
            looks[name] = (pal, rows)
        }
        return (names, looks)
    }

    /// `#RRGGBB` (or `RRGGBB`) to a colour; anything else is nil.
    static func color(_ hex: String) -> NSColor? {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }

    private static func castFiles() -> (builtIn: URL, custom: URL)? {
        guard let root = VaultContext.resolveRoot() else { return nil }
        return (root.appendingPathComponent("dashboard/office-cast.js"), root.appendingPathComponent("custom/office-cast.js"))
    }

    /// Re-reads the cast when either file changed since the last read. True when the looks changed,
    /// so a customisation shows on the pill without restarting the app.
    @discardableResult
    static func reloadCastIfChanged() -> Bool {
        guard let f = castFiles() else { return false }
        let stamp = [f.builtIn, f.custom].map { u -> String in
            let a = try? FileManager.default.attributesOfItem(atPath: u.path)
            return "\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0):\(a?[.size] ?? 0)"
        }.joined(separator: "|")
        if cast != nil && stamp == castStamp { return false }
        castStamp = stamp
        cast = loadCast(builtIn: (try? String(contentsOf: f.builtIn, encoding: .utf8)) ?? "",
                        custom: try? String(contentsOf: f.custom, encoding: .utf8))
        sprites = [:]
        return true
    }

    /// The cast's names in file order (the order the Office hands them out).
    static var castNames: [String] {
        reloadCastIfChanged()
        return cast?.names ?? []
    }

    /// The character as a small bitmap, built the same way as office-cast.js builds its canvas.
    static func sprite(_ name: String) -> NSImage? {
        if cast == nil { reloadCastIfChanged() }
        if let s = sprites[name] { return s }
        guard let c = cast?.looks[name] else { return nil }
        let half = c.rows.map(\.count).max() ?? 0, w = half * 2, h = c.rows.count
        guard w > 0, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        // Write RGBA bytes directly: setColor with a catalog colour like .clear logs colorspace warnings.
        guard let px = rep.bitmapData else { return nil }
        let stride = rep.bytesPerRow
        for (y, r) in c.rows.enumerated() {
            let full = r + String(repeating: r.last ?? ".", count: max(0, half - r.count))
            for (x, ch) in Array(full + String(full.reversed())).enumerated() {
                let o = y * stride + x * 4
                guard ch != ".", let col = c.pal[ch]?.usingColorSpace(.deviceRGB) else { px[o] = 0; px[o + 1] = 0; px[o + 2] = 0; px[o + 3] = 0; continue }
                px[o] = UInt8(col.redComponent * 255); px[o + 1] = UInt8(col.greenComponent * 255)
                px[o + 2] = UInt8(col.blueComponent * 255); px[o + 3] = 255
            }
        }
        let img = NSImage(size: NSSize(width: w, height: h))
        img.addRepresentation(rep)
        sprites[name] = img
        return img
    }

    /// One easing step of an agent's hover amount (0 resting, 1 fully lifted), about 0.2 s either way.
    static func easeHover(_ v: CGFloat, to target: CGFloat) -> CGFloat {
        let n = v + (target - v) * 0.2
        return abs(target - n) < 0.01 ? target : n
    }

    /// Draws one agent in `r` (a flipped view): the sprite, then its status mark at the bottom right.
    /// `t` is seconds, for the working spinner and the question hop. `lift` (0 to 1) is the hover:
    /// a soft gold halo fades in and the sprite grows a little and rises.
    func draw(in r: NSRect, t: Double, lift: CGFloat = 0) {
        if lift > 0.01 {
            let d = r.width * (0.78 + 0.12 * lift)
            let halo = NSBezierPath(ovalIn: NSRect(x: r.midX - d / 2, y: r.midY - d / 2 + 1, width: d, height: d))
            Theme.gold.withAlphaComponent(0.24 * lift).setFill(); halo.fill()
            Theme.goldHi.withAlphaComponent(0.45 * lift).setStroke(); halo.lineWidth = 1; halo.stroke()
        }
        let hop = state == .question ? CGFloat(abs(sin(t * 4))) * -4 : 0
        let grow = 1 + 0.1 * lift
        let base = r.insetBy(dx: 2, dy: 3)
        let art = NSRect(x: base.midX - base.width * grow / 2, y: base.midY - base.height * grow / 2,
                         width: base.width * grow, height: base.height * grow).offsetBy(dx: 0, dy: hop - 1 * lift)
        if let img = Self.sprite(name) {
            let s = min(art.width / img.size.width, art.height / img.size.height)
            let size = NSSize(width: img.size.width * s, height: img.size.height * s)
            let dst = NSRect(x: art.midX - size.width / 2, y: art.maxY - size.height, width: size.width, height: size.height)
            NSGraphicsContext.current?.imageInterpolation = .none   // keep the pixel art crisp
            img.draw(in: dst, from: .zero, operation: .sourceOver, fraction: state == .ready ? 0.85 + 0.15 * lift : 1,
                     respectFlipped: true, hints: nil)
        } else {
            let c = NSBezierPath(ovalIn: art.insetBy(dx: 3, dy: 3))
            Theme.surface2.setFill(); c.fill()
            let f = Theme.sans(10, "SemiBold"), l = String(name.prefix(1))
            let s = Theme.size(l, font: f)
            Theme.draw(l, at: NSPoint(x: art.midX - s.width / 2, y: art.midY - s.height / 2), font: f, color: Theme.text)
        }
        let d: CGFloat = 15
        let mark = NSRect(x: r.maxX - d + 1, y: r.maxY - d + 1, width: d, height: d)
        let ring = NSBezierPath(ovalIn: mark)
        Theme.surface.setFill(); ring.fill()
        switch state {
        case .ready:
            let dot = NSBezierPath(ovalIn: mark.insetBy(dx: 2.5, dy: 2.5))
            Theme.green.setFill(); dot.fill()
        case .working:
            let arc = NSBezierPath()
            let start = CGFloat((t * 360).truncatingRemainder(dividingBy: 360))
            arc.appendArc(withCenter: NSPoint(x: mark.midX, y: mark.midY), radius: d / 2 - 3, startAngle: start, endAngle: start + 260)
            arc.lineWidth = 2.4
            arc.lineCapStyle = .round
            Theme.text.setStroke(); arc.stroke()
        case .question:
            let dot = NSBezierPath(ovalIn: mark.insetBy(dx: 0.5, dy: 0.5))
            Theme.goldHi.setFill(); dot.fill()
            let f = Theme.sans(11.5, "Bold")
            let s = Theme.size("?", font: f)
            Theme.draw("?", at: NSPoint(x: mark.midX - s.width / 2, y: mark.midY - s.height / 2), font: f, color: Theme.bg)
        }
    }
}

/// Polls `/api/office/agents` while the indicator rests on screen. Quiet when the server is down.
final class AgentPeekFeed {
    var onChange: ([AgentPeek]) -> Void = { _ in }
    private var timer: Timer?
    private var inFlight = false
    private var url: URL { URL(string: "http://127.0.0.1:\(GWConfig.port)/api/office/agents")! }

    func start() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func poll() {
        guard !inFlight else { return }
        inFlight = true
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 2)) { [weak self] data, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            let agents = ok ? data.flatMap(AgentPeek.parse) : nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                self.onChange(agents ?? [])
            }
        }.resume()
    }
}
