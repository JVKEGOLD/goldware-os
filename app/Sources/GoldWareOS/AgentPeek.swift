import AppKit

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
    private static var cast: [String: (pal: [Character: NSColor], rows: [String])]?

    /// The Office cast, read from `dashboard/office-cast.js` so the pill and the Office always draw
    /// the same characters: each row is the left half, mirrored to make the full width.
    static func parseCast(_ js: String) -> [String: (pal: [Character: NSColor], rows: [String])] {
        var out: [String: (pal: [Character: NSColor], rows: [String])] = [:]
        let entry = try! NSRegularExpression(pattern: #"(\w+): \{[^\n]*\n\s*color: '#[0-9a-fA-F]{6}',\s*\n\s*pal: \{([^}]*)\},\s*\n\s*rows: \[([^\]]*)\]"#)
        let pair = try! NSRegularExpression(pattern: #"(\w): '#([0-9a-fA-F]{6})'"#)
        let row = try! NSRegularExpression(pattern: #"'([^']*)'"#)
        let ns = js as NSString
        for m in entry.matches(in: js, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1)), palText = ns.substring(with: m.range(at: 2)), rowText = ns.substring(with: m.range(at: 3))
            var pal: [Character: NSColor] = [:]
            for p in pair.matches(in: palText, range: NSRange(location: 0, length: (palText as NSString).length)) {
                let key = (palText as NSString).substring(with: p.range(at: 1)).first!
                let v = UInt32((palText as NSString).substring(with: p.range(at: 2)), radix: 16) ?? 0
                pal[key] = NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
            }
            let rows = row.matches(in: rowText, range: NSRange(location: 0, length: (rowText as NSString).length))
                .map { (rowText as NSString).substring(with: $0.range(at: 1)) }
            if !rows.isEmpty { out[name] = (pal, rows) }
        }
        return out
    }

    /// The cast's names in file order (the order the Office hands them out).
    static var castNames: [String] {
        let url = VaultContext.resolveRoot()?.appendingPathComponent("dashboard/office-cast.js")
        let js = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let re = try! NSRegularExpression(pattern: #"^    (\w+): \{"#, options: .anchorsMatchLines)
        return re.matches(in: js, range: NSRange(location: 0, length: (js as NSString).length)).map { (js as NSString).substring(with: $0.range(at: 1)) }
    }

    /// The character as a small bitmap, built the same way as office-cast.js builds its canvas.
    static func sprite(_ name: String) -> NSImage? {
        if let s = sprites[name] { return s }
        if cast == nil {
            let url = VaultContext.resolveRoot()?.appendingPathComponent("dashboard/office-cast.js")
            cast = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map(parseCast) ?? [:]
        }
        guard let c = cast?[name] else { return nil }
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
