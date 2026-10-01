import AppKit
import Vision

/// Vision Mode: control the Mac with one hand in front of the camera, with the mirror pinned under
/// the notch so you can see what GoldWare sees. The camera stays on (green light) while the mode is on
/// and turns itself off after 15 minutes without a hand.
///   Point (index finger up)   move the pointer like a trackpad. The gap between thumb and index tips
///                             sets the speed: wide is fast, close is fine control
///   Pinch and let go          click; twice quickly to double-click
///   Pinch, hold, and move     scroll: the page follows the hand (like Apple Vision Pro); let go mid-move to fling
///   Open hand, fist           nothing: rest here, the pointer stays put
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
/// Vision Mode (`LockGesture`, praying hands held, locks it again).
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

/// Send (pointer and Quadrants): the diamond (index tips touching, thumb tips touching, palms apart),
/// held 0.2 s, then the tips let go. It never goes through praying hands: closing the diamond into
/// prayer is the lock instead, so prayer calls a send off. The release counts once the tips read apart,
/// or once they have not read close for 0.25 s (a fingertip lost as the hands part). Hands still
/// touching at the tips while the palms close toward prayer are not a release.
struct SendGesture {
    private var diamondSince: CFTimeInterval?
    private var diamondAt: CFTimeInterval?       // last frame of the diamond
    private var closeAt: CFTimeInterval?         // last frame both tip pairs were still close

    /// 0 or 1 step done, for the footer's dot.
    private(set) var steps = 0
    var inProgress: Bool { steps > 0 }

    mutating func reset() { diamondSince = nil; diamondAt = nil; closeAt = nil; steps = 0 }

    /// Feeds one frame; true on the frame the tips let go.
    mutating func feed(_ f: VisionFrame) -> Bool {
        let t = f.time
        let pair = f.pair
        if pair?.together == true { reset(); return false }
        if let p = pair, p.diamond {
            if diamondSince == nil { diamondSince = t }
            diamondAt = t
        } else if let at = diamondAt, t - at > 1.0 {
            reset()
        }
        if let p = pair, (p.index ?? 9) < 0.6, (p.thumb ?? 9) < 0.6 { closeAt = t }
        let held = diamondSince.map { since in diamondAt.map { $0 - since >= 0.2 } ?? false } ?? false
        steps = held ? 1 : 0
        guard held, let at = closeAt ?? diamondAt, pair?.apart == true || t - at >= 0.25 else { return false }
        reset()
        return true
    }
}

/// The lock: praying hands (palms together, fingertips touching) held for a moment (`HeldGesture`,
/// 0.8 s, riding out brief misreads, since praying hands hide each other's joints).
struct LockGesture {
    private var hold = HeldGesture()

    mutating func reset() { hold.reset() }

    /// Feeds one frame; true on the frame the prayer has held.
    mutating func feed(_ f: VisionFrame) -> Bool {
        hold.update(f.pair?.together == true, now: f.time) == .fired
    }
}

/// Let's work by hand (pointer style only): both hands show thumb, index, and middle (ring and little
/// curled), the two thumb tips touch, then the hands pull apart. The touch has to last 0.2 s and the
/// pull has to follow within 1.5 s, so hands passing near each other do nothing. Fires once; the hands
/// have to drop the shape before it can fire again.
struct ThumbPull {
    private var touchSince: CFTimeInterval?
    private var touchAt: CFTimeInterval?
    private var spent = false
    private var seenAt: CFTimeInterval = -9     // last frame both hands showed the shape

    /// Both hands are in the shape (or were a moment ago): the pointer should rest meanwhile, since
    /// one hand alone in this shape reads as two fingers up (scroll).
    func busy(at t: CFTimeInterval) -> Bool { t - seenAt < 0.5 }

    /// Index and middle straight, ring and little curled, thumb not folded in.
    static func shape(_ j: HandGesture.Joints) -> Bool {
        guard let e = HandGesture.extended(j), e.fingers == [true, true, false, false],
              let thumb = HandGesture.thumb(j) else { return false }
        return thumb != .tucked
    }

    mutating func reset() { touchSince = nil; touchAt = nil }

    /// Feeds one frame; true on the frame the hands pull apart.
    mutating func feed(_ f: VisionFrame) -> Bool {
        let t = f.time
        let both = !f.lead.isEmpty && !f.second.isEmpty && Self.shape(f.squared) && Self.shape(f.secondSquared)
        // Spent until the shape has been gone for half a second (checked before this frame counts).
        if spent, t - seenAt > 0.5 { spent = false }
        if both { seenAt = t }
        if spent { return false }
        let gap = f.pair?.thumb
        if both, let g = gap, g < 0.45 {
            if touchSince == nil { touchSince = t }
            touchAt = t
        } else if let at = touchAt, t - at > 1.5 {
            reset()
        }
        guard let since = touchSince, let at = touchAt, at - since >= 0.2,
              t - seenAt < 0.3, (gap ?? 0) > 1.2 else { return false }
        reset()
        spent = true
        return true
    }
}

/// Lock Up and Clear Out by hand (pointer style only). Both start with both hands open (four fingers
/// up) for a beat. Then both close into fists: Lock Up. Or only one closes and the other stays open:
/// Clear Out. The open hands have to last 0.3 s and the closing has to start within 1 s. Two fists
/// fire after 0.15 s; one fist has to hold 0.5 s next to the open hand, so two hands that close a
/// moment apart still lock up. Fists that were never open do nothing. Fires once; the hands have to
/// drop the shapes before it can fire again.
struct OpenToFists {
    enum Outcome: Equatable { case lockUp, clearOut }
    private var openSince: CFTimeInterval?
    private var openAt: CFTimeInterval?
    private var fistSince: CFTimeInterval?
    private var oneFistSince: CFTimeInterval?
    private var spent = false
    private var seenAt: CFTimeInterval = -9     // last frame of the gesture: both open, fists, or one of each once armed

    /// The gesture is underway (or just was): the pointer waits.
    func busy(at t: CFTimeInterval) -> Bool { t - seenAt < 0.5 }

    static func fingers(_ j: HandGesture.Joints) -> [Bool]? { j.isEmpty ? nil : HandGesture.extended(j)?.fingers }

    mutating func reset() { openSince = nil; openAt = nil; fistSince = nil; oneFistSince = nil }

    /// Feeds one frame; the outcome on the frame that completes it.
    mutating func feed(_ f: VisionFrame) -> Outcome? {
        let t = f.time
        let a = Self.fingers(f.squared), b = Self.fingers(f.secondSquared)
        let up = [true, true, true, true], down = [false, false, false, false]
        // Open hands apart: praying hands read as two open hands too.
        let open = a == up && b == up && (f.pair?.palms ?? 0) > 1.5
        let fists = a == down && b == down
        let oneFist = (a == down && b == up) || (a == up && b == down)
        if spent, t - seenAt > 0.5 { spent = false }
        if open || fists || (oneFist && (openSince != nil || spent)) { seenAt = t }
        if spent { return nil }
        if open {
            if openSince == nil { openSince = t }
            openAt = t
            fistSince = nil
            oneFistSince = nil
            return nil
        }
        // The open hands count only if they were held, and only for a moment after they close.
        guard let since = openSince, let at = openAt, at - since >= 0.3,
              t - at < 1.0 || fistSince != nil || oneFistSince != nil else {
            if let at = openAt, t - at > 0.2 { reset() }   // a brief misread keeps the open hands
            return nil
        }
        if fists {
            oneFistSince = nil
            if fistSince == nil { fistSince = t }
            guard t - (fistSince ?? t) >= 0.15 else { return nil }
            reset()
            spent = true
            return .lockUp
        }
        if oneFist {
            fistSince = nil
            if oneFistSince == nil { oneFistSince = t }
            guard t - (oneFistSince ?? t) >= 0.5 else { return nil }
            reset()
            spent = true
            return .clearOut
        }
        if t - at > 1.0 { reset() }
        return nil
    }
}

/// The passcode: Vision Mode turns on locked, and the hands drive nothing until the two-hand gesture.
/// The mirror only counts the steps with dots and never says what they are. After a minute with no
/// hand in view it locks again, and praying hands held (`LockGesture`) lock it on the spot.
struct VisionLock {
    enum State: Equatable { case locked, open }
    private(set) var state = State.locked
    private var lastHand: CFTimeInterval = 0
    private var settleUntil: CFTimeInterval = 0
    private var gesture = TwoHandGesture()
    private var closer = LockGesture()
    /// The prayer that just locked, until the hands have been out of it for a second: lowering them from
    /// prayer passes through the diamond and apart, which is the unlock, so that prayer cannot start one.
    private var lockedPrayerAt: CFTimeInterval?
    static let relockAfter = 60.0

    var steps: Int { gesture.steps }
    var status: String { state == .locked ? "LOCKED" + String(repeating: " ·", count: steps) : "" }

    mutating func lock() { state = .locked; lastHand = 0; gesture.reset(); closer.reset(); lockedPrayerAt = nil }

    /// Seconds since a hand was last in view.
    func idle(at now: CFTimeInterval) -> CFTimeInterval { lastHand == 0 ? 0 : now - lastHand }

    /// Feeds one frame; returns true when the frame may drive the hand. `unlocked` is set on the frame
    /// the passcode is accepted, `relocked` on the frame the lock gesture locks it again.
    mutating func admit(_ f: VisionFrame, unlocked: inout Bool, relocked: inout Bool) -> Bool {
        let t = f.time
        if lastHand == 0 { lastHand = t }
        let away = t - lastHand
        if !f.lead.isEmpty { lastHand = t }
        if state == .open {
            if away > Self.relockAfter { lock(); return false }
            if closer.feed(f) {
                lock()
                lockedPrayerAt = t
                relocked = true
                return false
            }
            return t >= settleUntil   // a beat for the hands to come down before anything moves
        }
        if let at = lockedPrayerAt {
            if f.pair?.together == true { lockedPrayerAt = t } else if t - at > 1.0 { lockedPrayerAt = nil }
            return false
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
    init(seconds: Double = 0.8) { self.seconds = seconds }
    var seconds = 0.8
    private var since: CFTimeInterval?
    private var lastSeen: CFTimeInterval = 0
    var isHolding: Bool { since != nil }

    mutating func reset() { since = nil }

    /// Fires once per hold; the pose has to go away before it can fire again.
    mutating func update(_ seen: Bool, now: CFTimeInterval) -> Result {
        if seen {
            lastSeen = now
            if since == nil { since = now }
            if let s = since, s > 0, now - s >= seconds { since = -1; return .fired }
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

    enum Pose: String { case none = "NO HAND", track = "POINTING", pinch = "PINCHED", scroll = "SCROLLING",
                         open = "OPEN HAND", other = "RESTING", switching = "FOUR FINGERS · TO QUADRANTS",
                         letsWork = "LET'S WORK · PULL APART", lockUp = "TWO HANDS · FISTS LOCK UP · ONE FIST CLEARS OUT",
                         clear = "PINKY · CLEAR", shaka = "SHAKA · SEND" }

    private(set) var pose: Pose = .none {
        didSet { if pose != oldValue { PoseLog.shared.write("\(oldValue.rawValue) -> \(pose.rawValue)  \(diag)") } }
    }
    /// This frame's raw reading, for the pose log: fingers up (index, middle, ring, little), thumb to
    /// index tip in hand sizes.
    private var diag = ""
    var status: String {
        if send.inProgress { return "VISION MODE · SEND" + String(repeating: " ·", count: send.steps) }
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
    /// Both hands thumb, index, and middle, thumbs touching, pulled apart: open Let's work.
    var onLetsWork: (() -> Void)?
    private var thumbPull = ThumbPull()
    /// Both hands open, then both fists: Lock Up (close every terminal).
    var onLockUp: (() -> Void)?
    /// Both hands open, then one fist: Clear Out (close the Hermes terminals nobody wrote in).
    var onClearOut: (() -> Void)?
    private var openToFists = OpenToFists()
    /// The two-hand gesture after a hand dictation pasted: press Return there (as in Quadrants).
    var onSend: (() -> Void)?
    private var send = SendGesture()
    /// The pinky alone, held: clear what was just pasted.
    var onClear: (() -> Void)?
    private var clearHold = HeldGesture()
    private var switchHold = HeldGesture()
    /// The shaka held half a second sends, like the diamond.
    private var shakaHold = HeldGesture(seconds: 0.5)
    /// Set once the shaka sends, until the hand leaves the little-finger shape: tucking the thumb to
    /// lower it reads as the pinky clear, which must not undo the send.
    private var shakaSent = false
    /// Last frame's fingers, so a finger at the line does not flicker (see `HandGesture.extended`).
    private var lastFingers: [Bool]?
    /// For `--test-hand`: when set, pointer moves are reported here instead of posted, and the pointer
    /// position is simulated, so the checks never move the real pointer.
    var dryRun: ((CGPoint) -> Void)?
    /// For `--test-hand`: clicks (with their click count) are reported here instead of posted.
    var dryClick: ((Int) -> Void)?
    private var simulated = CGPoint(x: 500, y: 500)
    /// The pointer style never dictates (dictation lives in Quadrants); the protocol asks.
    var isDictating: Bool { false }

    private var pinched = false
    private var tipsAt: CFTimeInterval = -9          // last frame both tips were seen
    private var pinchAt: CFTimeInterval = 0          // when this pinch closed
    private var pinchTravel = CGPoint.zero           // hand travel (pointer px at 1x) since it closed
    private var caught = false                       // this pinch stopped a fling, so letting go does not click
    private var lastUp: (t: CFTimeInterval, p: CGPoint, clicks: Int) = (0, .zero, 0)
    private var freezeUntil: CFTimeInterval = 0
    private var filter = OneEuro()
    private var lastFiltered: CGPoint?
    /// Pinch and move scrolls like Apple Vision Pro: the page follows the hand while pinched, and a
    /// quick release flings it on. Camera frames only add to `scrollOwed`; a 120 Hz timer pays it out
    /// in small steps (and the fling in `coast`), so the page moves evenly instead of 30 lurches a second.
    private var scrollOwed = CGPoint.zero            // px the hand has moved that are not posted yet
    private var scrollCarry = CGPoint.zero           // fractions of a pixel left over
    private var payRate = CGPoint.zero               // px/s that pays `scrollOwed` off by the next frame
    private var frameGap: CGFloat = 1.0 / 30         // smoothed time between camera frames
    private(set) var coast = CGPoint.zero            // fling after release, px/s
    private var handVelocity = CGPoint.zero          // smoothed page speed while scrolling, px/s
    private var glideTimer: DispatchSourceTimer?
    private var lastGlide: CFTimeInterval?
    static let glideHz: Double = 120
    private var lastFrameAt: CFTimeInterval = 0      // last camera frame; the glide stops if they stop
    /// For `--test-hand`: scroll amounts (x sideways, y up and down, as posted) reported instead of posted.
    var dryScroll: ((CGPoint) -> Void)?
    /// Hand travel, as a share of the camera frame, before a pinch scrolls instead of clicking.
    static let scrollStart: CGFloat = 0.015
    /// Page pixels per pointer pixel of hand travel (times Pointer Speed).
    static let scrollGain: CGFloat = 1.5
    /// A pinch let go within this long without moving clicks; held longer it does nothing.
    static let tapMax: CFTimeInterval = 0.6
    /// Fling: only above this release speed, capped, and slowing with this time constant.
    static let flingMin: CGFloat = 250
    static let flingMax: CGFloat = 5000
    static let coastTau: CGFloat = 0.35
    private var lastHand = CACurrentMediaTime()
    private var missedSince: CFTimeInterval?

    deinit { glideTimer?.cancel() }

    func stop() {
        switchHold.reset()
        clearHold.reset()
        shakaHold.reset()
        shakaSent = false
        send.reset()
        lastFingers = nil
        pinched = false
        pose = .none
        tips = nil
        resetMotion()
        stopScroll()
    }

    /// One glide step: pay out the hand travel owed (evenly over one camera frame), plus the fling,
    /// which slows on its own, and post whatever whole pixels that adds up to.
    func glide(at now: CFTimeInterval) {
        let dt = CGFloat(min(0.05, max(0, now - (lastGlide ?? now))))
        lastGlide = now
        // No camera frame for half a second (camera taken, sleep, a stall): nothing says keep going.
        if now - lastFrameAt > 0.5 { coast = .zero; scrollOwed = .zero }
        // Even steps: what one frame owes is spread across the ticks until the next frame.
        func pay(_ owed: CGFloat, _ rate: CGFloat) -> CGFloat { owed > 0 ? min(owed, max(0, rate * dt)) : max(owed, min(0, rate * dt)) }
        var out = CGPoint(x: pay(scrollOwed.x, payRate.x), y: pay(scrollOwed.y, payRate.y))
        scrollOwed.x -= out.x; scrollOwed.y -= out.y
        let decay = exp(-dt / Self.coastTau)
        coast = CGPoint(x: coast.x * decay, y: coast.y * decay)
        if hypot(coast.x, coast.y) < 20 { coast = .zero }
        out.x += coast.x * dt; out.y += coast.y * dt
        scrollCarry.x += out.x; scrollCarry.y += out.y
        let px = CGPoint(x: scrollCarry.x.rounded(.towardZero), y: scrollCarry.y.rounded(.towardZero))
        if px != .zero { scrollCarry.x -= px.x; scrollCarry.y -= px.y; postScroll(px) }
        if coast == .zero && hypot(scrollOwed.x, scrollOwed.y) < 0.5 {
            scrollOwed = .zero
            glideTimer?.cancel(); glideTimer = nil; lastGlide = nil
        }
    }

    private func startGlide() {
        guard dryRun == nil, glideTimer == nil else { return }   // the self-test steps `glide` itself
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1 / Self.glideHz, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.glide(at: CACurrentMediaTime()) }
        glideTimer = t
        t.resume()
    }

    /// Stop the page dead: nothing owed, no fling.
    private func stopScroll() {
        scrollOwed = .zero; scrollCarry = .zero; coast = .zero; handVelocity = .zero; payRate = .zero
        glideTimer?.cancel(); glideTimer = nil; lastGlide = nil
    }

    /// `d.y` positive moves the content down (toward the top of the page), `d.x` positive moves it right.
    private func postScroll(_ d: CGPoint) {
        if dryRun != nil { dryScroll?(d); return }
        // Marked continuous, like a trackpad, so apps scroll by the exact pixels instead of line steps.
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(d.y), wheel2: Int32(d.x), wheel3: 0)
        e?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e?.post(tap: .cghidEventTap)
    }

    /// Forget where the hand was, so the next pointing starts from rest instead of jumping.
    private func resetMotion() {
        filter.reset()
        lastFiltered = nil
    }

    /// Leave any pinch without clicking or flinging (another gesture took over).
    private func dropPinch() {
        pinched = false
        if pose == .scroll { handVelocity = .zero }
    }

    func handle(_ frame: VisionFrame) {
        let now = frame.time
        let frameDt = CGFloat(max(1.0 / 120, min(0.2, now - lastFrameAt)))
        lastFrameAt = now
        frameGap += (min(frameDt, 0.1) - frameGap) * 0.2
        // The two-hand gesture sends what was just dictated. It goes first (it can finish with no
        // hand in view), and while it is underway nothing else reads the hands.
        let sent = send.feed(frame)
        if sent || send.inProgress {
            dropPinch()
            switchHold.reset()
            pose = .other
            resetMotion()
            if sent { onSend?() }
            return
        }
        let j = frame.lead
        guard let wrist = j[.wrist], let knuckle = j[.indexMCP], let mid = j[.middleMCP] else {
            // Ride out a few dropped frames (a scroll must not end because one frame missed the hand).
            if missedSince == nil { missedSince = now }
            if now - (missedSince ?? now) > 0.3 { lost(now) }
            return
        }
        missedSince = nil
        lastHand = now
        let size = hypot(wrist.x - mid.x, wrist.y - mid.y)
        guard size > 0.025 else { lost(now); return }
        // Let's work: while both hands hold the shape nothing else reads them.
        let home = thumbPull.feed(frame)
        if home || thumbPull.busy(at: now) {
            dropPinch()
            switchHold.reset()
            pose = .letsWork
            resetMotion()
            if home { onLetsWork?() }
            return
        }
        // Lock Up (two open hands, then two fists) and Clear Out (then one fist). Meanwhile nothing else
        // reads them.
        let ending = openToFists.feed(frame)
        if ending != nil || openToFists.busy(at: now) {
            dropPinch()
            switchHold.reset()
            pose = .lockUp
            resetMotion()
            if ending == .lockUp { onLockUp?() }
            if ending == .clearOut { onClearOut?() }
            return
        }
        // Two hands close together (praying, or resting one on the other) read as four fingers or an
        // open hand; they drive nothing here, as in Quadrants.
        if (frame.pair?.palms ?? 9) < 2.5 {
            dropPinch()
            switchHold.reset()
            pose = .other
            resetMotion()
            return
        }

        // Pinch: thumb tip meets index tip while the index tip is out in front, not tucked in a fist.
        let tipsDistance = j[.thumbTip].flatMap { t in j[.indexTip].map { hypot(t.x - $0.x, t.y - $0.y) / size } }
        let indexOut = j[.indexTip].map { hypot($0.x - wrist.x, $0.y - wrist.y) > size * 1.1 } ?? false
        if let d = tipsDistance {
            tipsAt = now
            // Never from an OK sign: the thumb meets the index there too, with the other three fingers up.
            if pinched { if d > 0.6 { pinched = false } }
            else if d < 0.35 && indexOut && !HandGesture.isOK(frame.squared) { pinched = true }
            spread = spread.map { $0 + (d - $0) * 0.3 } ?? d
        } else if now - tipsAt > 0.3 {
            // A moving hand can lose a fingertip for a few frames; that must not end the scroll.
            pinched = false
        }
        if let t = j[.thumbTip], let i = j[.indexTip] { tips = (t, i) } else { tips = nil }
        // The gap sets the speed while aiming; while pinched it is closed, so it holds its last value.
        if !pinched, let s = spread { gain = Self.gain(forSpread: s) * CGFloat(Self.baseSpeed) }
        let reading = HandGesture.extended(j, last: lastFingers)
        let ext = reading?.fingers
        lastFingers = ext
        let isPoint = ext.map { $0[0] && !$0[1] } == true
        let isOpen = !pinched && (ext?.filter { $0 }.count ?? 0) >= 3
        diag = (ext.map { $0.map { $0 ? "1" : "0" }.joined() } ?? "????") + String(format: " tips %.2f", tipsDistance ?? -1)

        let m = CGPoint(x: 1 - knuckle.x, y: knuckle.y)   // mirrored, as in the preview

        // Four fingers up with the thumb tucked, held: switch to Quadrant Dictation.
        let isFour = !pinched && ext == [true, true, true, true] && HandGesture.thumb(frame.squared) == .tucked
        switch switchHold.update(isFour, now: now) {
        case .fired:
            resetMotion()
            onSwitchStyle?(.quadrants)
            return
        case .holding:
            resetMotion()
            pose = .switching
            return
        case .idle:
            break
        }
        // The shaka, held: send what was just dictated. While it is up the pinky clear cannot run, so a
        // thumb flickering in mid-shaka never clears what was just sent.
        if ext != [false, false, false, true] { shakaSent = false }
        switch shakaHold.update(!pinched && HandGesture.isShaka(frame.squared, last: ext), now: now) {
        case .fired:
            shakaSent = true
            clearHold.reset()
            resetMotion()
            pose = .shaka
            onSend?()
            return
        case .holding:
            clearHold.reset()
            resetMotion()
            pose = .shaka
            return
        case .idle:
            break
        }
        // The pinky alone, held: clear what was just pasted. It already moves nothing (not a point).
        switch clearHold.update(!pinched && !shakaSent && HandGesture.isPinky(frame.squared, last: ext), now: now) {
        case .fired:
            resetMotion()
            pose = .clear
            onClear?()
            return
        case .holding:
            resetMotion()
            pose = .clear
            return
        case .idle:
            break
        }
        if isOpen {
            pose = .open
            resetMotion()
            return
        }
        // Only a pointing hand (or one mid-pinch) moves anything; any other shape (a fist, two
        // fingers) rests.
        guard isPoint || pinched || pose == .pinch || pose == .scroll else {
            pose = .other
            resetMotion()
            return
        }
        if pose != .track && pose != .pinch && pose != .scroll { resetMotion() }

        // Relative, like a trackpad: the knuckle's movement (smoothed) times the speed. The knuckle
        // barely moves when the thumb does, so opening or closing the gap does not nudge the pointer.
        // One camera-frame width of hand travel is about 1.7 screen widths at 1x.
        let unit = (NSScreen.main?.frame.width ?? 1440) / 0.6
        let f = filter.filter(CGPoint(x: m.x * unit, y: -m.y * unit), t: now)
        let step = lastFiltered.map { CGPoint(x: f.x - $0.x, y: f.y - $0.y) } ?? .zero
        lastFiltered = f

        if pinched {
            // Like Apple Vision Pro: pinch, hold, and move, and the page follows the hand. Touching
            // down catches a page still flinging. The pointer stays where it was.
            if pose != .pinch && pose != .scroll {
                pinchAt = now; pinchTravel = .zero; handVelocity = .zero
                caught = coast != .zero
                coast = .zero; scrollOwed = .zero
                pose = .pinch
            }
            pinchTravel.x += step.x; pinchTravel.y += step.y
            let k = Self.scrollGain * CGFloat(Self.baseSpeed)
            if pose == .pinch, hypot(pinchTravel.x, pinchTravel.y) > Self.scrollStart * unit {
                pose = .scroll
                owe(pinchTravel, k)   // catch up with the hand so far, so the page sticks to it
            } else if pose == .scroll {
                let d = owe(step, k)
                handVelocity.x += (d.x / frameDt - handVelocity.x) * 0.5
                handVelocity.y += (d.y / frameDt - handVelocity.y) * 0.5
            }
            return
        }
        // Let go: a quick pinch that never moved clicks (unless it only caught a fling); a scroll flings on at the speed it was going.
        if pose == .pinch, !caught, now - pinchAt <= Self.tapMax { click(at: pointer(), now: now) }
        if pose == .scroll {
            let v = hypot(handVelocity.x, handVelocity.y)
            if v > Self.flingMin {
                let s = min(1, Self.flingMax / v)
                coast = CGPoint(x: handVelocity.x * s, y: handVelocity.y * s)
                startGlide()
            }
            handVelocity = .zero
        }
        if pose == .pinch || pose == .scroll {
            pose = isPoint ? .track : .other
            resetMotion()
            return
        }
        guard isPoint else { pose = .other; resetMotion(); return }
        pose = .track
        // Hold still for a moment after a click so a double-click lands in the same place.
        if now >= freezeUntil, step != .zero {
            let p = pointer()
            move(to: Self.clamp(CGPoint(x: p.x + step.x * gain, y: p.y + step.y * gain)))
        }
    }

    /// Add hand travel (screen-style: y down) to what the glide owes, kept to the main direction
    /// (a vertical stroke does not drift the page sideways). Returns the page pixels added.
    @discardableResult
    private func owe(_ hand: CGPoint, _ k: CGFloat) -> CGPoint {
        var d = CGPoint(x: hand.x * k, y: hand.y * k)
        if abs(d.x) < abs(d.y) * 0.5 { d.x = 0 } else if abs(d.y) < abs(d.x) * 0.5 { d.y = 0 }
        // The content follows the hand: hand down moves the content down (positive wheel), hand right
        // moves it right (positive sideways wheel).
        scrollOwed.x += d.x; scrollOwed.y += d.y
        payRate = CGPoint(x: scrollOwed.x / frameGap, y: scrollOwed.y / frameGap)
        if d != .zero { startGlide() }
        return d
    }

    private func lost(_ now: CFTimeInterval) {
        // Hand out of view: a pinch ends without a click or a fling.
        dropPinch()
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
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    /// A whole click (down and up) where the pointer is. Two within 0.6 s in the same spot double-click.
    private func click(at p: CGPoint, now: CFTimeInterval) {
        let clicks = now - lastUp.t < 0.6 && hypot(p.x - lastUp.p.x, p.y - lastUp.p.y) < 12 ? lastUp.clicks + 1 : 1
        lastUp = (now, p, clicks)
        freezeUntil = now + 0.15
        if dryRun != nil { dryClick?(clicks); return }   // the self-test never clicks for real
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
            e?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
            e?.post(tap: .cghidEventTap)
        }
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

/// Pose changes while Vision Mode drives the pointer, one line each with the raw reading, so a live
/// misread ("it thought my pinch was a fist") can be read back afterwards. Capped at about 200 KB.
final class PoseLog {
    static let shared = PoseLog()
    var enabled = true
    let url = Paths.dataDir.appendingPathComponent("vision-poses.log")
    private let queue = DispatchQueue(label: "goldware.poselog")
    func write(_ line: String) {
        guard enabled else { return }
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime, .withFractionalSeconds])
        queue.async { [url] in
            let data = Data((stamp + "  " + line + "\n").utf8)
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil, size > 200_000 {
                try? FileManager.default.removeItem(at: url)
            }
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
            else { try? data.write(to: url) }
        }
    }
}
