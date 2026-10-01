import AppKit

/// The GoldWare mark (Resources/goldware-logo.png), drawn smoothly at any size,
/// plus a peeking GoldWare for the assistant-mode pill.
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
