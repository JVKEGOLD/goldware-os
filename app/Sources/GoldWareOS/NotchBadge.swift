import AppKit

/// Small gold glyphs flanking the camera notch while Vision Mode is on, so its state reads at a
/// glance even with the mirror hidden. Left: the style (pointer arrow or Quadrants grid). Right: the
/// lock (closed while locked, open once unlocked). They ignore the mouse and never take focus.
final class NotchBadge {
    enum Side { case left, right }
    static let size = NSSize(width: 22, height: 22)
    let side: Side
    private var panel: NSPanel?
    private let icon = CALayer()
    private(set) var isShown = false
    private(set) var symbol = ""

    init(side: Side) { self.side = side }

    /// Shown whenever Vision Mode is on.
    static func visible(modeOn: Bool) -> Bool { modeOn }
    static func lockSymbol(locked: Bool) -> String { locked ? "lock.fill" : "lock.open.fill" }
    /// Face ID is on and you are not in view: nobody drives.
    static let notYouSymbol = "person.fill.xmark"
    static func styleSymbol(_ style: HandControl.Style) -> String {
        style == .quadrants ? "square.grid.2x2.fill" : "cursorarrow"
    }

    /// Beside the notch on `side`, centred in the menu bar. On a screen without a notch, beside the
    /// top-centre strip the mirror grows from.
    static func frame(notch zone: NSRect, menuBar: CGFloat, side: Side) -> NSRect {
        let barHeight = max(zone.height, menuBar)
        let x = side == .right ? zone.maxX + 6 : zone.minX - 6 - size.width
        return NSRect(x: x, y: (zone.maxY - barHeight / 2 - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }

    func set(_ show: Bool, symbol: String, label: String, notch zone: NSRect?) {
        if symbol != self.symbol {
            let swapping = !self.symbol.isEmpty
            self.symbol = symbol
            CATransaction.begin(); CATransaction.setDisableActions(true)
            setIcon(symbol, label: label)
            CATransaction.commit()
            if swapping {
                // A short crossfade so the swap reads as a change, not a flicker.
                let swap = CATransition()
                swap.type = .fade; swap.duration = 0.2
                icon.add(swap, forKey: "swap")
            }
        }
        guard show != isShown else { return }
        isShown = show
        if show {
            guard let zone else { return }
            let p = panel ?? makePanel()
            panel = p
            setIcon(symbol, label: label)
            p.setFrame(Self.frame(notch: zone, menuBar: NSStatusBar.system.thickness, side: side), display: false)
            icon.opacity = 1
            p.orderFrontRegardless()
            fade(from: 0, to: 1)
        } else if let p = panel {
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, !self.isShown else { return }
                p.orderOut(nil)
            }
            icon.opacity = 0
            fade(from: 1, to: 0)
            CATransaction.commit()
        }
    }

    private func fade(from: Float, to: Float) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from; a.toValue = to; a.duration = 0.2
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        icon.add(a, forKey: "fade")
    }

    /// Sets the glyph at a fixed height, so a wider glyph (the open lock) keeps the same body size.
    private func setIcon(_ symbol: String, label: String) {
        let img = Self.image(symbol, label: label)
        icon.contents = img
        if let img { icon.frame = Self.glyphRect(img.size, in: NSRect(origin: .zero, size: Self.size)) }
    }

    /// The glyph's rect: 16 pt tall, its own width, centred in `box`.
    static func glyphRect(_ image: NSSize, in box: NSRect) -> NSRect {
        let h: CGFloat = 16, w = h * image.width / max(1, image.height)
        return NSRect(x: (box.midX - w / 2).rounded(), y: (box.midY - h / 2).rounded(), width: w, height: h)
    }

    /// A gold glyph, also used by the offscreen render.
    static func image(_ symbol: String, label: String = "") -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(.init(paletteColors: [Theme.goldHi]))
        return NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(config)
    }

    private func makePanel() -> NSPanel {
        let p = BadgePanel(contentRect: NSRect(origin: .zero, size: Self.size),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        // Above the mirror panel, which can cover the menu bar beside the notch.
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(origin: .zero, size: Self.size))
        root.wantsLayer = true
        p.contentView = root
        icon.contentsGravity = .resizeAspect
        icon.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        icon.shadowColor = Theme.gold.cgColor
        icon.shadowOpacity = 0.7
        icon.shadowRadius = 3
        icon.shadowOffset = .zero
        root.layer?.addSublayer(icon)
        return p
    }
}

private final class BadgePanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
}
