import AppKit
import ApplicationServices

/// Quadrant Dictation, a style of Vision Mode: hold up 1 to 4 fingers to pick a quarter of the screen
/// (1 top left, 2 top right, 3 bottom left, 4 bottom right). GoldWare outlines it, brings the window there
/// to the front, puts the cursor in its text box, and dictates while the fingers stay up. Lowering them
/// (or any other hand shape) finishes, and GoldWare Voice pastes into that text box.
/// A fist is the resting position here; an open hand held for a moment goes back to the pointer.
final class QuadrantDictation: VisionDriver {
    enum Phase: Equatable { case idle, choosing(Int), dictating(Int) }
    private(set) var phase: Phase = .idle
    /// Start (with the chosen quadrant) or finish an GoldWare Voice dictation.
    var onDictate: ((Bool) -> Void)?
    var onIdleTimeout: (() -> Void)?
    var onSwitchStyle: ((HandControl.Style) -> Void)?
    /// A quadrant's window was brought to the front (reported in dry runs too, for the self-test).
    var onRaise: ((Int) -> Void)?
    /// The two-hand gesture after a dictation pasted: press Return in that window. The app decides
    /// whether there is something to send.
    var onSend: (() -> Void)?
    /// The pinky alone, held: clear what the last hand dictation pasted.
    var onClear: (() -> Void)?
    /// For `--test-hand`: no window lookups, focus changes, or outlines on screen.
    var dryRun = false

    private let overlay = QuadrantOverlay()
    private let map = (1...4).map { _ in QuadrantOverlay() }
    private var mapHide: DispatchWorkItem?
    private var candidate: Int?
    private var target: QuadrantTarget?   // looked up once per quadrant, not every frame
    private var raised = false
    private var since: CFTimeInterval = 0
    private var goneSince: CFTimeInterval?
    /// A count that must not start anything until the hand clearly changes: the one that just dictated,
    /// or the four that switched into this mode. A fist or a lowered hand clears it at once; another
    /// shape clears it after 0.3 s, so a one-frame misread cannot.
    private var blocked: Int?
    private var unblockSince: CFTimeInterval?
    private var switchHold = HeldGesture()
    private var clearHold = HeldGesture()
    private var send = SendGesture()
    private var resting = false
    /// Last frame's fingers, so a finger at the line does not flicker (see `HandGesture.extended`).
    private var lastFingers: [Bool]?
    var isDictating: Bool { if case .dictating = phase { return true } else { return false } }
    private var lastHand = CACurrentMediaTime()
    private static let hold = 0.45
    /// How long a count has to stay before its window comes forward: long enough that passing through
    /// 1 and 2 on the way to 3 raises nothing, short enough to feel immediate.
    private static let raiseAfter = 0.2

    var status: String {
        if switchHold.isHolding { return "OPEN HAND · BACK TO POINTER" }
        if clearHold.isHolding { return "PINKY · CLEAR" }
        if send.inProgress { return "SEND" + String(repeating: " ·", count: send.steps) }
        switch phase {
        case .idle: return resting ? "QUADRANTS · RESTING" : "QUADRANTS"
        case .choosing(let q): return "QUADRANT \(q)"
        case .dictating(let q): return "DICTATING · \(q)"
        }
    }

    func stop() {
        finish()
        cancelChoice()
        hideMap()
        blocked = nil
        unblockSince = nil
        switchHold.reset()
        clearHold.reset()
        send.reset()
        lastFingers = nil
    }

    /// Ignore `n` fingers until the hand clearly changes (used for the four that switched modes).
    func block(_ n: Int) { blocked = n; unblockSince = nil }

    func handle(_ f: VisionFrame) {
        let now = f.time
        let e = HandGesture.extended(f.squared, last: lastFingers)
        lastFingers = e?.fingers
        if !f.lead.isEmpty { lastHand = now }
        resting = e.map { !$0.fingers.contains(true) } == true

        if case .dictating(let q) = phase {
            // While talking the thumb is ignored, so a thumb drifting out neither ends it nor switches modes.
            // A one-frame misread keeps going; the fingers have to be really down to finish.
            if e.map({ $0.fingers.filter { $0 }.count }) == q { goneSince = nil; return }
            if goneSince == nil { goneSince = now }
            if now - (goneSince ?? now) >= 0.3 { finish() }
            return
        }

        // The two-hand send (the diamond, then let go) presses Return on what was just pasted. While it
        // is underway nothing else reads the hands, and two hands close together never count as fingers
        // or an open hand.
        if send.feed(f) {
            cancelChoice()
            onSend?()
            return
        }
        if send.inProgress || (f.pair?.palms ?? 9) < 2.5 {
            cancelChoice()
            return
        }

        // An open hand (four fingers and the thumb spread), held: back to the pointer.
        let open = HandGesture.isOpenHand(f.squared, last: e?.fingers)
        switch switchHold.update(open, now: now) {
        case .fired:
            cancelChoice()
            onSwitchStyle?(.pointer)
            return
        case .holding where open:
            return   // pause: a thumb flickering out while choosing 4 must not throw the choice away
        case .holding, .idle:
            break
        }

        // The pinky alone, held: clear what was just pasted (never quadrant 1, see `quadrant`).
        switch clearHold.update(HandGesture.isPinky(f.squared, last: e?.fingers), now: now) {
        case .fired:
            cancelChoice()
            onClear?()
            return
        case .holding:
            cancelChoice()
            return
        case .idle:
            break
        }

        let count = Self.quadrant(f.squared, last: e?.fingers)
        if let b = blocked {
            if f.lead.isEmpty || resting {
                blocked = nil
            } else if count == b {
                unblockSince = nil
                return
            } else {
                if unblockSince == nil { unblockSince = now }
                guard now - (unblockSince ?? now) >= 0.3 else { return }
                blocked = nil
            }
            unblockSince = nil
        }
        guard let n = count else {
            cancelChoice()
            if now - lastHand > 15 * 60 { lastHand = now; onIdleTimeout?() }
            return
        }
        if n != candidate {
            candidate = n; since = now; raised = false; target = dryRun ? nil : QuadrantTarget.find(n)
            hideMap()
        }
        // The chosen window comes to the front, so you see all of it before dictating into it.
        if !raised, now - since >= Self.raiseAfter {
            raised = true
            // Off the main thread: a busy app can take a moment to answer, and the camera must not stall.
            if let t = target { DispatchQueue.global(qos: .userInitiated).async { t.raise() } }
            onRaise?(n)
        }
        let progress = min(1, (now - since) / Self.hold)
        phase = .choosing(n)
        if !dryRun { overlay.show(quadrant: n, frame: QuadrantTarget.rect(n), appName: target?.appName, progress: progress, dictating: false) }
        guard progress >= 1, !dryRun else { return }
        guard let target, target.focus() else {
            Sounds.play(.error)
            overlay.flash(quadrant: n, frame: QuadrantTarget.rect(n), text: Self.noTargetMessage(trusted: AXIsProcessTrusted(), app: target?.appName))
            blocked = n
            candidate = nil
            phase = .idle
            return
        }
        phase = .dictating(n)
        goneSince = nil
        overlay.show(quadrant: n, frame: QuadrantTarget.rect(n), appName: target.appName, progress: 1, dictating: true)
        // Give the app a beat to come forward so the recording targets it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.phase == .dictating(n) else { return }
            self.onDictate?(true)
        }
    }

    /// Tiles the windows on screen into the quadrants, then shows each quarter's number and app for a
    /// moment so you know which fingers pick what.
    func arrangeWindows() {
        guard !dryRun, AXIsProcessTrusted() else { return }
        let quads = (1...4).map(QuadrantTarget.rect)
        let top = NSScreen.screens[0].frame.maxY
        let apps = QuadrantTarget.regularApps()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let placed = QuadrantTarget.arrange(quadrants: quads, screenTop: top, apps: apps)
            DispatchQueue.main.async { self?.showMap(placed, quads) }
        }
    }

    private func showMap(_ placed: [Int: (app: String, behind: Int)], _ quads: [NSRect]) {
        guard HandControl.enabled, HandControl.style == .quadrants, phase == .idle else { return }
        for q in 1...4 {
            let name = placed[q].map { $0.behind > 0 ? "\($0.app) +\($0.behind) behind" : $0.app }
            map[q - 1].show(quadrant: q, frame: quads[q - 1], appName: name, progress: 0, dictating: false)
        }
        mapHide?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.hideMap() }
        mapHide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: w)
    }

    private func hideMap() {
        mapHide?.cancel(); mapHide = nil
        map.forEach { $0.hide() }
    }

    private func cancelChoice() {
        guard candidate != nil || phase != .idle else { return }
        candidate = nil
        if case .choosing = phase { phase = .idle }
        overlay.hide()
    }

    /// Fingers up, index to little, from squared joints. The thumb is ignored (a loose thumb beside one
    /// finger is still 1), except that four fingers with the thumb spread is an open hand, which picks nothing.
    static func quadrant(_ j: HandGesture.Joints, last: [Bool]? = nil) -> Int? {
        // The OK sign has three fingers up, but it hides the mirror; it is not quadrant 3.
        guard let e = HandGesture.extended(j, last: last), !HandGesture.isOK(j) else { return nil }
        let n = e.fingers.filter { $0 }.count
        guard (1...4).contains(n), !(n == 4 && HandGesture.thumb(j) == .spread) else { return nil }
        // The pinky alone clears; it never picks quadrant 1.
        if e.fingers == [false, false, false, true] { return nil }
        return n
    }

    private func finish() {
        guard case .dictating(let q) = phase else { return }
        blocked = q
        unblockSince = nil
        candidate = nil
        phase = .idle
        overlay.hide()
        onDictate?(false)
    }
}

/// The window server's id for an Accessibility window. Private, but it is what window managers use to
/// tell apart windows of one app that share a frame (two Terminals stacked in a quadrant).
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

extension QuadrantDictation {
    /// Why a quadrant could not be dictated into. Without Accessibility no window can be read at all,
    /// which after a rebuild (an ad-hoc signed app loses its permissions) looks like an empty screen.
    static func noTargetMessage(trusted: Bool, app: String?) -> String {
        guard trusted else { return "Turn on Accessibility for \(GWConfig.name): System Settings > Privacy & Security" }
        guard let app else { return "No window here" }
        return "No text box found in \(app)"
    }
}

/// The window in a quadrant and the text box inside it, found through Accessibility.
struct QuadrantTarget {
    let pid: pid_t
    let appName: String
    let window: AXUIElement

    /// A quarter of the camera screen's visible area, in AppKit coordinates (origin bottom left).
    static func rect(_ q: Int) -> NSRect {
        let s = (NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let w = s.width / 2, h = s.height / 2
        let left = q == 1 || q == 3, top = q == 1 || q == 2
        return NSRect(x: left ? s.minX : s.midX, y: top ? s.midY : s.minY, width: w, height: h)
    }

    /// The frontmost ordinary window whose center sits in the quadrant.
    static func find(_ q: Int, only: pid_t? = nil) -> QuadrantTarget? {
        let area = cg(rect(q), top: NSScreen.screens[0].frame.maxY)
        for w in listed(only: only) where area.contains(CGPoint(x: w.bounds.midX, y: w.bounds.midY)) {
            let app = AXUIElementCreateApplication(w.pid)
            guard let window = Self.axWindow(of: app, matching: w.bounds, id: w.id) else { continue }
            return QuadrantTarget(pid: w.pid, appName: w.name, window: window)
        }
        return nil
    }

    // MARK: Tiling

    /// An on-screen window from the window server, in CG coordinates (origin top left).
    struct Listed {
        let pid: pid_t
        let owner: String
        let bounds: CGRect
        var id: CGWindowID = 0
        var name: String { NSRunningApplication(processIdentifier: pid)?.localizedName ?? owner }
    }

    /// Ordinary app windows on screen, front to back. GoldWare's own are skipped (they cannot be driven
    /// from the main thread), unless `only` names a process or `includeSelf` is set.
    static func listed(only: pid_t? = nil, includeSelf: Bool = false) -> [Listed] {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, only.map({ pid == $0 }) ?? (includeSelf || pid != me),
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"],
                  width > 120, height > 80 else { return nil }
            return Listed(pid: pid, owner: w[kCGWindowOwnerName as String] as? String ?? "",
                          bounds: CGRect(x: x, y: y, width: width, height: height),
                          id: w[kCGWindowNumber as String] as? CGWindowID ?? 0)
        }
    }

    /// An AppKit rect (origin bottom left) in CG coordinates, given the main screen's top.
    static func cg(_ r: NSRect, top: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: top - r.maxY, width: r.width, height: r.height)
    }

    /// Quadrants are listed 1 to 4: top left, top right, bottom left, bottom right (CG, y down).
    private static func isLeft(_ q: Int) -> Bool { q % 2 == 0 }
    private static func isTop(_ q: Int) -> Bool { q < 2 }

    /// Where a window of `size` sits in quadrant `q`: pinned to the screen's corner, so one that cannot
    /// shrink to a quarter (a minimum size) hangs toward the middle instead of off the screen.
    static func anchored(_ size: CGSize, in quads: [CGRect], _ q: Int) -> CGRect {
        let r = quads[q]
        return CGRect(x: isLeft(q) ? r.minX : r.maxX - size.width, y: isTop(q) ? r.minY : r.maxY - size.height,
                      width: size.width, height: size.height)
    }

    /// Frames GoldWare left windows at that could not shrink to a quarter (a minimum size), pinned to their
    /// corner. Only those count as placed while oversize; a big window that merely touches a corner
    /// (a maximized one) still gets resized.
    private static var pinned: [CGRect] = []
    private static let pinnedLock = NSLock()

    /// True when `f` already sits in quadrant `q`: filling it (Terminal rounds to whole characters, so
    /// within a few points), or pinned to its corner by GoldWare because it cannot shrink that far.
    static func sits(_ f: CGRect, in quads: [CGRect], _ q: Int, pinned: [CGRect]? = nil) -> Bool {
        if distance(f, quads[q]) < 16 { return true }
        let known = pinned ?? { pinnedLock.lock(); defer { pinnedLock.unlock() }; return Self.pinned }()
        return known.contains { distance($0, f) < 6 } && distance(f, anchored(f.size, in: quads, q)) < 6
    }

    /// Which quadrant (0 to 3) each window goes to. Every window is placed. One already sitting in a
    /// quadrant keeps it, so switching in again reshuffles nothing. The rest go front to back to the
    /// least crowded quadrant, the nearest one when several tie, so the windows you used last each get
    /// a quadrant of their own and the older ones stack behind them.
    static func plan(_ windows: [CGRect], into quads: [CGRect], pinned: [CGRect]? = nil) -> [(window: Int, quadrant: Int)] {
        var load = Array(repeating: 0, count: quads.count)
        var result: [(window: Int, quadrant: Int)] = []
        var rest: [Int] = []
        for (i, f) in windows.enumerated() {
            if let q = quads.indices.first(where: { sits(f, in: quads, $0, pinned: pinned) }) {
                result.append((i, q)); load[q] += 1
            } else {
                rest.append(i)
            }
        }
        for i in rest {
            let c = CGPoint(x: windows[i].midX, y: windows[i].midY)
            let least = load.min() ?? 0
            let q = quads.indices.filter { load[$0] == least }.min { a, b in
                hypot(quads[a].midX - c.x, quads[a].midY - c.y) < hypot(quads[b].midX - c.x, quads[b].midY - c.y)
            } ?? 0
            result.append((i, q)); load[q] += 1
        }
        return result
    }

    /// Apps with windows of their own (not agents or background helpers). Read on the main thread.
    static func regularApps() -> [(pid: pid_t, name: String)] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            .map { ($0.processIdentifier, $0.localizedName ?? "") }
    }

    private struct AppWindow {
        let name: String
        /// Another app's window, driven through Accessibility.
        var ax: (app: AXUIElement, window: AXUIElement)?
        /// One of GoldWare's own, moved directly on the main thread. Through Accessibility it deadlocks:
        /// GoldWare's main thread has to answer the request while it is busy drawing.
        var own: NSWindow?
        var frame: CGRect
        var z = Int.max          // front to back on this Space; Int.max when on another Space
    }

    /// Runs on the main thread and waits (callers are on a background queue).
    private static func onMain<T>(_ work: () -> T) -> T {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }

    private static func cgFrame(_ w: NSWindow) -> CGRect {
        cg(w.frame, top: NSScreen.screens.first?.frame.maxY ?? 0)
    }

    /// The windows a person would call their apps: standard windows (and resizable document windows
    /// such as QuickTime's), on every Space, not minimized. Overlays, panels, and dialogs are left alone.
    private static func appWindows(_ apps: [(pid: pid_t, name: String)], log: ((String) -> Void)?) -> [AppWindow] {
        var out: [AppWindow] = []
        let me = ProcessInfo.processInfo.processIdentifier
        for (pid, name) in apps {
            if pid == me {
                out += onMain {
                    NSApp.windows.filter { w in
                        w.isVisible && !w.isMiniaturized && !(w is NSPanel) && w.level == .normal &&
                            w.styleMask.contains(.titled) && w.styleMask.contains(.resizable) &&
                            w.frame.width > 120 && w.frame.height > 80
                    }.map { AppWindow(name: name, own: $0, frame: cgFrame($0)) }
                }
                continue
            }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 1)
            let windows: [AXUIElement] = attr(app, kAXWindowsAttribute) ?? []
            for w in windows {
                AXUIElementSetMessagingTimeout(w, 1)
                let sub: String = attr(w, kAXSubroleAttribute) ?? ""
                var sizable: DarwinBoolean = false
                AXUIElementIsAttributeSettable(w, kAXSizeAttribute as CFString, &sizable)
                guard sub == kAXStandardWindowSubrole as String || (sub == kAXDialogSubrole as String && sizable.boolValue) else { continue }
                if (attr(w, kAXMinimizedAttribute) as Bool?) == true { log?("leave \(name): minimized"); continue }
                guard let f = frame(w), f.width > 120, f.height > 80 else { continue }
                out.append(AppWindow(name: name, ax: (app, w), frame: f))
            }
        }
        return out
    }

    /// Tiles every app window into the quadrants: full-screen windows leave full screen first (a
    /// full-screen window cannot be resized), then each window is sized to its quarter. Windows on this
    /// Space and on other Spaces are planned separately, so this screen's corners fill first. Returns
    /// each quadrant's front app and how many wait behind it (this Space only). Call off the main thread:
    /// a busy app can take a second to answer, and leaving full screen takes about one.
    static func arrange(quadrants: [NSRect], screenTop top: CGFloat, apps: [(pid: pid_t, name: String)],
                        log: ((String) -> Void)? = nil) -> [Int: (app: String, behind: Int)] {
        let quads = quadrants.map { cg($0, top: top) }
        let screen = quads.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -40, dy: -60)
        var windows = appWindows(apps, log: log)

        // Full screen: ask each to leave, then wait for the animation to finish.
        let full = windows.filter { w in w.ax.map { (attr($0.window, "AXFullScreen") as Bool?) == true } ?? false }
        if !full.isEmpty {
            for w in full {
                log?("\(w.name): leaving full screen")
                AXUIElementSetAttributeValue(w.ax!.window, "AXFullScreen" as CFString, kCFBooleanFalse)
            }
            let deadline = Date() + 4
            while Date() < deadline, full.contains(where: { (attr($0.ax!.window, "AXFullScreen") as Bool?) == true }) {
                Thread.sleep(forTimeInterval: 0.2)
            }
            Thread.sleep(forTimeInterval: 0.8)   // the zoom-out animation, then the window settles
            windows = appWindows(apps, log: nil)
        }

        // Which are on this Space, front to back.
        let onScreen = listed(includeSelf: true)
        for k in windows.indices {
            if let a = windows[k].ax { windows[k].frame = frame(a.window) ?? windows[k].frame }
            else if let o = windows[k].own { windows[k].frame = onMain { cgFrame(o) } }
            let id = windows[k].ax.flatMap { windowID($0.window) } ?? windows[k].own.map { CGWindowID($0.windowNumber) }
            if let z = onScreen.firstIndex(where: { id != nil ? $0.id == id : distance($0.bounds, windows[k].frame) < 40 }) { windows[k].z = z }
        }
        windows = windows.filter { screen.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) || $0.z == .max }
        let here = windows.filter { $0.z != .max }.sorted { $0.z < $1.z }
        let elsewhere = windows.filter { $0.z == .max }

        var result: [Int: (app: String, behind: Int)] = [:]
        for (group, isHere) in [(here, true), (elsewhere, false)] {
            for (i, q) in plan(group.map(\.frame), into: quads) {
                let w = group[i]
                if distance(w.frame, quads[q]) < 16 {
                    log?("\(w.name): already fills Q\(q + 1)")
                } else {
                    let l = log.map { l in { (s: String) in l("\(w.name)\(isHere ? "" : " (other Space)"): " + s) } }
                    if let a = w.ax { setFrame(a.window, in: quads, q, app: a.app, log: l) }
                    else if let o = w.own { setOwnFrame(o, in: quads, q, log: l) }
                }
                guard isHere else { continue }
                if let r = result[q + 1] { result[q + 1] = (r.app, r.behind + 1) } else { result[q + 1] = (w.name, 0) }
            }
        }
        return result
    }

    private static func setFrame(_ window: AXUIElement, in quads: [CGRect], _ q: Int, app: AXUIElement,
                                 log: ((String) -> Void)? = nil) {
        let start = frame(window)
        // With the enhanced interface on (some assistive tools turn it on), Chrome and Electron apps
        // animate a resize and end up clamped, so switch it off while moving.
        let enhanced: Bool = attr(app, "AXEnhancedUserInterface") ?? false
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer { if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) } }
        func set(_ r: CGRect, size: Bool) {
            var origin = r.origin, sz = r.size
            if size, let s = AXValueCreate(.cgSize, &sz) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s) }
            if let p = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, p) }
        }
        // Size, then position, then size again: a window moving across the screen can refuse a size
        // that does not fit where it starts.
        set(quads[q], size: true)
        var sz = quads[q].size
        if let s = AXValueCreate(.cgSize, &sz) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s) }
        var end = frame(window)
        // It may not shrink that far (a minimum size); pin what it took to the screen's corner and
        // remember it, so the next arrange knows it is placed.
        if let got = end?.size, abs(got.width - sz.width) > 16 || abs(got.height - sz.height) > 16 {
            let spot = anchored(got, in: quads, q)
            set(spot, size: false)
            end = frame(window)
            pinnedLock.lock(); pinned.append(end ?? spot); if pinned.count > 64 { pinned.removeFirst() }; pinnedLock.unlock()
        }
        if let log {
            let fits = end.map { distance($0, quads[q]) < 16 } ?? false
            log("Q\(q + 1) \(fits ? "resized" : "PINNED (min size)") \(start.map(Self.short) ?? "?") -> \(end.map(Self.short) ?? "?")")
        }
    }

    /// GoldWare's own window, sized on the main thread (see `AppWindow.own`).
    private static func setOwnFrame(_ w: NSWindow, in quads: [CGRect], _ q: Int, log: ((String) -> Void)?) {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        func appKit(_ r: CGRect) -> NSRect { NSRect(x: r.minX, y: top - r.maxY, width: r.width, height: r.height) }
        let (start, end): (CGRect, CGRect) = onMain {
            let start = cgFrame(w)
            w.setFrame(appKit(quads[q]), display: true)
            var got = cgFrame(w)
            if abs(got.width - quads[q].width) > 16 || abs(got.height - quads[q].height) > 16 {
                w.setFrame(appKit(anchored(got.size, in: quads, q)), display: true)
                got = cgFrame(w)
                pinnedLock.lock(); pinned.append(got); pinnedLock.unlock()
            }
            return (start, got)
        }
        log?("Q\(q + 1) \(distance(end, quads[q]) < 16 ? "resized" : "PINNED (min size)") \(short(start)) -> \(short(end))")
    }

    private static func short(_ r: CGRect) -> String { "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))" }

    /// Brings the window forward and puts the cursor in its text box. False when there is no text box.
    /// Brings the window to the front, above every other app's window. `activate` makes its app the
    /// active one; the self-test turns that off so it never takes focus from the app you are using.
    func raise(activate: Bool = true) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        AXUIElementSetMessagingTimeout(window, 0.5)
        // This window first, so activating the app brings this one forward rather than another of its
        // windows (Terminal has one per quadrant), then again once the app is in front.
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        guard activate else { return }
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        // Only this window: activating with all windows would pull the app's windows in the other
        // quadrants over whatever is in front there.
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    func focus() -> Bool {
        raise()
        let app = AXUIElementCreateApplication(pid)
        // Already typing in this window: leave the cursor where it is.
        if let focused: AXUIElement = Self.attr(app, kAXFocusedUIElementAttribute), Self.isTextInput(focused),
           let w: AXUIElement = Self.attr(focused, kAXWindowAttribute), CFEqual(w, window) { return true }
        guard let box = Self.textBox(in: window) else { return false }
        return AXUIElementSetAttributeValue(box, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    // MARK: Accessibility helpers

    private static func attr<T>(_ e: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    private static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p: AXValue = attr(e, kAXPositionAttribute), let s: AXValue = attr(e, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p, .cgPoint, &point)
        AXValueGetValue(s, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    /// The Accessibility window for an on-screen window: by window id when known (exact, even when
    /// windows share a frame), otherwise the one whose frame is closest.
    static func axWindow(of app: AXUIElement, matching bounds: CGRect, id: CGWindowID = 0) -> AXUIElement? {
        let windows: [AXUIElement] = attr(app, kAXWindowsAttribute) ?? []
        if id != 0, let exact = windows.first(where: { windowID($0) == id }) { return exact }
        return windows.min { a, b in
            distance(frame(a), bounds) < distance(frame(b), bounds)
        }.flatMap { distance(frame($0), bounds) < 40 ? $0 : nil }
    }

    static func windowID(_ w: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(w, &id) == .success && id != 0 ? id : nil
    }

    private static func distance(_ a: CGRect?, _ b: CGRect) -> CGFloat {
        guard let a else { return .greatestFiniteMagnitude }
        return abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    private static func isTextInput(_ e: AXUIElement) -> Bool {
        let role: String = attr(e, kAXRoleAttribute) ?? ""
        if [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole, "AXSearchField"].contains(role) {
            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(e, kAXValueAttribute as CFString, &settable)
            return settable.boolValue || role == kAXTextAreaRole
        }
        // Web text boxes (Slack, Gmail, ChatGPT) are editable groups inside a web area.
        let editable: Bool = attr(e, "AXEditable") ?? false
        return editable && role != "AXWebArea"
    }

    /// The text box a person would type in: of the visible inputs, the lowest one (chat and reply boxes
    /// sit at the bottom), preferring the larger when two share a row. Bounded so a huge page stays fast.
    private static func textBox(in window: AXUIElement) -> AXUIElement? {
        var best: (e: AXUIElement, f: CGRect)?
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 1200 {
            let (e, depth) = queue.removeFirst()
            visited += 1
            if isTextInput(e), let f = frame(e), f.width > 40, f.height > 12 {
                if best == nil || f.maxY > best!.f.maxY + 4 || (abs(f.maxY - best!.f.maxY) <= 4 && f.width > best!.f.width) {
                    best = (e, f)
                }
                continue   // an input's own children are its text runs
            }
            guard depth < 40 else { continue }
            let children: [AXUIElement] = attr(e, kAXChildrenAttribute) ?? []
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return best?.e
    }
}

/// A gold outline around the chosen quarter of the screen, with its number and the app, filling as the
/// fingers are held and glowing while GoldWare listens. Click-through.
final class QuadrantOverlay {
    private var panel: NSPanel?
    private let box = CAShapeLayer()
    private let fill = CALayer()
    private let label = CATextLayer()
    private let ring = CAShapeLayer()
    private var hideWork: DispatchWorkItem?

    func show(quadrant q: Int, frame: NSRect, appName: String?, progress: Double, dictating: Bool) {
        hideWork?.cancel()
        let p = panel ?? make()
        panel = p
        if p.frame != frame { p.setFrame(frame, display: false) }
        let b = CGRect(origin: .zero, size: frame.size).insetBy(dx: 6, dy: 6)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        box.path = CGPath(roundedRect: b, cornerWidth: 14, cornerHeight: 14, transform: nil)
        box.lineWidth = dictating ? 3 : 2
        box.lineDashPattern = dictating ? nil : [10, 6]
        box.strokeColor = (dictating ? Theme.goldHi : Theme.gold).cgColor
        fill.frame = b
        fill.backgroundColor = Theme.gold.withAlphaComponent(dictating ? 0.08 : 0.04).cgColor
        let text = dictating ? "Listening · \(appName ?? "")" : "\(q) · \(appName ?? "No window here")"
        label.string = NSAttributedString(string: text, attributes: [.font: Theme.sans(15, "SemiBold"), .foregroundColor: Theme.goldHi])
        let size = Theme.size(text, font: Theme.sans(15, "SemiBold"))
        label.frame = CGRect(x: b.minX + 44, y: b.maxY - 38, width: size.width + 4, height: size.height)
        let c = CGPoint(x: b.minX + 24, y: b.maxY - 28)
        ring.path = CGPath(ellipseIn: CGRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18), transform: nil)
        ring.strokeEnd = CGFloat(progress)
        ring.fillColor = dictating ? Theme.goldHi.cgColor : nil
        CATransaction.commit()
        if !p.isVisible { p.alphaValue = 0; p.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }
    }

    /// A short message in the quadrant, then gone.
    func flash(quadrant q: Int, frame: NSRect, text: String) {
        show(quadrant: q, frame: frame, appName: nil, progress: 0, dictating: false)
        let size = Theme.size(text, font: Theme.sans(15, "SemiBold"))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        label.string = NSAttributedString(string: text, attributes: [.font: Theme.sans(15, "SemiBold"), .foregroundColor: Theme.red])
        label.frame.size.width = size.width + 4
        CATransaction.commit()
        let w = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: w)
    }

    func hide() {
        hideWork?.cancel()
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; p.animator().alphaValue = 0 },
                                             completionHandler: { if p.alphaValue == 0 { p.orderOut(nil) } })
    }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let v = NSView()
        v.wantsLayer = true
        p.contentView = v
        fill.cornerRadius = 14
        v.layer?.addSublayer(fill)
        box.fillColor = nil
        box.shadowColor = Theme.gold.cgColor
        box.shadowOpacity = 0.9
        box.shadowRadius = 8
        box.shadowOffset = .zero
        v.layer?.addSublayer(box)
        ring.strokeColor = Theme.goldHi.cgColor
        ring.lineWidth = 2.5
        ring.lineCap = .round
        v.layer?.addSublayer(ring)
        label.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        v.layer?.addSublayer(label)
        return p
    }
}
