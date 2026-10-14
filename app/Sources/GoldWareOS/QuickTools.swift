import AppKit
import AVFoundation
import AVKit

/// Quick Tools: a small gold button on the right edge of the screen, opening a panel of the tools you use often. While a tutorial records, the panel holds the
/// recording tools (pen and colours, spotlight, pointer halo, camera bubble, clear) and a big Stop.
/// Otherwise it holds Record plus the recordings themselves: click one to watch it in the panel, drag
/// it out to drop the file anywhere. The ball and panel are left out of the video.
enum QuickToolsRules {
    static let tab = NSSize(width: 30, height: 30)
    static let width: CGFloat = 340
    static let listCap = 6
    static let leaveGrace: TimeInterval = 0.25

    /// Right edge, mid height.
    static func tabFrame(in visible: NSRect) -> NSRect {
        NSRect(x: visible.maxX - tab.width - 2, y: (visible.midY - tab.height / 2).rounded(), width: tab.width, height: tab.height)
    }

    /// Flush with the right edge, centred on the ball, kept on screen.
    static func panelFrame(in visible: NSRect, height: CGFloat) -> NSRect {
        let h = min(height, visible.height - 16)
        let y = min(max(visible.midY - h / 2, visible.minY + 8), visible.maxY - 8 - h)
        return NSRect(x: visible.maxX - width, y: y.rounded(), width: width, height: h)
    }

    /// Tucks away a moment after the pointer leaves, but only once it has been inside (a panel that
    /// opened by itself after a recording waits for him), and never while a video plays or a file drags.
    static func shouldClose(inside: Bool, entered: Bool, busy: Bool, outsideFor: TimeInterval?) -> Bool {
        guard !inside, entered, !busy, let t = outsideFor else { return false }
        return t >= leaveGrace
    }

    /// Videos in the folder, newest first.
    static func recordings(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
        return files.filter { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }
            .map { ($0, date($0)) }.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// "Today 12:59", "Yesterday 09:14", "Oct 13 09:14".
    static func label(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "HH:mm"
        let time = f.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "Yesterday \(time)" }
        f.dateFormat = "MMM d HH:mm"
        return f.string(from: date)
    }

    static func size(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000 ? String(format: "%.1f GB", Double(bytes) / 1e9) : "\(max(1, bytes / 1_000_000)) MB"
    }
}

/// What the panel shows about the recorder; the app fills it from the running session.
struct RecState: Equatable {
    enum Phase: Equatable { case idle, countdown(Int), recording, saving }
    var phase = Phase.idle
    var elapsed: TimeInterval = 0
    var pen = false, spotlight = false, halo = true, camera = true
    var penColor = 0
}

final class QuickTools: NSObject {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "quickToolsEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "quickToolsEnabled") }
    }
    /// "record", "stop", "pen", "clear", "spotlight", "halo", "camera", "color:N".
    var onAction: (String) -> Void = { _ in }
    var state = RecState() { didSet { if state != oldValue { stateChanged(from: oldValue) } } }

    private var strip: ToolPanel?
    private var panel: ToolPanel?
    private let content = ToolsView()
    private var monitors: [Any] = []
    private var watch: Timer?
    private var hoverWork: DispatchWorkItem?
    private var outsideSince: Date?
    private var entered = false
    private(set) var isOpen = false

    /// Window ids to leave out of a recording: the ball and the panel (built now if it wasn't yet).
    var windowIDs: [CGWindowID] {
        if panel == nil { panel = makePanel() }
        return [strip, panel].compactMap { $0 }.map { CGWindowID($0.windowNumber) }
    }

    func start() {
        guard Self.enabled else { return }
        content.onAction = { [weak self] a in self?.act(a) }
        content.onResize = { [weak self] in self?.place() }
        let s = strip ?? makeStrip()
        strip = s
        place()
        s.orderFrontRegardless()
        NotificationCenter.default.addObserver(self, selector: #selector(place), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func stop() {
        close()
        strip?.orderOut(nil)
        NotificationCenter.default.removeObserver(self)
    }

    private var screen: NSRect { (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame ?? .zero }

    @objc private func place() {
        strip?.setFrame(QuickToolsRules.tabFrame(in: screen), display: true)
        if isOpen { panel?.setFrame(QuickToolsRules.panelFrame(in: screen, height: content.wantedHeight), display: true) }
    }

    /// A finished recording: open the panel on it, ready to watch or drag.
    func showSaved(_ url: URL) {
        content.reload()
        content.select(url)
        open(auto: true)
    }

    private func act(_ a: String) {
        if a == "record" { close() }
        onAction(a)
    }

    private func stateChanged(from old: RecState) {
        content.state = state
        (strip?.contentView as? ToolsTab)?.live = state.phase != .idle
        if old.phase == .idle, state.phase != .idle { content.stopPlayback() }
        if isOpen { place() }
    }

    // MARK: Open and close

    func open(auto: Bool = false) {
        hoverWork?.cancel()
        entered = !auto
        guard !isOpen else { return }
        isOpen = true
        let p = panel ?? makePanel()
        panel = p
        content.reload()
        let end = QuickToolsRules.panelFrame(in: screen, height: content.wantedHeight)
        p.setFrame(end.offsetBy(dx: end.width, dy: 0), display: false)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().setFrame(end, display: true)
            p.animator().alphaValue = 1
        }
        let down: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: down, handler: { [weak self] _ in self?.close() }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: down, handler: { [weak self] e in
            if e.window !== self?.panel && e.window !== self?.strip { self?.close() }
            return e
        }) { monitors.append(l) }
        outsideSince = nil
        let w = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in self?.watchPointer() }
        RunLoop.main.add(w, forMode: .common)
        watch = w
    }

    private func watchPointer() {
        guard isOpen, let p = panel else { return }
        let m = NSEvent.mouseLocation
        let inside = p.frame.insetBy(dx: -6, dy: -6).contains(m) || (strip?.frame.contains(m) ?? false)
        if inside { entered = true; outsideSince = nil } else if outsideSince == nil { outsideSince = Date() }
        if QuickToolsRules.shouldClose(inside: inside, entered: entered, busy: content.busy,
                                       outsideFor: outsideSince.map { Date().timeIntervalSince($0) }) { close() }
    }

    func close() {
        guard isOpen, let p = panel else { return }
        isOpen = false
        content.stopPlayback()
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        watch?.invalidate(); watch = nil
        let end = p.frame.offsetBy(dx: p.frame.width, dy: 0)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().setFrame(end, display: true)
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in if self?.isOpen == false { p.orderOut(nil) } })
    }

    private func hover(_ inside: Bool) {
        hoverWork?.cancel()
        guard inside, NSEvent.pressedMouseButtons == 0 else { return }   // not while drawing or dragging past it
        let w = DispatchWorkItem { [weak self] in self?.open() }
        hoverWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
    }

    private func makeStrip() -> ToolPanel {
        let p = ToolPanel(contentRect: NSRect(origin: .zero, size: QuickToolsRules.tab), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.hasShadow = false
        let v = ToolsTab(frame: NSRect(origin: .zero, size: QuickToolsRules.tab))
        v.onHover = { [weak self] in self?.hover($0) }
        v.onClick = { [weak self] in self?.isOpen == true ? self?.close() : self?.open() }
        p.contentView = v
        return p
    }

    private func makePanel() -> ToolPanel {
        let f = QuickToolsRules.panelFrame(in: screen, height: content.wantedHeight)
        let p = ToolPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.hasShadow = true
        p.onEscape = { [weak self] in self?.close() }
        content.frame = NSRect(origin: .zero, size: f.size)
        content.autoresizingMask = [.width, .height]
        p.contentView = content
        return p
    }

    /// The panel's view on its own, for the offscreen render and tests.
    static func render(state: RecState, folder: URL, selected: URL? = nil) -> ToolsView {
        let v = ToolsView(frame: NSRect(x: 0, y: 0, width: QuickToolsRules.width, height: 600))
        v.folder = folder
        v.state = state
        if let selected { v.select(selected, autoplay: false) }
        v.reload()
        v.setFrameSize(NSSize(width: QuickToolsRules.width, height: v.wantedHeight))
        v.layoutSubtreeIfNeeded()
        return v
    }
}

/// Above the tutorial's ink layer, so the tools still click while the pen is on.
final class ToolPanel: NSPanel {
    var onEscape: (() -> Void)?
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        isOpaque = false
        backgroundColor = .clear
        level = NSWindow.Level(rawValue: tutorialInkLevel.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }
    override var canBecomeKey: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

// MARK: The ball

/// The Quick Tools button: a small dark disc with a gold ring and a gold record dot, faded at rest,
/// full on hover or while a tutorial runs (then the dot turns red and the ring with it).
final class ToolsTab: NSView {
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    var live = false { didSet { alphaValue = live || hovering ? 1 : 0.6; needsDisplay = true } }
    private var hovering = false { didSet { alphaValue = live || hovering ? 1 : 0.6; needsDisplay = true } }

    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; alphaValue = 0.6 }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; onHover?(true) }
    override func mouseExited(with event: NSEvent) { hovering = false; onHover?(false) }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        Self.drawTab(center: NSPoint(x: bounds.midX, y: bounds.midY), radius: hovering ? 12 : 11, live: live)
    }

    static func drawTab(center c: NSPoint, radius r: CGFloat, live: Bool) {
        let disc = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        Theme.surface.setFill(); disc.fill()
        (live ? Tutorial.pen : Theme.gold).setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: c.x - r + 1, y: c.y - r + 1, width: r * 2 - 2, height: r * 2 - 2))
        ring.lineWidth = live ? 2 : 1.5; ring.stroke()
        let d = r * 0.38
        (live ? Tutorial.pen : Theme.gold).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - d, y: c.y - d, width: d * 2, height: d * 2)).fill()
    }
}

// MARK: The panel

final class ToolsView: NSView {
    var onAction: (String) -> Void = { _ in }
    var onResize: () -> Void = {}
    var folder = Tutorial.folder
    /// A new second only rewrites the status line. Rebuilding every view each second would swap the
    /// Stop button out from under a click that straddles the tick, and the click would be lost.
    var state = RecState() {
        didSet {
            guard state != oldValue else { return }
            var a = state, b = oldValue
            a.elapsed = 0; b.elapsed = 0
            if a == b, let s = subLabel { s.stringValue = subtitle() } else { rebuild() }
        }
    }
    private var subLabel: NSTextField?
    private(set) var wantedHeight: CGFloat = 300
    /// Each control's frame by id, for tests ("stop", "pen", "record", "row0", "player").
    private(set) var frames: [String: NSRect] = [:]
    private var files: [URL] = []
    private var selected: URL?
    private let player = FirstClickPlayerView()
    private var dragging = false
    private static var thumbs: [String: NSImage] = [:]
    private static var durations: [String: TimeInterval] = [:]

    var busy: Bool { dragging || (player.player?.rate ?? 0) > 0 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg.withAlphaComponent(0.97).cgColor
        layer?.cornerRadius = 14
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        layer?.borderColor = Theme.border.cgColor
        layer?.borderWidth = 1
        player.controlsStyle = .inline
        player.showsFullScreenToggleButton = true
        player.wantsLayer = true
        player.layer?.cornerRadius = 8
        player.layer?.masksToBounds = true
    }
    convenience init() { self.init(frame: NSRect(x: 0, y: 0, width: QuickToolsRules.width, height: 300)) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func reload() {
        files = QuickToolsRules.recordings(in: folder)
        rebuild()
    }

    func select(_ url: URL, autoplay: Bool = false) {
        selected = url
        let item = AVPlayer(url: url)
        player.player = item
        if autoplay { item.play() }
        rebuild()
    }

    func stopPlayback() { player.player?.pause() }

    private let pad: CGFloat = 18

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        frames = [:]
        var y: CGFloat = 16
        let w = QuickToolsRules.width - pad * 2
        add(label("Quick Tools", Theme.display(26), Theme.text), x: pad, y: y, w: w, h: 32)
        y += 34
        let s = label(subtitle(), Theme.sans(12), state.phase == .idle ? Theme.textMuted : Tutorial.pen)
        subLabel = s
        s.lineBreakMode = .byWordWrapping
        s.maximumNumberOfLines = 2
        add(s, x: pad, y: y, w: w, h: 32)
        y += 40
        y = state.phase == .idle ? idle(y: y, w: w) : recording(y: y, w: w)
        wantedHeight = y + 16
        if abs(frame.height - wantedHeight) > 0.5 { onResize() }
    }

    func subtitle() -> String {
        switch state.phase {
        case .idle: return "Record, then watch or drag your videos.  ⌃⌥R"
        case .countdown(let n): return "Starting in \(n). Esc cancels."
        case .recording: return "Recording \(Tutorial.clock(state.elapsed)). This panel stays out of the video."
        case .saving: return "Saving the video…"
        }
    }

    private func recording(y start: CGFloat, w: CGFloat) -> CGFloat {
        var y = start
        let stopTitle = state.phase == .saving ? "Saving…" : { if case .countdown = state.phase { return "✕  Cancel" } else { return "✕  Stop and save" } }()
        let stop = Tile(title: stopTitle, symbol: nil, on: false, danger: true) { [weak self] in self?.onAction("stop") }
        add(stop, x: pad, y: y, w: w, h: 46, id: "stop")
        y += 58
        let tools: [(String, String, String, Bool)] = [
            ("pen", "Pen", "pencil.tip", state.pen), ("spotlight", "Spotlight", "flashlight.on.fill", state.spotlight),
            ("halo", "Halo", "cursorarrow.rays", state.halo), ("camera", "Camera", state.camera ? "video.fill" : "video.slash", state.camera),
            ("clear", "Clear ink", "eraser", false),
        ]
        let cols = 3, gap: CGFloat = 8
        let tw = (w - gap * CGFloat(cols - 1)) / CGFloat(cols)
        for (i, t) in tools.enumerated() {
            let tile = Tile(title: t.1, symbol: t.2, on: t.3, danger: false) { [weak self] in self?.onAction(t.0) }
            add(tile, x: pad + CGFloat(i % cols) * (tw + gap), y: y + CGFloat(i / cols) * (64 + gap), w: tw, h: 64, id: t.0)
        }
        y += 2 * (64 + gap) + 6
        add(label("PEN COLOUR", Theme.mono(10), Theme.textMuted), x: pad, y: y + 6, w: 100, h: 14)
        for (i, c) in Tutorial.penColors.enumerated() {
            let sw = Swatch(color: c, on: state.pen && state.penColor == i) { [weak self] in self?.onAction("color:\(i)") }
            add(sw, x: pad + 110 + CGFloat(i) * 34, y: y, w: 26, h: 26, id: "color\(i)")
        }
        y += 40
        let keys = label("⌃⌥D pen   ⌃⌥C clear   Esc pen down   ⌃⌥R stop", Theme.mono(10), Theme.textMuted)
        add(keys, x: pad, y: y, w: w, h: 14)
        return y + 18
    }

    private func idle(y start: CGFloat, w: CGFloat) -> CGFloat {
        var y = start
        let rec = Tile(title: "●  Record a Tutorial", symbol: nil, on: false, danger: true,
                       detail: "Screen, voice, camera bubble, halo, pen") { [weak self] in self?.onAction("record") }
        add(rec, x: pad, y: y, w: w, h: 56, id: "record")
        y += 70
        if let sel = selected, FileManager.default.fileExists(atPath: sel.path) {
            let h = (w * 9 / 16).rounded()
            add(player, x: pad, y: y, w: w, h: h, id: "player")
            y += h + 6
            let finder = Link("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([sel]) }
            let qt = Link("Open in QuickTime") { NSWorkspace.shared.open(sel) }
            add(finder, x: pad, y: y, w: 110, h: 18)
            add(qt, x: pad + 120, y: y, w: 130, h: 18)
            y += 28
        }
        add(label("RECORDINGS", Theme.mono(10), Theme.gold), x: pad, y: y, w: w, h: 14)
        y += 20
        if files.isEmpty {
            add(label("None yet. Your videos land here.", Theme.sans(12), Theme.textMuted), x: pad, y: y, w: w, h: 18)
            return y + 22
        }
        for (i, url) in files.prefix(QuickToolsRules.listCap).enumerated() {
            let row = RecordingRow(url: url, selected: url == selected)
            row.thumb = Self.thumbs[url.path]
            row.duration = Self.durations[url.path]
            row.onClick = { [weak self] in self?.select(url, autoplay: true) }
            row.onDrag = { [weak self] on in self?.dragging = on }
            add(row, x: pad - 6, y: y, w: w + 12, h: 62, id: "row\(i)")
            if row.thumb == nil || row.duration == nil { load(url, into: row) }
            y += 64
        }
        if files.count > QuickToolsRules.listCap {
            let more = Link("+\(files.count - QuickToolsRules.listCap) more in Finder") { [folder] in NSWorkspace.shared.open(folder) }
            add(more, x: pad, y: y + 4, w: w, h: 18)
            y += 26
        }
        return y
    }

    /// Thumbnail and length, read once per file in the background.
    private func load(_ url: URL, into row: RecordingRow) {
        Task {
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 320, height: 180)
            let image = try? await gen.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
            let seconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds)
            await MainActor.run {
                if let image { Self.thumbs[url.path] = NSImage(cgImage: image, size: .zero); row.thumb = Self.thumbs[url.path] }
                if let seconds, seconds.isFinite { Self.durations[url.path] = seconds; row.duration = seconds }
            }
        }
    }

    private func label(_ s: String, _ font: NSFont, _ color: NSColor) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = font
        f.textColor = color
        return f
    }

    private func add(_ v: NSView, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, id: String? = nil) {
        v.frame = NSRect(x: x, y: y, width: w, height: h)
        addSubview(v)
        if let id { frames[id] = v.frame }
    }
}

/// A rounded tool button: gold edge and symbol when on, red face for Record and Stop.
private final class Tile: NSView {
    let title: String, symbol: String?, on: Bool, danger: Bool, detail: String?
    let action: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }

    init(title: String, symbol: String?, on: Bool, danger: Bool, detail: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.on = on; self.danger = danger; self.detail = detail; self.action = action
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { action() } }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        (danger ? Tutorial.pen.withAlphaComponent(hovering ? 1 : 0.88) : on ? Theme.goldSoft : hovering ? Theme.surface2 : Theme.surface).setFill()
        box.fill()
        (danger ? Tutorial.pen : on ? Theme.gold : Theme.border).setStroke()
        box.lineWidth = 1
        box.stroke()
        let ink = danger ? NSColor.white : on ? Theme.goldHi : Theme.textDim
        if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .medium)) {
            let tinted = NSImage(size: img.size, flipped: false) { r in
                img.draw(in: r); ink.set(); r.fill(using: .sourceAtop); return true
            }
            tinted.draw(in: NSRect(x: bounds.midX - img.size.width / 2, y: 12, width: img.size.width, height: img.size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            let f = Theme.sans(11, "Medium")
            let s = Theme.size(title, font: f)
            _ = Theme.draw(title, at: NSPoint(x: bounds.midX - s.width / 2, y: bounds.height - s.height - 9), font: f, color: ink)
        } else {
            let f = Theme.sans(15, "SemiBold")
            let s = Theme.size(title, font: f)
            let ty = detail == nil ? (bounds.height - s.height) / 2 : 9
            _ = Theme.draw(title, at: NSPoint(x: 16, y: ty), font: f, color: ink)
            if let detail { _ = Theme.draw(detail, at: NSPoint(x: 16, y: ty + s.height + 2), font: Theme.sans(11), color: ink.withAlphaComponent(0.85)) }
        }
    }
}

private final class Swatch: NSView {
    let color: NSColor, on: Bool, action: () -> Void
    init(color: NSColor, on: Bool, action: @escaping () -> Void) { self.color = color; self.on = on; self.action = action; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseUp(with event: NSEvent) { action() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 4, dy: 4)
        color.setFill(); NSBezierPath(ovalIn: r).fill()
        Theme.border.setStroke(); let edge = NSBezierPath(ovalIn: r); edge.lineWidth = 1; edge.stroke()
        if on { Theme.goldHi.setStroke(); let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)); ring.lineWidth = 2; ring.stroke() }
    }
}

private final class Link: NSView {
    let title: String, action: () -> Void
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func mouseUp(with event: NSEvent) { action() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) { _ = Theme.draw(title, at: NSPoint(x: 0, y: 1), font: Theme.sans(12, "Medium"), color: Theme.gold) }
}

/// One video: thumbnail, when, length and size. Click plays it in the panel, double-click opens it
/// in QuickTime, and dragging hands the file itself to Finder, Mail, Slack or a browser upload.
private final class RecordingRow: NSView, NSDraggingSource {
    let url: URL, isSelected: Bool
    var thumb: NSImage? { didSet { needsDisplay = true } }
    var duration: TimeInterval? { didSet { needsDisplay = true } }
    var onClick: () -> Void = {}
    var onDrag: (Bool) -> Void = { _ in }
    private var downAt: NSPoint?
    private var hovering = false { didSet { needsDisplay = true } }

    init(url: URL, selected: Bool) { self.url = url; isSelected = selected; super.init(frame: .zero); toolTip = "Click to watch, drag to share. \(url.lastPathComponent)" }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { downAt = event.locationInWindow }
    override func mouseDragged(with event: NSEvent) {
        guard let d = downAt, hypot(event.locationInWindow.x - d.x, event.locationInWindow.y - d.y) > 4 else { return }
        downAt = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let thumbRect = NSRect(x: 6, y: 4, width: 96, height: 54)
        item.setDraggingFrame(thumbRect, contents: thumb ?? NSWorkspace.shared.icon(forFile: url.path))
        onDrag(true)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    override func mouseUp(with event: NSEvent) {
        guard downAt != nil else { return }
        downAt = nil
        if event.clickCount >= 2 { NSWorkspace.shared.open(url) } else { onClick() }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { onDrag(false) }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected || hovering {
            (isSelected ? Theme.goldSoft : Theme.surface).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        let t = NSRect(x: 6, y: 4, width: 96, height: 54)
        let clip = NSBezierPath(roundedRect: t, xRadius: 6, yRadius: 6)
        Theme.surface2.setFill(); clip.fill()
        if let thumb {
            NSGraphicsContext.saveGraphicsState(); clip.addClip()
            thumb.draw(in: t, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let when = QuickToolsRules.label(for: attrs?.contentModificationDate ?? Date())
        _ = Theme.draw(when, at: NSPoint(x: 114, y: 10), font: Theme.sans(14, "Medium"), color: Theme.text)
        let size = QuickToolsRules.size(Int64(attrs?.fileSize ?? 0))
        let meta = [duration.map(Tutorial.clock), size].compactMap { $0 }.joined(separator: "  ·  ")
        _ = Theme.draw(meta, at: NSPoint(x: 114, y: 32), font: Theme.mono(11), color: Theme.textMuted)
    }
}

/// The panel never becomes key, so the player's controls must take the first click.
private final class FirstClickPlayerView: AVPlayerView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
