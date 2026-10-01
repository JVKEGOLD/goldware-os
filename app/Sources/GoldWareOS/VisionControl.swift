import AppKit
import Vision

/// Vision Mode: control the Mac with one hand in front of the camera, with the mirror pinned under
/// the notch so you can see what GoldWare sees. The camera stays on (green light) while the mode is on
/// and turns itself off after 15 minutes without a hand.
///   Point (index finger up)   move the pointer like a trackpad. The gap between thumb and index tips
///                             sets the speed: wide is fast, close is fine control
///   Pinch thumb to index      click; pinch twice quickly to double-click; hold and move to drag
///   Two fingers, tilted       scroll that way; the steeper the tilt the faster (flat, pointing sideways, pauses)
///   Open hand                 nothing: rest here, the pointer stays put
///   Fist, held                dictate with GoldWare Voice until the fist opens (like holding Right Option)
///   Four fingers, held        switch to Quadrant Dictation (thumb folded in; with it spread it is an open hand)
///   OK sign, held             hide the mirror (Vision stays on); again to show it. Never a click.
/// Events are posted with the Accessibility grant the app already has for pasting.
/// Something that turns camera frames into actions while Vision Mode is on.
protocol VisionDriver: AnyObject {
    func handle(_ frame: VisionFrame)
    func stop()
    /// A few words for the mirror's footer.
    var status: String { get }
    /// A hand-started dictation is recording (a thumbs up then is part of the fist, not the lock).
    var isDictating: Bool { get }
    /// A held gesture asked to change style: four fingers into Quadrants, an open hand back.
    var onSwitchStyle: ((HandControl.Style) -> Void)? { get set }
}

/// The two-hand gesture: both hands start together, palms flat as in prayer; the palms spread while
/// the index tips stay touching and the thumb tips stay touching (a diamond); then the tips let go.
/// Each step has to follow the last within a moment, so no one pose on its own completes it. It unlocks
/// Vision Mode, and in Quadrants it sends what was just pasted.
struct TwoHandGesture {
    private var togetherAt: CFTimeInterval?      // last frame the hands were together
    private var diamondSince: CFTimeInterval?    // first frame of the diamond that followed "together"
    private var diamondAt: CFTimeInterval?       // last frame of that diamond

    /// 0, 1, or 2 steps done, for the mirror's dots.
    private(set) var steps = 0
    /// Partway through (hands together or in the diamond): other gestures should hold off.
    var inProgress: Bool { steps > 0 }

    mutating func reset() { togetherAt = nil; diamondSince = nil; diamondAt = nil; steps = 0 }

    /// Feeds one frame; true on the frame the gesture completes.
    mutating func feed(_ f: VisionFrame) -> Bool {
        let t = f.time
        let pair = f.pair
        if let p = pair, p.together { togetherAt = t }
        // The diamond counts only if it grew out of "together" (within 2.5 s), and stays counted
        // through a flicker.
        if let p = pair, p.diamond, diamondSince != nil || togetherAt.map({ t - $0 < 2.5 }) == true {
            if diamondSince == nil { diamondSince = t }
            diamondAt = t
        } else if let at = diamondAt, t - at > 0.8 {
            diamondSince = nil; diamondAt = nil
        }
        // Held: diamond frames spanning 0.2 s. A single frame of diamond is a misread.
        let held = diamondSince.map { since in diamondAt.map { $0 - since >= 0.2 } ?? false } ?? false
        steps = held ? 2 : togetherAt.map { t - $0 < 2.5 } == true ? 1 : 0

        // Release: the tips come apart, or the diamond has been gone for 0.25 s however it ended (a
        // hand out of view, a fingertip lost as the hands part). Waiting for both hands to be tracked
        // through the letting go is what made it hit or miss.
        guard held, let at = diamondAt, pair?.apart == true || t - at >= 0.25 else { return false }
        reset()
        return true
    }
}

/// Lock Up by hand (pointer style only): both hands open (four fingers up) for a beat, then both close
/// into fists. The open hands have to last 0.3 s, the fists have to follow within 1 s and hold 0.15 s,
/// so one hand closing, or fists that were never open, do nothing. Fires once; the hands have to drop
/// the shapes before it can fire again.
struct OpenToFists {
    private var openSince: CFTimeInterval?
    private var openAt: CFTimeInterval?
    private var fistSince: CFTimeInterval?
    private var spent = false
    private var seenAt: CFTimeInterval = -9     // last frame both hands were open or both were fists

    /// Both hands open or both in fists (or were a moment ago): the pointer and fist dictation wait.
    func busy(at t: CFTimeInterval) -> Bool { t - seenAt < 0.5 }

    static func fingers(_ j: HandGesture.Joints) -> [Bool]? { j.isEmpty ? nil : HandGesture.extended(j)?.fingers }

    mutating func reset() { openSince = nil; openAt = nil; fistSince = nil }

    /// Feeds one frame; true on the frame the fists complete it.
    mutating func feed(_ f: VisionFrame) -> Bool {
        let t = f.time
        let a = Self.fingers(f.squared), b = Self.fingers(f.secondSquared)
        // Open hands apart: praying hands read as two open hands too.
        let open = a == [true, true, true, true] && b == [true, true, true, true] && (f.pair?.palms ?? 0) > 1.5
        let fists = a == [false, false, false, false] && b == [false, false, false, false]
        if spent, t - seenAt > 0.5 { spent = false }
        if open || fists { seenAt = t }
        if spent { return false }
        if open {
            if openSince == nil { openSince = t }
            openAt = t
            fistSince = nil
            return false
        }
        // The open hands count only if they were held, and only for a moment after they close.
        guard let since = openSince, let at = openAt, at - since >= 0.3, t - at < 1.0 || fistSince != nil else {
            if let at = openAt, t - at > 0.2 { reset() }   // a brief misread keeps the open hands
            return false
        }
        guard fists else {
            if t - at > 1.0 { reset() }
            return false
        }
        if fistSince == nil { fistSince = t }
        guard t - (fistSince ?? t) >= 0.15 else { return false }
        reset()
        spent = true
        return true
    }
}

/// The passcode: Vision Mode turns on locked, and the hands drive nothing until the two-hand gesture.
/// The mirror only counts the steps with dots and never says what they are. After a minute with no
/// hand in view it locks again, and a thumbs up held while open locks it on the spot.
struct VisionLock {
    enum State: Equatable { case locked, open }
    private(set) var state = State.locked
    private var lastHand: CFTimeInterval = 0
    private var settleUntil: CFTimeInterval = 0
    private var gesture = TwoHandGesture()
    private var thumbHold = HeldGesture()
    /// A thumbs up that was used for something else (filing a scan) cannot also lock until it goes away.
    private var thumbSpentAt: CFTimeInterval?
    static let relockAfter = 60.0

    var steps: Int { gesture.steps }
    var status: String { state == .locked ? "LOCKED" + String(repeating: " ·", count: steps) : "" }

    mutating func lock() { state = .locked; lastHand = 0; gesture.reset(); thumbHold.reset(); thumbSpentAt = nil }

    /// Seconds since a hand was last in view.
    func idle(at now: CFTimeInterval) -> CFTimeInterval { lastHand == 0 ? 0 : now - lastHand }

    /// Feeds one frame; returns true when the frame may drive the hand. `unlocked` is set on the frame
    /// the passcode is accepted, `relocked` on the frame a held thumbs up locks it again. `thumbLocks` is
    /// false while a thumbs up means something else (a scan waiting to be filed).
    mutating func admit(_ f: VisionFrame, unlocked: inout Bool, relocked: inout Bool, thumbLocks: Bool = true) -> Bool {
        let t = f.time
        if lastHand == 0 { lastHand = t }
        let away = t - lastHand
        if !f.lead.isEmpty { lastHand = t }
        if state == .open {
            if away > Self.relockAfter { lock(); return false }
            let thumb = HandGesture.classify(f.squared) == .thumbsUp
            if !thumbLocks {
                thumbHold.reset()
                if thumb { thumbSpentAt = t }
            } else if let spent = thumbSpentAt {
                if thumb { thumbSpentAt = t } else if t - spent > 0.5 { thumbSpentAt = nil }
            } else if thumbHold.update(thumb, now: t) == .fired {
                lock()
                relocked = true
                return false
            }
            return t >= settleUntil   // a beat for the hands to come down before anything moves
        }
        if gesture.feed(f) {
            state = .open
            settleUntil = t + 0.4
            unlocked = true
        }
        return false
    }
}

/// The OK sign held for a moment: hides the mirror, or brings it back. Fires once per hold.
struct MirrorToggle {
    private var hold = HeldGesture()
    mutating func feed(_ f: VisionFrame) -> Bool {
        hold.update(Self.sees(f), now: f.time) == .fired
    }

    /// One hand making the OK sign. Praying hands can read as an OK (thumb resting on a straight index),
    /// so a second hand close by rules it out.
    static func sees(_ f: VisionFrame) -> Bool {
        guard !f.lead.isEmpty, HandGesture.isOK(f.squared) else { return false }
        return f.pair.map { ($0.palms ?? 9) > 2.5 } ?? true
    }
}

/// A pose that has to be held to count, riding out brief misreads (a thumb flickering in or out).
struct HeldGesture {
    enum Result { case idle, holding, fired }
    static let seconds = 0.8
    private var since: CFTimeInterval?
    private var lastSeen: CFTimeInterval = 0
    var isHolding: Bool { since != nil }

    mutating func reset() { since = nil }

    /// Fires once per hold; the pose has to go away before it can fire again.
    mutating func update(_ seen: Bool, now: CFTimeInterval) -> Result {
        if seen {
            lastSeen = now
            if since == nil { since = now }
            if let s = since, s > 0, now - s >= Self.seconds { since = -1; return .fired }
            return since == -1 ? .idle : .holding
        }
        guard since != nil else { return .idle }
        if now - lastSeen > 0.2 { since = nil; return .idle }
        return since == -1 ? .idle : .holding
    }
}

final class HandControl: VisionDriver {
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "visionModeEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "visionModeEnabled") }
    }
    /// What the hand does in Vision Mode: drive the pointer, or pick a quadrant to dictate into.
    enum Style: String { case pointer, quadrants }
    static var style: Style {
        get { Style(rawValue: UserDefaults.standard.string(forKey: "visionStyle") ?? "") ?? .pointer }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "visionStyle") }
    }
    /// Pointer Speed in the menu: scales every speed the thumb gap picks.
    static var baseSpeed: Double {
        get { UserDefaults.standard.object(forKey: "visionPointerBase") as? Double ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: "visionPointerBase") }
    }

    /// Speed from the thumb-to-index gap (tip to tip, in hand sizes: wrist to middle knuckle). Log-linear
    /// through three anchors, so each bit of spread feels like the same step:
    ///   0.55  thumb just off the index           0.25x, fine work
    ///   1.1   thumb relaxed beside the fingers   1x
    ///   1.9   a wide L                           2.5x
    /// Measured on real poses; a closed pinch (below 0.35) is a click, never a speed.
    static func gain(forSpread s: CGFloat) -> CGFloat {
        let (lo, mid, hi): ((CGFloat, CGFloat), (CGFloat, CGFloat), (CGFloat, CGFloat)) = ((0.55, 0.25), (1.1, 1), (1.9, 2.5))
        let s = min(max(s, lo.0), hi.0)
        let (a, b) = s <= mid.0 ? (lo, mid) : (mid, hi)
        let t = (s - a.0) / (b.0 - a.0)
        return exp(log(a.1) + t * (log(b.1) - log(a.1)))
    }

    /// 0 at the slowest speed, 1 at the fastest, for drawing the gap in the mirror.
    static func level(_ g: CGFloat) -> CGFloat { (log(g) - log(0.25)) / (log(2.5) - log(0.25)) }

    enum Pose: String { case none = "NO HAND", track = "POINTING", pinch = "CLICK", drag = "DRAGGING", scroll = "SCROLLING",
                         open = "OPEN HAND", dictate = "DICTATING", other = "RESTING", switching = "FOUR FINGERS · TO QUADRANTS",
                         lockUp = "TWO HANDS · FISTS TO LOCK UP",
                         clear = "PINKY · CLEAR" }

    private(set) var pose: Pose = .none
    var status: String {
        if send.inProgress { return "VISION MODE · SEND" + String(repeating: " ·", count: send.steps) }
        if pose == .scroll {
            let name = scrollDir > 0 ? "SCROLLING UP" : scrollDir < 0 ? "SCROLLING DOWN" : "SCROLL PAUSED"
            return "VISION MODE · " + name + (scrollDir != 0 ? " · \(Int(abs(scrollSpeed) / 10) * 10) PX/S" : "")
        }
        let speed = pose == .track ? String(format: " · %.1f×", gain) : ""
        return "VISION MODE · " + pose.rawValue + speed
    }
    /// Thumb and index tips (Vision coordinates), for drawing the gap in the mirror.
    private(set) var tips: (thumb: CGPoint, index: CGPoint)?
    /// The current speed from the thumb gap (smoothed), already scaled by Pointer Speed.
    private(set) var gain: CGFloat = 1
    private var spread: CGFloat?
    var onIdleTimeout: (() -> Void)?
    var onSwitchStyle: ((HandControl.Style) -> Void)?
    /// Both hands open, then both fists: Lock Up (close every terminal).
    var onLockUp: (() -> Void)?
    private var openToFists = OpenToFists()
    /// The two-hand gesture after a fist dictation pasted: press Return there (as in Quadrants).
    var onSend: (() -> Void)?
    private var send = TwoHandGesture()
    /// The pinky alone, held: clear what was just pasted.
    var onClear: (() -> Void)?
    private var clearHold = HeldGesture()
    private var switchHold = HeldGesture()
    /// Last frame's fingers, so a finger at the line does not flicker (see `HandGesture.extended`).
    private var lastFingers: [Bool]?
    /// For `--test-hand`: when set, pointer moves are reported here instead of posted, and the pointer
    /// position is simulated, so the checks never move the real pointer.
    var dryRun: ((CGPoint) -> Void)?
    private var simulated = CGPoint(x: 500, y: 500)
    /// Fist dictation: true to start (fist held a beat), false to finish (fist opened or hand gone).
    var onDictate: ((Bool) -> Void)?
    private(set) var dictating = false
    var isDictating: Bool { dictating }
    private var fistSince: CFTimeInterval?
    private var fistGoneSince: CFTimeInterval?
    /// Set whenever control pauses: a fist already closed then (say, the one that discarded a scan)
    /// has to open once before it can start dictating.
    private var fistLocked = false

    private var pinched = false
    private var mouseDown = false
    private var downPoint = CGPoint.zero
    private var lastUp: (t: CFTimeInterval, p: CGPoint, clicks: Int) = (0, .zero, 0)
    private var freezeUntil: CFTimeInterval = 0
    private var filter = OneEuro()
    private var lastFiltered: CGPoint?
    private var scrollCarry: CGFloat = 0
    /// Where the two fingers point: 1 straight up, -1 straight down (smoothed sine of the tilt), and
    /// the direction it settled on: 1 up, -1 down, 0 paused (flat, or not held long enough yet).
    private var scrollAim: CGFloat = 0
    private var scrollDir = 0
    /// Signed pixels per second right now, gliding toward `scrollTarget` (what the tilt asks for).
    private(set) var scrollSpeed: CGFloat = 0
    private var scrollTarget: CGFloat = 0
    /// Scrolling is posted from its own 120 Hz timer, not per camera frame (30 fps), so the page moves
    /// in small even steps and speeds up and stops with an ease instead of 30 lurches a second.
    private var glideTimer: DispatchSourceTimer?
    private var lastGlide: CFTimeInterval?
    static let glideHz: Double = 120
    private var scrollSince: CFTimeInterval = 0     // when the two fingers came up
    private var dirSince: CFTimeInterval = 0        // when the current direction began (for the ease-in)
    private var lastScroll: CFTimeInterval = 0
    /// For `--test-hand`: scroll amounts are reported here instead of posted.
    var dryScroll: ((Int32) -> Void)?
    /// Tilt speed curve: flat (within the dead zone) pauses; past it the speed grows exponentially from
    /// reading pace to fast at straight up or down, so each extra degree feels like the same step.
    static let scrollDeadZone: CGFloat = 15         // degrees from flat; once going, it holds down to 10
    static let scrollSlowest: CGFloat = 30          // px/s just past the dead zone
    static let scrollFastest: CGFloat = 1200        // px/s at full tilt
    /// Full tilt: straight up is easy, but a wrist only bends the fingers about 60 degrees down, so
    /// down reaches top speed there (and every speed in between sooner).
    static let scrollUpFull: CGFloat = 90
    static let scrollDownFull: CGFloat = 60
    private var lastHand = CACurrentMediaTime()
    private var missedSince: CFTimeInterval?

    func stop() {
        endDictation()
        switchHold.reset()
        clearHold.reset()
        send.reset()
        lastFingers = nil
        fistLocked = true
        release(at: pointer())
        pose = .none
        tips = nil
        resetMotion()
        glideTimer?.cancel(); glideTimer = nil; lastGlide = nil
        scrollSpeed = 0; scrollCarry = 0
    }

    /// Signed scroll speed (px/s, positive up) for a finger tilt in degrees above flat (negative below).
    /// Inside the dead zone it is 0; past it, exponential from `scrollSlowest` to `scrollFastest` at
    /// full tilt (90 up, 60 down).
    static func scrollRate(tilt deg: CGFloat, deadZone: CGFloat = scrollDeadZone) -> CGFloat {
        let full = deg < 0 ? scrollDownFull : scrollUpFull
        let a = min(full, abs(deg))
        guard a > deadZone else { return 0 }
        let t = (a - deadZone) / (full - deadZone)
        return (deg < 0 ? -1 : 1) * scrollSlowest * pow(scrollFastest / scrollSlowest, t)
    }

    /// Two fingers out: scroll the way they tilt, faster the steeper. Flat (pointing sideways) pauses.
    /// It waits 0.2 s after the fingers come up (so passing through two fingers on the way to another
    /// shape scrolls nothing); the 120 Hz glide eases it in and out.
    /// The thumb gap plays no part here (it is the pointer's speed).
    private func scroll(_ j: HandGesture.Joints, now: CFTimeInterval) {
        let dt = min(0.1, max(0, now - lastScroll))
        lastScroll = now
        guard let im = j[.indexMCP], let mm = j[.middleMCP], let it = j[.indexTip], let mt = j[.middleTip] else { return }
        // Knuckles to fingertips, in true proportions (Vision's y is up).
        let v = CGPoint(x: (it.x + mt.x - im.x - mm.x) / 2, y: (it.y + mt.y - im.y - mm.y) / 2)
        let len = hypot(v.x, v.y)
        guard len > 0 else { return }
        scrollAim += (v.y / len - scrollAim) * 0.3
        let tilt = asin(min(1, max(-1, scrollAim))) * 180 / .pi
        // A little stickier once going, so hovering at the edge of the dead zone does not stutter.
        let target = Self.scrollRate(tilt: tilt, deadZone: scrollDir == 0 ? Self.scrollDeadZone : Self.scrollDeadZone - 5)
        let dir = target > 0 ? 1 : target < 0 ? -1 : 0
        if dir != scrollDir { scrollDir = dir; dirSince = now }
        // The glide eases the speed in and out; here we only say where it should head.
        scrollTarget = now - scrollSince >= 0.2 ? target : 0
        _ = dt
        if scrollTarget != 0 { startGlide() }
    }

    /// One glide step: ease the speed toward the target (0.15 s to speed up, 0.06 s to stop, so a
    /// stop is soft but short), and post whatever whole pixels that adds up to.
    func glide(at now: CFTimeInterval) {
        let dt = min(0.05, max(0, now - (lastGlide ?? now)))
        lastGlide = now
        let tau: CGFloat = scrollTarget == 0 || scrollTarget.sign != scrollSpeed.sign ? 0.06 : 0.15
        scrollSpeed += (scrollTarget - scrollSpeed) * (1 - exp(-CGFloat(dt) / tau))
        if scrollTarget == 0 && abs(scrollSpeed) < 12 { scrollSpeed = 0; scrollCarry = 0 }
        scrollCarry += scrollSpeed * CGFloat(dt)
        let px = scrollCarry.rounded(.towardZero)
        if px != 0 { scrollCarry -= px; postScroll(px) }
        if scrollSpeed == 0 && scrollTarget == 0 { glideTimer?.cancel(); glideTimer = nil; lastGlide = nil }
    }

    private func startGlide() {
        guard dryRun == nil, glideTimer == nil else { return }   // the self-test steps `glide` itself
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1 / Self.glideHz, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.glide(at: CACurrentMediaTime()) }
        glideTimer = t
        t.resume()
    }

    private func postScroll(_ px: CGFloat) {
        guard px != 0 else { return }
        // Positive scrolls toward the top of the page, the same sign the earlier move-to-scroll used.
        if dryRun != nil { dryScroll?(Int32(px)); return }
        // Marked continuous, like a trackpad, so apps scroll by the exact pixels instead of line steps.
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(px), wheel2: 0, wheel3: 0)
        e?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e?.post(tap: .cghidEventTap)
    }

    /// Forget where the hand was, so the next pointing starts from rest instead of jumping.
    private func resetMotion() {
        filter.reset()
        lastFiltered = nil
        scrollDir = 0
        scrollTarget = 0   // the glide eases to a stop on its own
    }

    func handle(_ frame: VisionFrame) {
        let now = frame.time
        // The two-hand gesture sends what the fist just dictated. It goes first (it can finish with no
        // hand in view), and while it is underway nothing else reads the hands.
        let sent = send.feed(frame)
        if sent || send.inProgress {
            endDictation()
            release(at: pointer())
            switchHold.reset()
            pose = .other
            resetMotion()
            if sent { onSend?() }
            return
        }
        let j = frame.lead
        guard let wrist = j[.wrist], let knuckle = j[.indexMCP], let mid = j[.middleMCP] else {
            // Ride out a few dropped frames (a drag must not end because one frame missed the hand).
            if missedSince == nil { missedSince = now }
            if now - (missedSince ?? now) > 0.3 { lost(now) }
            return
        }
        missedSince = nil
        lastHand = now
        let size = hypot(wrist.x - mid.x, wrist.y - mid.y)
        guard size > 0.025 else { lost(now); return }
        // Lock Up: two open hands, then two fists. Meanwhile nothing else reads them, and a fist left
        // over afterwards has to open before it can dictate.
        let lockUp = openToFists.feed(frame)
        if lockUp || openToFists.busy(at: now) {
            endDictation()
            fistLocked = true
            release(at: pointer())
            switchHold.reset()
            pose = .lockUp
            resetMotion()
            if lockUp { onLockUp?() }
            return
        }
        // Two hands close together (praying, or resting one on the other) read as four fingers or an
        // open hand; they drive nothing here, as in Quadrants.
        if (frame.pair?.palms ?? 9) < 2.5 {
            endDictation()
            release(at: pointer())
            switchHold.reset()
            pose = .other
            resetMotion()
            return
        }

        // Pinch: thumb tip meets index tip while the index tip is out in front, not tucked in a fist.
        let tipsDistance = j[.thumbTip].flatMap { t in j[.indexTip].map { hypot(t.x - $0.x, t.y - $0.y) / size } }
        let indexOut = j[.indexTip].map { hypot($0.x - wrist.x, $0.y - wrist.y) > size * 1.1 } ?? false
        if let d = tipsDistance {
            // Never from a scroll: slowing a scroll brings the thumb in, and that must not click.
            // Nor from an OK sign: the thumb meets the index there too, with the other three fingers up.
            if pinched { if d > 0.6 { pinched = false } }
            else if d < 0.35 && indexOut && pose != .scroll && !HandGesture.isOK(frame.squared) { pinched = true }
            spread = spread.map { $0 + (d - $0) * 0.3 } ?? d
        } else if !mouseDown {
            pinched = false
        }
        if let t = j[.thumbTip], let i = j[.indexTip] { tips = (t, i) } else { tips = nil }
        // The gap sets the speed while aiming; while pinched it is closed, so it holds its last value.
        if !pinched, let s = spread { gain = Self.gain(forSpread: s) * CGFloat(Self.baseSpeed) }
        let reading = HandGesture.extended(j, last: lastFingers)
        let ext = reading?.fingers
        lastFingers = ext
        let noFingers = ext.map { !$0.contains(true) } == true
        // A closed fist; a thumbs up is not a fist, but a thumb the pose model invents off to the side
        // of a fist that hides it (one frame in ten on HaGRID fists) still is.
        let isFist = !pinched && noFingers && !indexOut && HandGesture.classify(frame.squared) != .thumbsUp
        let isScroll = !pinched && ext == [true, true, false, false]
        let isPoint = ext.map { $0[0] && !$0[1] } == true
        let isOpen = !pinched && (ext?.filter { $0 }.count ?? 0) >= 3

        let m = CGPoint(x: 1 - knuckle.x, y: knuckle.y)   // mirrored, as in the preview

        // Fist: hold a beat to start dictating; opening the hand (for a moment) finishes it. While
        // dictating the thumb is ignored, so one drifting out of the fist does not cut the recording off.
        if isFist || (dictating && noFingers && !pinched) {
            fistGoneSince = nil
            if fistSince == nil { fistSince = now }
            release(at: pointer())
            resetMotion()
            if !dictating, !fistLocked, now - (fistSince ?? now) >= 0.35 {
                dictating = true
                onDictate?(true)
            }
            pose = dictating ? .dictate : .other
            return
        }
        fistSince = nil
        fistLocked = false
        if dictating {
            // A fist briefly misread mid-sentence must not cut the recording off.
            if fistGoneSince == nil { fistGoneSince = now }
            if now - (fistGoneSince ?? now) < 0.3 { pose = .dictate; return }
            endDictation()
        }
        // Four fingers up with the thumb tucked, held: switch to Quadrant Dictation.
        let isFour = !pinched && ext == [true, true, true, true] && HandGesture.thumb(frame.squared) == .tucked
        switch switchHold.update(isFour, now: now) {
        case .fired:
            release(at: pointer())
            resetMotion()
            onSwitchStyle?(.quadrants)
            return
        case .holding:
            release(at: pointer())
            resetMotion()
            pose = .switching
            return
        case .idle:
            break
        }
        // The pinky alone, held: clear what was just pasted. It already moves nothing (not a point).
        switch clearHold.update(!pinched && HandGesture.isPinky(frame.squared, last: ext), now: now) {
        case .fired:
            release(at: pointer())
            resetMotion()
            pose = .clear
            onClear?()
            return
        case .holding:
            release(at: pointer())
            resetMotion()
            pose = .clear
            return
        case .idle:
            break
        }
        if isOpen {
            release(at: pointer())
            pose = .open
            resetMotion()
            return
        }
        if isScroll {
            release(at: pointer())
            if pose != .scroll { resetMotion(); scrollSince = now; scrollAim = 0; lastScroll = now }
            pose = .scroll
            scroll(frame.squared, now: now)
            return
        }
        // Only a pointing hand (or one mid-pinch or drag) moves the pointer; any other shape rests.
        guard isPoint || pinched || mouseDown else {
            pose = .other
            resetMotion()
            return
        }
        if pose != .track && pose != .pinch && pose != .drag { resetMotion() }

        // Relative, like a trackpad: the knuckle's movement (smoothed) times the speed. The knuckle
        // barely moves when the thumb does, so opening or closing the gap does not nudge the pointer.
        // One camera-frame width of hand travel is about 1.7 screen widths at 1x.
        let unit = (NSScreen.main?.frame.width ?? 1440) / 0.6
        let f = filter.filter(CGPoint(x: m.x * unit, y: -m.y * unit), t: now)
        let step = lastFiltered.map { CGPoint(x: f.x - $0.x, y: f.y - $0.y) } ?? .zero
        lastFiltered = f

        if pinched && !mouseDown { press(at: pointer(), now: now) }
        if !pinched && mouseDown { release(at: pointer(), now: now) }
        pose = mouseDown ? (hypot(pointer().x - downPoint.x, pointer().y - downPoint.y) > 6 ? .drag : .pinch) : .track
        // A drag moves at normal speed; the gap is closed then, so it cannot choose one.
        let speed = mouseDown ? CGFloat(Self.baseSpeed) : gain
        // Hold still for a moment around a pinch so the click lands where you aimed.
        if now >= freezeUntil, step != .zero {
            let p = pointer()
            move(to: Self.clamp(CGPoint(x: p.x + step.x * speed, y: p.y + step.y * speed)))
        }
    }

    private func endDictation() {
        fistSince = nil
        fistGoneSince = nil
        guard dictating else { return }
        dictating = false
        onDictate?(false)
    }

    private func lost(_ now: CFTimeInterval) {
        // Hand out of view ends a fist dictation, after the same short grace as a drag.
        endDictation()
        release(at: pointer())
        pose = .none
        tips = nil
        lastFingers = nil
        resetMotion()
        if now - lastHand > 15 * 60 { lastHand = now; onIdleTimeout?() }
    }

    // MARK: Events

    /// Current pointer in CG global coordinates (top-left origin).
    private func pointer() -> CGPoint { dryRun == nil ? CGEvent(source: nil)?.location ?? .zero : simulated }

    private func move(to p: CGPoint) {
        if let dryRun { simulated = p; dryRun(p); return }
        let type: CGEventType = mouseDown ? .leftMouseDragged : .mouseMoved
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private func press(at p: CGPoint, now: CFTimeInterval = CACurrentMediaTime()) {
        guard !mouseDown else { return }
        mouseDown = true
        downPoint = p
        freezeUntil = now + 0.15
        guard dryRun == nil else { return }   // the self-test never clicks for real
        let clicks = now - lastUp.t < 0.45 && hypot(p.x - lastUp.p.x, p.y - lastUp.p.y) < 12 ? lastUp.clicks + 1 : 1
        let e = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)
        e?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        e?.post(tap: .cghidEventTap)
        lastUp.clicks = clicks
    }

    private func release(at p: CGPoint, now: CFTimeInterval = CACurrentMediaTime()) {
        guard mouseDown else { return }
        mouseDown = false
        freezeUntil = now + 0.12
        guard dryRun == nil else { return }
        let e = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)
        e?.setIntegerValueField(.mouseEventClickState, value: Int64(lastUp.clicks))
        e?.post(tap: .cghidEventTap)
        lastUp = (now, p, lastUp.clicks)
    }

    /// Every display together, in CG global coordinates (top-left origin).
    static func screenUnion() -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return NSScreen.screens.reduce(CGRect.null) { r, s in
            r.union(CGRect(x: s.frame.minX, y: top - s.frame.maxY, width: s.frame.width, height: s.frame.height))
        }
    }

    private static func clamp(_ p: CGPoint) -> CGPoint {
        let b = screenUnion()
        guard !b.isNull else { return p }
        return CGPoint(x: min(max(p.x, b.minX), b.maxX - 1), y: min(max(p.y, b.minY), b.maxY - 1))
    }
}

/// One Euro filter (Casiez et al.): smooth when the hand is still, responsive when it moves.
struct OneEuro {
    var minCutoff = 1.4, beta = 0.012, dCutoff = 1.0
    private var last: (p: CGPoint, dp: CGPoint, t: CFTimeInterval)?

    mutating func reset() { last = nil }

    mutating func filter(_ p: CGPoint, t: CFTimeInterval) -> CGPoint {
        guard let l = last else { last = (p, .zero, t); return p }
        let dt = max(1.0 / 120, t - l.t)
        func alpha(_ cutoff: Double) -> CGFloat { CGFloat(1 / (1 + (1 / (2 * .pi * cutoff)) / dt)) }
        let dx = CGPoint(x: (p.x - l.p.x) / dt, y: (p.y - l.p.y) / dt)
        let ad = alpha(dCutoff)
        let dp = CGPoint(x: l.dp.x + ad * (dx.x - l.dp.x), y: l.dp.y + ad * (dx.y - l.dp.y))
        let a = alpha(minCutoff + beta * Double(hypot(dp.x, dp.y)))
        let out = CGPoint(x: l.p.x + a * (p.x - l.p.x), y: l.p.y + a * (p.y - l.p.y))
        last = (out, dp, t)
        return out
    }
}
