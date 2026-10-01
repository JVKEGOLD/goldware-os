import AppKit

/// What the card shows about the current state.
struct IndicatorInfo {
    var ready = false
    var status = "Starting"
    var dictationsToday = 0
    var capturesToday = 0
    var waiting = 0
    var lastCapture: String?
    var model = ""
}

/// The always-on indicator, in three sizes:
///   1. a tiny orb at the bottom of the screen,
///   2. hover it: a pill with the keys and today's count,
///   3. hover the orb inside that pill: the full card with keys, prompts, and snippets.
/// While you talk it becomes the status pill. It never takes focus from your app,
/// so clicking a prompt or snippet pastes into whatever you were typing in.
final class HUD {
    enum Tint { case plain, assistant }

    static let gold = Theme.goldHi

    var infoProvider: () -> IndicatorInfo = { IndicatorInfo() }
    var library: Library?
    var onOpenTasks: () -> Void = {}
    var onOpenHistory: () -> Void = {}
    var onEditSnippets: () -> Void = {}
    var onUse: (LibraryItem, _ copyOnly: Bool) -> Void = { _, _ in }
    var onUndo: () -> Void = {}
    /// Label for the card's undo link, when there is something to undo.
    var undoLabel: () -> String? = { nil }
    var agendaProvider: () async -> Agenda = { Agenda() }
    private var activeAction: (() -> Void)?
    /// Whether the indicator stays on screen when idle. Off: it only appears while working.
    var alwaysVisible = true { didSet { if isIdle { settleIdle() } } }

    private let pill: NSPanel
    private let pillView = PillView()
    private let card: NSPanel
    private let cardView = CardView()
    private var isIdle = true
    private var hideWork: DispatchWorkItem?
    private var cardCloseWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var pinned = false
    private var hoverPill = false
    private var hoverOrb = false
    private var hoverCard = false
    private var cardOpen = false
    /// Files parked on the pill. The resting indicator grows into a row of thumbnails while it holds any.
    let shelf = ShelfStore()

    init() {
        Theme.registerFonts()
        pill = Self.panel()
        card = Self.panel()
        pill.contentView = pillView
        card.contentView = cardView
        card.alphaValue = 0

        pillView.onHover = { [weak self] inside, orb in
            guard let self else { return }
            self.hoverPill = inside
            self.hoverOrb = orb
            self.update()
        }
        pillView.onClick = { [weak self] in
            guard let self else { return }
            if !self.isIdle {
                // The status pill's chip: Undo, Confirm, and so on.
                if let run = self.activeAction { self.activeAction = nil; run() }
                return
            }
            self.pinned.toggle()
            self.update()
        }
        pillView.onDragged = { [weak self] in self?.saveAnchor(); self?.positionCard() }
        pillView.shelf = shelf
        pillView.onDropHover = { [weak self] over in
            guard let self else { return }
            self.dropOver = over
            if self.isIdle { self.settleIdle() }
        }
        watchFileDrags()
        shelf.onChange = { [weak self] in
            guard let self else { return }
            self.pillView.needsDisplay = true
            if self.isIdle { self.settleIdle() }
        }
        cardView.onHover = { [weak self] inside in self?.hoverCard = inside; self?.update() }
        cardView.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .tasks: self.closeCard(); self.onOpenTasks()
            case .history: self.closeCard(); self.onOpenHistory()
            case .editSnippets: self.closeCard(); self.onEditSnippets()
            case .hide:
                self.closeCard()
                self.alwaysVisible = false
                UserDefaults.standard.set(false, forKey: "indicatorAlwaysVisible")
            case .use(let item, let copyOnly):
                self.closeCard()
                self.onUse(item, copyOnly)
            case .undo:
                self.closeCard()
                self.onUndo()
            }
        }
        alwaysVisible = UserDefaults.standard.object(forKey: "indicatorAlwaysVisible") as? Bool ?? true
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.layoutPill(animated: false)
        }
    }

    private static func panel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return p
    }

    // MARK: Public API used by the app

    func showIdle() {
        isIdle = true
        settleIdle()
    }

    /// `orb` picks the animation: listening while recording, composing or connecting
    /// while working, breathing when done. With `autoHide`, it settles back to idle.
    func show(_ text: String, orb state: OrbState = .breathing, tint: Tint = .plain, autoHide: TimeInterval? = nil,
              action: (label: String, run: () -> Void)? = nil) {
        hideWork?.cancel()
        activeAction = action?.run
        pillView.actionLabel = action?.label
        collapseWork?.cancel()
        isIdle = false
        pinned = false
        closeCard()
        pillView.mode = .active(text: text, assistant: tint == .assistant)
        pillView.orb.state = state
        pillView.orb.tint = tint == .assistant ? Theme.goldHi : .white
        if state != .listening { pillView.orb.level = 0 }
        // The mascot shows up in assistant mode: peeking while it listens, up while it thinks,
        // a hop when he is done.
        if tint == .assistant {
            switch state {
            case .listening: pillView.peek.pose = .peek
            case .breathing: pillView.peek.pose = .hop
            default: pillView.peek.pose = .up
            }
        } else {
            pillView.peek.pose = .hidden
        }
        layoutPill(animated: true)
        pill.orderFrontRegardless()
        pillView.orb.start()
        if let autoHide {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHide, execute: work)
        }
    }

    /// Live words while you talk: the tail of what Whisper has heard so far.
    func updateLive(_ text: String) {
        guard !isIdle, case .active(_, let assistant) = pillView.mode, !text.isEmpty else { return }
        let tail = text.count > 64 ? "…" + text.suffix(63) : text
        pillView.mode = .active(text: tail, assistant: assistant)
        layoutPill(animated: true)
    }

    /// Opens the card on a tab and keeps it open (for "GoldWare, what's on my plate?").
    func presentCard(tab: CardView.Tab) {
        cardView.tab = tab
        showIdle()
        pinned = true
        update()
        settleIdle()
    }

    func setLevel(_ level: Float) {
        pillView.orb.level = level
        pillView.peek.level = level
    }

    /// Back to the resting indicator (or hidden, if it only appears while working).
    func hide() {
        hideWork?.cancel()
        showIdle()
    }

    // MARK: Hover states

    private func settleIdle() {
        guard isIdle else { return }
        guard alwaysVisible || hoverPill || pinned || !shelf.items.isEmpty || fileDrag else {
            pill.orderOut(nil)
            pillView.orb.stop()
            return
        }
        let expanded = hoverPill || hoverCard || pinned || cardOpen
        let info = infoProvider()
        shelf.prune()   // a shelved file deleted or moved elsewhere drops off
        // While the shelf holds files the pill stays a row of thumbnails, so hovering never hides them;
        // its orb still opens the card.
        if fileDrag || !shelf.items.isEmpty {
            pillView.mode = .shelf(drop: dropOver ? .over : fileDrag ? .ready : .none)
        } else if expanded {
            pillView.mode = .expanded(today: info.dictationsToday + info.capturesToday, ready: info.ready)
        } else {
            pillView.mode = .mini
        }
        layoutPill(animated: true)
        pill.orderFrontRegardless()
        pillView.orb.start()
    }

    private func update() {
        guard isIdle else { return }
        collapseWork?.cancel()
        let wantsExpanded = hoverPill || hoverCard || pinned
        if wantsExpanded {
            if case .mini = pillView.mode { settleIdle() }
        } else {
            // Collapse after a beat, so a pointer passing by does not make it flicker.
            let work = DispatchWorkItem { [weak self] in
                guard let self, !(self.hoverPill || self.hoverCard || self.pinned || self.cardOpen) else { return }
                self.settleIdle()
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
        // The card opens from the orb, then stays while the pointer is on the card or the pill.
        let wantsCard = pinned || hoverOrb || hoverCard || (cardOpen && hoverPill)
        wantsCard ? openCard() : scheduleCardClose()
        pillView.pinned = pinned
    }

    private func openCard() {
        cardCloseWork?.cancel()
        if cardOpen { return }
        cardOpen = true
        library?.refresh()
        cardView.library = library
        cardView.info = infoProvider()
        cardView.undoLabel = undoLabel()
        let provider = agendaProvider
        Task { @MainActor in
            let agenda = await provider()
            self.cardView.agenda = agenda
        }
        positionCard()
        card.orderFrontRegardless()
        cardView.surf.start()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            card.animator().alphaValue = 1
        }
    }

    private func scheduleCardClose() {
        guard cardOpen else { return }
        cardCloseWork?.cancel()
        // A short grace period lets the pointer travel from the orb up into the card.
        let work = DispatchWorkItem { [weak self] in self?.closeCard() }
        cardCloseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func closeCard() {
        cardCloseWork?.cancel()
        guard cardOpen else { return }
        cardOpen = false
        pinned = false
        pillView.pinned = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            self.card.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.cardOpen else { return }
            self.card.orderOut(nil)
            self.cardView.surf.stop()
            self.update()
        })
    }

    // MARK: Layout

    /// The indicator is anchored by its bottom centre, which the user can drag.
    /// A file is being dragged somewhere on screen, and whether it is over the pill right now.
    private var fileDrag = false
    private var dropOver = false
    private var dragPasteboardCount = NSPasteboard(name: .drag).changeCount

    /// Grows the pill into a drop target the moment a file drag starts anywhere, so it is easy to hit.
    /// Mouse monitors need no permission; the drag pasteboard changes once per new drag.
    private func watchFileDrags() {
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] e in
            guard let self else { return }
            if e.type == .leftMouseUp { self.endFileDrag(); return }
            let pb = NSPasteboard(name: .drag)
            guard !self.fileDrag, pb.changeCount != self.dragPasteboardCount else { return }
            self.dragPasteboardCount = pb.changeCount
            guard ShelfStore.canAccept(pb), self.isIdle, !self.pillView.isDraggingOut else { return }
            self.fileDrag = true
            self.settleIdle()
            // Another app's drag can end without a mouse-up reaching us, so also watch the button itself.
            self.dragWatch?.invalidate()
            self.dragWatch = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                if NSEvent.pressedMouseButtons & 1 == 0 { self?.endFileDrag() }
            }
        }
    }

    private var dragWatch: Timer?

    private func endFileDrag() {
        dragWatch?.invalidate(); dragWatch = nil
        // Give a drop on the pill a moment to land before the target shrinks.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.fileDrag else { return }
            self.fileDrag = false
            self.dropOver = false
            if self.isIdle { self.settleIdle() }
        }
    }

    private var anchor: NSPoint {
        let d = UserDefaults.standard
        if d.object(forKey: "indicatorX") != nil {
            let p = NSPoint(x: d.double(forKey: "indicatorX"), y: d.double(forKey: "indicatorY"))
            if NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -4, dy: -4).contains(p) }) { return p }
        }
        let f = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: f.midX, y: f.minY + 12)
    }

    private func saveAnchor() {
        let f = pill.frame
        UserDefaults.standard.set(Double(f.midX), forKey: "indicatorX")
        UserDefaults.standard.set(Double(f.minY), forKey: "indicatorY")
    }

    private func layoutPill(animated: Bool) {
        let size = pillView.preferredSize
        let a = anchor
        let frame = NSRect(x: (a.x - size.width / 2).rounded(), y: a.y, width: size.width, height: size.height)
        if animated && pill.isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                pill.animator().setFrame(frame, display: true)
            }
        } else {
            pill.setFrame(frame, display: true)
        }
        pillView.needsDisplay = true
        if cardOpen { positionCard() }
    }

    private func positionCard() {
        let size = cardView.preferredSize
        let a = anchor
        var x = a.x - size.width / 2
        var y = a.y + 40 + 10
        if let screen = pill.screen ?? NSScreen.main {
            let v = screen.visibleFrame
            x = min(max(v.minX + 8, x), v.maxX - size.width - 8)
            if y + size.height > v.maxY { y = a.y - size.height - 10 }
        }
        card.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), display: true)
    }

    // MARK: Offscreen rendering for checks and screenshots

    static func renderSheet(to url: URL, info: IndicatorInfo, library: Library, agenda: Agenda? = nil) {
        Theme.registerFonts()
        var views: [(NSView, NSSize)] = []
        for tab in CardView.Tab.allCases {
            let c = CardView()
            c.library = library
            c.info = info
            c.agenda = agenda
            c.undoLabel = "Undo"
            c.tab = tab
            views.append((c, c.preferredSize))
        }
        let mini = PillView(), expanded = PillView(), active = PillView(), assistant = PillView()
        mini.mode = .mini
        expanded.mode = .expanded(today: info.dictationsToday + info.capturesToday, ready: true)
        expanded.hoveringOrb = true
        active.mode = .active(text: "Listening…", assistant: false)
        active.orb.state = .listening
        assistant.mode = .active(text: "Task added to your tasks: Renew the domain", assistant: true)
        assistant.actionLabel = "Undo"
        assistant.orb.tint = Theme.goldHi
        assistant.orb.state = .connecting
        assistant.layoutSubtreeIfNeeded()
        assistant.peek.settle(.up)
        // The shelf holding a few files from the repo, and the same pill while a file hovers over it.
        let shelf = ShelfStore(persists: false)
        let samples = ["app/Resources/goldware-logo.png", "app/README.md", "README.md"]
        if let root = VaultContext.resolveRoot() {
            for s in samples.reversed() { shelf.add(root.appendingPathComponent(s)) }
        }
        let shelved = PillView(), dropping = PillView()
        for (p, drop) in [(shelved, PillView.Drop.none), (dropping, .over)] { p.shelf = shelf; p.mode = .shelf(drop: drop) }
        for p in [mini, expanded, active, assistant, shelved, dropping] { views.append((p, p.preferredSize)) }

        let pad: CGFloat = 28
        let cards = views.prefix(CardView.Tab.allCases.count), pills = views.suffix(6)
        let width = cards.reduce(pad) { $0 + $1.1.width + pad }
        let height = pad + (cards.map(\.1.height).max() ?? 0) + pad + (pills.map(\.1.height).max() ?? 0) + pad
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(height * 2), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(srgbRed: 0.33, green: 0.36, blue: 0.42, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        func place(_ v: NSView, _ s: NSSize, at p: NSPoint) {
            v.frame = NSRect(origin: .zero, size: s)
            let image = NSImage(size: s)
            image.lockFocusFlipped(true)   // every view here draws top-down
            v.draw(v.bounds)
            for sub in v.subviews {
                NSGraphicsContext.current?.saveGraphicsState()
                let t = NSAffineTransform()
                t.translateX(by: sub.frame.minX, yBy: sub.frame.minY)
                t.concat()
                sub.draw(sub.bounds)
                NSGraphicsContext.current?.restoreGraphicsState()
            }
            image.unlockFocus()
            image.draw(in: NSRect(origin: p, size: s))
        }
        var x = pad
        for (v, s) in cards {
            place(v, s, at: NSPoint(x: x, y: height - pad - s.height))
            x += s.width + pad
        }
        x = pad
        for (v, s) in pills {
            place(v, s, at: NSPoint(x: x, y: pad))
            x += s.width + pad
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

// MARK: - Pill

final class PillView: NSView, NSDraggingSource {
    /// A file drag somewhere on screen (`ready`) grows the pill into a target; `over` when it is on the pill.
    enum Drop: Equatable { case none, ready, over }
    enum Mode: Equatable {
        case mini
        case expanded(today: Int, ready: Bool)
        case active(text: String, assistant: Bool)
        /// The resting pill holding shelved files, or offering to take the file being dragged.
        case shelf(drop: Drop)
    }

    var mode: Mode = .mini { didSet { relayout() } }
    var pinned = false { didSet { needsDisplay = true } }
    /// A small chip at the right of the status pill, like "Undo" or "Confirm". Click the pill to use it.
    var actionLabel: String? { didSet { needsDisplay = true } }
    private let chipFont = Theme.sans(11.5, "SemiBold")
    private var chipWidth: CGFloat { actionLabel.map { Theme.size($0, font: chipFont).width + 22 + 8 } ?? 0 }
    var hoveringOrb = false { didSet { if hoveringOrb != oldValue { needsDisplay = true } } }
    /// (pointer inside the pill, pointer over the orb)
    var onHover: (Bool, Bool) -> Void = { _, _ in }
    var onClick: () -> Void = {}
    var onDragged: () -> Void = {}
    /// A file drag entered (true) or left (false) the pill.
    var onDropHover: (Bool) -> Void = { _ in }
    weak var shelf: ShelfStore?
    let orb = OrbView()
    let peek = PeekView()

    /// Room above the pill for GoldWare to peek over it, in assistant mode.
    var headroom: CGFloat { if case .active(_, true) = mode { return 32 } else { return 0 } }
    private var pillRect: NSRect { NSRect(x: 0, y: headroom, width: bounds.width, height: bounds.height - headroom) }

    private var hovering = false
    private var dragStart: NSPoint?
    private var dragged = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(orb)
        addSubview(peek)
        registerForDraggedTypes(ShelfStore.dropTypes)
        relayout()
    }

    // MARK: Shelf geometry

    private static func dropLabel(_ drop: Drop) -> String? {
        switch drop {
        case .none: return nil
        case .ready: return "Drop here to shelve"
        case .over: return "Let go to shelve"
        }
    }
    private static let dropFont = Theme.sans(11.5, "Medium")
    private static let thumb: CGFloat = 26
    private static let thumbGap: CGFloat = 6
    private var shelfItems: [URL] { shelf?.items ?? [] }

    /// Where each shelved file is drawn, left to right after the orb.
    private func thumbRects() -> [(URL, NSRect)] {
        shelfItems.enumerated().map { i, url in
            (url, NSRect(x: 32 + CGFloat(i) * (Self.thumb + Self.thumbGap), y: (bounds.height - Self.thumb) / 2,
                         width: Self.thumb, height: Self.thumb))
        }
    }

    private func shelfWidth(_ drop: Drop) -> CGFloat {
        let n = CGFloat(shelfItems.count)
        let thumbs = n == 0 ? 0 : n * Self.thumb + (n - 1) * Self.thumbGap + 10
        let label = Self.dropLabel(drop).map { Theme.size($0, font: Self.dropFont).width + 14 } ?? 0
        return 32 + thumbs + label
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private let hintFont = Theme.sans(12, "Medium")

    var preferredSize: NSSize {
        switch mode {
        case .mini:
            return NSSize(width: 26, height: 26)
        case .expanded(let today, _):
            return NSSize(width: 40 + expandedContentWidth(today) + 16, height: 40)
        case .active(let text, _):
            let w = Theme.size(text, font: Theme.sans(13.5, "Medium")).width
            return NSSize(width: min(680, max(170, 8 + 40 + 10 + ceil(w) + 22 + chipWidth)), height: 52 + headroom)
        case .shelf(let drop):
            return NSSize(width: shelfWidth(drop), height: 36)
        }
    }

    private func todayLabel(_ n: Int) -> String { "\(n) today" }

    private func expandedContentWidth(_ today: Int) -> CGFloat {
        22 + 6 + Theme.size("Dictate", font: hintFont).width + 14 + 22 + 6 + 16 + 5 + Theme.size(GWConfig.name, font: hintFont).width
            + 14 + 1 + 12 + 10 + Theme.size(todayLabel(today), font: Theme.sans(11.5)).width
    }

    /// The part of the pill that opens the full card.
    var orbZone: NSRect {
        switch mode {
        case .expanded: return NSRect(x: 0, y: 0, width: 42, height: bounds.height)
        case .shelf(.none): return NSRect(x: 0, y: 0, width: 30, height: bounds.height)
        default: return .zero
        }
    }

    private func relayout() {
        switch mode {
        case .mini:
            orb.frame = NSRect(x: 3, y: 3, width: 20, height: 20)
            orb.speedMul = 0.4
            orb.idle = true
            orb.state = .breathing
            orb.tint = Theme.textDim
        case .expanded:
            orb.frame = NSRect(x: 6, y: 5, width: 30, height: 30)
            orb.speedMul = 0.6
            orb.idle = true
            orb.state = .breathing
            orb.tint = hoveringOrb ? Theme.goldHi : Theme.text
        case .active:
            orb.frame = NSRect(x: 7, y: 6 + headroom, width: 40, height: 40)
            orb.speedMul = 1
            orb.idle = false
        case .shelf(let drop):
            orb.frame = NSRect(x: 5, y: 7, width: 22, height: 22)
            orb.speedMul = drop == .over ? 1 : drop == .ready ? 0.7 : 0.4
            orb.idle = drop != .over
            orb.state = drop == .over ? .connecting : .breathing
            orb.tint = drop == .none ? Theme.textDim : Theme.goldHi
        }
        peek.frame = NSRect(x: 3, y: 0, width: 50, height: headroom + 2)
        peek.horizon = headroom + 0.5
        if headroom == 0 { peek.settle(.hidden) }
        orb.needsDisplay = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = pillRect.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        var assistant = false
        if case .active(_, let a) = mode { assistant = a }
        Theme.surface.withAlphaComponent(mode == .mini && !hovering ? 0.82 : 0.95).setFill()
        shape.fill()
        if assistant {
            Theme.goldSoft.setFill()
            shape.fill()
        }
        var drop = Drop.none
        if case .shelf(let d) = mode { drop = d }
        if drop == .over {
            Theme.goldSoft.setFill()
            shape.fill()
        }
        if drop == .ready {
            // A dashed gold rim: "you can drop here".
            Theme.goldLine.setStroke()
            shape.setLineDash([5, 4], count: 2, phase: 0)
            shape.lineWidth = 1.2
            shape.stroke()
            shape.setLineDash(nil, count: 0, phase: 0)
        } else {
            (assistant || pinned || drop == .over ? Theme.goldLine : (hovering ? Theme.borderLight : Theme.border)).setStroke()
            shape.lineWidth = drop == .over ? 1.5 : 1
            shape.stroke()
        }

        switch mode {
        case .mini:
            break
        case .shelf(let drop):
            for (url, r) in thumbRects() {
                let clip = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
                NSGraphicsContext.saveGraphicsState()
                clip.addClip()
                Theme.surface2.setFill(); r.fill()
                shelf?.thumbnail(for: url).draw(in: r.insetBy(dx: 1, dy: 1), from: .zero, operation: .sourceOver,
                                                  fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
                NSGraphicsContext.restoreGraphicsState()
                (hoveredThumb == url ? Theme.goldHi : Theme.border).setStroke()
                clip.lineWidth = 1; clip.stroke()
            }
            if let label = Self.dropLabel(drop) {
                let s = Theme.size(label, font: Self.dropFont)
                let x = (thumbRects().last?.1.maxX ?? 22) + 10
                Theme.draw(label, at: NSPoint(x: x, y: bounds.midY - s.height / 2), font: Self.dropFont,
                           color: drop == .over ? Theme.goldHi : Theme.textDim)
            }
        case .expanded(let today, let ready):
            // The orb zone gets a faint gold halo: hover here for the full card.
            if hoveringOrb || pinned {
                let halo = NSBezierPath(ovalIn: NSRect(x: 4, y: 3, width: 34, height: 34))
                Theme.goldSoft.setFill()
                halo.fill()
                Theme.goldLine.setStroke()
                halo.lineWidth = 1
                halo.stroke()
            }
            var x: CGFloat = 44
            let mid = bounds.midY
            x += Theme.drawKey("⌥", at: NSPoint(x: x, y: mid - 11)) + 6
            let s1 = Theme.size("Dictate", font: hintFont)
            Theme.draw("Dictate", at: NSPoint(x: x, y: mid - s1.height / 2), font: hintFont, color: Theme.text)
            x += s1.width + 14
            x += Theme.drawKey("⌘", at: NSPoint(x: x, y: mid - 11), gold: true) + 6
            Mascot.draw(in: Mascot.rect(height: 15, at: NSPoint(x: x, y: mid - 8)))
            x += 16 + 5
            let s2 = Theme.size(GWConfig.name, font: hintFont)
            Theme.draw(GWConfig.name, at: NSPoint(x: x, y: mid - s2.height / 2), font: hintFont, color: Theme.goldHi)
            x += s2.width + 14
            Theme.border.setFill()
            NSRect(x: x, y: mid - 9, width: 1, height: 18).fill()
            x += 12
            let dot = NSBezierPath(ovalIn: NSRect(x: x - 1, y: mid - 3, width: 6, height: 6))
            (ready ? Theme.green : Theme.gold).setFill()
            dot.fill()
            let tf = Theme.sans(11.5)
            let label = todayLabel(today)
            let s3 = Theme.size(label, font: tf)
            Theme.draw(label, at: NSPoint(x: x + 10, y: mid - s3.height / 2), font: tf, color: Theme.textDim)
        case .active(let text, let assistant):
            let f = Theme.sans(13.5, "Medium")
            let s = Theme.size(text, font: f)
            let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: assistant ? Theme.goldHi : Theme.text]
            (text as NSString).draw(with: NSRect(x: 57, y: pillRect.midY - s.height / 2, width: bounds.width - 77 - chipWidth, height: s.height),
                                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
            if let label = actionLabel {
                let ls = Theme.size(label, font: chipFont)
                let chip = NSRect(x: bounds.width - 14 - ls.width - 22, y: pillRect.midY - 13, width: ls.width + 22, height: 26)
                let path = NSBezierPath(roundedRect: chip, xRadius: 13, yRadius: 13)
                (hovering ? Theme.goldLine : Theme.goldSoft).setFill()
                path.fill()
                Theme.goldLine.setStroke()
                path.lineWidth = 1
                path.stroke()
                Theme.draw(label, at: NSPoint(x: chip.midX - ls.width / 2, y: chip.midY - ls.height / 2), font: chipFont, color: Theme.goldHi)
            }
        }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    private func report(_ event: NSEvent?) {
        let p = event.map { convert($0.locationInWindow, from: nil) } ?? .zero
        let overOrb = hovering && orbZone.contains(p)
        if overOrb != hoveringOrb {
            hoveringOrb = overOrb
            if case .expanded = mode { orb.tint = overOrb ? Theme.goldHi : Theme.text }
            if case .shelf(.none) = mode { orb.tint = overOrb ? Theme.goldHi : Theme.textDim }
        }
        onHover(hovering, hoveringOrb)
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true; report(event) }
    override func mouseMoved(with event: NSEvent) { report(event); updateThumbHover(event) }
    override func mouseExited(with event: NSEvent) { hovering = false; hoveredThumb = nil; needsDisplay = true; report(nil) }

    private var hoveredThumb: URL?
    private var pressedThumb: URL?
    /// A thumbnail is on its way out; the pill must not turn into a drop target for its own file.
    private(set) var isDraggingOut = false

    private func thumb(at event: NSEvent) -> URL? {
        guard case .shelf = mode else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        return thumbRects().first { $0.1.insetBy(dx: -2, dy: -4).contains(p) }?.0
    }

    private func updateThumbHover(_ event: NSEvent) {
        let t = thumb(at: event)
        if t != hoveredThumb {
            hoveredThumb = t
            toolTip = t?.lastPathComponent
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        pressedThumb = thumb(at: event)
        dragStart = NSEvent.mouseLocation
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        // Dragging a thumbnail hands the file to wherever it is dropped.
        if let url = pressedThumb {
            pressedThumb = nil
            dragStart = nil
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let r = thumbRects().first { $0.0 == url }?.1 ?? NSRect(x: 0, y: 0, width: Self.thumb, height: Self.thumb)
            item.setDraggingFrame(r, contents: shelf?.thumbnail(for: url))
            isDraggingOut = true
            beginDraggingSession(with: [item], event: event, source: self)
            return
        }
        guard let start = dragStart, let window else { return }
        let now = NSEvent.mouseLocation
        if !dragged && hypot(now.x - start.x, now.y - start.y) < 3 { return }
        dragged = true
        var o = window.frame.origin
        o.x += now.x - start.x
        o.y += now.y - start.y
        window.setFrameOrigin(o)
        dragStart = now
        onDragged()
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; pressedThumb = nil }
        if let url = pressedThumb, thumb(at: event) == url {
            NSWorkspace.shared.open(url)
            return
        }
        if !dragged { onClick() } else { onDragged() }
    }

    // MARK: Drag out

    /// Copy only: dropping into a Finder folder must never move the original file away.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    /// Pulling a file out takes it off the shelf. Hold Option while dropping to keep it there as well.
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDraggingOut = false
        guard operation != [], !NSEvent.modifierFlags.contains(.option),
              let url = (session.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first else { return }
        shelf?.remove(url)
    }

    // MARK: Drop in

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Our own thumbnails dragged back over the pill are not a new drop.
        guard sender.draggingSource as? PillView !== self, ShelfStore.canAccept(sender.draggingPasteboard) else { return [] }
        onDropHover(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingSource as? PillView === self ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onDropHover(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { onDropHover(false) }
        guard shelf?.accept(sender.draggingPasteboard) == true else { return false }
        Sounds.play(.done)
        return true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// MARK: - Card

final class CardView: NSView {
    enum Tab: String, CaseIterable { case today = "Today", keys = "Keys", prompts = "Prompts", snippets = "Snippets" }
    enum Action { case tasks, history, hide, editSnippets, undo, use(LibraryItem, copyOnly: Bool) }

    var info = IndicatorInfo() { didSet { needsDisplay = true } }
    var library: Library? { didSet { needsDisplay = true } }
    var agenda: Agenda? { didSet { needsDisplay = true } }
    var undoLabel: String? { didSet { needsDisplay = true } }
    var tab: Tab = Tab(rawValue: UserDefaults.standard.string(forKey: "indicatorTab") ?? "") ?? .keys {
        didSet { scroll = 0; UserDefaults.standard.set(tab.rawValue, forKey: "indicatorTab"); needsDisplay = true }
    }
    var onHover: (Bool) -> Void = { _ in }
    var onAction: (Action) -> Void = { _ in }

    private enum Hit: Equatable { case tab(Tab), tasks, history, hide, editSnippets, undo, item(Int), task }
    private var hits: [(NSRect, Hit)] = []
    private var hot: Hit?
    private var scroll: CGFloat = 0
    private var contentHeight: CGFloat = 0
    private var rowItems: [LibraryItem] = []
    let surf = SurfView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        surf.frame = NSRect(x: 8, y: 6, width: 124, height: 60)
        addSubview(surf)
    }
    required init?(coder: NSCoder) { fatalError() }

    private let width: CGFloat = 392
    private let pad: CGFloat = 24
    private let contentTop: CGFloat = 168
    private let footerHeight: CGFloat = 108

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var preferredSize: NSSize { NSSize(width: width, height: 596) }
    private var contentRect: NSRect { NSRect(x: 0, y: contentTop, width: width, height: bounds.height - contentTop - footerHeight) }

    private let shortcuts: [(keys: [String], gold: Bool, what: String, how: String)] = [
        (["⌥"], false, "Dictate", "Hold right Option, talk, let go"),
        (["⌘"], true, "Tell \(GWConfig.name)", "Hold right Command: task, note, draft, or paste"),
        (["⌥", "⌥"], false, "Hands-free", "Double-tap either key, tap again to finish"),
        (["esc"], false, "Cancel", "Drop the recording, nothing is kept"),
    ]
    private let examples = ["Remind me Friday to renew the domain", "Draft a text to Sam saying I'm running late",
                            "Paste my email", "Summarize this"]

    override func draw(_ dirtyRect: NSRect) {
        hits.removeAll()
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: r, xRadius: 18, yRadius: 18)
        Theme.surface.withAlphaComponent(0.97).setFill()
        shape.fill()
        Theme.border.setStroke()
        shape.lineWidth = 1
        shape.stroke()

        drawMasthead()
        drawTabs()

        // Scrollable content
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: contentRect).addClip()
        let top = contentTop - scroll
        switch tab {
        case .today: contentHeight = drawToday(from: top)
        case .keys: contentHeight = drawKeys(from: top)
        case .prompts: contentHeight = drawItems(promptItems, from: top, hint: "Click pastes into the app you are in. ⌥-click copies.")
        case .snippets: contentHeight = drawItems(library?.snippets ?? [], from: top, hint: "Click pastes. ⌥-click copies. Private values stay masked.", editLink: true)
        }
        NSGraphicsContext.current?.restoreGraphicsState()
        // Fade content under the footer and tabs so scrolling reads as scrolling.
        if contentHeight > contentRect.height {
            let fade = NSGradient(starting: Theme.surface.withAlphaComponent(0), ending: Theme.surface)!
            fade.draw(in: NSRect(x: 1, y: contentRect.maxY - 22, width: width - 2, height: 22), angle: 90)
            if scroll > 0 { fade.draw(in: NSRect(x: 1, y: contentRect.minY, width: width - 2, height: 16), angle: -90) }
        }

        drawFooter()
        window?.invalidateCursorRects(for: self)
    }

    private var promptItems: [LibraryItem] { (library?.prompts ?? []) + Library.commands }

    private func drawMasthead() {
        // GoldWare surfs his binary wave in the corner, as in the dashboard's top bar.
        var y: CGFloat = 26
        Theme.gold.setFill()
        NSRect(x: 142, y: y + 6, width: 18, height: 1).fill()
        Theme.draw("\(GWConfig.upperName) VOICE", at: NSPoint(x: 168, y: y), font: Theme.sans(10, "Medium"), color: Theme.gold, kern: 2.4)
        let status = info.ready ? "Ready" : info.status
        let sf = Theme.sans(11.5, "Medium")
        let sw = Theme.size(status, font: sf).width
        Theme.draw(status, at: NSPoint(x: width - pad - sw, y: y - 1), font: sf, color: Theme.textDim)
        (info.ready ? Theme.green : Theme.gold).setFill()
        NSBezierPath(ovalIn: NSRect(x: width - pad - sw - 12, y: y + 3.5, width: 6, height: 6)).fill()
        y += 44
        let tf = Theme.display(32)
        let lead = Theme.draw("Talk, don't ", at: NSPoint(x: pad - 1, y: y), font: tf, color: Theme.text, kern: -0.5)
        Theme.draw("type.", at: NSPoint(x: pad - 1 + lead.width, y: y), font: Theme.display(32, italic: true), color: Theme.goldHi, kern: -0.3)
    }

    /// Segmented tabs like the dashboard's Reference modes.
    private func drawTabs() {
        let y: CGFloat = 122
        var x = pad
        let f = Theme.sans(12, "SemiBold")
        for t in Tab.allCases {
            var label = t.rawValue
            if t == .prompts { label += "  \(promptItems.count)" }
            if t == .today, let a = agenda, a.error == nil { label += "  \(a.focus.count + a.due.count + a.approvals.count)" }
            if t == .snippets { label += "  \((library?.snippets ?? []).filter { !$0.value.isEmpty }.count)" }
            let s = Theme.size(label, font: f)
            let rect = NSRect(x: x, y: y, width: s.width + 26, height: 28)
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
            let active = t == tab, isHot = hot == .tab(t)
            (active ? Theme.goldSoft : (isHot ? Theme.surface2 : Theme.surface)).setFill()
            path.fill()
            (active ? Theme.goldLine : Theme.border).setStroke()
            path.lineWidth = 1
            path.stroke()
            Theme.draw(label, at: NSPoint(x: rect.minX + 13, y: rect.midY - s.height / 2), font: f,
                       color: active ? Theme.goldHi : (isHot ? Theme.text : Theme.textDim))
            hits.append((rect, .tab(t)))
            x += rect.width + 8
        }
        Theme.border.setFill()
        NSRect(x: pad, y: contentTop - 10, width: width - pad * 2, height: 1).fill()
        Theme.goldGradient.draw(in: NSRect(x: pad, y: contentTop - 10, width: 110, height: 1), angle: 0)
    }

    /// Today: focus, due or overdue, and approvals from your tasks.
    private func drawToday(from top: CGFloat) -> CGFloat {
        var y = top + 2
        guard let a = agenda else {
            Theme.draw("Reading your tasks…", at: NSPoint(x: pad, y: y + 4), font: Theme.sans(12.5), color: Theme.textMuted)
            return 40
        }
        if let error = a.error {
            Theme.draw(error, at: NSPoint(x: pad, y: y + 4), font: Theme.sans(12.5), color: Theme.textMuted)
            return 40
        }
        Theme.draw("Say “\(GWConfig.name), done with …” to close one. Click a task to open your tasks.", at: NSPoint(x: pad, y: y),
                   font: Theme.sans(11), color: Theme.textMuted)
        y += 22
        let sections: [(String, [BoardTask])] = [("Focus today", a.focus), ("Due or overdue", a.due), ("Waiting on your approval", a.approvals)]
        for (title, tasks) in sections where !tasks.isEmpty {
            y += 4
            Theme.drawSectionTitle(title, at: NSPoint(x: pad, y: y))
            y += 22
            for t in tasks.prefix(6) {
                let row = NSRect(x: pad - 10, y: y, width: width - (pad - 10) * 2, height: 40)
                if row.intersects(contentRect) && hot == .task {
                    // Rows share one hit so hover reads as "these open your tasks".
                }
                (t.title as NSString).draw(with: NSRect(x: row.minX + 10, y: y + 3, width: row.width - 20, height: 18),
                                           options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                           attributes: [.font: Theme.sans(13, "SemiBold"), .foregroundColor: Theme.text])
                var meta: [String] = []
                if let due = t.dueOn { meta.append(due < a.today ? "overdue since \(due)" : "due \(due)") }
                if t.priority == "high" { meta.append("high priority") }
                Theme.draw(meta.joined(separator: " · "), at: NSPoint(x: row.minX + 10, y: y + 21), font: Theme.sans(11.5),
                           color: t.dueOn.map { $0 < a.today } == true ? Theme.red : Theme.textMuted)
                if row.intersects(contentRect) { hits.append((row.intersection(contentRect), .task)) }
                y += 42
            }
            if tasks.count > 6 {
                Theme.draw("and \(tasks.count - 6) more in your tasks", at: NSPoint(x: pad, y: y), font: Theme.sans(11.5), color: Theme.textMuted)
                y += 20
            }
        }
        if a.focus.isEmpty && a.due.isEmpty && a.approvals.isEmpty {
            Theme.draw("Nothing in focus, due, or waiting on you.", at: NSPoint(x: pad, y: y + 4), font: Theme.display(17, italic: true), color: Theme.textDim)
            y += 32
        }
        if a.inbox > 0 {
            y += 6
            Theme.draw("\(a.inbox) item\(a.inbox == 1 ? "" : "s") in the inbox", at: NSPoint(x: pad, y: y),
                       font: Theme.sans(12, "Medium"), color: Theme.gold)
            y += 22
        }
        return y + 6 - top
    }

    private func drawKeys(from top: CGFloat) -> CGFloat {
        var y = top + 6
        for s in shortcuts {
            var x = pad
            for (i, k) in s.keys.enumerated() {
                x += Theme.drawKey(k, at: NSPoint(x: x, y: y), gold: s.gold) + (i < s.keys.count - 1 ? 3 : 0)
            }
            let col: CGFloat = pad + 62
            Theme.draw(s.what, at: NSPoint(x: col, y: y - 1), font: Theme.sans(13, "SemiBold"), color: s.gold ? Theme.goldHi : Theme.text)
            Theme.draw(s.how, at: NSPoint(x: col, y: y + 15), font: Theme.sans(11.5), color: Theme.textMuted)
            y += 40
        }
        y += 4
        Mascot.draw(in: Mascot.rect(height: 17, at: NSPoint(x: pad - 3, y: y - 3)))
        Theme.draw("SAY TO \(GWConfig.upperName)", at: NSPoint(x: pad + 20, y: y), font: Theme.sans(10, "Medium"), color: Theme.textDim, kern: 2)
        y += 22
        for e in examples {
            Theme.draw("“\(e)”", at: NSPoint(x: pad, y: y), font: Theme.display(15.5, italic: true), color: Theme.textDim)
            y += 21
        }
        return y + 8 - top
    }

    private func drawItems(_ items: [LibraryItem], from top: CGFloat, hint: String, editLink: Bool = false) -> CGFloat {
        rowItems = items
        var y = top + 2
        Theme.draw(hint, at: NSPoint(x: pad, y: y), font: Theme.sans(11), color: Theme.textMuted)
        y += 22
        var group = ""
        for (i, item) in items.enumerated() {
            if item.group != group {
                group = item.group
                y += 4
                Theme.drawSectionTitle(group, at: NSPoint(x: pad, y: y))
                y += 22
            }
            let row = NSRect(x: pad - 10, y: y, width: width - (pad - 10) * 2, height: 42)
            let empty = item.value.isEmpty
            let visible = row.intersects(contentRect)
            if visible && hot == .item(i) && !empty {
                let bg = NSBezierPath(roundedRect: row, xRadius: 10, yRadius: 10)
                Theme.surface2.setFill()
                bg.fill()
                Theme.goldLine.setStroke()
                bg.lineWidth = 1
                bg.stroke()
                let use = "Paste"
                let uf = Theme.sans(11, "SemiBold")
                let us = Theme.size(use, font: uf)
                Theme.draw(use, at: NSPoint(x: row.maxX - 12 - us.width, y: row.midY - us.height / 2), font: uf, color: Theme.goldHi)
            }
            let textWidth = row.width - 20 - (hot == .item(i) ? 44 : 0)
            let titleColor = item.kind == .command ? Theme.goldHi : Theme.text
            let titleFont = item.kind == .command ? Theme.mono(12, "Medium") : Theme.sans(13, "SemiBold")
            (item.title as NSString).draw(with: NSRect(x: row.minX + 10, y: y + 4, width: textWidth, height: 18),
                                          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                          attributes: [.font: titleFont, .foregroundColor: titleColor])
            let second: String
            let secondFont: NSFont
            if item.kind == .snippet {
                second = empty ? "Empty. Add it with Edit snippets." : (item.isPrivate ? String(repeating: "•", count: min(18, max(8, item.value.count))) : item.value)
                secondFont = empty ? Theme.sans(11.5) : Theme.mono(11, "Regular")
            } else {
                second = item.detail
                secondFont = Theme.sans(11.5)
            }
            (second as NSString).draw(with: NSRect(x: row.minX + 10, y: y + 22, width: textWidth, height: 16),
                                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                      attributes: [.font: secondFont, .foregroundColor: empty ? Theme.textMuted.withAlphaComponent(0.7) : Theme.textMuted])
            if visible && !empty { hits.append((row.intersection(contentRect), .item(i))) }
            y += 44
        }
        if editLink {
            y += 8
            let label = "Edit snippets…"
            let f = Theme.sans(12, "SemiBold")
            let s = Theme.size(label, font: f)
            let rect = NSRect(x: pad, y: y, width: s.width, height: s.height)
            Theme.draw(label, at: rect.origin, font: f, color: hot == .editSnippets ? Theme.goldHi : Theme.gold)
            if rect.intersects(contentRect) { hits.append((rect.insetBy(dx: -6, dy: -4).intersection(contentRect), .editSnippets)) }
            y += s.height + 8
        }
        return y + 6 - top
    }

    private func drawFooter() {
        var y = bounds.height - footerHeight + 8
        Theme.border.setFill()
        NSRect(x: pad, y: y, width: width - pad * 2, height: 1).fill()
        y += 12
        var today = "\(info.dictationsToday) dictation\(info.dictationsToday == 1 ? "" : "s") · \(info.capturesToday) for \(GWConfig.name) today"
        if info.waiting > 0 { today += " · \(info.waiting) waiting" }
        Theme.draw(today, at: NSPoint(x: pad, y: y), font: Theme.sans(12, "Medium"), color: Theme.text)
        let mf = Theme.mono(10, "Regular")
        let mw = Theme.size(info.model, font: mf).width
        Theme.draw(info.model, at: NSPoint(x: width - pad - mw, y: y + 1), font: mf, color: Theme.textMuted)
        y += 18
        let last = info.lastCapture.map { "Last: \($0)" } ?? "Nothing sent to \(GWConfig.name) yet today"
        Mascot.draw(in: Mascot.rect(height: 14, at: NSPoint(x: pad, y: y + 1)))
        var lastWidth = width - pad * 2 - 20
        if let undo = undoLabel {
            let uf = Theme.sans(11.5, "SemiBold")
            let us = Theme.size(undo, font: uf)
            let rect = NSRect(x: width - pad - us.width, y: y, width: us.width, height: us.height)
            Theme.draw(undo, at: rect.origin, font: uf, color: hot == .undo ? Theme.goldHi : Theme.gold)
            hits.append((rect.insetBy(dx: -6, dy: -4), .undo))
            lastWidth -= us.width + 12
        }
        (last as NSString).draw(with: NSRect(x: pad + 20, y: y, width: lastWidth, height: 16),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: [.font: Theme.sans(11.5), .foregroundColor: Theme.textMuted])
        y += 26
        var x = pad
        x += button("Open Tasks", .tasks, at: NSPoint(x: x, y: y), primary: true) + 8
        _ = button("History", .history, at: NSPoint(x: x, y: y), primary: false)
        let hideLabel = "Hide"
        let hf = Theme.sans(11.5, "Medium")
        let hw = Theme.size(hideLabel, font: hf).width
        let hideRect = NSRect(x: width - pad - hw, y: y + 7, width: hw, height: 16)
        Theme.draw(hideLabel, at: hideRect.origin, font: hf, color: hot == .hide ? Theme.textDim : Theme.textMuted)
        hits.append((hideRect.insetBy(dx: -6, dy: -6), .hide))
    }

    private func button(_ title: String, _ hit: Hit, at p: NSPoint, primary: Bool) -> CGFloat {
        let f = Theme.sans(12, "SemiBold")
        let ts = Theme.size(title, font: f)
        let rect = NSRect(x: p.x, y: p.y, width: ts.width + 28, height: 30)
        let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 15, yRadius: 15)
        let isHot = hot == hit
        if primary {
            NSGraphicsContext.current?.saveGraphicsState()
            shape.addClip()
            Theme.goldGradient.draw(in: rect, angle: isHot ? 180 : 0)
            NSGraphicsContext.current?.restoreGraphicsState()
        } else {
            (isHot ? Theme.surface2 : Theme.surface).setFill()
            shape.fill()
            (isHot ? Theme.goldLine : Theme.borderLight).setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
        Theme.draw(title, at: NSPoint(x: rect.midX - ts.width / 2, y: rect.midY - ts.height / 2),
                   font: f, color: primary ? Theme.bg : Theme.text)
        hits.append((rect, hit))
        return rect.width
    }

    // MARK: Events

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { hot = nil; needsDisplay = true; onHover(false) }
    override func mouseMoved(with event: NSEvent) { updateHot(event) }

    private func updateHot(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let now = hits.first { $0.0.contains(p) }?.1
        if now != hot { hot = now; needsDisplay = true }
    }

    override func scrollWheel(with event: NSEvent) {
        let maxScroll = max(0, contentHeight - contentRect.height)
        scroll = min(maxScroll, max(0, scroll - event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 10)))
        needsDisplay = true
        displayIfNeeded()
        updateHot(event)
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let hit = hits.first(where: { $0.0.contains(p) })?.1 else { return }
        switch hit {
        case .tab(let t): tab = t
        case .tasks: onAction(.tasks)
        case .history: onAction(.history)
        case .hide: onAction(.hide)
        case .editSnippets: onAction(.editSnippets)
        case .undo: onAction(.undo)
        case .task: onAction(.tasks)
        case .item(let i):
            guard rowItems.indices.contains(i) else { return }
            onAction(.use(rowItems[i], copyOnly: event.modifierFlags.contains(.option)))
        }
    }

    override func resetCursorRects() {
        for (rect, _) in hits { addCursorRect(rect, cursor: .pointingHand) }
    }
}
