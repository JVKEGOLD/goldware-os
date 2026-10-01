import AppKit
import AVFoundation
import Vision

/// GoldWare Vision: camera features around a mirror that drops out of the camera notch.
///   Hand mirror   rest the pointer behind the notch; it opens while you stay there
///   Scan          hold a card, receipt, or page up in the mirror; GoldWare reads and files it
///   Vision Mode   the mirror stays pinned open and your hand drives the pointer
/// The camera runs only while the mirror is open or Vision Mode is on, so the green light
/// always matches something visible on screen.
final class VisionController {
    static var mirrorEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "visionMirrorEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "visionMirrorEnabled") }
    }

    let camera = VisionCamera()
    private lazy var mirror = NotchMirror(camera: camera)
    let control = HandControl()
    let quadrants = QuadrantDictation()
    let scanner = VisionScanner()
    /// Short status lines for the GoldWare HUD.
    var onNotice: ((String) -> Void)?
    /// Vision Mode fist dictation: start (true) or finish (false) an GoldWare Voice dictation.
    /// Quadrants: the two-hand gesture after a paste, to press Return.
    var onSend: (() -> Void)? {
        get { quadrants.onSend }
        set { quadrants.onSend = newValue; control.onSend = newValue }
    }
    /// The pinky, held (either style): clear what the last hand dictation pasted.
    var onClear: (() -> Void)? {
        get { control.onClear }
        set { control.onClear = newValue; quadrants.onClear = newValue }
    }
    /// Pointer style: both hands open, then both fists (close every terminal).
    var onLockUp: (() -> Void)? {
        get { control.onLockUp }
        set { control.onLockUp = newValue }
    }
    var onDictate: ((Bool) -> Void)? {
        get { control.onDictate }
        set { control.onDictate = newValue; quadrants.onDictate = newValue }
    }
    private var monitors: [Any] = []
    private var dwell: DispatchWorkItem?
    private var leave: DispatchWorkItem?

    func configure(agent: Assistant, store: Store) {
        scanner.agent = agent
        mirror.scan.scanner = scanner
        mirror.scan.store = store
    }

    func start() {
        guard monitors.isEmpty else { return }
        camera.onFrame = { [weak self] f in
            guard let self else { return }
            // Vision Mode keeps reading the hand while its mirror is hidden.
            guard self.mirror.isShown || (self.modeOn && self.mirrorHidden) else { return }
            guard self.modeOn else { self.mirror.handle(f, driver: nil); return }
            var unlocked = false, relocked = false
            let open = self.lock.admit(f, unlocked: &unlocked, relocked: &relocked,
                                       thumbLocks: !self.mirror.scan.isActive && !self.driver.isDictating)
            if open, self.mirrorToggle.feed(f) { self.setMirrorHidden(!self.mirrorHidden) }
            if open {
                self.driverActive = true
                if self.mirror.isShown { self.mirror.handle(f, driver: self.driver) } else { self.driver.handle(f) }
                return
            }
            if unlocked {
                Sounds.play(.assistantStart)
                self.onNotice?("Vision unlocked")
            }
            if relocked {
                Sounds.play(.done)
                self.onNotice?("Vision locked")
            }
            // Locked: the mirror still shows the hand, but nothing drives. Let go of anything held once.
            if self.driverActive { self.driver.stop(); self.driverActive = false }
            if self.mirror.isShown {
                self.mirror.handle(f, driver: nil)
                self.mirror.setStatus(self.lock.status)
            }
            if self.lock.idle(at: f.time) > 15 * 60 { self.setMode(false); self.onNotice?("Vision Mode turned off after 15 minutes without a hand") }
        }
        let idle = { [weak self] in
            self?.setMode(false)
            self?.onNotice?("Vision Mode turned off after 15 minutes without a hand")
        }
        control.onIdleTimeout = idle
        quadrants.onIdleTimeout = idle
        let switchTo: (HandControl.Style) -> Void = { [weak self] style in self?.switchStyle(to: style) }
        control.onSwitchStyle = switchTo
        quadrants.onSwitchStyle = switchTo
        // Mouse-move monitors need no Accessibility grant. Global covers other apps, local covers ours.
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.pointerMoved() }) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.pointerMoved(); return e }) {
            monitors.append(l)
        }
        // Relaunching with Vision on comes back as the pointer too.
        if HandControl.enabled { setMode(true, style: .pointer) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        dwell?.cancel(); leave?.cancel()
        setMode(false)
        mirror.hide()
    }

    // MARK: Vision Mode

    var modeOn: Bool { HandControl.enabled }
    private var lock = VisionLock()
    /// The OK sign hid the mirror; Vision Mode keeps running without it until the OK sign again.
    private(set) var mirrorHidden = false
    private var mirrorToggle = MirrorToggle()
    private var notchScreen: NSScreen? { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main }

    /// Hides the pinned mirror (the camera and hand control keep running) or brings it back.
    func setMirrorHidden(_ hide: Bool) {
        guard modeOn, hide != mirrorHidden else { return }
        mirrorHidden = hide
        if hide { mirror.hide() } else { mirror.pin(on: notchScreen) }
        Sounds.play(.done)
        if hide { onNotice?("Mirror hidden. Vision is still on. OK sign again to bring it back.") }
    }
    private var driverActive = false
    private var driver: VisionDriver { HandControl.style == .quadrants ? quadrants : control }

    /// Turns Vision Mode on in a style, or off. Switching style while on hands over cleanly.
    func setMode(_ on: Bool, style requested: HandControl.Style? = nil) {
        let style = Self.startStyle(on: on, wasOn: HandControl.enabled, requested: requested)
        let wasQuadrants = HandControl.enabled && HandControl.style == .quadrants
        defer {
            // Entering Quadrants (not relaunching into it) tiles the windows on screen.
            if on, HandControl.style == .quadrants, !wasQuadrants { quadrants.arrangeWindows() }
        }
        if let style, style != HandControl.style {
            control.stop(); quadrants.stop()
            HandControl.style = style
        }
        // Turning on (not a style switch while on) starts locked until the unlock gesture, with the
        // mirror showing.
        if on && !HandControl.enabled { lock.lock(); mirrorHidden = false }
        HandControl.enabled = on
        if on {
            if !AXIsProcessTrusted() { onNotice?("Vision Mode needs Accessibility access to move the pointer") }
            camera.claim("mode")
            if !mirrorHidden { mirror.pin(on: notchScreen) }     // asks for camera access itself if needed
        } else {
            mirrorHidden = false
            control.stop()
            quadrants.stop()
            camera.release("mode")
            mirror.unpin()
        }
        mirror.modeChanged(on, style: HandControl.style)
    }

    /// Vision always starts as the pointer (shortcut, voice, the switch, or a relaunch); Quadrants only
    /// when asked for by name (menu, control center) or switched to by hand once running.
    static func startStyle(on: Bool, wasOn: Bool, requested: HandControl.Style?) -> HandControl.Style? {
        if let requested { return requested }
        return on && !wasOn ? .pointer : nil
    }

    /// A held gesture changed style mid-use: four fingers into Quadrants, an open hand back to the pointer.
    private func switchStyle(to style: HandControl.Style) {
        guard modeOn, style != HandControl.style else { return }
        setMode(true, style: style)
        if style == .quadrants { quadrants.block(4) }   // the four that switched must not also pick quadrant 4
        Sounds.play(.assistantStart)
        onNotice?(style == .quadrants ? "Quadrants. Hold up 1 to 4 fingers to dictate there. Fist rests, open hand goes back."
                                      : "Pointer. Point to move, pinch to click. Four fingers for Quadrants.")
    }

    // MARK: Pointer at the notch

    private func pointerMoved() {
        guard Self.mirrorEnabled || mirror.isShown else { return }
        let p = NSEvent.mouseLocation
        if mirror.isShown {
            if mirror.keepsOpen(at: p) {
                leave?.cancel(); leave = nil
            } else if leave == nil {
                let w = DispatchWorkItem { [weak self] in
                    self?.leave = nil
                    self?.mirror.hide()
                }
                leave = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
            }
            return
        }
        guard let zone = NotchMirror.hotZone(containing: p) else {
            dwell?.cancel(); dwell = nil
            return
        }
        // A short dwell so sweeping across the menu bar does not flash the camera on.
        guard dwell == nil else { return }
        let w = DispatchWorkItem { [weak self] in
            self?.dwell = nil
            guard let self, NotchMirror.hotZone(containing: NSEvent.mouseLocation) != nil else { return }
            self.mirror.show(below: zone)
        }
        dwell = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: w)
    }
}

/// The mirror panel. It reads as part of the notch: pure black at the top
/// with concave shoulders into the menu bar, a gold hairline that fades in toward the bottom, the
/// live view in a rounded well, and GoldWare's footer (pixel mascot, letterspaced gold caps).
final class NotchMirror {
    private var panel: NSPanel?
    private let card = CALayer()
    private let fill = CAGradientLayer()
    private let fillMask = CAShapeLayer()
    private let edge = CAGradientLayer()
    private let edgeMask = CAShapeLayer()
    private let well = CALayer()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let title = CATextLayer()
    private let status = CATextLayer()
    private let liveDot = CALayer()
    private let mascot = CALayer()
    private let message = CATextLayer()
    private let orb = OrbView()
    private let hands = HandTracer()
    let scan = MirrorScan()
    private let spreadLine = CAShapeLayer()
    private let spreadLabel = CATextLayer()
    private var modeOn = false
    private var lastStatus = ""
    private let camera: VisionCamera
    private static let idleStatus = "TRACING · NOT RECORDED"
    /// Held open by Vision Mode or a scan in progress, regardless of the pointer.
    private(set) var pinned = false
    private(set) var isShown = false
    private var openFrame = NSRect.zero
    private var zone = NSRect.zero
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    // Geometry, in points.
    private static let ear: CGFloat = 12          // concave shoulder where the card meets the menu bar
    private static let bodyWidth: CGFloat = 368
    private static let pad: CGFloat = 10
    private static let videoHeight: CGFloat = 232
    private static let footer: CGFloat = 34
    private static let corner: CGFloat = 26

    init(camera: VisionCamera) {
        self.camera = camera
        scan.scannerCamera = camera
        // The scan card slides in under the live view and away again when the scan settles.
        scan.onActiveChange = { [weak self] _ in self?.resize() }
        scan.onScanDone = { [weak self] in
            guard let self, !self.keepsOpen(at: NSEvent.mouseLocation) else { return }
            self.hide()
        }
    }

    private var boardHeight: CGFloat { scan.isActive ? MirrorBoard.height + 8 : 0 }

    /// The notch on a MacBook display, or a strip at the top center of a screen without one.
    static func zone(of screen: NSScreen) -> NSRect {
        let f = screen.frame
        if screen.safeAreaInsets.top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            let h = screen.safeAreaInsets.top
            return NSRect(x: f.minX + l.maxX, y: f.maxY - h, width: r.minX - l.maxX, height: h)
        }
        return NSRect(x: f.midX - 90, y: f.maxY - 6, width: 180, height: 6)
    }

    static func hotZone(containing p: NSPoint) -> NSRect? {
        for screen in NSScreen.screens {
            let rect = zone(of: screen)
            // mouseLocation can sit exactly on the top edge, so include it.
            if p.x >= rect.minX, p.x <= rect.maxX, p.y >= rect.minY, p.y <= rect.maxY + 1 { return rect }
        }
        return nil
    }

    /// Stay open while the pointer is in the notch or over the mirror itself.
    func keepsOpen(at p: NSPoint) -> Bool {
        if pinned || scan.isActive { return true }
        let area = openFrame.union(zone).insetBy(dx: -8, dy: -8)
        return area.contains(p) || (p.x >= area.minX && p.x <= area.maxX && p.y >= area.maxY - 10)
    }

    /// Vision Mode: open and stay open.
    func pin(on screen: NSScreen?) {
        pinned = true
        guard let screen, !isShown else { return }
        show(below: Self.zone(of: screen))
    }

    /// Vision Mode ended: close unless the pointer or a scan is holding the mirror open.
    func unpin() {
        pinned = false
        if isShown && !keepsOpen(at: NSEvent.mouseLocation) { hide() }
    }

    func modeChanged(_ on: Bool, style: HandControl.Style) {
        modeOn = on
        // The speed gauge belongs to the pointer style only.
        if !on || style != .pointer {
            CATransaction.begin(); CATransaction.setDisableActions(true); spreadLine.path = nil; spreadLabel.isHidden = true; CATransaction.commit()
        }
        setStatus(!on ? Self.idleStatus : style == .quadrants ? "QUADRANTS" : "VISION MODE")
    }

    func handle(_ f: VisionFrame, driver: VisionDriver?) {
        hands.show(f)
        scan.observe(f)
        hands.showDocument(scan.trackedDocument, progress: scan.scanProgress, imageSize: f.imageSize)
        guard let driver else {
            CATransaction.begin(); CATransaction.setDisableActions(true); spreadLine.path = nil; spreadLabel.isHidden = true; CATransaction.commit()
            return
        }
        if scan.isActive {
            driver.stop()     // a scan owns the hand until it is filed or discarded
            setStatus("SCANNING")
        } else {
            driver.handle(f)
            setStatus(driver.status)
        }
        if let control = driver as? HandControl { drawModeOverlay(control, imageSize: f.imageSize) }
    }

    /// The speed gauge: a gold line from thumb tip to index tip that thickens and brightens as the gap
    /// (and so the speed) grows, with the speed beside it. It becomes a dot while pinched.
    private func drawModeOverlay(_ control: HandControl, imageSize: CGSize) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard imageSize != .zero, !scan.isActive, let tips = control.tips,
              [.track, .pinch, .drag].contains(control.pose) else {
            spreadLine.path = nil; spreadLabel.isHidden = true
            return
        }
        let a = wellPoint(tips.thumb, in: well.bounds, imageSize: imageSize)
        let b = wellPoint(tips.index, in: well.bounds, imageSize: imageSize)
        let pressed = control.pose == .pinch || control.pose == .drag
        if pressed {
            let c = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            spreadLine.path = CGPath(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12), transform: nil)
            spreadLine.fillColor = Theme.goldHi.cgColor
            spreadLine.lineWidth = 2
            spreadLabel.isHidden = true
            return
        }
        let t = min(1, max(0, HandControl.level(control.gain / CGFloat(HandControl.baseSpeed))))
        let line = CGMutablePath()
        line.move(to: a); line.addLine(to: b)
        spreadLine.path = line
        spreadLine.fillColor = nil
        spreadLine.lineWidth = 1.5 + 3 * t
        spreadLine.strokeColor = Theme.goldHi.withAlphaComponent(0.45 + 0.55 * t).cgColor
        let text = String(format: "%.1f×", control.gain)
        spreadLabel.string = NSAttributedString(string: text, attributes: [.font: Theme.mono(10.5, "Medium"), .foregroundColor: Theme.goldHi])
        let size = Theme.size(text, font: Theme.mono(10.5, "Medium"))
        // Beside the middle of the line, pushed outward along its normal so the fingers do not cover it.
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let len = max(1, hypot(b.x - a.x, b.y - a.y))
        var n = CGPoint(x: -(b.y - a.y) / len, y: (b.x - a.x) / len)
        if n.x > 0 { n = CGPoint(x: -n.x, y: -n.y) }
        spreadLabel.frame = CGRect(x: mid.x + n.x * 16 - size.width / 2, y: mid.y + n.y * 16 - size.height / 2,
                                   width: size.width + 2, height: size.height)
        spreadLabel.isHidden = false
    }

    func setStatus(_ text: String) {
        guard text != lastStatus else { return }
        lastStatus = text
        let size = Theme.size(text, font: Theme.mono(9, "Regular"), kern: 0.6)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        status.string = NSAttributedString(string: text, attributes: [
            .font: Theme.mono(9, "Regular"), .foregroundColor: modeOn ? Theme.gold : Theme.textMuted, .kern: 0.6])
        let right = status.frame.maxX
        status.frame = CGRect(x: right - size.width - 2, y: status.frame.minY, width: size.width + 2, height: size.height)
        liveDot.frame.origin.x = status.frame.minX - 11
        CATransaction.commit()
    }

    /// Re-fits the panel when the scan card appears or goes away, keeping the top edge in the notch.
    private func resize() {
        guard isShown, let panel else { return }
        let cap = max(zone.height, NSStatusBar.system.thickness)
        let h = cap + 4 + Self.videoHeight + boardHeight + Self.footer
        openFrame = NSRect(x: openFrame.minX, y: zone.maxY - h, width: openFrame.width, height: h)
        panel.setFrame(openFrame, display: true)
        layout(size: openFrame.size, scale: panel.screen?.backingScaleFactor ?? 2)
        if scan.isActive {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0; fade.duration = 0.2
            scan.board.add(fade, forKey: "appear")
        }
    }

    func show(below zone: NSRect) {
        self.zone = zone
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // On a display without a notch there is no black cutout to grow from, so use a menu-bar-high cap.
        let cap = max(zone.height, NSStatusBar.system.thickness)
        let w = Self.bodyWidth + 2 * Self.ear
        let h = cap + 4 + Self.videoHeight + boardHeight + Self.footer
        openFrame = NSRect(x: (zone.midX - w / 2).rounded(), y: zone.maxY - h, width: w, height: h)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(zone) }) {
            openFrame.origin.x = min(max(openFrame.minX, screen.frame.minX), screen.frame.maxX - w)
        }
        panel.setFrame(openFrame, display: false)
        layout(size: openFrame.size, scale: panel.screen?.backingScaleFactor ?? 2)
        isShown = true
        panel.orderFrontRegardless()
        animateOpen()
        startCamera()
    }

    func hide() {
        guard isShown, let panel else { return }
        isShown = false
        pinned = false
        scan.closed()
        orb.stop()
        hands.clear()
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, !self.isShown else { return }
            panel.orderOut(nil)
        }
        let dur = reduceMotion ? 0.12 : 0.2
        let fold = CABasicAnimation(keyPath: "transform")
        fold.toValue = collapsedTransform()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = reduceMotion ? [fade] : [fold, fade]
        fade.beginTime = reduceMotion ? 0 : dur * 0.45
        fade.duration = reduceMotion ? dur : dur * 0.55
        fold.duration = dur
        group.duration = dur
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.8, 0.4)
        card.opacity = 0
        card.transform = reduceMotion ? CATransform3DIdentity : collapsedTransform()
        card.add(group, forKey: "fold")
        CATransaction.commit()
        orb.animator().alphaValue = 0

        // Keep the camera warm briefly so a quick second look opens instantly, then let it go.
        camera.release("mirror", after: 2)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.05) { [weak self] in
            guard let self, !self.isShown, !self.camera.isRunning else { return }
            self.previewLayer?.opacity = 0
        }
    }

    // MARK: Motion

    /// Squeezed to the notch's width and a sliver of height, pinned at the top edge.
    private func collapsedTransform() -> CATransform3D {
        let sx = max(0.2, min(1, zone.width / max(1, card.bounds.width)))
        return CATransform3DMakeScale(sx, 0.06, 1)
    }

    private func animateOpen() {
        card.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.transform = CATransform3DIdentity
        card.opacity = 1
        CATransaction.commit()
        if reduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0; fade.duration = 0.15
            card.add(fade, forKey: "open")
            return
        }
        let grow = CASpringAnimation(keyPath: "transform")
        grow.fromValue = collapsedTransform()
        grow.toValue = CATransform3DIdentity
        grow.mass = 1
        grow.stiffness = 320
        grow.damping = 26
        grow.initialVelocity = 0
        grow.duration = grow.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.1
        card.add(grow, forKey: "open")
        card.add(fade, forKey: "openFade")
    }

    // MARK: Camera

    private func startCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setMessage(nil)
            runSession()
        case .notDetermined:
            setMessage("Allow camera access to use the mirror")
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    guard self.isShown else { return }
                    if granted { self.setMessage(nil); self.runSession() }
                    else { self.setMessage("Camera access is off.\nSystem Settings › Privacy › Camera › \(GWConfig.name)") }
                }
            }
        default:
            setMessage("Camera access is off.\nSystem Settings › Privacy › Camera › \(GWConfig.name)")
        }
    }

    private func runSession() {
        let warm = camera.isRunning && (previewLayer?.opacity ?? 0) > 0
        if !warm { showWaiting(true) }
        camera.claim("mirror") { [weak self] ok in
            guard let self else { return }
            guard ok else { self.showWaiting(false); self.setMessage("No camera found"); return }
            self.applyMirroring()
            // The first frames arrive a beat after startRunning; reveal once they can.
            DispatchQueue.main.asyncAfter(deadline: .now() + (warm ? 0 : 0.12)) { self.reveal() }
        }
    }

    private func reveal() {
        guard isShown, camera.isRunning else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.28)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        previewLayer?.opacity = 1
        CATransaction.commit()
        showWaiting(false)
    }

    /// GoldWare's thinking orb holds the well while the camera wakes up.
    private func showWaiting(_ on: Bool) {
        if on {
            orb.alphaValue = 0
            orb.isHidden = false
            orb.start()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; orb.animator().alphaValue = 1 }
        } else {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; orb.animator().alphaValue = 0 },
                                                 completionHandler: { [weak self] in
                guard let self, self.orb.alphaValue == 0 else { return }
                self.orb.stop(); self.orb.isHidden = true
            })
        }
    }

    // MARK: Panel

    private func makePanel() -> NSPanel {
        let p = MirrorPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false   // the card casts its own, shaped shadow
        p.ignoresMouseEvents = true
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.isReleasedWhenClosed = false

        let root = NSView()
        root.wantsLayer = true
        p.contentView = root
        root.layer?.addSublayer(card)

        // Body: pure black where it meets the notch, warming to the dashboard surface at the footer.
        fill.colors = [Theme.surface.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
        fill.locations = [0, 0.3, 1]
        fill.mask = fillMask
        card.addSublayer(fill)
        card.shadowColor = NSColor.black.cgColor
        card.shadowOpacity = 0.55
        card.shadowRadius = 18
        card.shadowOffset = CGSize(width: 0, height: -6)

        // Gold hairline that is invisible at the notch and resolves toward the bottom edge.
        edge.colors = [Theme.gold.withAlphaComponent(0.45).cgColor, Theme.gold.withAlphaComponent(0.12).cgColor,
                       Theme.gold.withAlphaComponent(0).cgColor]
        edge.locations = [0, 0.55, 0.92]
        edgeMask.fillColor = nil
        edgeMask.strokeColor = NSColor.white.cgColor
        edgeMask.lineWidth = 1
        edge.mask = edgeMask
        card.addSublayer(edge)

        // The live view sits in a rounded well with a hairline rim.
        well.backgroundColor = Theme.surface.cgColor
        well.cornerRadius = 17
        well.cornerCurve = .continuous
        well.borderWidth = 1
        well.borderColor = Theme.border.cgColor
        well.masksToBounds = true
        card.addSublayer(well)

        let preview = AVCaptureVideoPreviewLayer(session: camera.session)
        preview.videoGravity = .resizeAspectFill
        preview.opacity = 0
        well.addSublayer(preview)
        previewLayer = preview
        well.addSublayer(hands.layer)
        card.addSublayer(scan.board)
        spreadLine.strokeColor = Theme.goldHi.cgColor
        spreadLine.lineCap = .round
        spreadLine.shadowColor = Theme.gold.cgColor
        spreadLine.shadowOpacity = 0.9
        spreadLine.shadowRadius = 4
        spreadLine.shadowOffset = .zero
        well.addSublayer(spreadLine)
        spreadLabel.alignmentMode = .center
        spreadLabel.isHidden = true
        well.addSublayer(spreadLabel)

        message.alignmentMode = .center
        message.isWrapped = true
        message.isHidden = true
        well.addSublayer(message)

        mascot.contents = Mascot.image
        mascot.magnificationFilter = .linear
        mascot.contentsGravity = .resizeAspect
        card.addSublayer(mascot)
        title.string = NSAttributedString(string: "\(GWConfig.upperName) VISION", attributes: [
            .font: Theme.sans(10, "Medium"), .foregroundColor: Theme.gold, .kern: 2.4])
        card.addSublayer(title)
        liveDot.backgroundColor = Theme.green.cgColor
        liveDot.cornerRadius = 2.5
        liveDot.shadowColor = Theme.green.cgColor
        liveDot.shadowOpacity = 0.8
        liveDot.shadowRadius = 3
        liveDot.shadowOffset = .zero
        card.addSublayer(liveDot)
        status.string = NSAttributedString(string: Self.idleStatus, attributes: [
            .font: Theme.mono(9, "Regular"), .foregroundColor: Theme.textMuted, .kern: 0.6])
        status.alignmentMode = .right
        card.addSublayer(status)

        orb.tint = Theme.goldHi
        orb.state = .connecting
        orb.isHidden = true
        root.addSubview(orb)
        return p
    }

    /// Card outline in layer coordinates (origin bottom-left): flush with the top edge, concave
    /// shoulders into the menu bar, rounded bottom corners. `closed` adds the top edge for filling.
    private static func outline(_ w: CGFloat, _ h: CGFloat, closed: Bool) -> CGPath {
        let e = ear, r = corner, path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: h))
        path.addQuadCurve(to: CGPoint(x: e, y: h - e), control: CGPoint(x: e, y: h))
        path.addLine(to: CGPoint(x: e, y: r))
        path.addArc(tangent1End: CGPoint(x: e, y: 0), tangent2End: CGPoint(x: e + r, y: 0), radius: r)
        path.addLine(to: CGPoint(x: w - e - r, y: 0))
        path.addArc(tangent1End: CGPoint(x: w - e, y: 0), tangent2End: CGPoint(x: w - e, y: r), radius: r)
        path.addLine(to: CGPoint(x: w - e, y: h - e))
        path.addQuadCurve(to: CGPoint(x: w, y: h), control: CGPoint(x: w - e, y: h))
        if closed { path.closeSubpath() }
        return path
    }

    private func layout(size: NSSize, scale: CGFloat) {
        let w = size.width, h = size.height
        let e = Self.ear, pad = Self.pad, f = Self.footer
        CATransaction.begin(); CATransaction.setDisableActions(true)
        card.anchorPoint = CGPoint(x: 0.5, y: 1)     // grow down out of the notch
        card.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        card.position = CGPoint(x: w / 2, y: h)
        let body = Self.outline(w, h, closed: true)
        card.shadowPath = body
        fill.frame = card.bounds
        fillMask.path = body
        edge.frame = card.bounds
        edgeMask.path = Self.outline(w, h, closed: false)

        let board = boardHeight
        let wellRect = CGRect(x: e + pad, y: f + board, width: w - 2 * (e + pad), height: Self.videoHeight)
        scan.board.frame = CGRect(x: wellRect.minX, y: f + 2, width: wellRect.width, height: max(0, board - 4))
        scan.board.isHidden = board == 0
        scan.board.contentsScale = scale
        spreadLine.frame = CGRect(origin: .zero, size: wellRect.size)
        spreadLabel.contentsScale = scale
        well.frame = wellRect
        previewLayer?.frame = well.bounds
        hands.layer.frame = well.bounds
        message.frame = CGRect(x: 24, y: well.bounds.midY - 26, width: well.bounds.width - 48, height: 52)

        let footerMid = f / 2 + 1
        mascot.frame = CGRect(x: wellRect.minX + 4, y: footerMid - 7, width: 15, height: 14)
        let titleSize = Theme.size("\(GWConfig.upperName) VISION", font: Theme.sans(10, "Medium"), kern: 2.4)
        title.frame = CGRect(x: mascot.frame.maxX + 8, y: footerMid - titleSize.height / 2 - 0.5,
                             width: titleSize.width + 4, height: titleSize.height)
        let statusSize = Theme.size(lastStatus.isEmpty ? Self.idleStatus : lastStatus, font: Theme.mono(9, "Regular"), kern: 0.6)
        status.frame = CGRect(x: wellRect.maxX - 4 - statusSize.width - 2, y: footerMid - statusSize.height / 2 - 0.5,
                              width: statusSize.width + 2, height: statusSize.height)
        liveDot.frame = CGRect(x: status.frame.minX - 11, y: footerMid - 2.5, width: 5, height: 5)
        for l in [title, status, message] as [CATextLayer] { l.contentsScale = scale }
        mascot.contentsScale = scale
        CATransaction.commit()

        // The root view is unflipped, so the orb shares the card's coordinates.
        orb.frame = NSRect(x: wellRect.midX - 26, y: wellRect.midY - 26, width: 52, height: 52)
        applyMirroring()
    }

    /// A mirror shows you flipped. The preview connection exists only once the camera input is added.
    private func applyMirroring() {
        if let c = previewLayer?.connection, c.isVideoMirroringSupported, !c.isVideoMirrored {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true
        }
    }

    private func setMessage(_ text: String?) {
        if let text {
            message.string = NSAttributedString(string: text, attributes: [
                .font: Theme.display(16, italic: true), .foregroundColor: Theme.textDim,
                .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = .center; p.lineSpacing = 2; return p }()])
            showWaiting(false)
        }
        message.isHidden = text == nil
    }
}

/// Traces the hands in the mirror: a gold dot on each fingertip and at the wrist, joined by gold
/// lines that fan out from the wrist, plus a gold outline around a document being scanned.
/// Readings come from VisionCamera; frames are analysed in memory and dropped.
final class HandTracer {
    let layer = CALayer()
    private let lines = CAShapeLayer()
    private let dots = CAShapeLayer()
    private let wrists = CAShapeLayer()
    private let doc = CAShapeLayer()
    private let docGlow = CAShapeLayer()
    /// Smoothed positions per hand slot, in layer points, so the trace glides instead of jittering.
    private var smoothed: [[CGPoint?]] = []
    private var missed = 0
    init() {
        layer.masksToBounds = true
        for l in [docGlow, doc] {
            l.fillColor = Theme.gold.withAlphaComponent(0.06).cgColor
            l.strokeColor = Theme.goldHi.cgColor
            l.lineJoin = .round
            layer.addSublayer(l)
        }
        doc.lineWidth = 2
        docGlow.lineWidth = 2
        docGlow.fillColor = nil
        docGlow.strokeColor = Theme.goldHi.cgColor
        docGlow.shadowColor = Theme.gold.cgColor
        docGlow.shadowOpacity = 1
        docGlow.shadowRadius = 6
        docGlow.shadowOffset = .zero
        doc.strokeColor = Theme.gold.withAlphaComponent(0.4).cgColor
        lines.fillColor = nil
        lines.strokeColor = Theme.goldHi.withAlphaComponent(0.85).cgColor
        lines.lineWidth = 1.5
        lines.lineCap = .round
        dots.fillColor = Theme.goldHi.cgColor
        dots.strokeColor = Theme.gold.withAlphaComponent(0.55).cgColor
        dots.lineWidth = 3
        wrists.fillColor = Theme.gold.cgColor
        wrists.strokeColor = Theme.goldHi.withAlphaComponent(0.5).cgColor
        wrists.lineWidth = 3
        for l in [lines, wrists, dots] {
            l.shadowColor = Theme.gold.cgColor
            l.shadowOpacity = 0.9
            l.shadowRadius = 4
            l.shadowOffset = .zero
            layer.addSublayer(l)
        }
    }

    func clear() {
        smoothed = []
        render([])
        showDocument(nil, progress: 0, imageSize: .zero)
    }

    func show(_ f: VisionFrame) {
        update(f.hands, imageSize: f.imageSize)
    }

    /// Outlines the document being scanned; the bright stroke traces around it as the hold completes.
    func showDocument(_ d: VNRectangleObservation?, progress: Double, imageSize: CGSize) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let d, imageSize != .zero, !layer.bounds.isEmpty else {
            doc.path = nil; docGlow.path = nil
            return
        }
        let path = CGMutablePath()
        let pts = [d.topLeft, d.topRight, d.bottomRight, d.bottomLeft].map { wellPoint($0, in: layer.bounds, imageSize: imageSize) }
        path.addLines(between: pts)
        path.closeSubpath()
        doc.path = path
        docGlow.path = path
        docGlow.strokeEnd = CGFloat(progress)
    }

    private func update(_ found: [[CGPoint?]], imageSize: CGSize) {
        guard !layer.bounds.isEmpty else { return }
        if found.isEmpty {
            // Hold the last trace for a few frames so a single missed detection does not flicker.
            missed += 1
            if missed > 4 { smoothed = [] }
        } else {
            missed = 0
            // Keep slots stable by pairing each new hand with the nearest previous wrist.
            var next: [[CGPoint?]] = []
            var previous = smoothed
            for hand in found where hand.count == 6 {
                let pts = hand.map { $0.map { wellPoint($0, in: layer.bounds, imageSize: imageSize) } }
                let anchor = pts[0] ?? pts.compactMap { $0 }.first
                var match: Int?
                if let anchor {
                    match = previous.indices.min { a, b in
                        dist(previous[a].compactMap { $0 }.first, anchor) < dist(previous[b].compactMap { $0 }.first, anchor)
                    }
                    if let m = match, dist(previous[m].compactMap { $0 }.first, anchor) > 120 { match = nil }
                }
                let old = match.map { previous.remove(at: $0) }
                next.append(pts.enumerated().map { i, p in
                    guard let p else { return nil }
                    guard let o = old?[i] else { return p }
                    let k: CGFloat = 0.55   // higher follows faster, lower is calmer
                    return CGPoint(x: o.x + (p.x - o.x) * k, y: o.y + (p.y - o.y) * k)
                })
            }
            smoothed = next
        }
        render(smoothed)
    }

    private func dist(_ a: CGPoint?, _ b: CGPoint) -> CGFloat {
        guard let a else { return .greatestFiniteMagnitude }
        return hypot(a.x - b.x, a.y - b.y)
    }

    private func render(_ hands: [[CGPoint?]]) {
        let l = CGMutablePath(), d = CGMutablePath(), w = CGMutablePath()
        for hand in hands where hand.count == 6 {
            let wrist = hand[0]
            for tip in hand.dropFirst().compactMap({ $0 }) {
                if let wrist {
                    l.move(to: wrist)
                    l.addLine(to: tip)
                }
                d.addEllipse(in: CGRect(x: tip.x - 3.5, y: tip.y - 3.5, width: 7, height: 7))
            }
            if let wrist { w.addEllipse(in: CGRect(x: wrist.x - 5, y: wrist.y - 5, width: 10, height: 10)) }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        lines.path = l; dots.path = d; wrists.path = w
        CATransaction.commit()
    }
}

/// A normalized camera point (Vision coordinates) to a point in the mirror's well, matching the
/// preview's aspect fill and mirroring.
private func wellPoint(_ p: CGPoint, in b: CGRect, imageSize: CGSize) -> CGPoint {
    let scale = max(b.width / imageSize.width, b.height / imageSize.height)
    let w = imageSize.width * scale, h = imageSize.height * scale
    return CGPoint(x: (b.width - w) / 2 + (1 - p.x) * w, y: (b.height - h) / 2 + p.y * h)
}

/// Borderless, and allowed to sit over the menu bar and notch.
private final class MirrorPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
}
