import AppKit

/// Draws a thinking orb (see OrbEngine.swift) with Core Graphics, driven by the display.
/// Geometry is always computed at the tuned 64pt preset and scaled to the view, so
/// the look matches the upstream demo at any size.
final class OrbView: NSView {
    var state: OrbState = .breathing { didSet { if state != oldValue { resolve() } } }
    /// Ink colour for near dots on a dark background. Far dots fade toward black.
    var tint: NSColor = .white
    /// 0...1 input level. Speeds the orb up and swells it slightly while you talk.
    var level: Float = 0
    /// Multiplies the preset speed. The idle pill breathes at about half speed.
    var speedMul: Double = 1
    /// Idle orbs draw at 30 fps to keep the always-on pill cheap.
    var idle = false { didSet { if idle != oldValue { applyFrameRate() } } }

    private var resolved = OrbEngine.resolve(.breathing, size: 64)
    private var presetSize = 64

    /// Upstream ships a 64pt design and a separate 20pt design with fewer, larger dots.
    /// Small orbs use the 20pt one; geometry is then computed at the real size.
    private func resolve() {
        presetSize = min(bounds.width, bounds.height) < 48 ? 20 : 64
        resolved = OrbEngine.resolve(state, size: presetSize)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resolve()
    }
    private var t = 0.6
    private var lastTick: CFTimeInterval = 0
    private var lastDraw: CFTimeInterval = 0
    private var smoothed: Double = 0
    private var link: CADisplayLink?
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func start() {
        guard link == nil, !reduceMotion else { needsDisplay = true; return }
        lastTick = CACurrentMediaTime()
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        applyFrameRate()
    }

    private func applyFrameRate() {
        link?.preferredFrameRateRange = idle ? CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
                                             : CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ sender: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = min(0.1, now - lastTick)
        lastTick = now
        smoothed += (Double(level) - smoothed) * min(1, dt * 12)
        // The shared clock: t = seconds × preset speed, plus a boost while speaking.
        t += dt * resolved.speed * speedMul * (1 + 1.4 * smoothed)
        // The display may tick at 120 Hz regardless of the requested range, so pace redraws here:
        // 15 fps idle (a slow breath needs no more), 60 fps while working.
        if now - lastDraw >= (idle ? 1.0 / 15 : 1.0 / 60) - 0.002 {
            lastDraw = now
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let side = min(bounds.width, bounds.height)
        let frame = OrbEngine.frame(resolved.mode, size: side, t: reduceMotion ? 0.6 : t, opts: resolved.opts)
        let swell = 1 + 0.08 * smoothed
        ctx.saveGState()
        ctx.translateBy(x: bounds.midX, y: bounds.midY)
        ctx.scaleBy(x: swell, y: swell)
        ctx.translateBy(x: -side / 2, y: -side / 2)

        // Batch marks by quantized ink so a frame is a few fills, not hundreds of colour conversions.
        let rgb = tint.usingColorSpace(.sRGB) ?? .white
        let steps = 24.0
        func key(_ white: Double, _ alpha: Double) -> Int {
            let g = Int(((1 - min(1, max(0, white))) * steps).rounded())   // dark substrate: near dots read bright
            let a = Int((min(1, max(0, alpha)) * steps).rounded())
            return g * 100 + a
        }
        func color(_ key: Int) -> CGColor {
            let g = CGFloat(key / 100) / CGFloat(steps), a = CGFloat(key % 100) / CGFloat(steps)
            return CGColor(srgbRed: rgb.redComponent * g, green: rgb.greenComponent * g, blue: rgb.blueComponent * g, alpha: a)
        }
        if !frame.lines.isEmpty {
            var strokes: [Int: (CGMutablePath, CGFloat)] = [:]
            for l in frame.lines {
                let k = key(l.white, l.a)
                let path = strokes[k]?.0 ?? CGMutablePath()
                path.move(to: CGPoint(x: l.x1, y: l.y1))
                path.addLine(to: CGPoint(x: l.x2, y: l.y2))
                strokes[k] = (path, CGFloat(l.w))
            }
            for (k, (path, w)) in strokes {
                ctx.addPath(path)
                ctx.setStrokeColor(color(k))
                ctx.setLineWidth(w)
                ctx.strokePath()
            }
        }
        // Dots stay in z order: consecutive dots with the same ink share one fill.
        var run = CGMutablePath()
        var runKey = -1
        for d in frame.dots {
            let k = key(d.white, d.a)
            if k != runKey && runKey >= 0 {
                ctx.addPath(run)
                ctx.setFillColor(color(runKey))
                ctx.fillPath()
                run = CGMutablePath()
            }
            runKey = k
            run.addEllipse(in: CGRect(x: d.x - d.r, y: d.y - d.r, width: d.r * 2, height: d.r * 2))
        }
        if runKey >= 0 {
            ctx.addPath(run)
            ctx.setFillColor(color(runKey))
            ctx.fillPath()
        }
        ctx.restoreGState()
    }
}
