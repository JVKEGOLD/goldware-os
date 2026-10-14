import AppKit
import AVFoundation
import CoreAudio
import ScreenCaptureKit

/// Tutorial recorder (a Loom of your own): records the screen the pointer is on, a round camera bubble,
/// a halo around the pointer that ripples on every click, and a pen for drawing on the screen.
/// The bubble, halo and ink are real windows on that screen, so the capture picks them up as they
/// are; the Quick Tools button and its panel (where the tools and Stop live) are left out of the video.
/// Saves an .mp4 to ~/Movies/<assistant name> Recordings, where the Quick Tools panel lists it.
///
/// Shortcuts while it runs: ⌃⌥R start or stop, ⌃⌥D pen on or off, ⌃⌥C clear the ink, Esc leaves the
/// pen (or cancels the countdown).
enum Tutorial {
    static let countdown = 3
    static let haloRadius: CGFloat = 24
    static let rippleLength: TimeInterval = 0.45
    static let bubbleSize: CGFloat = 220
    static let bubbleInset: CGFloat = 28
    static let penWidth: CGFloat = 5
    static let pen = NSColor(red: 1, green: 0.23, blue: 0.19, alpha: 1)
    /// Pen colours offered in Quick Tools: red, yellow, blue, white.
    static let penColors: [NSColor] = [pen, NSColor(red: 1, green: 0.84, blue: 0.04, alpha: 1),
                                       NSColor(red: 0.04, green: 0.52, blue: 1, alpha: 1), .white]
    static let spotlightRadius: CGFloat = 150
    static let halo = NSColor(red: 1, green: 0.84, blue: 0.2, alpha: 1)

    enum Key: Equatable { case toggle, pen, clear, escape }

    /// The recorder's keys: ⌃⌥R, ⌃⌥D, ⌃⌥C exactly (no Command or Shift), and a bare Esc.
    static func key(_ code: UInt16, _ raw: NSEvent.ModifierFlags) -> Key? {
        let m = raw.intersection([.command, .option, .shift, .control])
        if code == 53, m.isEmpty { return .escape }
        guard m == [.control, .option] else { return nil }
        return [15: Key.toggle, 2: .pen, 8: .clear][code]
    }

    /// The whole clip is a start phrase ("start recording", "record my screen", "record a tutorial"),
    /// optionally with "hey/okay" and the assistant's name around it.
    static func matchesStart(_ spoken: String, names: [String]? = nil) -> Bool {
        TerminalCommands.matchesPhrase(spoken, #"(please )?((start|begin) (a |the )?(screen )?(recording|tutorial|loom)|record (my |the )?screen|record (a |the )?(tutorial|loom))( please)?"#, names: names)
    }

    /// The whole clip is a stop phrase ("stop recording", "end the recording").
    static func matchesStop(_ spoken: String, names: [String]? = nil) -> Bool {
        TerminalCommands.matchesPhrase(spoken, #"(please )?(stop|end|finish) (the )?(screen )?(recording|tutorial|loom)( please)?"#, names: names)
    }

    /// The folder's name: "<assistant name> Recordings", with characters a folder can't hold turned into dashes.
    static func folderName(for name: String) -> String {
        let safe = name.replacingOccurrences(of: #"[/:\\]"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return (safe.isEmpty ? "GoldWare" : safe) + " Recordings"
    }

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies", isDirectory: true)
            .appendingPathComponent(folderName(for: GWConfig.name), isDirectory: true)
    }

    static func fileURL(at date: Date, in folder: URL) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return folder.appendingPathComponent("Tutorial \(f.string(from: date)).mp4")
    }

    /// Bottom-left of the visible screen, clear of the Dock.
    static func bubbleFrame(in visible: NSRect, size: CGFloat = bubbleSize) -> NSRect {
        NSRect(x: visible.minX + bubbleInset, y: visible.minY + bubbleInset, width: size, height: size)
    }

    /// How close (beyond its edge) the pointer may come before the camera bubble jumps away.
    static let dodgeMargin: CGFloat = 12

    /// Where the camera bubble goes when the pointer reaches it: the corner of the visible screen
    /// farthest from the pointer, so whatever sat under the bubble is free. Nil while the pointer is
    /// clear of it, while Option is held (hold Option to grab and drag the bubble), or while a mouse
    /// button is down (mid-drag or mid-stroke).
    static func dodge(bubble: NSRect, pointer: NSPoint, visible: NSRect, option: Bool, mouseDown: Bool) -> NSRect? {
        guard !option, !mouseDown else { return nil }
        let c = NSPoint(x: bubble.midX, y: bubble.midY)
        guard hypot(pointer.x - c.x, pointer.y - c.y) <= bubble.width / 2 + dodgeMargin else { return nil }
        let s = bubble.width, i = bubbleInset
        let corners = [NSPoint(x: visible.minX + i, y: visible.minY + i), NSPoint(x: visible.maxX - i - s, y: visible.minY + i),
                       NSPoint(x: visible.minX + i, y: visible.maxY - i - s), NSPoint(x: visible.maxX - i - s, y: visible.maxY - i - s)]
        let far = corners.max { hypot($0.x + s / 2 - pointer.x, $0.y + s / 2 - pointer.y) < hypot($1.x + s / 2 - pointer.x, $1.y + s / 2 - pointer.y) }!
        return NSRect(origin: far, size: bubble.size)
    }

    /// What the ink layer must repaint after the pointer moves: the old and new halo spots (and a running
    /// ripple), or nil for the whole screen when the spotlight, the countdown or a stroke changes
    /// more than that. A full-screen redraw at 60 Hz for a moving pointer was the main idle cost.
    static func dirtyRect(old: NSPoint?, new: NSPoint?, ripple: NSPoint?, full: Bool) -> NSRect? {
        guard !full else { return nil }
        let r = haloRadius * 2.6 + 4
        let spots = [old, new, ripple].compactMap { $0 }.map { NSRect(x: $0.x - r, y: $0.y - r, width: r * 2, height: r * 2) }
        guard let first = spots.first else { return .zero }
        return spots.dropFirst().reduce(first) { $0.union($1) }
    }

    /// 0 to 1 through a click ripple, nil when there is none.
    static func ripple(since: TimeInterval?, now: TimeInterval) -> CGFloat? {
        guard let s = since, now >= s, now - s < rippleLength else { return nil }
        return CGFloat((now - s) / rippleLength)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Bluetooth mics (AirPods) drop the headset into its call profile and wreck music output, so a
    /// Bluetooth default falls back to the built-in mic; any other default input is used as is.
    static func useBuiltInMic(defaultTransport: UInt32) -> Bool {
        defaultTransport == kAudioDeviceTransportTypeBluetooth || defaultTransport == kAudioDeviceTransportTypeBluetoothLE
    }

    static func micDeviceID() -> String? {
        let mics = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
        guard let def = AVCaptureDevice.default(for: .audio) else { return nil }
        guard useBuiltInMic(defaultTransport: UInt32(bitPattern: def.transportType)) else { return def.uniqueID }
        return mics.first { UInt32(bitPattern: $0.transportType) == kAudioDeviceTransportTypeBuiltIn }?.uniqueID
    }
}

// MARK: Ink layer (halo, pen, spotlight, countdown)

final class InkView: NSView {
    struct Stroke { var points: [NSPoint]; var endedAt: TimeInterval?; var color: NSColor = Tutorial.pen }
    var strokes: [Stroke] = []
    var pointer: NSPoint?
    var pressed = false
    var rippleAt: TimeInterval?
    var rippleCenter = NSPoint.zero
    var countdown: Int?
    var penOn = false
    var penColor = Tutorial.pen
    var haloOn = true
    var spotlightOn = false
    var now: () -> TimeInterval = { CACurrentMediaTime() }

    /// True while a click ripple still runs, so the timer knows to redraw. Ink stays until cleared.
    var animating: Bool {
        let t = now()
        return Tutorial.ripple(since: rippleAt, now: t) != nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = now()
        if spotlightOn, let p = pointer {
            // Dim everything but a circle around the pointer (even-odd: the circle is the hole).
            let r = Tutorial.spotlightRadius
            let dim = NSBezierPath(rect: bounds)
            dim.appendOval(in: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            dim.windingRule = .evenOdd
            NSColor(white: 0, alpha: 0.55).setFill()
            dim.fill()
        }
        for s in strokes where s.points.count > 0 {
            s.color.setStroke()
            let p = Self.smooth(s.points)
            p.lineWidth = Tutorial.penWidth
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            p.stroke()
        }
        if haloOn, let r = Tutorial.ripple(since: rippleAt, now: t) {
            let rad = Tutorial.haloRadius * (1 + 1.4 * r)
            let ring = NSBezierPath(ovalIn: NSRect(x: rippleCenter.x - rad, y: rippleCenter.y - rad, width: rad * 2, height: rad * 2))
            Tutorial.halo.withAlphaComponent(0.85 * (1 - r)).setStroke()
            ring.lineWidth = 3
            ring.stroke()
        }
        if let p = pointer, haloOn || penOn {
            let rad = penOn ? 7 : Tutorial.haloRadius * (pressed ? 0.8 : 1)
            let o = NSBezierPath(ovalIn: NSRect(x: p.x - rad, y: p.y - rad, width: rad * 2, height: rad * 2))
            (penOn ? penColor : Tutorial.halo).withAlphaComponent(penOn ? 0.9 : pressed ? 0.42 : 0.26).setFill()
            o.fill()
            (penOn ? penColor : Tutorial.halo).withAlphaComponent(0.8).setStroke()
            o.lineWidth = 2
            o.stroke()
        }
        if let n = countdown {
            let c = NSPoint(x: bounds.midX, y: bounds.midY), rad: CGFloat = 90
            NSColor(white: 0, alpha: 0.62).setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2)).fill()
            let font = NSFont.systemFont(ofSize: 96, weight: .semibold)
            let sz = Theme.size("\(n)", font: font)
            _ = Theme.draw("\(n)", at: NSPoint(x: c.x - sz.width / 2, y: c.y - sz.height / 2), font: font, color: .white)
        }
    }

    /// A curve through the midpoints, so fast strokes read as handwriting rather than a polyline.
    static func smooth(_ pts: [NSPoint]) -> NSBezierPath {
        let p = NSBezierPath()
        guard let first = pts.first else { return p }
        p.move(to: first)
        if pts.count == 1 { p.line(to: NSPoint(x: first.x + 0.1, y: first.y)); return p }
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            let mid = NSPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            p.curve(to: mid, controlPoint1: a, controlPoint2: a)
        }
        p.line(to: pts[pts.count - 1])
        return p
    }

    override func mouseDown(with e: NSEvent) {
        guard penOn else { return }
        strokes.append(Stroke(points: [convert(e.locationInWindow, from: nil)], endedAt: nil, color: penColor))
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        guard penOn, !strokes.isEmpty else { return }
        strokes[strokes.count - 1].points.append(convert(e.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        guard penOn, !strokes.isEmpty else { return }
        strokes[strokes.count - 1].endedAt = now()
    }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(frame: NSRect, level: NSWindow.Level) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.level = level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
}

// MARK: Session

/// Window level for the ink layer; Quick Tools sits above it so its buttons work while the pen is on.
let tutorialInkLevel = NSWindow.Level.screenSaver

@available(macOS 15.0, *)
final class TutorialSession: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    enum Phase { case countdown, recording, stopping, done }
    private(set) var phase = Phase.countdown
    /// Called once with the saved file, or an error to show.
    var onFinish: (URL?, String?) -> Void = { _, _ in }
    /// Called when the phase, a tool, or the elapsed second changes (Quick Tools redraws).
    var onChange: () -> Void = {}
    /// Windows left out of the video (the Quick Tools button and panel).
    var excludedWindowIDs: () -> [CGWindowID] = { [] }

    let url: URL
    private let screen: NSScreen
    private let ink: OverlayPanel
    private let inkView: InkView
    private var bubble: OverlayPanel?
    private var camera: AVCaptureSession?
    private var stream: SCStream?
    /// Held for the whole take: ScreenCaptureKit keeps its delegate weakly, so an unheld output can
    /// vanish and its "finished" callback never arrives (the session then sat in Saving forever).
    private var recording: SCRecordingOutput?
    private var startedAt: Date?
    private var timer: Timer?
    private var countdownWork: [DispatchWorkItem] = []
    private var wasPressed = false
    private var lastPointer: NSPoint?
    private var lastSecond = -1
    private var dodgeUntil: TimeInterval = 0
    private var lastDrawn: NSPoint?
    private(set) var countdownLeft: Int?

    var penOn: Bool { inkView.penOn }
    var penColor: NSColor { inkView.penColor }
    var haloOn: Bool { inkView.haloOn }
    var spotlightOn: Bool { inkView.spotlightOn }
    var cameraOn: Bool { bubble != nil }
    var elapsed: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }

    init(screen: NSScreen) {
        self.screen = screen
        url = Tutorial.fileURL(at: Date(), in: Tutorial.folder)
        ink = OverlayPanel(frame: screen.frame, level: tutorialInkLevel)
        inkView = InkView(frame: NSRect(origin: .zero, size: screen.frame.size))
        ink.contentView = inkView
        ink.ignoresMouseEvents = true
        super.init()
    }

    /// Checks Screen Recording access, shows the bubble, counts down, then records.
    func start() async throws {
        _ = try await SCShareableContent.current   // throws when Screen Recording is not allowed
        try FileManager.default.createDirectory(at: Tutorial.folder, withIntermediateDirectories: true)
        await MainActor.run {
            guard phase == .countdown else { return }   // stopped while the permission check ran: show nothing
            ink.orderFrontRegardless()
            showCamera(true)
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer!, forMode: .common)
            for i in 0..<Tutorial.countdown {
                let w = DispatchWorkItem { [weak self] in
                    self?.countdownLeft = Tutorial.countdown - i
                    self?.inkView.countdown = Tutorial.countdown - i
                    self?.inkView.needsDisplay = true
                    self?.onChange()
                }
                countdownWork.append(w)
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i), execute: w)
            }
            let go = DispatchWorkItem { [weak self] in
                guard let self, self.phase == .countdown else { return }
                self.countdownLeft = nil
                self.inkView.countdown = nil
                self.inkView.display()   // the number is gone before the first frame is captured
                Task { await self.beginCapture() }
            }
            countdownWork.append(go)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(Tutorial.countdown), execute: go)
        }
    }

    private func beginCapture() async {
        do {
            // Every window, not only on-screen ones: the Quick Tools panel may be tucked away right now.
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let (displayID, hidden, scale) = await MainActor.run {
                ((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0,
                 Set(excludedWindowIDs()), screen.backingScaleFactor)
            }
            guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
                throw NSError(domain: "Tutorial", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display to record"])
            }
            let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { hidden.contains($0.windowID) })
            let cfg = Self.streamConfig(width: Int(CGFloat(display.width) * scale), height: Int(CGFloat(display.height) * scale),
                                        mic: Tutorial.micDeviceID())
            let rc = SCRecordingOutputConfiguration()
            rc.outputURL = url
            rc.outputFileType = .mp4
            rc.videoCodecType = .h264
            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            let out = SCRecordingOutput(configuration: rc, delegate: self)
            try s.addRecordingOutput(out)
            try await s.startCapture()
            await MainActor.run {
                guard phase == .countdown else { s.stopCapture { _ in }; return }   // stopped while starting
                stream = s
                recording = out
                startedAt = Date()
                phase = .recording
                onChange()
            }
        } catch {
            await MainActor.run { finish(nil, "Couldn't start recording: \(error.localizedDescription)") }
        }
    }

    /// What the stream records: the display at full resolution and 60 fps with the pointer, your voice,
    /// and the computer's own sound (videos, apps, browser), leaving out the app's own chimes.
    static func streamConfig(width: Int, height: Int, mic: String?) -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()
        cfg.width = width
        cfg.height = height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.showsCursor = true
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2
        cfg.captureMicrophone = true
        cfg.microphoneCaptureDeviceID = mic
        return cfg
    }

    /// Stops and saves; during the countdown it cancels and saves nothing.
    func stop() {
        switch phase {
        case .countdown:
            countdownWork.forEach { $0.cancel() }
            finish(nil, nil)
        case .recording:
            phase = .stopping
            onChange()
            stream?.stopCapture { [weak self] error in
                // The file normally lands in recordingOutputDidFinishRecording; if that never comes,
                // close up anyway once the stream has stopped so the bubble and ink never stay up.
                DispatchQueue.main.asyncAfter(deadline: .now() + (error == nil ? 3 : 0)) { self?.closeUp(error) }
            }
        case .stopping:
            closeUp(nil)   // a second press always ends it
        case .done:
            break
        }
    }

    // MARK: Tools (Quick Tools buttons and the ⌃⌥ keys)

    func togglePen() {
        inkView.penOn.toggle()
        ink.ignoresMouseEvents = !inkView.penOn
        changed()
    }

    func setPenColor(_ c: NSColor) {
        inkView.penColor = c
        if !inkView.penOn { togglePen() } else { changed() }
    }

    func clearInk() {
        inkView.strokes.removeAll()
        changed()
    }

    func toggleSpotlight() { inkView.spotlightOn.toggle(); changed() }
    func toggleHalo() { inkView.haloOn.toggle(); changed() }
    func toggleCamera() { showCamera(bubble == nil); onChange() }

    private func changed() {
        inkView.needsDisplay = true
        onChange()
    }

    private func showCamera(_ on: Bool) {
        guard on else {
            bubble?.orderOut(nil)
            bubble = nil
            let c = camera
            camera = nil
            DispatchQueue.global(qos: .userInitiated).async { c?.stopRunning() }
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        let session = AVCaptureSession()
        session.sessionPreset = .high
        guard session.canAddInput(input) else { return }
        session.addInput(input)
        let frame = Tutorial.bubbleFrame(in: screen.visibleFrame)
        let panel = OverlayPanel(frame: frame, level: NSWindow.Level(rawValue: tutorialInkLevel.rawValue - 1))
        panel.isMovableByWindowBackground = true
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        preview.cornerRadius = frame.width / 2
        preview.masksToBounds = true
        preview.borderColor = Theme.gold.cgColor
        preview.borderWidth = 3
        if let conn = preview.connection, conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = true
        }
        view.layer?.addSublayer(preview)
        panel.contentView = view
        panel.orderFrontRegardless()
        bubble = panel
        camera = session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    private func tick() {
        let m = NSEvent.mouseLocation
        let inside = screen.frame.contains(m)
        let p = inside ? NSPoint(x: m.x - screen.frame.minX, y: m.y - screen.frame.minY) : nil
        let pressed = inside && NSEvent.pressedMouseButtons & 1 != 0
        var dirty = p != lastPointer || pressed != wasPressed || inkView.animating || (inkView.penOn && pressed)
        if pressed && !wasPressed, let p {
            inkView.rippleAt = inkView.now()
            inkView.rippleCenter = p
            dirty = true
        }
        wasPressed = pressed
        lastPointer = p
        inkView.pointer = p
        inkView.pressed = pressed
        if dirty {
            if let r = Tutorial.dirtyRect(old: lastDrawn, new: p, ripple: Tutorial.ripple(since: inkView.rippleAt, now: inkView.now()) != nil ? inkView.rippleCenter : nil,
                                          full: inkView.spotlightOn || inkView.animating || inkView.countdown != nil || (inkView.penOn && pressed)) {
                inkView.setNeedsDisplay(r)
            } else {
                inkView.needsDisplay = true
            }
            lastDrawn = p
        }
        dodgeBubble(m)
        if phase == .recording, Int(elapsed) != lastSecond { lastSecond = Int(elapsed); onChange() }
    }

    /// The camera bubble slides to the farthest corner when the pointer reaches it.
    private func dodgeBubble(_ m: NSPoint) {
        guard let b = bubble, CACurrentMediaTime() >= dodgeUntil,
              let to = Tutorial.dodge(bubble: b.frame, pointer: m, visible: screen.visibleFrame,
                                      option: NSEvent.modifierFlags.contains(.option), mouseDown: NSEvent.pressedMouseButtons != 0) else { return }
        dodgeUntil = CACurrentMediaTime() + 0.35
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            b.animator().setFrame(to, display: true)
        }
    }

    /// Ends the session with whatever file was written.
    private func closeUp(_ error: Error?) {
        let saved = FileManager.default.fileExists(atPath: url.path) ? url : nil
        finish(saved, saved == nil ? "Recording failed: \(error?.localizedDescription ?? "no file was written")" : nil)
    }

    private func finish(_ file: URL?, _ error: String?) {
        guard phase != .done else { return }
        phase = .done
        timer?.invalidate()
        countdownWork.forEach { $0.cancel() }
        showCamera(false)
        ink.orderOut(nil)
        if let s = stream, recording != nil { s.stopCapture { _ in } }   // harmless if it already stopped
        stream = nil
        recording = nil
        onFinish(file, error)
    }

    // SCRecordingOutputDelegate / SCStreamDelegate
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        DispatchQueue.main.async { self.finish(self.url, nil) }
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        DispatchQueue.main.async { self.finish(nil, "Recording failed: \(error.localizedDescription)") }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Stopped from the system's own recording menu: whatever was written is kept.
        DispatchQueue.main.async { self.closeUp(error) }
    }

    /// Offscreen picture of the ink layer for `--render-tutorial` (no windows, no capture).
    static func renderPreview(to path: String) -> Bool {
        let size = NSSize(width: 900, height: 520)
        let v = InkView(frame: NSRect(origin: .zero, size: size))
        let t: TimeInterval = 100
        v.now = { t }
        v.strokes = [
            .init(points: (0...40).map { i in NSPoint(x: 120 + Double(i) * 8, y: 300 + 50 * sin(Double(i) / 6)) }, endedAt: t - 1),
            .init(points: (0...40).map { i in NSPoint(x: 140 + Double(i) * 8, y: 180 + 30 * cos(Double(i) / 5)) },
                  endedAt: t - 60, color: Tutorial.penColors[2]),
        ]
        v.pointer = NSPoint(x: 640, y: 320)
        v.spotlightOn = true
        v.rippleAt = t - Tutorial.rippleLength / 2
        v.rippleCenter = NSPoint(x: 700, y: 260)
        v.countdown = 2
        let root = NSView(frame: v.frame)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(white: 0.85, alpha: 1).cgColor
        root.addSubview(v)
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return false }
        root.cacheDisplay(in: root.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
