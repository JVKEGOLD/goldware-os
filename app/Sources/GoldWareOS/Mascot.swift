import AppKit

/// The GoldWare mark (Resources/goldware-logo.png), drawn smoothly at any size, plus the
/// plus the dashboard's surfing GoldWare and a peeking GoldWare for the assistant-mode pill.
enum Mascot {
    static let image: NSImage? = {
        var urls: [URL] = []
        if let res = Bundle.main.resourceURL { urls.append(res.appendingPathComponent("goldware-logo.png")) }
        if let root = VaultContext.resolveRoot() {
            urls.append(root.appendingPathComponent("app/Resources/goldware-logo.png"))
        }
        return urls.lazy.compactMap { NSImage(contentsOf: $0) }.first
    }()

    /// Width over height of the GoldWare GW mark (2021 × 1223, trimmed with a small margin).
    static let aspect: CGFloat = 2021.0 / 1223.0

    /// The logo is vector-like art, so scale it smoothly.
    static func draw(in rect: NSRect, alpha: CGFloat = 1) {
        guard let image, let ctx = NSGraphicsContext.current else { return }
        let old = ctx.imageInterpolation
        ctx.imageInterpolation = .high
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
        ctx.imageInterpolation = old
    }

    static func rect(height h: CGFloat, at p: NSPoint) -> NSRect { NSRect(x: p.x, y: p.y, width: (h * aspect).rounded(), height: h) }

    /// Menu bar icon: the GoldWare mark, 14pt tall.
    static func menuBarIcon() -> NSImage? {
        guard image != nil else { return nil }
        let size = NSSize(width: (14 * aspect).rounded(), height: 14)
        let icon = NSImage(size: size, flipped: true) { r in draw(in: r); return true }
        icon.isTemplate = false
        return icon
    }

    /// The dashboard's inner tube: one ellipse, white on the upper-left, red on the lower-right,
    /// drawn as a back half (behind GoldWare) and a front half (in front).
    static func drawTube(in r: NSRect, front: Bool) {
        let ring = NSBezierPath(ovalIn: r.insetBy(dx: r.height * 0.17, dy: r.height * 0.17))
        ring.lineWidth = r.height * 0.33
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: front ? NSRect(x: r.minX - 4, y: r.midY, width: r.width + 8, height: r.height)
                                 : NSRect(x: r.minX - 4, y: r.minY - 4, width: r.width + 8, height: r.height / 2 + 4)).addClip()
        NSColor(srgbRed: 0.957, green: 0.957, blue: 0.957, alpha: 1).setStroke()
        ring.stroke()
        // red on the right and bottom edges
        NSBezierPath(rect: NSRect(x: r.midX, y: r.minY - 4, width: r.width, height: r.height + 8)).addClip()
        NSColor(srgbRed: 0.89, green: 0.286, blue: 0.282, alpha: 1).setStroke()
        ring.stroke()
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}

/// The mascot in an inner tube, surfing a wave of flipping binary digits, the same scene as the
/// dashboard's top bar (npStartSurf): 19 × 4 digits on a travelling sine wave, and the mascot
/// tilting with the slope. Drawn in the dashboard's 132 × 64 space and scaled to fit.
final class SurfView: NSView {
    private let cols = 19, rows = 4
    private var digits: [Bool] = (0..<76).map { _ in Bool.random() }
    private var t: Double = 1.2
    private var link: CADisplayLink?
    private var lastDraw: CFTimeInterval = 0
    private var lastFlip: CFTimeInterval = 0
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    override var isFlipped: Bool { true }

    func start() {
        guard link == nil, !reduceMotion else { return }
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ sender: CADisplayLink) {
        let now = CACurrentMediaTime()
        t = now
        if now - lastFlip > 0.07 {
            lastFlip = now
            digits[Int.random(in: 0..<digits.count)].toggle()
        }
        if now - lastDraw >= 1.0 / 30 { lastDraw = now; needsDisplay = true }
    }

    private func wave(_ x: Double) -> Double { 40 + 7 * sin((x + t * 26) * 2 * .pi / 88) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = min(bounds.width / 132, bounds.height / 64)
        ctx.saveGState()
        ctx.scaleBy(x: s, y: s)
        let tones = [0xE6F0FF, 0x86B6EF, 0x3987E5, 0x1C5CAB].map { Theme.hex($0) }
        let font = Theme.mono(9, "Bold")
        let dx = 132.0 / Double(cols - 1)
        for r in 0..<rows {
            for c in 0..<cols {
                let x = Double(c) * dx
                // Fade the ends, like the dashboard's mask.
                let edge = min(1, min(x, 132 - x) / (132 * 0.14))
                let alpha = (1 - Double(r) * 0.2) * edge
                let y = wave(x) + Double(r) * 8.5
                Theme.draw(digits[r * cols + c] ? "1" : "0", at: NSPoint(x: x - 2.5, y: y - 9),
                           font: font, color: tones[r].withAlphaComponent(alpha))
            }
        }
        // The rider: a 40 × 36 box whose bottom centre follows the wave and tilts with it.
        let riderX = 44.0
        let y = wave(riderX), slope = (wave(riderX + 2) - wave(riderX - 2)) / 4
        ctx.translateBy(x: riderX, y: y + 3)
        ctx.rotate(by: CGFloat(atan(slope) * 0.55))
        ctx.translateBy(x: -20, y: -36)
        Mascot.drawTube(in: NSRect(x: 4, y: 20, width: 32, height: 15), front: false)
        Mascot.draw(in: NSRect(x: 2, y: 0, width: 36, height: 35))
        Mascot.drawTube(in: NSRect(x: 4, y: 20, width: 32, height: 15), front: true)
        ctx.restoreGState()
    }
}

/// The mascot peeking over the top of the assistant-mode pill. Only the part above the pill's top
/// edge is drawn, so it appears to rise from behind it.
final class PeekView: NSView {
    enum Pose { case hidden, peek, up, hop }

    var pose: Pose = .hidden { didSet { if pose != oldValue { poseChanged() } } }
    /// Voice level 0...1 while listening: the mascot bounces a little with it.
    var level: Float = 0
    /// The pill's top edge in this view's coordinates; nothing is drawn below it.
    var horizon: CGFloat = 26

    private var rise: CGFloat = 0          // how many points of the mascot show above the horizon
    private var velocity: CGFloat = 0
    private var hopStart: CFTimeInterval = 0
    private var link: CADisplayLink?
    private var lastDraw: CFTimeInterval = 0
    private let height: CGFloat = 36

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func poseChanged() {
        if pose == .hop { hopStart = CACurrentMediaTime() }
        if pose != .hidden { start() }
    }

    private var target: CGFloat {
        switch pose {
        case .hidden: return 0
        case .peek: return 18 + CGFloat(level) * 7       // hat and eyes, bobbing with your voice
        case .up: return 33 + 2 * CGFloat(sin(CACurrentMediaTime() * 4.2))
        case .hop:
            let p = CACurrentMediaTime() - hopStart
            return p < 0.5 ? 33 + CGFloat(sin(p / 0.5 * .pi)) * 12 : 33
        }
    }

    func start() {
        guard link == nil else { return }
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ sender: CADisplayLink) {
        // A soft spring toward the pose, so he pops up and sinks down rather than teleporting.
        let force = (target - rise) * 0.22 - velocity * 0.32
        velocity += force
        rise += velocity
        let now = CACurrentMediaTime()
        if now - lastDraw >= 1.0 / 60 { lastDraw = now; needsDisplay = true }
        if pose == .hidden && rise < 0.3 && abs(velocity) < 0.1 { rise = 0; stop(); needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard rise > 0.3 else { return }
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: bounds.width, height: horizon + 1)).addClip()
        let r = Mascot.rect(height: height, at: NSPoint(x: (bounds.width - height * Mascot.aspect) / 2, y: horizon - rise))
        Mascot.draw(in: r)
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    /// For offscreen renders: jump straight to a pose.
    func settle(_ pose: Pose) {
        self.pose = pose
        rise = pose == .hidden ? 0 : (pose == .peek ? 18 : 33)
        stop()
    }
}
