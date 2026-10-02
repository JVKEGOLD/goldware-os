import AppKit

/// The always-on indicator at the bottom of the screen:
///   1. a tiny orb while idle, with the Office's agents beside it,
///   2. hover the orb: your recent dictations; click one to copy it (for anything a paste missed).
/// While you talk it becomes the status pill. It never takes focus from your app.
final class HUD {
    enum Tint { case plain, assistant }

    static let gold = Theme.goldHi

    /// The newest dictations, newest first.
    var historyProvider: () -> [Dictation] = { [] }
    var onCopy: (Dictation) -> Void = { _ in }
    var onOpenHistory: () -> Void = {}
    private var activeAction: (() -> Void)?
    /// Whether the indicator stays on screen when idle. Off: it only appears while working.
    var alwaysVisible = true { didSet { if isIdle { settleIdle() } } }

    private let pill: NSPanel
    private let pillView = PillView()
    private let card: NSPanel
    private let cardView = HistoryView()
    private var isIdle = true
    private var hideWork: DispatchWorkItem?
    private var cardCloseWork: DispatchWorkItem?
    private var pinned = false
    private var hoverPill = false
    private var hoverOrb = false
    private var hoverCard = false
    private var cardOpen = false
    /// Files parked on the pill. The resting indicator grows into a row of thumbnails while it holds any.
    let shelf = ShelfStore()
    /// The Office's agents, shown on the resting indicator with a working / ready / question mark.
    private let agentFeed = AgentPeekFeed()

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
        pillView.onAgentClick = { agent in
            guard !agent.tty.isEmpty else { return }
            WorkData.focus(tty: "/dev/" + agent.tty)
        }
        agentFeed.onChange = { [weak self] agents in
            guard let self, agents != self.pillView.agents else { return }
            self.pillView.agents = agents
            if self.isIdle { self.settleIdle() }
        }
        agentFeed.start()
        shelf.onChange = { [weak self] in
            guard let self else { return }
            self.pillView.needsDisplay = true
            if self.isIdle { self.settleIdle() }
        }
        cardView.onHover = { [weak self] inside in self?.hoverCard = inside; self?.update() }
        cardView.onCopy = { [weak self] d in
            guard let self else { return }
            self.closeCard()
            self.onCopy(d)
        }
        cardView.onOpenAll = { [weak self] in self?.closeCard(); self?.onOpenHistory() }
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
        shelf.prune()   // a shelved file deleted or moved elsewhere drops off
        // While the shelf holds files the pill stays a row of thumbnails, so hovering never hides them;
        // its orb still opens the history.
        if fileDrag || !shelf.items.isEmpty {
            pillView.mode = .shelf(drop: dropOver ? .over : fileDrag ? .ready : .none)
        } else {
            pillView.mode = .mini
        }
        layoutPill(animated: true)
        pill.orderFrontRegardless()
        pillView.orb.start()
    }

    private func update() {
        guard isIdle else { return }
        // The history opens from the orb, then stays while the pointer is on it or the pill.
        let wantsCard = pinned || hoverOrb || hoverCard || (cardOpen && hoverPill)
        wantsCard ? openCard() : scheduleCardClose()
        pillView.pinned = pinned
    }

    private func openCard() {
        cardCloseWork?.cancel()
        if cardOpen { return }
        cardOpen = true
        cardView.rows = historyProvider()
        positionCard()
        card.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            card.animator().alphaValue = 1
        }
    }

    private func scheduleCardClose() {
        guard cardOpen else { return }
        cardCloseWork?.cancel()
        // A short grace period lets the pointer travel from the orb up into the list.
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
            self.cardView.hot = nil
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
        var y = a.y + pill.frame.height + 8
        if let screen = pill.screen ?? NSScreen.main {
            let v = screen.visibleFrame
            x = min(max(v.minX + 8, x), v.maxX - size.width - 8)
            if y + size.height > v.maxY { y = a.y - size.height - 10 }
        }
        card.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), display: true)
    }

    // MARK: Offscreen rendering for checks and screenshots

    static func renderSheet(to url: URL, rows: [Dictation]) {
        Theme.registerFonts()
        let history = HistoryView(), empty = HistoryView()
        history.rows = rows
        history.hot = rows.isEmpty ? nil : 1
        history.settleHover()
        let mini = PillView(), active = PillView(), assistant = PillView()
        mini.mode = .mini
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
        let cards: [(NSView, NSSize)] = [(history, history.preferredSize), (empty, empty.preferredSize)]
        // The resting pill with agents: one asking, one working (hovered), one ready.
        let names = AgentPeek.castNames
        let crew = [AgentPeek(id: "a", name: names[0], title: "Fix the signup form", tty: "", state: .question),
                    AgentPeek(id: "b", name: names[1], title: "Write the launch post", tty: "", state: .working),
                    AgentPeek(id: "c", name: names[2], title: "Tidy the inbox", tty: "", state: .ready)]
        let miniCrew = PillView()
        miniCrew.mode = .mini; miniCrew.agents = crew
        miniCrew.setHoveredAgent(crew[1]); for _ in 0..<60 { miniCrew.stepLift() }
        let pillViews: [PillView] = [mini, active, assistant, shelved, dropping, miniCrew]
        let pills: [(NSView, NSSize)] = pillViews.map { ($0, $0.preferredSize) }

        let pad: CGFloat = 28
        let width = max(cards.reduce(pad) { $0 + $1.1.width + pad }, pills.reduce(pad) { $0 + $1.1.width + pad })
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
    /// Agents drawn after the orb at rest. Click one to bring up its terminal.
    var agents: [AgentPeek] = [] { didSet { relayout(); updateTicker() } }
    var onAgentClick: (AgentPeek) -> Void = { _ in }
    private var ticker: Timer?
    /// Each agent's hover amount, eased toward 1 under the pointer and back to 0 after.
    private(set) var lift: [String: CGFloat] = [:]
    private var liftTimer: Timer?
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

    // MARK: Agents

    private static let moreFont = Theme.sans(10.5, "Medium")
    private var shownAgents: ArraySlice<AgentPeek> { agents.prefix(AgentPeek.maxShown) }
    private var moreLabel: String? { agents.count > AgentPeek.maxShown ? "+\(agents.count - AgentPeek.maxShown)" : nil }
    private var showsAgents: Bool {
        if case .mini = mode { return !agents.isEmpty } else { return false }
    }
    /// Width of the agent strip, including its leading gap.
    private var agentsWidth: CGFloat {
        guard showsAgents else { return 0 }
        let more = moreLabel.map { Theme.size($0, font: Self.moreFont).width + 4 } ?? 0
        return 4 + CGFloat(shownAgents.count) * AgentPeek.slot + more + 14
    }
    private let agentsStart: CGFloat = 26
    func agentRects() -> [(AgentPeek, NSRect)] {
        guard showsAgents else { return [] }
        let s = AgentPeek.slot
        return shownAgents.enumerated().map { i, a in
            (a, NSRect(x: agentsStart + 4 + CGFloat(i) * s, y: (bounds.height - s) / 2, width: s, height: s))
        }
    }
    private func agent(at p: NSPoint) -> AgentPeek? { agentRects().first { $0.1.insetBy(dx: 0, dy: -4).contains(p) }?.0 }

    /// Redraw about 12 times a second only while a spinner or question mark is moving.
    private func updateTicker() {
        let moving = showsAgents && agents.contains { $0.state != .ready }
        if moving, ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
                guard let self, self.window?.isVisible == true else { return }
                self.needsDisplay = true
            }
        } else if !moving {
            ticker?.invalidate(); ticker = nil
        }
    }

    private var hoveredAgent: String?

    /// Point the hover at an agent (or none) and glide every sprite toward its new lift.
    func setHoveredAgent(_ a: AgentPeek?) {
        hoveredAgent = a?.id
        toolTip = a?.tooltip
        if let a, lift[a.id] == nil { lift[a.id] = 0 }
        guard liftTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.stepLift() }
        RunLoop.main.add(timer, forMode: .common)
        liftTimer = timer
    }

    /// One 60 Hz frame; the timer stops once every sprite has settled.
    func stepLift() {
        var settled = true
        for (id, v) in lift {
            let target: CGFloat = id == hoveredAgent ? 1 : 0
            let n = AgentPeek.easeHover(v, to: target)
            if n == 0 && target == 0 { lift[id] = nil } else { lift[id] = n }
            if n != target { settled = false }
        }
        needsDisplay = true
        if settled { liftTimer?.invalidate(); liftTimer = nil }
    }

    private func drawAgents() {
        let rects = agentRects()
        guard let first = rects.first?.1 else { return }
        let t = Date().timeIntervalSinceReferenceDate
        for (a, r) in rects { a.draw(in: r, t: t, lift: lift[a.id] ?? 0) }
        if let more = moreLabel {
            let s = Theme.size(more, font: Self.moreFont)
            let x = (rects.last?.1.maxX ?? first.minX) + 3
            Theme.draw(more, at: NSPoint(x: x, y: bounds.midY - s.height / 2), font: Self.moreFont, color: Theme.textDim)
        }
    }

    var preferredSize: NSSize {
        switch mode {
        case .mini:
            return showsAgents ? NSSize(width: 26 + agentsWidth, height: AgentPeek.slot + 6) : NSSize(width: 26, height: 26)
        case .active(let text, _):
            let w = Theme.size(text, font: Theme.sans(13.5, "Medium")).width
            return NSSize(width: min(680, max(170, 8 + 40 + 10 + ceil(w) + 22 + chipWidth)), height: 52 + headroom)
        case .shelf(let drop):
            return NSSize(width: shelfWidth(drop), height: 36)
        }
    }

    /// The part of the pill that opens the history: the orb, not the agents beside it.
    var orbZone: NSRect {
        switch mode {
        case .mini: return showsAgents ? NSRect(x: 0, y: 0, width: 26, height: bounds.height) : bounds
        case .shelf(.none): return NSRect(x: 0, y: 0, width: 30, height: bounds.height)
        default: return .zero
        }
    }

    private func relayout() {
        switch mode {
        case .mini:
            orb.frame = NSRect(x: 3, y: (preferredSize.height - 20) / 2, width: 20, height: 20)
            orb.speedMul = 0.4
            orb.idle = true
            orb.state = .breathing
            orb.tint = hoveringOrb ? Theme.goldHi : Theme.textDim
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
        updateTicker()
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
        drawAgents()
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
            if case .mini = mode { orb.tint = overOrb || pinned ? Theme.goldHi : Theme.textDim }
            if case .shelf(.none) = mode { orb.tint = overOrb ? Theme.goldHi : Theme.textDim }
        }
        onHover(hovering, hoveringOrb)
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true; report(event) }
    override func mouseMoved(with event: NSEvent) { report(event); updateThumbHover(event) }
    override func mouseExited(with event: NSEvent) {
        hovering = false; hoveredThumb = nil; setHoveredAgent(nil); needsDisplay = true; report(nil)
    }

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
        if showsAgents {
            let a = agent(at: convert(event.locationInWindow, from: nil))
            if a?.id != hoveredAgent { setHoveredAgent(a) }
            if a != nil { return }
        }
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
        if !dragged, let a = agent(at: convert(event.locationInWindow, from: nil)) { onAgentClick(a); return }
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

// MARK: - History

/// Recent dictations above the orb. Click a row to copy its text, for anything a paste missed.
/// The hover highlight glides between rows instead of jumping.
final class HistoryView: NSView {
    var rows: [Dictation] = [] { didSet { hot = nil; glow = nil; invalidateIntrinsicSize() } }
    var onHover: (Bool) -> Void = { _ in }
    var onCopy: (Dictation) -> Void = { _ in }
    var onOpenAll: () -> Void = {}
    /// Hovered row index, or -1 for the "All history" link.
    var hot: Int? { didSet { if hot != oldValue { startGlide() } } }

    static let limit = 8
    private let width: CGFloat = 340
    private let pad: CGFloat = 14
    private let rowHeight: CGFloat = 50
    private let headerHeight: CGFloat = 34
    private let footerHeight: CGFloat = 30
    private var hits: [(NSRect, Int)] = []
    private let textFont = Theme.sans(12.5, "Medium")
    private let metaFont = Theme.sans(10.5)

    // MARK: Smooth hover
    /// The highlight's current top edge and opacity; they ease toward the hovered row.
    private(set) var glow: (y: CGFloat, alpha: CGFloat)?
    private var glideTimer: Timer?
    /// Fraction of the remaining distance covered per 1/60 s frame (about 0.2 s to settle).
    static let ease: CGFloat = 0.22

    private func rowTop(_ i: Int) -> CGFloat { headerHeight + CGFloat(i) * rowHeight }
    private var target: (y: CGFloat, alpha: CGFloat)? {
        guard let h = hot, h >= 0, h < shown.count else { return nil }
        return (rowTop(h), 1)
    }

    /// One easing step toward the hovered row. Pure on its inputs, so the self-test can drive it.
    static func step(_ g: (y: CGFloat, alpha: CGFloat)?, to t: (y: CGFloat, alpha: CGFloat)?) -> (y: CGFloat, alpha: CGFloat)? {
        guard let t else {
            guard let g else { return nil }
            let a = g.alpha * (1 - ease * 1.4)
            return a < 0.02 ? nil : (g.y, a)
        }
        guard let g else { return (t.y, 0.35) }   // first hover: fade in where it is, no slide from nowhere
        let y = abs(t.y - g.y) < 0.4 ? t.y : g.y + (t.y - g.y) * ease
        let a = min(1, g.alpha + (1 - g.alpha) * ease * 1.6)
        return (y, a > 0.98 ? 1 : a)
    }

    private func startGlide() {
        needsDisplay = true
        guard glideTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.glideTick() }
        RunLoop.main.add(t, forMode: .common)
        glideTimer = t
    }

    private func glideTick() {
        let next = Self.step(glow, to: target)
        let done = next.map { n in target.map { n.y == $0.y && n.alpha == 1 } ?? false } ?? true
        glow = next
        needsDisplay = true
        if done { glideTimer?.invalidate(); glideTimer = nil }
    }

    /// Jump straight to the end state (offscreen renders).
    func settleHover() { glow = target }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var shown: [Dictation] { Array(rows.filter { !$0.finalText.isEmpty }.prefix(Self.limit)) }

    var preferredSize: NSSize {
        let n = shown.count
        return NSSize(width: width, height: headerHeight + (n == 0 ? 44 : CGFloat(n) * rowHeight) + footerHeight)
    }

    private func invalidateIntrinsicSize() {
        if let window, window.frame.size != preferredSize {
            var f = window.frame
            f.size = preferredSize
            window.setFrame(f, display: false)
        }
        needsDisplay = true
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private static func when(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? time.string(from: d) : RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())
    }

    override func draw(_ dirtyRect: NSRect) {
        hits.removeAll()
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14)
        Theme.surface.withAlphaComponent(0.97).setFill()
        shape.fill()
        Theme.border.setStroke()
        shape.lineWidth = 1
        shape.stroke()

        Theme.draw("RECENT", at: NSPoint(x: pad, y: 13), font: Theme.sans(9.5, "Medium"), color: Theme.gold, kern: 2)
        let hint = "Click to copy"
        let hs = Theme.size(hint, font: metaFont)
        Theme.draw(hint, at: NSPoint(x: width - pad - hs.width, y: 13), font: metaFont, color: Theme.textMuted)

        var y = headerHeight
        let list = shown
        if list.isEmpty {
            Theme.draw("Nothing yet. Hold ⌥ and talk.", at: NSPoint(x: pad, y: y + 12), font: textFont, color: Theme.textDim)
            y += 44
        }
        if let g = glow {
            let row = NSRect(x: 6, y: g.y, width: width - 12, height: rowHeight - 2)
            let bg = NSBezierPath(roundedRect: row, xRadius: 9, yRadius: 9)
            Theme.surface2.withAlphaComponent(g.alpha).setFill(); bg.fill()
            Theme.goldLine.withAlphaComponent(0.34 * g.alpha).setStroke(); bg.lineWidth = 1; bg.stroke()
        }
        for (i, d) in list.enumerated() {
            let row = NSRect(x: 6, y: y, width: width - 12, height: rowHeight - 2)
            // How lit this row is: 1 under the settled highlight, fading as it slides away.
            let lit = glow.map { max(0, 1 - abs($0.y - y) / rowHeight) * $0.alpha } ?? 0
            let assistant = d.mode == "assistant"
            let text = d.finalText.replacingOccurrences(of: "\n", with: " ")
            (text as NSString).draw(with: NSRect(x: pad + 3 * lit, y: y + 7, width: width - pad * 2 - 40 * lit, height: 17),
                                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                    attributes: [.font: textFont, .foregroundColor: Theme.text])
            var meta = [Self.when(d.createdAt)]
            if let app = d.appName, !app.isEmpty { meta.append(app) }
            if assistant { meta.append(GWConfig.name) }
            Theme.draw(meta.joined(separator: " · "), at: NSPoint(x: pad + 3 * lit, y: y + 27), font: metaFont,
                       color: assistant ? Theme.gold : Theme.textMuted)
            if lit > 0.05 {
                let c = "Copy", cf = Theme.sans(10.5, "SemiBold")
                let cs = Theme.size(c, font: cf)
                Theme.draw(c, at: NSPoint(x: row.maxX - 10 - cs.width, y: row.midY - cs.height / 2), font: cf,
                           color: Theme.goldHi.withAlphaComponent(lit))
            }
            hits.append((row, i))
            y += rowHeight
        }
        Theme.border.setFill()
        NSRect(x: pad, y: y + 2, width: width - pad * 2, height: 1).fill()
        let all = "All history", af = Theme.sans(11, "Medium")
        let s = Theme.size(all, font: af)
        let link = NSRect(x: pad, y: y + 9, width: s.width, height: s.height)
        Theme.draw(all, at: link.origin, font: af, color: hot == -1 ? Theme.goldHi : Theme.textDim)
        hits.append((link.insetBy(dx: -6, dy: -4), -1))
        window?.invalidateCursorRects(for: self)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { hot = nil; onHover(false) }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hot = hits.first { $0.0.contains(p) }?.1
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = hits.first(where: { $0.0.contains(p) })?.1 else { return }
        if i == -1 { onOpenAll(); return }
        let list = shown
        if list.indices.contains(i) { onCopy(list[i]) }
    }

    override func resetCursorRects() {
        for (rect, _) in hits { addCursorRect(rect, cursor: .pointingHand) }
    }
}
