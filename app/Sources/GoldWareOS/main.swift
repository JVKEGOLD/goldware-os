import AppKit
import CoreImage
import ImageIO
import Vision
import Speech
import ServiceManagement

// Test entry points, no hotkey, paste, or menu bar:
//   GoldWareOS --test file.wav [App Name]          dictation pipeline on a file
//   GoldWareOS --assistant file.wav [--execute]    assistant pipeline on a file
//   GoldWareOS --assistant-text "remind me..." [--execute]
//   GoldWareOS --flush-outbox                      retry captures saved while offline
// Assistant runs are dry runs that print what would happen unless --execute is given.
let args = CommandLine.arguments
func runAndExit(_ body: @escaping () async throws -> Void) -> Never {
    let done = DispatchSemaphore(value: 0)
    Task {
        do { try await body() } catch { print("ERROR: \(error.localizedDescription)") }
        done.signal()
    }
    done.wait()
    exit(0)
}
let model = UserDefaults.standard.string(forKey: "cleanupModel") ?? GWConfig.current.localModel

if args.count >= 3, args[1] == "--test" {
    runAndExit {
        let vocab = Vocabulary.load()
        let t0 = Date()
        let raw = try await WhisperEngine().transcribe(URL(fileURLWithPath: args[2]), vocabulary: vocab)
        let t1 = Date()
        let clean = try await CleanupEngine().clean(raw, model: model, appName: args.count >= 4 ? args[3] : nil, vocabulary: vocab)
        print("RAW   (\(Int(t1.timeIntervalSince(t0) * 1000)) ms): \(raw)")
        print("FINAL (\(Int(Date().timeIntervalSince(t1) * 1000)) ms, \(model)): \(clean)")
    }
}

// Dictation cleanup on typed text, including saved-item expansion. Prints labels, not private values.
if args.count >= 3, args[1] == "--clean-text" {
    runAndExit {
        let library = Library()
        library.root = VaultContext.resolveRoot()
        library.refresh()
        let raw = args[2]
        if let item = library.standaloneItem(raw) {
            print("STANDALONE: \(item.title)   inserted=\(item.value.isEmpty ? [] : [item.title]) empty=\(item.value.isEmpty ? [item.title] : [])")
            return
        }
        let asks = library.mightRequestInsert(raw)
        let cleaned = try await CleanupEngine().clean(raw, model: model, appName: args.count >= 4 ? args[3] : nil,
                                                      vocabulary: [], savedItems: asks ? library.all.map(\.title) : [])
        let e = library.expand(cleaned, raw: raw)
        print("MODEL: \(cleaned)")
        print("PASTE: \(e.historyText)   inserted=\(e.inserted) empty=\(e.empty)")
    }
}

// Hand-gesture self-check on synthetic joints: classification, the fist dictation hold, and
// release rules. Exits 1 on any mismatch. Posts no events (no pointing frames are fed).
if args.count >= 2, args[1] == "--test-hand" {
    typealias J = VNHumanHandPoseObservation.JointName
    func hand(_ ext: [Bool], thumb: String) -> HandGesture.Joints {
        var j: HandGesture.Joints = [.wrist: CGPoint(x: 0.5, y: 0.1), .indexMCP: CGPoint(x: 0.45, y: 0.3), .middleMCP: CGPoint(x: 0.5, y: 0.3)]
        let names: [(J, J, CGFloat)] = [(.indexPIP, .indexTip, 0.45), (.middlePIP, .middleTip, 0.5), (.ringPIP, .ringTip, 0.55), (.littlePIP, .littleTip, 0.6)]
        for (i, (pip, tip, x)) in names.enumerated() {
            j[pip] = CGPoint(x: x, y: 0.38)
            j[tip] = CGPoint(x: x, y: ext[i] ? 0.5 : 0.28)
        }
        let thumbs: [String: (CGPoint, CGPoint)] = ["up": (CGPoint(x: 0.38, y: 0.4), CGPoint(x: 0.38, y: 0.55)),
                                                    "side": (CGPoint(x: 0.33, y: 0.25), CGPoint(x: 0.22, y: 0.28)),
                                                    "in": (CGPoint(x: 0.44, y: 0.25), CGPoint(x: 0.47, y: 0.27))]
        (j[.thumbIP], j[.thumbTip]) = thumbs[thumb]!
        return j
    }
    let fist = hand([false, false, false, false], thumb: "in"), open = hand([true, true, true, true], thumb: "side")
    var failures = 0
    func expect(_ what: String, _ got: String, _ want: String) {
        print("\(got == want ? "PASS" : "FAIL")  \(what)\(got == want ? "" : "  (got \(got), want \(want))")")
        if got != want { failures += 1 }
    }
    for (name, j, want) in [("fist", fist, HandGesture.fist), ("thumbs up", hand([false, false, false, false], thumb: "up"), .thumbsUp),
                            ("two fingers", hand([true, true, false, false], thumb: "in"), .count(2)), ("open hand", open, .count(5))] {
        expect("reads \(name)", String(describing: HandGesture.classify(j)), String(describing: Optional(want)))
    }
    PoseLog.shared.enabled = false   // the checks must not fill the live pose log
    // The pointer never dictates (dictation lives in Quadrants): a held fist only rests.
    let c = HandControl()
    var cMoves = 0, cPoses = Set<String>()
    c.dryRun = { _ in cMoves += 1 }
    var t = 100.0
    func feed(_ j: HandGesture.Joints?, _ seconds: Double) {
        let end = t + seconds
        while t < end { var f = VisionFrame(); f.lead = j ?? [:]; f.time = t; c.handle(f); cPoses.insert(c.pose.rawValue); t += 1.0 / 30 }
    }
    feed(open, 1); feed(fist, 3)
    expect("in the pointer a held fist only rests (no dictation), and moves nothing", "\(c.isDictating) \(cMoves) \(c.pose.rawValue)", "false 0 RESTING")
    expect("the pointer has no dictating pose at all", "\(cPoses.contains("DICTATING"))", "false")
    c.stop(); c.dryRun = nil
    // Quadrant Dictation: counting fingers picks the quarter; four fingers with the thumb tucked is 4.
    for n in 1...4 {
        let up = (0..<4).map { $0 < n }
        expect("reads \(n) finger\(n == 1 ? "" : "s") up", String(describing: HandGesture.classify(hand(up, thumb: "in"))),
               String(describing: Optional(HandGesture.count(n))))
    }
    let q = QuadrantDictation()
    var qEvents: [String] = []
    q.onDictate = { qEvents.append($0 ? "start" : "finish") }
    func feedQ(_ j: HandGesture.Joints?, _ seconds: Double) {
        let end = t + seconds
        while t < end {
            var f = VisionFrame(); f.lead = j ?? [:]; f.time = t
            f.gesture = j.flatMap(HandGesture.classify)
            q.handle(f); t += 1.0 / 30
        }
    }
    feedQ(open, 1)
    expect("quadrants: an open hand (5) picks nothing", "\(q.phase) \(qEvents)", "idle []")
    feedQ(fist, 1)
    expect("quadrants: a fist picks nothing", "\(q.phase) \(qEvents)", "idle []")
    expect("quadrants: one finger with the thumb out is still 1",
           String(describing: QuadrantDictation.quadrant(hand([true, false, false, false], thumb: "side"))), "Optional(1)")
    feedQ(hand([true, true, false, false], thumb: "in"), 0.2)
    expect("quadrants: a brief 2 is only a preview", "\(q.phase) \(qEvents)", "choosing(2) []")
    feedQ(nil, 0.1)
    expect("quadrants: lowering the hand cancels the preview", "\(q.phase)", "idle")
    q.stop()
    // Switching styles by hand: four fingers (thumb tucked) held goes to Quadrants, an open hand held
    // goes back, and in Quadrants a fist rests.
    let four = hand([true, true, true, true], thumb: "in")
    var switched: [HandControl.Style] = []
    let pc = HandControl()
    pc.dryRun = { _ in }
    pc.onSwitchStyle = { switched.append($0) }
    func feedP(_ j: HandGesture.Joints?, _ seconds: Double) {
        let end = t + seconds
        while t < end { var f = VisionFrame(); f.lead = j ?? [:]; f.time = t; f.gesture = j.flatMap(HandGesture.classify); pc.handle(f); t += 1.0 / 30 }
    }
    feedP(four, 0.4)
    expect("a brief four fingers does not switch", "\(switched)", "[]")
    feedP(open, 0.3); feedP(four, 1)
    expect("four fingers held switches to Quadrants", "\(switched)", "[GoldWareOS.HandControl.Style.quadrants]")
    let qs = QuadrantDictation()
    qs.dryRun = true
    var back: [HandControl.Style] = []
    qs.onSwitchStyle = { back.append($0) }
    qs.block(4)   // as VisionController does after the switch
    func feedS(_ j: HandGesture.Joints?, _ seconds: Double) {
        let end = t + seconds
        while t < end { var f = VisionFrame(); f.lead = j ?? [:]; f.time = t; f.gesture = j.flatMap(HandGesture.classify); qs.handle(f); t += 1.0 / 30 }
    }
    feedS(four, 1)
    expect("the four that switched does not also pick quadrant 4", "\(qs.phase)", "idle")
    feedS(fist, 0.5)
    expect("a fist rests in Quadrants", "\(qs.phase) \(back)", "idle []")
    feedS(four, 0.3)
    expect("after resting, four fingers picks quadrant 4", "\(qs.phase)", "choosing(4)")
    var flicker = four
    flicker[.thumbIP] = CGPoint(x: 0.33, y: 0.25); flicker[.thumbTip] = CGPoint(x: 0.22, y: 0.28)
    feedS(flicker, 1.0 / 30); feedS(four, 0.1)
    expect("a one-frame thumb flicker keeps the quadrant choice", "\(qs.phase)", "choosing(4)")
    // The chosen quadrant's window comes to the front after a brief hold; passing through counts does not.
    var raisedQ: [Int] = []
    qs.onRaise = { raisedQ.append($0) }
    feedS(fist, 0.3)
    feedS(hand([true, false, false, false], thumb: "in"), 0.1); feedS(hand([true, true, false, false], thumb: "in"), 0.1)
    feedS(hand([true, true, true, false], thumb: "in"), 0.3)
    expect("holding a count brings its window forward; passing through 1 and 2 does not", "\(raisedQ)", "[3]")
    feedS(hand([true, true, true, false], thumb: "in"), 0.3)
    expect("it comes forward once, not every frame", "\(raisedQ)", "[3]")
    feedS(fist, 0.3); feedS(hand([true, true, false, false], thumb: "in"), 0.3)
    expect("choosing another quadrant brings that one forward", "\(raisedQ)", "[3, 2]")
    feedS(fist, 0.3); feedS(open, 0.4)
    expect("a brief open hand does not switch back", "\(back)", "[]")
    feedS(open, 0.6)
    expect("an open hand held switches back to the pointer", "\(back)", "[GoldWareOS.HandControl.Style.pointer]")
    // A flat hand with the thumb resting beside the index (a "stop") is neither four fingers nor open.
    var beside = four
    beside[.thumbIP] = CGPoint(x: 0.40, y: 0.30); beside[.thumbTip] = CGPoint(x: 0.41, y: 0.33)
    expect("a thumb beside the index is neither tucked nor spread", "\(HandGesture.thumb(beside)!) \(HandGesture.thumb(four)!) \(HandGesture.thumb(open)!)",
           "unsure tucked spread")
    switched = []; feedP(open, 0.3); feedP(beside, 1.2)
    expect("a flat hand with the thumb beside the index does not switch to Quadrants", "\(switched)", "[]")
    // A finger hovering at the line keeps its last reading, so a count does not flicker.
    func hover(_ j: HandGesture.Joints, ratio: CGFloat) -> HandGesture.Joints {
        var j = j
        let w = j[.wrist]!, p = j[.middlePIP]!
        let reach = hypot(p.x - w.x, p.y - w.y) * ratio
        j[.middleTip] = CGPoint(x: w.x + (p.x - w.x) / hypot(p.x - w.x, p.y - w.y) * reach, y: w.y + (p.y - w.y) / hypot(p.x - w.x, p.y - w.y) * reach)
        return j
    }
    let twoF = hand([true, true, false, false], thumb: "in")
    feedS(fist, 0.3); feedS(twoF, 0.1)
    feedS(hover(twoF, ratio: 1.05), 0.3)
    expect("a middle finger hovering at the line keeps quadrant 2", "\(qs.phase)", "choosing(2)")
    expect("a hovering finger read fresh (no last frame) is down, so the line itself did not move",
           "\(HandGesture.extended(hover(twoF, ratio: 1.05))!.fingers)", "[true, false, false, false]")
    feedS(hover(twoF, ratio: 0.9), 0.3)
    expect("curling it under the line drops to quadrant 1", "\(qs.phase)", "choosing(1)")
    // Thumbs up needs the thumb well above the knuckles and pointing up; a fist's thumb off to the side is a fist.
    var lowThumb = fist
    lowThumb[.thumbIP] = CGPoint(x: 0.38, y: 0.32); lowThumb[.thumbTip] = CGPoint(x: 0.38, y: 0.40)
    expect("a fist with the thumb out sideways, or barely raised, is a fist", "\(HandGesture.classify(hand([false, false, false, false], thumb: "side"))!) \(HandGesture.classify(lowThumb)!)", "fist fist")

    // The OK sign hides or shows the mirror: once per hold, never a click, never quadrant 3.
    var ok = hand([false, true, true, true], thumb: "in")
    ok[.indexPIP] = CGPoint(x: 0.45, y: 0.38); ok[.indexTip] = CGPoint(x: 0.44, y: 0.36)   // curled into the ring, out in front
    ok[.thumbTip] = CGPoint(x: 0.45, y: 0.35)
    expect("reads the OK sign (and not a fist, open hand, or pointing hand)",
           "\(HandGesture.isOK(ok)) \(HandGesture.isOK(fist)) \(HandGesture.isOK(open)) \(HandGesture.isOK(hand([true, false, false, false], thumb: "in")))",
           "true false false false")
    expect("the OK sign is not quadrant 3", String(describing: QuadrantDictation.quadrant(ok)), "nil")
    var toggle = MirrorToggle(), toggles = 0
    func feedT(_ j: HandGesture.Joints?, _ seconds: Double) {
        let end = t + seconds
        while t < end { var f = VisionFrame(); f.lead = j ?? [:]; f.time = t; if toggle.feed(f) { toggles += 1 }; t += 1.0 / 30 }
    }
    feedT(ok, 0.4)
    expect("a brief OK sign does not hide the mirror", "\(toggles)", "0")
    feedT(fist, 0.3); feedT(ok, 2)
    expect("an OK sign held hides it once, however long it is held", "\(toggles)", "1")
    feedT(fist, 0.3); feedT(ok, 1)
    expect("the next OK sign brings it back", "\(toggles)", "2")
    let okc = HandControl()
    okc.dryRun = { _ in }
    var okPoses = Set<String>()
    for (j, secs) in [(hand([true, false, false, false], thumb: "in"), 0.5), (ok, 1.2)] {
        let end = t + secs
        while t < end { var f = VisionFrame(); f.lead = j; f.time = t; f.gesture = HandGesture.classify(j); okc.handle(f); okPoses.insert(okc.pose.rawValue); t += 1.0 / 30 }
    }
    expect("an OK sign in pointer mode never clicks", "\(okPoses.contains("CLICK") || okPoses.contains("DRAGGING"))", "false")

    // The passcode: praying hands, spread into a diamond (index to index, thumb to thumb), then let go.
    // Two mirrored hands built around the center line; `gap` is how far the palms sit from it.
    func twoHands(palms gap: CGFloat, tips: CGFloat) -> (HandGesture.Joints, HandGesture.Joints) {
        func one(_ side: CGFloat) -> HandGesture.Joints {
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: 0.5 + side * x, y: y) }
            return [.wrist: p(gap + 0.02, 0.2), .middleMCP: p(gap, 0.4), .indexMCP: p(gap - 0.01, 0.39),
                    .middlePIP: p(gap * 0.7, 0.47), .middleTip: p(max(tips, gap * 0.4), 0.55),
                    .indexPIP: p(gap * 0.6, 0.45), .indexTip: p(tips, 0.52),
                    .thumbIP: p(gap * 0.6, 0.33), .thumbTip: p(tips, 0.3),
                    .ringPIP: p(gap * 0.8, 0.45), .ringTip: p(max(tips, gap * 0.5), 0.52),
                    .littlePIP: p(gap * 0.9, 0.42), .littleTip: p(max(tips, gap * 0.6), 0.47)]
        }
        return (one(-1), one(1))
    }
    let praying = twoHands(palms: 0.03, tips: 0.005), diamond = twoHands(palms: 0.14, tips: 0.01),
        letGo = twoHands(palms: 0.16, tips: 0.1)
    let closing = twoHands(palms: 0.09, tips: 0.005)
    expect("reads praying hands, the diamond, and letting go",
           "\(HandGesture.Pair(praying.0, praying.1)!.together) \(HandGesture.Pair(diamond.0, diamond.1)!.diamond) \(HandGesture.Pair(letGo.0, letGo.1)!.apart)",
           "true true true")
    expect("one pose is not another", "\(HandGesture.Pair(praying.0, praying.1)!.diamond) \(HandGesture.Pair(diamond.0, diamond.1)!.together)",
           "false false")
    var lock = VisionLock()
    var relocks = 0
    func feedL(_ hands: (HandGesture.Joints, HandGesture.Joints)?, _ seconds: Double, one: HandGesture.Joints? = nil) -> Bool {
        var admitted = false
        let end = t + seconds
        while t < end {
            var f = VisionFrame(); f.time = t
            if let h = hands { f.lead = h.0; f.second = h.1 } else if let one { f.lead = one }
            var u = false, r = false
            admitted = lock.admit(f, unlocked: &u, relocked: &r)
            if r { relocks += 1 }
            t += 1.0 / 30
        }
        return admitted
    }
    let point1 = hand([true, false, false, false], thumb: "in")
    expect("locked: a pointing hand drives nothing", "\(feedL(nil, 1, one: point1)) \(lock.state)", "false locked")
    lock = VisionLock(); _ = feedL(diamond, 1); _ = feedL(letGo, 0.5)
    expect("a diamond without praying first does not unlock", "\(lock.state)", "locked")
    lock = VisionLock(); _ = feedL(praying, 0.6); _ = feedL(letGo, 0.5)
    expect("praying then letting go, skipping the diamond, does not unlock", "\(lock.state)", "locked")
    lock = VisionLock(); _ = feedL(praying, 0.6); _ = feedL(diamond, 0.6)
    expect("holding the diamond is not enough, it waits for the release", "\(lock.state) \(lock.steps)", "locked 2")
    _ = feedL(nil, 0.5, one: fist)
    expect("the diamond ending any way is the release, even with one hand still in view", "\(lock.state)", "open")
    lock = VisionLock(); _ = feedL(praying, 0.6); _ = feedL(diamond, 1.0 / 30); _ = feedL(letGo, 0.5)
    expect("a single frame of diamond is a misread, not a step", "\(lock.state)", "locked")
    lock = VisionLock(); _ = feedL(praying, 0.6); _ = feedL(diamond, 0.3); _ = feedL(nil, 0.1, one: diamond.0); _ = feedL(nil, 3, one: fist)
    expect("losing one hand's tracking right after the diamond still unlocks", "\(lock.state)", "open")
    lock = VisionLock(); _ = feedL(praying, 0.6); _ = feedL(nil, 3, one: fist); _ = feedL(diamond, 0.6); _ = feedL(letGo, 0.5)
    expect("a long pause between praying and the diamond does not unlock", "\(lock.state)", "locked")
    lock = VisionLock(); _ = feedL(praying, 0.6); _ = feedL(diamond, 0.6)
    expect("praying, the diamond, then letting go unlocks", "\(feedL(letGo, 0.1)) \(lock.state)", "false open")
    expect("control starts a moment later, once the hands come down", "\(feedL(nil, 0.5, one: point1))", "true")
    _ = feedL(nil, 30)
    expect("half a minute away stays unlocked", "\(feedL(nil, 0.1, one: fist)) \(lock.state)", "true open")
    _ = feedL(nil, 61)
    expect("a minute away locks again", "\(feedL(nil, 0.1, one: fist)) \(lock.state)", "false locked")
    lock = VisionLock(); _ = feedL(praying, 0.6); _ = feedL(diamond, 0.6); _ = feedL(nil, 0.5)
    expect("dropping both hands out of the diamond also counts as letting go", "\(lock.state)", "open")
    // The lock is praying hands, held.
    func unlocked() { lock = VisionLock(); _ = feedL(praying, 0.6); _ = feedL(diamond, 0.6); _ = feedL(letGo, 0.6) }
    let thumbUp = hand([false, false, false, false], thumb: "up")
    unlocked(); _ = feedL(nil, 0.3, one: fist); _ = feedL(nil, 2, one: thumbUp)
    expect("a held thumbs up does not lock", "\(lock.state)", "open")
    unlocked(); relocks = 0; _ = feedL(nil, 0.5, one: fist); _ = feedL(praying, 1)
    expect("praying hands held lock", "\(lock.state) \(relocks)", "locked 1")
    expect("locked again: a pointing hand drives nothing", "\(feedL(nil, 0.5, one: point1))", "false")
    unlocked(); _ = feedL(nil, 0.5, one: fist); _ = feedL(praying, 0.5)
    expect("a brief prayer does not lock", "\(lock.state)", "open")
    unlocked(); relocks = 0; _ = feedL(nil, 0.5, one: fist); _ = feedL(praying, 0.5); _ = feedL(closing, 0.1); _ = feedL(praying, 0.5)
    expect("a flicker mid-prayer still locks", "\(lock.state) \(relocks)", "locked 1")
    unlocked(); _ = feedL(nil, 0.5, one: fist); _ = feedL(praying, 0.5); _ = feedL(nil, 0.5, one: fist); _ = feedL(praying, 0.5)
    expect("two short prayers with a break do not add up", "\(lock.state)", "open")
    unlocked(); _ = feedL(letGo, 0.3); _ = feedL(diamond, 0.5); _ = feedL(letGo, 0.5)
    expect("the send (diamond, then let go) does not lock", "\(lock.state)", "open")
    // Lowering the hands from the locking prayer runs prayer, diamond, apart: the unlock. It must not.
    unlocked(); _ = feedL(nil, 0.5, one: fist); _ = feedL(praying, 1)
    _ = feedL(diamond, 0.4); _ = feedL(letGo, 0.5)
    expect("dropping the hands from the locking prayer does not unlock again", "\(lock.state)", "locked")
    _ = feedL(nil, 1.5, one: fist); _ = feedL(praying, 0.6); _ = feedL(diamond, 0.6); _ = feedL(letGo, 0.5)
    expect("a second later the full unlock works again", "\(lock.state)", "open")
    // Two hands close together drive nothing in pointer mode either (praying reads as four or open).
    let pairc = HandControl()
    pairc.dryRun = { _ in }
    var pairSwitched: [HandControl.Style] = []
    pairc.onSwitchStyle = { pairSwitched.append($0) }
    for (secs, second) in [(1.5, praying.1)] {
        let end = t + secs
        while t < end { var f = VisionFrame(); f.lead = four; f.second = second; f.time = t; pairc.handle(f); t += 1.0 / 30 }
    }
    expect("four fingers with the other hand against them (praying) does not switch modes", "\(pairSwitched) \(pairc.pose.rawValue)", "[] RESTING")
    var prayingOK = VisionFrame(); prayingOK.lead = ok; prayingOK.second = praying.1
    var soloOK = VisionFrame(); soloOK.lead = ok
    expect("an OK with the other hand close by (praying) does not toggle the mirror",
           "\(MirrorToggle.sees(soloOK)) \(MirrorToggle.sees(prayingOK))", "true false")
    // Send: an open hand swept to the user's left (toward larger x in the unmirrored camera image),
    // in both styles. Pointing, fists, slow drifts, rightward or vertical sweeps never send.
    func shifted(_ j: HandGesture.Joints, _ dx: CGFloat, _ dy: CGFloat = 0) -> HandGesture.Joints {
        j.mapValues { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }
    let pointing = hand([true, false, false, false], thumb: "in")
    for style in ["pointer", "quadrants"] {
        let pc = HandControl(), qc = QuadrantDictation()
        qc.dryRun = true
        var sent = 0, moved = 0, picked = Set<Int>(), dictated: [Bool] = [], switched: [HandControl.Style] = []
        pc.onSend = { sent += 1 }; qc.onSend = { sent += 1 }
        pc.dryRun = { _ in moved += 1 }
        qc.onDictate = { dictated.append($0) }; qc.onSwitchStyle = { switched.append($0) }; pc.onSwitchStyle = { switched.append($0) }
        func run(_ j: HandGesture.Joints?) {
            var f = VisionFrame(); f.time = t; if let j { f.lead = j }
            if style == "pointer" { pc.handle(f) } else { qc.handle(f); if case .choosing(let n) = qc.phase { picked.insert(n) } }
            t += 1.0 / 30
        }
        func hold(_ j: HandGesture.Joints?, _ seconds: Double) { let end = t + seconds; while t < end { run(j) } }
        /// Moves `j` from dx `from` to `to` (camera x) over `seconds`.
        func sweep(_ j: HandGesture.Joints, from: CGFloat, to: CGFloat, _ seconds: Double, dy: CGFloat = 0) {
            let n = max(1, Int(seconds * 30))
            for k in 0...n { let a = CGFloat(k) / CGFloat(n); run(shifted(j, from + (to - from) * a, dy * a)) }
        }
        hold(fist, 0.5)
        sweep(open, from: -0.15, to: 0.15, 0.3)
        expect("\(style): an open hand swept to your left sends once", "\(sent)", "1")
        hold(shifted(open, 0.15), 0.2); sweep(open, from: 0.15, to: -0.15, 0.3)
        expect("\(style): bringing the hand straight back does not send again", "\(sent)", "1")
        hold(fist, 1.2)
        sweep(open, from: 0.15, to: -0.15, 0.3)
        expect("\(style): a sweep to your right does not send", "\(sent)", "1")
        hold(fist, 1.2)
        sweep(open, from: -0.06, to: 0.06, 0.7)
        expect("\(style): a slow drift to your left does not send", "\(sent)", "1")
        hold(fist, 1.2)
        // A pointing hand moves the pointer or picks quadrant 1 as usual; only the send is checked here.
        let (p0, m0) = (picked, moved)
        sweep(pointing, from: -0.15, to: 0.15, 0.3)
        expect("\(style): a pointing hand swept left does not send", "\(sent)", "1")
        hold(fist, 1.2)
        (picked, moved) = (p0, m0)
        sweep(fist, from: -0.15, to: 0.15, 0.3)
        expect("\(style): a fist swept left does not send", "\(sent)", "1")
        hold(fist, 1.2)
        sweep(open, from: 0, to: 0.12, 0.3, dy: 0.3)
        expect("\(style): a mostly vertical sweep does not send", "\(sent)", "1")
        hold(fist, 1.2)
        sweep(open, from: -0.15, to: 0.15, 0.25)
        expect("\(style): a second swipe after a pause sends again", "\(sent)", "2")
        hold(nil, 1.2)
        if style == "quadrants" {
            expect("quadrants: swipes and the hand passing through pick no quadrant, dictate, or switch back",
                   "\(picked.sorted()) \(dictated) \(switched)", "[] [] []")
        } else {
            expect("pointer: an open-hand swipe moves no pointer and switches nothing", "\(moved) \(switched)", "0 []")
        }
    }
    // The pinky alone, held 0.8 s, clears. Thumb tucked or loose is fine; thumb out to the side is "call me".
    let pinky = hand([false, false, false, true], thumb: "in"), callMe = hand([false, false, false, true], thumb: "side")
    expect("reads the pinky, not call-me, a fist, or one finger",
           "\(HandGesture.isPinky(pinky)) \(HandGesture.isPinky(callMe)) \(HandGesture.isPinky(fist)) \(HandGesture.isPinky(hand([true, false, false, false], thumb: "in")))",
           "true false false false")
    expect("the pinky is never quadrant 1; the index still is",
           "\(QuadrantDictation.quadrant(pinky).map { "\($0)" } ?? "none") \(QuadrantDictation.quadrant(hand([true, false, false, false], thumb: "in")).map { "\($0)" } ?? "none")", "none 1")
    let pclear = HandControl()
    var pcMoves = 0, pcClears = 0
    pclear.dryRun = { _ in pcMoves += 1 }
    pclear.onClear = { pcClears += 1 }
    func feedC(_ j: HandGesture.Joints?, _ seconds: Double) {
        let end = t + seconds
        while t < end { var f = VisionFrame(); f.time = t; if let j { f.lead = j }; pclear.handle(f); t += 1.0 / 30 }
    }
    feedC(open, 0.3); feedC(pinky, 0.4); feedC(open, 0.5)
    expect("in the pointer, a brief pinky does not clear", "\(pcClears)", "0")
    feedC(pinky, 2.0)
    expect("in the pointer, a held pinky clears once, moving nothing", "\(pcClears) \(pcMoves)", "1 0")
    feedC(open, 0.6); feedC(pinky, 1.0)
    expect("a fresh pinky clears again", "\(pcClears)", "2")
    feedC(callMe, 1.5)
    expect("call-me (thumb out) does not clear", "\(pcClears)", "2")
    let qclear = QuadrantDictation()
    qclear.dryRun = true
    var qcClears = 0, qcPicked = Set<Int>()
    qclear.onClear = { qcClears += 1 }
    func feedQC(_ j: HandGesture.Joints?, _ seconds: Double) {
        let end = t + seconds
        while t < end {
            var f = VisionFrame(); f.time = t; if let j { f.lead = j }; qclear.handle(f)
            if case .choosing(let n) = qclear.phase { qcPicked.insert(n) }
            t += 1.0 / 30
        }
    }
    feedQC(fist, 0.5); feedQC(pinky, 1.5)
    expect("in Quadrants, a held pinky clears and picks no quadrant", "\(qcClears) \(qcPicked.sorted())", "1 []")
    feedQC(fist, 0.5); feedQC(hand([true, true, false, false], thumb: "in"), 0.6)
    expect("a quadrant can still be picked after clearing", "\(qcPicked.sorted())", "[2]")

    // When Return may be pressed: only the last hand dictation's paste, within two minutes, in that app.
    let now = Date()
    let sendable: AppDelegate.LastPaste? = .init(pid: 42, at: now.addingTimeInterval(-5), length: 12)
    expect("sends into the app that just got the paste", "\(AppDelegate.sendDecision(sendable: sendable, transcribing: false, front: 42, now: now))", "send")
    expect("not if another app came to the front", "\(AppDelegate.sendDecision(sendable: sendable, transcribing: false, front: 7, now: now))", "notInFront")
    expect("not two minutes later", "\(AppDelegate.sendDecision(sendable: .init(pid: 42, at: now.addingTimeInterval(-121), length: 12), transcribing: false, front: 42, now: now))", "nothing")
    expect("nothing pasted, nothing sent", "\(AppDelegate.sendDecision(sendable: nil, transcribing: false, front: 42, now: now))", "nothing")
    expect("still transcribing: it waits and sends once the paste lands",
           "\(AppDelegate.sendDecision(sendable: nil, transcribing: true, front: 42, now: now))", "wait")
    // Only what was typed in last: a real key or click after the paste means it may not be the last
    // thing in the box any more, so neither send nor clear acts. (The same rule serves the pinky.)
    expect("a key or click after the paste: not sent or cleared",
           "\(AppDelegate.sendDecision(sendable: sendable, typedSince: true, transcribing: false, front: 42, now: now))", "typedSince")
    // The app's own keys are marked so the key monitor does not count them as typing.
    expect("The app's keystrokes carry the marker", Paster.keystroke(51, []).map { $0.getIntegerValueField(.eventSourceUserData) == Paster.marker }.description, "[true, true]")
    // The Return it presses is a bare Return, and no keystroke leaves Command held: a Command-flagged
    // key-up from the paste once latched Command, so the send went out as Cmd+Return (full screen).
    // Vision starts as the pointer, whatever style it was last left in; asking for Quadrants still works.
    expect("turning Vision on starts the pointer", "\(VisionController.startStyle(on: true, wasOn: false, requested: nil).map { "\($0)" } ?? "keep")", "pointer")
    expect("asking for Quadrants by name gets Quadrants", "\(VisionController.startStyle(on: true, wasOn: false, requested: .quadrants).map { "\($0)" } ?? "keep")", "quadrants")
    expect("already on: the style stays", "\(VisionController.startStyle(on: true, wasOn: true, requested: nil).map { "\($0)" } ?? "keep")", "keep")
    let mods: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn]
    let ret = Paster.keystroke(36, [])
    expect("the send is a bare Return, down and up", ret.map { $0.flags.intersection(mods).isEmpty }.description, "[true, true]")
    expect("the paste key-up releases Command", Paster.keystroke(9, .maskCommand).map { $0.flags.contains(.maskCommand) }.description, "[true, false]")
    expect("the undo key-up releases Command", Paster.keystroke(6, .maskCommand).map { $0.flags.contains(.maskCommand) }.description, "[true, false]")

    expect("the mirror never names the gesture", "\(VisionLock().status)", "LOCKED")
    // On a 16:9 camera a spread thumb's sideways reach reads 44% short; squaring the joints fixes it.
    var wide = VisionFrame()
    wide.imageSize = CGSize(width: 1920, height: 1080)
    // A real open palm (HaGRID): the thumb spreads mostly sideways, 0.69 hand sizes from the middle knuckle.
    let palm: HandGesture.Joints = [.wrist: CGPoint(x: 0.5, y: 0.1), .middleMCP: CGPoint(x: 0.5, y: 0.3), .indexMCP: CGPoint(x: 0.44, y: 0.29),
        .indexPIP: CGPoint(x: 0.43, y: 0.38), .indexTip: CGPoint(x: 0.42, y: 0.47), .middlePIP: CGPoint(x: 0.5, y: 0.4), .middleTip: CGPoint(x: 0.5, y: 0.5),
        .ringPIP: CGPoint(x: 0.56, y: 0.39), .ringTip: CGPoint(x: 0.57, y: 0.48), .littlePIP: CGPoint(x: 0.61, y: 0.35), .littleTip: CGPoint(x: 0.63, y: 0.42),
        .thumbIP: CGPoint(x: 0.4, y: 0.24), .thumbTip: CGPoint(x: 0.37, y: 0.27)]
    wide.lead = palm.mapValues { CGPoint(x: 0.5 + ($0.x - 0.5) / (16.0 / 9), y: $0.y) }   // as the camera reports it
    expect("an open hand reads open on a widescreen camera (only once squared)",
           "\(HandGesture.isOpenHand(wide.lead)) \(HandGesture.isOpenHand(wide.squared))", "false true")

    // Thumb-gap speed: slow when close, 1x relaxed, fast when wide, and always increasing.
    let g = [0.4, 0.55, 1.1, 1.9, 2.5].map { HandControl.gain(forSpread: $0) }
    expect("thumb close is fine control (0.25x)", String(format: "%.2f", g[1]), "0.25")
    expect("thumb relaxed is normal speed (1x)", String(format: "%.2f", g[2]), "1.00")
    expect("wide L is fast (2.5x)", String(format: "%.2f", g[3]), "2.50")
    expect("speed only grows as the gap opens, and is capped", "\(zip(g, g.dropFirst()).allSatisfy { $0 <= $1 }) \(g[0] == g[1]) \(g[3] == g[4])",
           "true true true")
    // The same knuckle travel moves the pointer further with the thumb out, and adjusting the thumb
    // alone does not move it. Dry run: nothing is posted.
    // Thumb tip positions measured against the index tip at (0.45, 0.5), hand size 0.2.
    let nearTip = CGPoint(x: 0.43, y: 0.41), relaxed = CGPoint(x: 0.33, y: 0.30), wideL = CGPoint(x: 0.12, y: 0.26)
    func point(thumbAt t: CGPoint, knuckleX kx: CGFloat) -> HandGesture.Joints {
        var j = hand([true, false, false, false], thumb: "in")
        for k in j.keys { j[k]!.x += kx - 0.45 }
        j[.thumbTip] = CGPoint(x: t.x + kx - 0.45, y: t.y)
        j[.thumbIP] = CGPoint(x: (t.x + kx - 0.45 + j[.indexMCP]!.x) / 2, y: (t.y + 0.3) / 2)
        return j
    }
    func travel(thumb tx: CGPoint) -> CGFloat {
        let h = HandControl()
        var xs: [CGFloat] = []
        h.dryRun = { xs.append($0.x) }
        for i in 0...40 {   // settle 0.5 s, then move the knuckle 0.1 of the frame over 0.83 s
            var f = VisionFrame(); f.time = 200 + Double(i) / 30
            f.lead = point(thumbAt: tx, knuckleX: 0.45 - (i > 15 ? CGFloat(i - 15) * 0.004 : 0))
            f.gesture = HandGesture.classify(f.lead)
            h.handle(f)
        }
        return (xs.last ?? 0) - (xs.first ?? 0)
    }
    let slow = travel(thumb: nearTip), normal = travel(thumb: relaxed), fast = travel(thumb: wideL)
    expect("thumb gap speeds the pointer (close < relaxed < wide)", "\(slow < normal && normal < fast)", "true")
    expect("wide is several times the close speed", "\(fast > slow * 4)", "true")
    let still = HandControl()
    var moved: CGFloat = 0
    still.dryRun = { _ in moved += 1 }
    for i in 0...30 {   // knuckle still, thumb swinging out
        var f = VisionFrame(); f.time = 300 + Double(i) / 30
        let k = CGFloat(i) / 30
        f.lead = point(thumbAt: CGPoint(x: nearTip.x + (wideL.x - nearTip.x) * k, y: nearTip.y + (wideL.y - nearTip.y) * k), knuckleX: 0.45)
        f.gesture = HandGesture.classify(f.lead)
        still.handle(f)
    }
    expect("changing the thumb gap alone does not move the pointer", "\(moved)", "0.0")
    // Pinch and move scrolls (like Apple Vision Pro); a quick still pinch clicks. Dry run: nothing posted.
    // `pinchRun` moves the hand at a set speed (frame widths per second, Vision y up) and steps the
    // 120 Hz glide four times per 30 fps frame, stamping each post with its tick time.
    var pinchFix = hand([true, false, false, false], thumb: "in"); pinchFix[.thumbTip] = CGPoint(x: 0.45, y: 0.49); pinchFix[.thumbIP] = CGPoint(x: 0.42, y: 0.4)
    let pointFix = hand([true, false, false, false], thumb: "in")
    struct PinchOut { var posts: [(t: Double, d: CGPoint)] = []; var clicks: [Int] = []; var moves = 0; var poses: [(t: Double, pose: String)] = [] }
    func pinchRun(_ steps: [(HandGesture.Joints?, CGPoint, Double)], dropThumbAt: ClosedRange<Double>? = nil) -> PinchOut {
        let h = HandControl()
        var out = PinchOut()
        var now = 0.0, tick = 0.0, off = CGPoint.zero
        h.dryRun = { _ in out.moves += 1 }
        h.dryClick = { out.clicks.append($0) }
        h.dryScroll = { out.posts.append((tick, $0)) }
        for (j, v, secs) in steps {
            let end = now + secs
            while now < end - 1e-9 {
                var f = VisionFrame(); f.time = 900 + now
                if var j {
                    j = j.mapValues { CGPoint(x: $0.x + off.x, y: $0.y + off.y) }
                    if dropThumbAt?.contains(now) == true { j[.thumbTip] = nil }
                    f.lead = j; f.gesture = HandGesture.classify(j)
                }
                h.handle(f)
                out.poses.append((now, h.pose.rawValue))
                for k in 0..<4 { tick = now + Double(k) / 120; h.glide(at: 900 + tick) }
                off.x += v.x / 30; off.y += v.y / 30
                now += 1.0 / 30
            }
        }
        while now < 6 { tick = now; h.glide(at: 900 + now); now += 1.0 / 120 }   // let any fling run out
        return out
    }
    func ysum(_ o: PinchOut, _ from: Double = 0, _ to: Double = 99) -> CGFloat { o.posts.filter { $0.t >= from && $0.t < to }.map(\.d.y).reduce(0, +) }
    func xsum(_ o: PinchOut, _ from: Double = 0, _ to: Double = 99) -> CGFloat { o.posts.filter { $0.t >= from && $0.t < to }.map(\.d.x).reduce(0, +) }
    let still0 = CGPoint.zero
    let tap = pinchRun([(pointFix, still0, 0.5), (pinchFix, still0, 0.2), (pointFix, still0, 0.5)])
    expect("a quick still pinch clicks once and scrolls nothing", "\(tap.clicks) \(tap.posts.count)", "[1] 0")
    let dbl = pinchRun([(pointFix, still0, 0.5), (pinchFix, still0, 0.15), (pointFix, still0, 0.15), (pinchFix, still0, 0.15), (pointFix, still0, 0.5)])
    expect("two quick pinches double-click", "\(dbl.clicks)", "[1, 2]")
    let hold = pinchRun([(pointFix, still0, 0.5), (pinchFix, still0, 1.5), (pointFix, still0, 0.5)])
    expect("a long still pinch neither clicks nor scrolls", "\(hold.clicks) \(hold.posts.count)", "[] 0")
    // Hand down in the camera (Vision y falls) pulls the content down, like dragging a page on glass.
    let pullDown = pinchRun([(pointFix, still0, 0.5), (pinchFix, still0, 0.1), (pinchFix, CGPoint(x: 0, y: -0.25), 0.8), (pinchFix, still0, 0.5), (pointFix, still0, 0.3)])
    expect("pinch and move down scrolls the content down (positive), never sideways, no click, pointer still",
           "\(ysum(pullDown) > 200) \(pullDown.posts.allSatisfy { $0.d.y >= 0 && $0.d.x == 0 }) \(pullDown.clicks) \(pullDown.moves)", "true true [] 0")
    let pullUp = pinchRun([(pointFix, still0, 0.5), (pinchFix, still0, 0.1), (pinchFix, CGPoint(x: 0, y: 0.25), 0.8), (pinchFix, still0, 0.5), (pointFix, still0, 0.3)])
    expect("pinch and move up scrolls the other way, as far", "\(pullUp.posts.allSatisfy { $0.d.y <= 0 }) \(abs(ysum(pullUp) + ysum(pullDown)) < ysum(pullDown) * 0.1)", "true true")
    let side = pinchRun([(pointFix, still0, 0.5), (pinchFix, still0, 0.1), (pinchFix, CGPoint(x: 0.25, y: 0), 0.8), (pinchFix, still0, 0.5), (pointFix, still0, 0.3)])
    expect("pinch and move sideways scrolls sideways only", "\(abs(xsum(side)) > 200) \(side.posts.allSatisfy { $0.d.y == 0 })", "true true")
    let drift = pinchRun([(pointFix, still0, 0.5), (pinchFix, still0, 0.1), (pinchFix, CGPoint(x: 0.06, y: -0.25), 0.8), (pinchFix, still0, 0.5), (pointFix, still0, 0.3)])
    expect("a mostly vertical stroke with some drift scrolls only vertically", "\(ysum(drift) > 200) \(drift.posts.allSatisfy { $0.d.x == 0 })", "true true")
    // The page sticks to the hand: the distance scrolled is the hand travel times the gain, not a rate.
    let unit = (NSScreen.main?.frame.width ?? 1440) / 0.6
    let want = 0.25 * 0.8 * unit * HandControl.scrollGain * CGFloat(HandControl.baseSpeed)
    expect("the page follows the hand 1:1 with the gain (within 15%)", "\(abs(ysum(pullDown) - want) < want * 0.15)", "true")
    print(String(format: "  pinch-scroll: %.0f px for %.0f px wanted", ysum(pullDown), want))
    // Smooth: posts on (nearly) every 120 Hz tick while the hand moves, in small steps.
    let steadyPosts = pullDown.posts.filter { $0.t >= 0.9 && $0.t < 1.3 }
    expect("a steady pull scrolls in small even steps (100+ posts a second, none over 12 px)",
           "\(steadyPosts.count >= 40) \(steadyPosts.allSatisfy { abs($0.d.y) <= 12 })", "true true")
    expect("held still after moving, it stops (no fling while pinched)", "\(abs(ysum(pullDown, 1.6)) < 30)", "true")
    // Let go while moving: it flings on and eases to a stop; let go after stopping: it stays put.
    let fling = pinchRun([(pointFix, still0, 0.5), (pinchFix, still0, 0.1), (pinchFix, CGPoint(x: 0, y: -0.4), 0.4), (pointFix, still0, 3)])
    let flingEnd = fling.posts.last?.t ?? 0
    expect("letting go mid-move flings on, then eases to a stop within 2 s, no click",
           "\(ysum(fling, 1.05, 1.5) > 50) \(flingEnd < 3) \(fling.clicks)", "true true []")
    print(String(format: "  fling: %.0f px after release, last post at %.2f s", ysum(fling, 1.0), flingEnd))
    expect("letting go after holding still does not fling", "\(abs(ysum(pullDown, 1.6)) < 30)", "true")
    // Pinching a flinging page catches it: it stops, and that pinch does not click.
    let caught = pinchRun([(pointFix, still0, 0.5), (pinchFix, still0, 0.1), (pinchFix, CGPoint(x: 0, y: -0.4), 0.4), (pointFix, still0, 0.15),
                           (pinchFix, still0, 0.2), (pointFix, still0, 1)])
    expect("a pinch catches a fling (nothing after it) without clicking", "\(abs(ysum(caught, 1.25)) < 10) \(caught.clicks)", "true []")
    // A moving hand can lose its thumb tip for a few frames; the scroll carries on and never clicks.
    let blink = pinchRun([(pointFix, still0, 0.5), (pinchFix, still0, 0.1), (pinchFix, CGPoint(x: 0, y: -0.25), 1.0), (pinchFix, still0, 0.5), (pointFix, still0, 0.3)],
                         dropThumbAt: 0.9...1.1)
    expect("a fingertip lost for 0.2 s mid-scroll keeps scrolling", "\(blink.poses.filter { $0.t > 0.9 && $0.t < 1.1 }.allSatisfy { $0.pose == "SCROLLING" }) \(blink.clicks)", "true []")
    // The hand leaving view mid-scroll ends it: no fling, no click.
    let gone = pinchRun([(pointFix, still0, 0.5), (pinchFix, still0, 0.1), (pinchFix, CGPoint(x: 0, y: -0.4), 0.4), (nil, still0, 2)])
    expect("a hand leaving view mid-scroll stops without a fling or click", "\(abs(ysum(gone, 1.4)) < 10) \(gone.clicks)", "true []")
    // The old two-finger scroll is gone: two fingers, tilted or not, rest.
    let twoUp = hand([true, true, false, false], thumb: "in")
    let two = pinchRun([(twoUp, still0, 2)])
    expect("two fingers no longer scroll (they rest)", "\(two.posts.count) \(two.poses.last?.pose ?? "")", "0 RESTING")
    // Camera stall mid-fling: the glide must not run on alone.
    let st = HandControl(); st.dryRun = { _ in }
    var stallPx: [Double] = []; var stT = 0.0, stOff: CGFloat = 0
    st.dryScroll = { _ in stallPx.append(stT) }
    for (j, v, secs) in [(pointFix, CGFloat(0), 0.5), (pinchFix, 0, 0.1), (pinchFix, -0.6, 0.3), (pointFix, 0, 1.0 / 30)] {
        let end = stT + secs
        while stT < end - 1e-9 { var f = VisionFrame(); f.time = 1500 + stT; f.lead = j.mapValues { CGPoint(x: $0.x, y: $0.y + stOff) }; st.handle(f)
            for k in 0..<4 { st.glide(at: 1500 + stT + Double(k) / 120) }; stOff += v / 30; stT += 1.0 / 30 }
    }
    while stT < 3 { st.glide(at: 1500 + stT); stT += 1.0 / 120 }   // no frames at all
    expect("if camera frames stop, a fling stops within half a second", "\(stallPx.filter { $0 >= 1.5 }.count)", "0")
    print(String(format: "  pointer travel for the same hand move: close %.0f px, relaxed %.0f px, wide %.0f px", slow, normal, fast))
    // Let's work by hand: both hands thumb, index, middle; thumb tips touch, then pull apart.
    let homeBase = hand([true, true, false, false], thumb: "side")
    func homeHands(apart: CGFloat) -> (HandGesture.Joints, HandGesture.Joints) {
        // Left hand shifted so its thumb tip sits at x 0.52, right hand its mirror image; `apart` pulls them sideways.
        let a = homeBase.mapValues { CGPoint(x: $0.x + 0.3 - apart / 2, y: $0.y) }
        let b = homeBase.mapValues { CGPoint(x: 1.04 - ($0.x + 0.3) + apart / 2, y: $0.y) }
        return (a, b)
    }
    let hc = HandControl()
    hc.dryRun = { _ in }
    var homes = 0, homeScroll = 0
    hc.onLetsWork = { homes += 1 }
    hc.dryScroll = { _ in homeScroll += 1 }
    func feedH(_ pair: (HandGesture.Joints, HandGesture.Joints)?, _ seconds: Double, second: HandGesture.Joints? = nil) {
        let end = t + seconds
        while t < end {
            var f = VisionFrame(); f.time = t
            if let (a, b) = pair { f.lead = a; f.second = second ?? b }
            hc.handle(f); t += 1.0 / 30
        }
    }
    func pull(_ seconds: Double) {
        let steps = Int(seconds * 30)
        for i in 1...steps { feedH(homeHands(apart: 0.4 * CGFloat(i) / CGFloat(steps)), 1.0 / 30) }
    }
    expect("the Let's work shape reads on both synthetic hands",
           "\(ThumbPull.shape(homeHands(apart: 0).0)) \(ThumbPull.shape(homeHands(apart: 0).1))", "true true")
    feedH(homeHands(apart: 0), 0.5); pull(0.3); feedH(homeHands(apart: 0.4), 0.3)
    expect("thumbs touching, then pulled apart, opens Let's work once", "\(homes)", "1")
    expect("the two-finger hands do not scroll meanwhile", "\(homeScroll)", "0")
    feedH(homeHands(apart: 0), 0.5); pull(0.3)
    expect("again without dropping the hands does not fire twice", "\(homes)", "1")
    feedH(nil, 0.7); feedH(homeHands(apart: 0), 0.5); pull(0.3)
    expect("after the hands drop, it fires again", "\(homes)", "2")
    feedH(nil, 0.7); feedH(homeHands(apart: 0), 1.0 / 30); pull(0.3)
    expect("a one-frame touch does not fire", "\(homes)", "2")
    feedH(nil, 0.7); feedH(homeHands(apart: 0.4), 1)
    expect("hands in the shape but never touching do not fire", "\(homes)", "2")
    feedH(nil, 0.7); feedH(homeHands(apart: 0), 0.5); feedH(nil, 2); feedH(homeHands(apart: 0.4), 0.5)
    expect("a pull long after the touch does not fire", "\(homes)", "2")
    feedH(nil, 0.7); feedH(homeHands(apart: 0), 0.5, second: open); feedH(homeHands(apart: 0.4), 0.5, second: open)
    expect("one hand in the shape with an open hand does not fire", "\(homes)", "2")
    hc.stop()
    // Lock Up by hand: both hands open for a beat, then both fists.
    let lc = HandControl()
    lc.dryRun = { _ in }
    var locks = 0, clears = 0, lockMoves = 0
    lc.onLockUp = { locks += 1 }
    lc.onClearOut = { clears += 1 }
    lc.dryRun = { _ in lockMoves += 1 }
    let openL = open, openR = open.mapValues { CGPoint(x: $0.x + 0.35, y: $0.y) }
    let fistL = fist, fistR = fist.mapValues { CGPoint(x: $0.x + 0.35, y: $0.y) }
    let pointL = hand([true, false, false, false], thumb: "in")
    func feedL(_ a: HandGesture.Joints?, _ b: HandGesture.Joints?, _ seconds: Double) {
        let end = t + seconds
        while t < end { var f = VisionFrame(); f.time = t; f.lead = a ?? [:]; f.second = b ?? [:]; lc.handle(f); t += 1.0 / 30 }
    }
    feedL(openL, openR, 0.5); feedL(fistL, fistR, 0.5)
    expect("two open hands, then two fists, locks up once", "\(locks)", "1")
    feedL(fistL, fistR, 1)
    expect("the fists held on do not lock again", "\(locks)", "1")
    feedL(fistL, nil, 1)
    feedL(nil, nil, 0.7); feedL(openL, openR, 0.5); feedL(fistL, fistR, 0.5)
    expect("after the hands drop, it locks up again", "\(locks)", "2")
    feedL(nil, nil, 0.7); feedL(openL, openR, 0.1); feedL(fistL, fistR, 0.5)
    expect("a brief flash of open hands does not lock up", "\(locks)", "2")
    feedL(nil, nil, 0.7); feedL(fistL, fistR, 1)
    expect("two fists that were never open do not lock up", "\(locks)", "2")
    feedL(nil, nil, 0.7); feedL(openL, openR, 0.5); feedL(fistL, openR, 0.7)
    expect("two open hands, then one fist, clears out once and does not lock up", "\(locks) \(clears)", "2 1")
    feedL(fistL, openR, 1)
    expect("the one fist held on does not clear out again", "\(clears)", "1")
    feedL(nil, nil, 0.7); feedL(openL, openR, 0.5); feedL(openL, fistR, 0.7)
    expect("either hand can be the fist", "\(locks) \(clears)", "2 2")
    feedL(nil, nil, 0.7); feedL(openL, openR, 0.5); feedL(fistL, openR, 0.25); feedL(fistL, fistR, 0.5)
    expect("hands that close a moment apart lock up, not clear out", "\(locks) \(clears)", "3 2")
    feedL(nil, nil, 0.7); feedL(openL, openR, 0.5); feedL(fistL, openR, 0.3); feedL(openL, openR, 0.5)
    expect("a fist opened again before half a second does not clear out", "\(clears)", "2")
    feedL(nil, nil, 1.2); feedL(fistL, openR, 1)
    expect("one fist next to an open hand that was never two open hands does not clear out", "\(clears)", "2")
    feedL(nil, nil, 0.7); feedL(openL, openR, 0.5); feedL(fistL, nil, 1)
    expect("one fist with the other hand gone does not clear out", "\(clears)", "2")
    feedL(nil, nil, 0.7); feedL(openL, openR, 0.5); feedL(nil, nil, 1.5); feedL(fistL, openR, 0.7)
    expect("one fist long after the open hands does not clear out", "\(clears)", "2")
    feedL(nil, nil, 0.7); feedL(openL, openR, 0.5); feedL(nil, nil, 1.5); feedL(fistL, fistR, 0.5)
    expect("fists long after the open hands do not lock up", "\(locks)", "3")
    feedL(nil, nil, 0.7); feedL(openL, nil, 0.3); feedL(fistL, nil, 1)
    expect("one hand open then a fist does nothing", "\(locks) \(clears) \(lc.pose.rawValue)", "3 2 RESTING")
    feedL(openL, nil, 0.5); lockMoves = 0
    for i in 0..<10 { feedL(pointL.mapValues { CGPoint(x: $0.x + CGFloat(i) * 0.01, y: $0.y) }, nil, 1.0 / 30) }
    expect("pointing with one hand still moves the pointer", "\(lockMoves > 0)", "true")
    lc.stop()
    expect("turning Vision Mode on starts with the camera preview hidden",
           "\(VisionController.mirrorHidden(on: true, wasOn: false, hidden: false)) \(VisionController.mirrorHidden(on: true, wasOn: false, hidden: true))", "true true")
    expect("switching style while on keeps the preview as it was; turning off clears it",
           "\(VisionController.mirrorHidden(on: true, wasOn: true, hidden: false)) \(VisionController.mirrorHidden(on: true, wasOn: true, hidden: true)) \(VisionController.mirrorHidden(on: false, wasOn: true, hidden: true))",
           "false true false")
    print(failures == 0 ? "All hand checks passed" : "\(failures) hand check(s) failed")
    exit(failures == 0 ? 0 : 1)
}

// Quadrant Dictation self-check: the quadrant rectangles and window lookup, read only (no focus change).
// Runs the gesture rules on labelled photos: each argument is a folder of one gesture (for example
// HaGRID's palm, four, ok; v2's holy and hand_heart for the two-hand unlock). Prints how often each rule
// fires per folder, as a share of photos with a hand in them. Calibration only; nothing is stored.
if args.count >= 3, args[1] == "--gesture-eval" {
    for dir in args.dropFirst(2) {
        var n = 0, hits: [String: Int] = [:]
        for file in ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted() where file.hasSuffix(".jpg") {
            guard let img = NSImage(contentsOfFile: "\(dir)/\(file)"),
                  let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let req = VNDetectHumanHandPoseRequest()
            req.maximumHandCount = 2
            try? VNImageRequestHandler(cgImage: cg).perform([req])
            func span(_ o: VNHumanHandPoseObservation) -> CGFloat {
                guard let w = try? o.recognizedPoint(.wrist), let m = try? o.recognizedPoint(.middleMCP) else { return 0 }
                return hypot((w.location.x - m.location.x) * CGFloat(cg.width), (w.location.y - m.location.y) * CGFloat(cg.height))
            }
            let hands = (req.results ?? []).sorted { span($0) > span($1) }
            guard let o = hands.first else { continue }
            var f = VisionFrame()
            for name in HandGesture.joints {
                guard let p = try? o.recognizedPoint(name), p.confidence > 0.15 else { continue }
                f.leadLoose[name] = p.location
                if p.confidence > 0.3 { f.lead[name] = p.location }
            }
            if hands.count > 1 {
                for name in HandGesture.joints {
                    guard let p = try? hands[1].recognizedPoint(name), p.confidence > 0.15 else { continue }
                    f.secondLoose[name] = p.location
                    if p.confidence > 0.3 { f.second[name] = p.location }
                }
            }
            f.imageSize = CGSize(width: cg.width, height: cg.height)
            n += 1   // every photo with a hand; one-hand rules below only when that hand is readable
            if let p = f.pair {
                if p.together { hits["together", default: 0] += 1 }
                if p.diamond { hits["diamond", default: 0] += 1 }
                if (p.thumb ?? 9) < 0.45, ThumbPull.shape(f.squared), ThumbPull.shape(f.secondSquared) { hits["thumbTouch", default: 0] += 1 }
                if ThumbPull.shape(f.squared), ThumbPull.shape(f.secondSquared) { hits["homeShape", default: 0] += 1 }
                let fa = OpenToFists.fingers(f.squared), fb = OpenToFists.fingers(f.secondSquared)
                if fa == [true, true, true, true], fb == [true, true, true, true], (p.palms ?? 0) > 1.5 { hits["twoOpen", default: 0] += 1 }
                if fa == [false, false, false, false], fb == [false, false, false, false] { hits["twoFists", default: 0] += 1 }
                if (fa == [false, false, false, false] && fb == [true, true, true, true]) ||
                   (fa == [true, true, true, true] && fb == [false, false, false, false]) { hits["openAndFist", default: 0] += 1 }
            }
            if MirrorToggle.sees(f) { hits["ok", default: 0] += 1 }
            let j = f.squared
            guard let e = HandGesture.extended(j) else { continue }
            var fired: [String] = []
            if HandGesture.isOpenHand(j) { fired.append("open") }
            switch HandGesture.classify(j) {
            case .thumbsUp: fired.append("thumbsUp")
            case .fist: fired.append("fist")
            default: break
            }
            if HandGesture.thumb(j) == .tucked { fired.append("tucked") }
            if e.fingers == [true, true, true, true] && HandGesture.thumb(j) == .tucked { fired.append("four") }
            if let q = QuadrantDictation.quadrant(j) { fired.append("q\(q)") }
            if HandGesture.isPinky(j) { fired.append("pinky") }
            if e.fingers == [false, false, false, true] { fired.append("pinkyAnyThumb") }
            for k in fired { hits[k, default: 0] += 1 }
        }
        let cols = hits.sorted { $0.key < $1.key }.map { "\($0.key) \(Int((Double($0.value) * 100 / Double(max(n, 1))).rounded()))%" }
        print("\((dir as NSString).lastPathComponent) (\(n) hands): " + cols.joined(separator: "  "))
    }
    exit(0)
}

// The wake phrase matching, the cleanup, and end-of-speech timing. With a WAV argument it
// also runs Apple's on-device recognizer over the file (needs Speech Recognition access for this binary).
if args.count >= 2, args[1] == "--test-wake" {
    var failures = 0
    func expect(_ what: String, _ got: String, _ want: String) {
        print("\(got == want ? "PASS" : "FAIL")  \(what)\(got == want ? "" : "  (got \(got), want \(want))")")
        if got != want { failures += 1 }
    }
    let gold = WakeWord.buildWakeRegex(phrase: "Hey GoldWare", aliases: [])
    for (heard, want) in [("Hey GoldWare", true), ("hey gold wear add milk", true), ("okay goldware", true), ("Okay, GoldWare.", true),
                          ("hey gold ware what's on my plate", true), ("hi goldwear", true), ("hey gold-ware", true),
                          ("golden retriever", false), ("gold", false), ("GoldWare", false), ("I told them about goldware", false),
                          ("hey golden", false), ("my computer is slow", false), ("hey computer", false), ("hey there", false)] {
        expect("wake: \"\(heard)\"", "\(WakeWord.heardWake(heard, using: gold))", "\(want)")
    }
    for (said, want) in [("Hey GoldWare, remind me to call Sam", "Remind me to call Sam"),
                         ("So yeah. Hey GoldWare what's on my plate?", "What's on my plate?"),
                         ("GoldWare, turn on vision mode", "Turn on vision mode"),
                         ("Hey GoldWare.", ""), ("remind me to call Sam", "Remind me to call Sam")] {
        expect("strip: \"\(said)\"", WakeWord.stripWake(said, using: gold), want)
    }
    // A different configured name wakes on its own phrase and not on the default one.
    let nova = WakeWord.buildWakeRegex(phrase: "Hey Nova", aliases: ["hey no va"])
    for (heard, want) in [("hey nova", true), ("Okay Nova, what's next", true), ("hey no va", true), ("hey goldware", false), ("nova", false)] {
        expect("nova wake: \"\(heard)\"", "\(WakeWord.heardWake(heard, using: nova))", "\(want)")
    }
    expect("nova strip", WakeWord.stripWake("Hey Nova, add milk to the list", using: nova), "Add milk to the list")
    // Aliases from the config are used too, and the live path reads the configured phrase.
    var custom = GWSettings(); custom.assistantName = "Nova"; custom.wakePhrase = "Hey Nova"; custom.wakeAliases = ["hey noova"]
    GWConfig.inject(custom)
    expect("configured phrase wakes", "\(WakeWord.heardWake("hey nova") && WakeWord.heardWake("hey noova") && !WakeWord.heardWake("hey goldware"))", "true")
    expect("configured name is used for the hints", "\(WakeWord.contextualStrings.contains("Hey Nova") && !WakeWord.contextualStrings.contains { $0.lowercased().contains("gold") })", "true")
    GWConfig.inject(nil)
    // Invalid config falls back to defaults and says why.
    expect("invalid config is rejected", "\((try? GWSettings.parse(Data(#"{"assistantName":""}"#.utf8))) == nil)", "true")
    expect("missing fields keep defaults", "\((try? GWSettings.parse(Data("{}".utf8)))?.wakePhrase ?? "nil")", "Hey GoldWare")
    // Feeds loudness in 64 ms chunks (the tap's size); returns the verdict, when, and the gap since the last word.
    func run(_ pattern: [(Float, Double)]) -> (Endpointer.Verdict, Double, Double) {
        var e = Endpointer(floor: -62)
        var t = 0.0, lastVoice = 0.0
        for (db, secs) in pattern {
            var left = secs
            while left > 0.001 {
                let v = e.feed(db: db, seconds: 0.064)
                t += 0.064; left -= 0.064
                if db > -40 { lastVoice = t }
                if v != .listening { return (v, t, t - lastVoice) }
            }
        }
        return (.listening, t, t - lastVoice)
    }
    let quiet: Float = -62, voice: Float = -30
    let r1 = run([(voice, 0.4), (quiet, 0.4), (voice, 2.5), (quiet, 0.5), (voice, 1.0), (quiet, 3)])
    expect("a request with a short pause ends about 1.2 s after the last word", "\(r1.0) \(r1.2 >= 1.2 && r1.2 < 1.3)", "done true")
    let r2 = run([(quiet, 8)])
    expect("nothing said after the wake phrase gives up at 5 s", "\(r2.0) \(String(format: "%.0f", r2.1))", "nothing 5")
    let r3 = run([(voice, 40)])
    expect("a request never runs past 30 s", "\(r3.0) \(String(format: "%.0f", r3.1))", "done 30")
    let r4 = run([(quiet, 1.0), (voice, 0.15), (quiet, 1.5), (voice, 1.2), (quiet, 2)])
    expect("a click or a cough is not the request (it waits for real words)", "\(r4.0) \(r4.1 > 4.9 && r4.2 < 1.3)", "done true")
    // Words: a noisy room keeps loudness busy, so the transcript going quiet ends the request.
    var w = WordEndpointer(start: 0)
    for (t, text) in [(0.8, "remind"), (1.1, "remind me"), (1.6, "remind me to call"), (2.2, "remind me to call Alfred")] { w.heard(text, at: t) }
    w.heard("remind me to call Alfred", at: 3.0)   // the same words again are not new words
    expect("words: still listening 1.4 s after the last new word", "\(w.verdict(at: 3.6))", "listening")
    expect("words: done 1.5 s after the last new word, even while the room stays loud", "\(w.verdict(at: 3.7))", "done")
    var mid = WordEndpointer(start: 0); mid.heard("remind me", at: 1); mid.heard("remind me to call", at: 2.2)
    expect("words: a pause under 1.5 s mid-sentence keeps listening", "\(mid.verdict(at: 3.5))", "listening")
    let none = WordEndpointer(start: 0)
    expect("words: no words by 6 s is nothing", "\(none.verdict(at: 5.9)) \(none.verdict(at: 6.0))", "listening nothing")

    if args.count >= 3 {
        // A real clip: the wake phrase, then a request, with silence after it, 16 kHz mono.
        let url = URL(fileURLWithPath: args[2])
        let data = (try? Data(contentsOf: url)) ?? Data()
        let pcm: [Int16] = data.count > 44 ? data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) } : []
        var e = Endpointer(floor: -60)
        var t = 0.0, lastLoud = 0.0, verdict = Endpointer.Verdict.listening
        var i = 0
        while i < pcm.count, verdict == .listening {
            let chunk = pcm[i..<min(i + 1024, pcm.count)]
            let rms = (chunk.reduce(Float(0)) { $0 + pow(Float($1) / 32768, 2) } / Float(chunk.count)).squareRoot()
            let db = 20 * log10(max(rms, 1e-6))
            t += Double(chunk.count) / 16_000
            if db > -40 { lastLoud = t }
            verdict = e.feed(db: db, seconds: Double(chunk.count) / 16_000)
            i += 1024
        }
        print(String(format: "  clip: speech ends %.2f s, capture ends %.2f s (%@)", lastLoud, t, "\(verdict)"))
        expect("real speech: ends after the last word, within 1.5 s", "\(verdict) \(t - lastLoud > 0.9 && t - lastLoud < 1.5)", "done true")
        // Whisper (the running app's server) and the wake-phrase cleanup, as a wake request is handled.
        let sem = DispatchSemaphore(value: 0)
        var heard = ""
        Task { heard = (try? await WhisperEngine().transcribe(url, vocabulary: Vocabulary.load())) ?? ""; sem.signal() }
        _ = sem.wait(timeout: .now() + 60)
        print("  whisper heard: \(heard)")
        print("  Assistant gets:    \(WakeWord.stripWake(heard))")
        expect("the request reaches the assistant without the wake phrase", "\(WakeWord.heardWake(heard)) \(WakeWord.heardWake(WakeWord.stripWake(heard)))", "true false")
    }
    print(failures == 0 ? "All wake checks passed" : "\(failures) wake check(s) failed")
    exit(failures == 0 ? 0 : 1)
}

// The Command + Option shortcut: real key events through the real monitor, fed in by hand.
if args.count >= 2, args[1] == "--test-chord" {
    var failures = 0
    func expect(_ what: String, _ ok: Bool) { print("\(ok ? "PASS" : "FAIL")  \(what)"); if !ok { failures += 1 } }
    enum K { case down(UInt16), up(UInt16), key(UInt16), click, wait(Double), sysKey }
    // Left/right Command 55/54, left/right Option 58/61, Shift 56, Control 59.
    let flag: [UInt16: NSEvent.ModifierFlags] = [55: .command, 54: .command, 58: .option, 61: .option, 56: .shift, 59: .control]
    func run(_ seq: [K]) -> (chords: Int, talk: [String]) {
        let h = HotkeyMonitor()
        var chords = 0, talk: [String] = []
        var counter: UInt32 = 0
        h.activity = { counter }
        h.onChord = { chords += 1 }
        h.onPress = { talk.append("press \($0.rawValue)") }
        h.onRelease = { m, _ in talk.append("release \(m.rawValue)") }
        h.onOtherKey = { _, held in if held { talk.append("cancel") } }
        var down = Set<UInt16>(), t = 1000.0
        func mods() -> NSEvent.ModifierFlags { down.reduce([]) { $0.union(flag[$1] ?? []) } }
        for k in seq {
            switch k {
            case .down(let c): down.insert(c)
                h.handle(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: mods(), timestamp: t, windowNumber: 0,
                                          context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: c)!)
            case .up(let c): down.remove(c)
                h.handle(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: mods(), timestamp: t, windowNumber: 0,
                                          context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: c)!)
            case .key(let c): counter += 1
                h.handle(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods(), timestamp: t, windowNumber: 0,
                                          context: nil, characters: "d", charactersIgnoringModifiers: "d", isARepeat: false, keyCode: c)!)
            case .click: counter += 1
                h.handle(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: mods(), timestamp: t, windowNumber: 0,
                                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            case .sysKey: counter += 1   // a key the system keeps for itself (Force Quit): only the counter moves
            case .wait(let s): t += s
            }
            t += 0.05
        }
        return (chords, talk)
    }
    expect("left Command + left Option, released: toggles", run([.down(55), .down(58), .up(58), .up(55)]).chords == 1)
    expect("Option first, then Command: toggles", run([.down(58), .down(55), .up(55), .up(58)]).chords == 1)
    expect("right-hand keys: toggles", run([.down(54), .down(61), .up(61), .up(54)]).chords == 1)
    expect("Command + Option + D (hide the Dock) does not toggle", run([.down(55), .down(58), .key(2), .up(58), .up(55)]).chords == 0)
    expect("Command + Option + Esc (Force Quit, kept by the system) does not toggle",
           run([.down(55), .down(58), .sysKey, .up(58), .up(55)]).chords == 0)
    expect("Command + Option + click (Finder) does not toggle", run([.down(55), .down(58), .click, .up(58), .up(55)]).chords == 0)
    expect("adding Shift does not toggle", run([.down(55), .down(58), .down(56), .up(56), .up(58), .up(55)]).chords == 0)
    expect("held for two seconds does not toggle", run([.down(55), .down(58), .wait(2), .up(58), .up(55)]).chords == 0)
    expect("Command alone does not toggle", run([.down(55), .up(55)]).chords == 0)
    expect("two presses toggle twice (on, then off)", run([.down(55), .down(58), .up(58), .up(55), .down(55), .down(58), .up(58), .up(55)]).chords == 2)
    let fromTalk = run([.down(61), .down(55), .up(55), .up(61)])
    expect("starting from Right Option: the dictation is cancelled, and it toggles",
           fromTalk.chords == 1 && fromTalk.talk == ["press dictate", "cancel"])
    let talkAlone = run([.down(61), .wait(1), .up(61)])
    expect("Right Option alone still dictates", talkAlone.chords == 0 && talkAlone.talk == ["press dictate", "release dictate"])
    let cmdLetter = run([.down(54), .key(0), .up(54)])
    expect("Right Command + A is still a shortcut, not a toggle", cmdLetter.chords == 0 && cmdLetter.talk == ["press assistant", "cancel"])
    print(failures == 0 ? "All chord checks passed" : "\(failures) chord check(s) failed")
    exit(failures == 0 ? 0 : 1)
}

// The right-click menu, built offscreen by the real code and listed (top level, then Vision
// Settings). Nothing is shown, clicked, or started.
if args.count >= 2, args[1] == "--menu-check" {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let menu = NSMenu()
    AppDelegate().menuNeedsUpdate(menu)
    var failures = 0
    func expect(_ what: String, _ ok: Bool) { print("\(ok ? "PASS" : "FAIL")  \(what)"); if !ok { failures += 1 } }
    let top = menu.items.map(\.title)
    for t in top where !t.isEmpty { print("  " + t) }
    let hey = menu.items.first { $0.title.contains(GWConfig.wakePhrase) }
    let vision = menu.items.first { $0.title.hasPrefix("\(GWConfig.name) Vision (camera") }
    expect("the menu has a wake phrase switch, matching the setting", hey != nil && hey?.action != nil && hey?.state == (WakeWord.enabled ? .on : .off))
    expect("the menu has a Vision switch at the top level, showing the shortcut",
           vision != nil && vision?.action != nil && vision!.title.contains("⌘⌥"))
    expect("Vision Settings holds the style, mirror, and speed",
           menu.items.first { $0.title == "\(GWConfig.name) Vision Settings" }?.submenu.map { m in
               ["Pointer:", "Quadrants:", "Hand Mirror", "Pointer Speed"].allSatisfy { k in m.items.contains { $0.title.contains(k) } } } ?? false)
    let face = menu.items.first { $0.title == "\(GWConfig.name) Vision Settings" }?.submenu?.items.first { $0.title.hasPrefix("Face ID") }
    expect("Vision Settings has a Face ID switch, matching the setting, off by default",
           face != nil && face?.action != nil && face?.state == (FaceID.enabled ? .on : .off) &&
           (UserDefaults.standard.object(forKey: FaceID.key) != nil || !FaceID.enabled))
    print(failures == 0 ? "All menu checks passed" : "\(failures) menu check(s) failed")
    exit(failures == 0 ? 0 : 1)
}

if args.count >= 2, args[1] == "--test-quadrants" {
    var failures = 0
    func expect(_ what: String, _ ok: Bool) { print("\(ok ? "PASS" : "FAIL")  \(what)"); if !ok { failures += 1 } }
    let r = (1...4).map(QuadrantTarget.rect)
    expect("quadrants tile the screen without overlap", r[0].maxX == r[1].minX && r[2].maxY == r[0].minY &&
           !r[0].intersects(r[3]) && r[0].width == r[3].width)
    expect("1 is top left and 4 is bottom right", r[0].minX < r[1].minX && r[0].minY > r[2].minY && r[3].minX > r[2].minX)
    expect("AI Cleanup ships off under 12 GB and on from 12 GB",
           !CleanupEngine.defaultOn(memory: 8 << 30) && CleanupEngine.defaultOn(memory: 12 << 30) && CleanupEngine.defaultOn(memory: 16 << 30))
    expect("without Accessibility the message says to turn it on, not that there is no text box",
           QuadrantDictation.noTargetMessage(trusted: false, app: nil).contains("Accessibility"))
    expect("an empty quadrant and a window without a text box read differently",
           QuadrantDictation.noTargetMessage(trusted: true, app: nil) == "No window here" &&
           QuadrantDictation.noTargetMessage(trusted: true, app: "Notes") == "No text box found in Notes")
    print("Accessibility: \(AXIsProcessTrusted() ? "granted" : "not granted (window lookup needs it)")")
    for q in 1...4 {
        let t = QuadrantTarget.find(q)
        print("  quadrant \(q): \(t.map { $0.appName } ?? "no window")")
    }
    print(failures == 0 ? "All quadrant checks passed" : "\(failures) quadrant check(s) failed")
    exit(failures == 0 ? 0 : 1)
}

if args.count >= 2, args[1] == "--test-lets-work" {
    var failures = 0
    func expect(_ what: String, _ ok: Bool) { print("\(ok ? "PASS" : "FAIL")  \(what)"); if !ok { failures += 1 } }
    for s in ["Let's work.", "Let\u{2019}s Work!", "lets work", "Let us work", "Hey, let's work", "okay lets work", "GoldWare, let's work",
              "Hey GoldWare, let's work.", "Let's work, GoldWare."] {
        expect("opens on \"\(s)\"", LetsWork.matches(s))
    }
    for s in ["Remind me to tell Jen let's work on it at six", "Let's work out tonight", "let's", "work", "let's work on the proposal", "finish up"] {
        expect("stays a request on \"\(s)\"", !LetsWork.matches(s))
    }
    let b = LetsWork.bounds()
    expect("four windows", b.count == 4)
    expect("1 top left, 2 top right, 3 bottom left, 4 bottom right",
           b[0][0] < b[1][0] && b[0][1] < b[2][1] && b[3][0] == b[1][0] && b[3][1] == b[2][1])
    expect("windows meet without overlap", b[0][2] == b[1][0] && b[0][3] == b[2][1])
    let fixedBounds = [[0, 0, 10, 10], [10, 0, 20, 10], [0, 10, 10, 20], [10, 10, 20, 20]]
    let plain = LetsWork.script(settings: LetsWork.Settings(command: "", terminal: "iTerm", profile: ""), bounds: fixedBounds)
    expect("no profile and no command open four default-profile windows with nothing typed in",
           plain.components(separatedBy: "create window with default profile").count - 1 == 4 && !plain.contains("write text"))
    let custom = LetsWork.Settings(command: "htop --tree", terminal: "iTerm", profile: "My \"Dev\" Profile")
    let mine = LetsWork.script(settings: custom, bounds: fixedBounds)
    expect("a configured profile and command are used in each of the four windows",
           mine.components(separatedBy: "create window with profile \"My \\\"Dev\\\" Profile\"").count - 1 == 4 &&
           mine.components(separatedBy: "write text \"htop --tree\"").count - 1 == 4)
    expect("a missing profile falls back to the default profile in each window",
           mine.components(separatedBy: "on error\n    set w to (create window with default profile)").count - 1 == 4)
    let gw = LetsWork.script(settings: LetsWork.Settings(command: "", terminal: "iTerm", profile: "GoldWare"), bounds: fixedBounds)
    expect("the GoldWare profile is used, with the fallback, and compiles",
           gw.components(separatedBy: "create window with profile \"GoldWare\"").count - 1 == 4 && gw.contains("on error"))
    let shippedData = VaultContext.resolveRoot().flatMap { try? Data(contentsOf: $0.appendingPathComponent("goldware.default.json")) }
    let shipped = shippedData.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    expect("the shipped default profile is GoldWare", ((shipped?["letsWork"] as? [String: Any])?["profile"] as? String) == "GoldWare")
    expect("the shipped default runs Hermes on its default model", ((shipped?["letsWork"] as? [String: Any])?["command"] as? String) == LetsWork.defaultCommand)
    // An install whose goldware.json predates letsWork still gets the GoldWare look and Hermes.
    let old = try? GWSettings.parse(Data(#"{"assistantName":"GoldWare"}"#.utf8))
    expect("a goldware.json without letsWork uses the GoldWare profile and Hermes on its default model",
           old?.letsWork == LetsWork.Settings(command: "hermes", terminal: "iTerm", profile: "GoldWare"))
    expect("the default command pins no model, so /model can switch", !LetsWork.defaultCommand.contains("-m ") && !LetsWork.defaultCommand.contains("--provider"))
    let oldScript = LetsWork.script(settings: old?.letsWork, bounds: fixedBounds)
    expect("that script opens the GoldWare profile and types the Hermes command",
           oldScript.contains("create window with profile \"GoldWare\"") && oldScript.contains("write text \"hermes\""))
    let shell = try? GWSettings.parse(Data(#"{"letsWork":{"command":""}}"#.utf8))
    expect("command set to empty still opens a plain shell", shell?.letsWork.command == "" && !LetsWork.script(settings: shell?.letsWork, bounds: fixedBounds).contains("write text"))
    for (what, raw, want) in [("lets-work", "goldwareos://lets-work", ShortcutRoute.letsWork), ("lock-up", "goldwareos://lock-up", .lockUp),
                              ("clear-out", "goldwareos://clear-out", .clearOut), ("a trailing slash", "goldwareos://lock-up/", .lockUp),
                              ("a query string", "goldwareos://clear-out?x=1&y=/etc", .clearOut), ("a fragment", "goldwareos://lets-work#a", .letsWork),
                              ("an upper-case host", "GoldWareOS://Lets-Work", .letsWork)] {
        expect("route \(what) parses", URL(string: raw).flatMap { ShortcutRoute(url: $0) } == want)
    }
    for raw in ["goldwareos://evil", "goldwareos://", "goldwareos:///lets-work", "goldwareos://lets-work/extra", "goldwareos://x/lets-work",
                "goldwareos://lets-work.evil.com", "goldwareos://user@lock-up", "goldwareos://lock-up:80", "https://lets-work", "http://127.0.0.1:4188/lets-work",
                "goldwareos2://lets-work", "file:///lets-work", "goldwareos:lock-up", "goldwareos://lock-up/../clear-out"] {
        expect("route rejects \(raw)", URL(string: raw).flatMap { ShortcutRoute(url: $0) } == nil)
    }
    expect("exactly three routes exist", ShortcutRoute.allCases.count == 3)
    expect("a cold start closes iTerm's own default window", mine.contains("is running") && mine.contains("close s"))
    expect("the permission error names the configured assistant", {
        var s = GWSettings(); s.assistantName = "Nova"; GWConfig.inject(s); defer { GWConfig.inject(nil) }
        return TerminalCommands.friendly("error -1743").contains("Allow Nova to control iTerm")
    }())
    let cfg = try? GWSettings.parse(Data(#"{"letsWork":{"command":"claude","terminal":"iTerm","profile":"Dev"}}"#.utf8))
    expect("goldware.json letsWork is read", cfg?.letsWork == LetsWork.Settings(command: "claude", terminal: "iTerm", profile: "Dev"))
    expect("letsWork missing keeps the defaults", (try? GWSettings.parse(Data("{}".utf8)))?.letsWork == LetsWork.Settings())
    expect("a bad letsWork is rejected", (try? GWSettings.parse(Data(#"{"letsWork":{"command":5}}"#.utf8))) == nil)
    for (name, script) in [("default", plain), ("configured", mine), ("GoldWare", gw)] {
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        check.arguments = ["-o", NSTemporaryDirectory() + "lets-work-check.scpt", "-e", script]
        try? check.run(); check.waitUntilExit()
        expect("the \(name) AppleScript compiles", check.terminationStatus == 0)
    }
    print(failures == 0 ? "All Let's work checks passed" : "\(failures) Let's work check(s) failed")
    exit(failures == 0 ? 0 : 1)
}

if args.count >= 2, args[1] == "--test-terminal-commands" {
    var failures = 0
    func expect(_ what: String, _ ok: Bool) { print("\(ok ? "PASS" : "FAIL")  \(what)"); if !ok { failures += 1 } }
    for s in ["Finish up.", "finish up", "GoldWare, finish up", "Hey GoldWare, finish up!", "Finish up, GoldWare."] {
        expect("finish up on \"\(s)\"", TerminalCommands.matchesFinishUp(s) && !TerminalCommands.matchesLockUp(s))
    }
    for s in ["Lock up.", "lockup", "GoldWare, lock up", "Hey GoldWare lock up!"] {
        expect("lock up on \"\(s)\"", TerminalCommands.matchesLockUp(s) && !TerminalCommands.matchesFinishUp(s))
    }
    for s in ["Remind me to finish up the report", "finish up the deck", "lock up the house at nine", "finish", "lock", "up",
              "Let's work"] {
        expect("stays a request on \"\(s)\"", !TerminalCommands.matchesFinishUp(s) && !TerminalCommands.matchesLockUp(s))
    }
    let ps = """
    ??       /usr/bin/python3 -I -c import os\\012from hermes_cli.main import main --run-module x -- hermes gateway run
    ttys001  /usr/bin/python3 -I -c import os\\012if sys.argv[1:2] == ['--run-module']:\\012from hermes_cli.main import main
    ttys002  /usr/bin/python3 -I -c import os\\012from hermes_cli.main import main -m claude-opus-5-5 --provider anthropic
    ttys002  /usr/bin/python3 child of the same hermes_cli.main
    ttys003  -zsh
    ttys004  vim notes.md
    """
    let ttys = TerminalCommands.hermesTTYs(psOutput: ps)
    expect("finds each Hermes chat once, skips the gateway and plain shells", ttys == ["/dev/ttys001", "/dev/ttys002"])
    expect("lock up finds each terminal's processes, not its login", TerminalCommands.pidsOn(["ttys001"], psOutput: """
    44866 /usr/bin/login
    44868 -zsh
    44884 /usr/bin/python3
    """) == [44868, 44884])
    let fs = TerminalCommands.finishScript(ttys: ttys)
    expect("finish up queues the wrap-up prompt, then sends Return separately",
           TerminalCommands.finishLine == "/queue Finish up this session and commit anything that needs to be committed." &&
           fs.contains("write text \"\(TerminalCommands.finishLine)\" newline no") && fs.contains("do script \"\(TerminalCommands.finishLine)\" in t") &&
           fs.contains("write text \"\"") && fs.contains("{\"/dev/ttys001\", \"/dev/ttys002\"}"))
    expect("never launches iTerm or Terminal", fs.contains("application \"iTerm\" is running") && fs.contains("application \"Terminal\" is running") &&
                      TerminalCommands.listScript.contains("is running") &&
           TerminalCommands.closeScript(ttys: []).contains("is running") && TerminalCommands.screensScript(ttys: []).contains("is running"))
    for s in ["Clear out", "clear out", "GoldWare, clear out", "Hey GoldWare clear out!", "clearing out"] {
        expect("clear out on \"\(s)\"", TerminalCommands.matchesClearOut(s) && !TerminalCommands.matchesLockUp(s) && !TerminalCommands.matchesFinishUp(s))
    }
    for s in ["clear out the garage", "clear", "Lock up", "Finish up"] {
        expect("not clear out on \"\(s)\"", !TerminalCommands.matchesClearOut(s))
    }
    let yaml = "  t380: \"tip\"\n  # Empty-composer example prompts\n  placeholder:\n    p01: \"Ask anything\"\n    p02: \"Find and fix a failing test\"\n  other:\n    x: \"no\"\n"
    let ph = TerminalCommands.placeholders(yaml: yaml)
    expect("reads Hermes's grey example prompts", ph == ["Ask anything", "Find and fix a failing test"])
    expect("without a Hermes install the built-in example prompts are used", TerminalCommands.placeholders(yaml: "").contains("Find and fix a failing test") && !TerminalCommands.placeholders().isEmpty)
    let bar = "────────────"
    func screen(_ prompt: String) -> String { "Welcome to Hermes Agent!\n ☤ claude-opus-5-5 │ ctx --\n\(bar)\n\(prompt)\n\(bar)\n  " }
    let chats = ["ttys001": ["fresh"], "ttys002": ["talked"], "ttys003": ["fresh2"], "ttys004": ["fresh3"], "ttys005": ["old", "fresh4"]]
    let users = ["talked": 3, "old": 2]
    let screens = ["/dev/ttys001": screen("❯ "), "/dev/ttys002": screen("❯ "), "/dev/ttys003": screen("❯ Find and fix a failing test"),
                   "/dev/ttys004": screen("❯ fix the login bu"), "/dev/ttys005": screen("❯ ")]
    expect("clear out closes fresh Hermes chats (empty or grey example), keeps one you wrote in, one with typing, and a tty with an older chat",
           TerminalCommands.emptyTTYs(chats: chats, userMessages: users, screens: screens, placeholders: ph) == ["/dev/ttys001", "/dev/ttys003"])
    expect("clear out never closes a terminal whose screen it could not read",
           TerminalCommands.emptyTTYs(chats: ["ttys001": ["fresh"]], userMessages: [:], screens: [:], placeholders: ph).isEmpty)
    expect("a screen with no Hermes prompt is not empty", !TerminalCommands.promptIsEmpty("Last login: today\n$ ", placeholders: ph))
    let cs = TerminalCommands.closeScript(ttys: ["/dev/ttys001", "/dev/ttys003"])
    expect("clear out closes only the listed terminals and quits an app only when it has no windows left",
           cs.contains("{\"/dev/ttys001\", \"/dev/ttys003\"}") && cs.contains("if targets contains (tty of s) then set end of victims to contents of s") &&
           cs.contains("if (count of windows) = 0 then quit") && !cs.contains("to quit"))
    let cliPS = """
    ttys001   0.0 /bin/zsh
    ttys003  42.5 /opt/tools/bin/claude
    ttys004   0.1 claude
    ttys005  12.0 /opt/homebrew/bin/codex
    ??       80.0 /usr/local/bin/claude
    """
    let cli = TerminalCommands.cliAgents(psOutput: cliPS)
    expect("reads Claude Code and Codex processes with their CPU", cli.count == 5 && cli[1].name == "claude" && cli[1].cpu == 42.5)
    let busy = TerminalCommands.busyTTYs(chats: ["ttys001": ["idle"], "ttys002": ["working"], "ttys006": ["old", "helping"]],
                                         leased: ["working", "helping"], cli: cli)
    expect("lock up keeps only agents mid-task: a leased Hermes, a busy Claude Code or Codex; idle agents and shells close",
           busy == ["/dev/ttys002", "/dev/ttys003", "/dev/ttys005", "/dev/ttys006"])
    for (name, script) in [("finish up", fs), ("the terminal list", TerminalCommands.listScript),
                           ("close", cs), ("screens", TerminalCommands.screensScript(ttys: ["/dev/ttys001"]))] {
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        check.arguments = ["-o", NSTemporaryDirectory() + "terminal-commands-check.scpt", "-e", script]
        try? check.run(); check.waitUntilExit()
        expect("the \(name) AppleScript compiles", check.terminationStatus == 0)
    }
    expect("Let's work is not taken by the terminal phrases", !LetsWork.matches("finish up") && !LetsWork.matches("lock up") && !LetsWork.matches("clear out"))
    expect("Hermes not installed: no chats, no leased sessions, nothing to read", TerminalCommands.leasedSessions([]) == [] && TerminalCommands.userMessageCounts([]) == [:])
    expect("a configured assistant name is accepted around the phrase", TerminalCommands.matchesLockUp("Hey Nova, lock up") == false &&
           TerminalCommands.matchesPhrase("Hey Nova, lock up", "(lock up)", names: ["nova"]) && TerminalCommands.matchesPhrase("nova lock up", "(lock up)", names: ["nova"]))
    print(failures == 0 ? "All terminal command checks passed" : "\(failures) terminal command check(s) failed")
    exit(failures == 0 ? 0 : 1)
}

// Let's work from the command line: `--print` shows the AppleScript, otherwise it opens the windows.
if args.count >= 2, args[1] == "--lets-work" {
    if args.contains("--print") { print(LetsWork.script()); exit(0) }
    let error = LetsWork.open(LetsWork.script())
    print(error ?? "Opened four terminals")
    exit(error == nil ? 0 : 1)
}

// Read-only: every on-screen window, which quadrant it fills (if any), and whether Accessibility can
// move it. Moves nothing.
if args.count >= 2, args[1] == "--list-windows" {
    let quads = (1...4).map(QuadrantTarget.rect)
    let top = NSScreen.screens[0].frame.maxY
    let cgQuads = quads.map { QuadrantTarget.cg($0, top: top) }
    print("screens: " + NSScreen.screens.map { "\(NSStringFromRect($0.frame))\($0.safeAreaInsets.top > 0 ? " (camera)" : "")" }.joined(separator: ", "))
    print("quadrant: \(Int(quads[0].width)) x \(Int(quads[0].height))")
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { exit(1) }
    for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
        guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, let b = w[kCGWindowBounds as String] as? [String: CGFloat],
              let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"] else { continue }
        let r = CGRect(x: x, y: y, width: width, height: height)
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        let q = cgQuads.firstIndex { abs($0.minX - r.minX) + abs($0.minY - r.minY) + abs($0.width - r.width) + abs($0.height - r.height) < 3 }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v)
        let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
        var sub = "-", sizable = false, movable = false
        if let wins = v as? [AXUIElement] {
            for aw in wins {
                var p: CFTypeRef?, sz: CFTypeRef?
                AXUIElementCopyAttributeValue(aw, kAXPositionAttribute as CFString, &p)
                AXUIElementCopyAttributeValue(aw, kAXSizeAttribute as CFString, &sz)
                var pt = CGPoint.zero, size = CGSize.zero
                if let p { AXValueGetValue(p as! AXValue, .cgPoint, &pt) }
                if let sz { AXValueGetValue(sz as! AXValue, .cgSize, &size) }
                guard abs(pt.x - r.minX) + abs(pt.y - r.minY) + abs(size.width - r.width) + abs(size.height - r.height) < 40 else { continue }
                var sr: CFTypeRef?
                AXUIElementCopyAttributeValue(aw, kAXSubroleAttribute as CFString, &sr)
                sub = sr as? String ?? "none"
                var b1: DarwinBoolean = false, b2: DarwinBoolean = false
                AXUIElementIsAttributeSettable(aw, kAXSizeAttribute as CFString, &b1)
                AXUIElementIsAttributeSettable(aw, kAXPositionAttribute as CFString, &b2)
                sizable = b1.boolValue; movable = b2.boolValue
            }
        }
        print(String(format: "%-11@ %5.0f,%5.0f %5.0fx%-5.0f %@ alpha %.2f  ax:%d  subrole %@  size %@ move %@", (owner as NSString).substring(to: min(11, owner.count)),
                     r.minX, r.minY, r.width, r.height, q.map { "Q\($0 + 1)" } ?? "--", alpha, err.rawValue, sub,
                     sizable ? "yes" : "no", movable ? "yes" : "no"))
    }
    exit(0)
}

// Read-only: every regular app's windows as Accessibility sees them, on every Space, with full-screen
// and minimized state. Moves nothing.
if args.count >= 2, args[1] == "--list-app-windows" {
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 1)
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &v)
        let wins = (v as? [AXUIElement]) ?? []
        print("\(app.localizedName ?? "?") (pid \(app.processIdentifier)) ax \(err.rawValue), \(wins.count) window(s)")
        for w in wins {
            func a(_ n: String) -> CFTypeRef? { var r: CFTypeRef?; AXUIElementCopyAttributeValue(w, n as CFString, &r); return r }
            var pt = CGPoint.zero, sz = CGSize.zero
            if let p = a(kAXPositionAttribute) { AXValueGetValue(p as! AXValue, .cgPoint, &pt) }
            if let s = a(kAXSizeAttribute) { AXValueGetValue(s as! AXValue, .cgSize, &sz) }
            let title = (a(kAXTitleAttribute) as? String ?? "").prefix(30)
            print(String(format: "   %5.0f,%5.0f %5.0fx%-5.0f %@ full %@ min %@  \"%@\"", pt.x, pt.y, sz.width, sz.height,
                         a(kAXSubroleAttribute) as? String ?? "-", "\(a("AXFullScreen") as? Bool ?? false)",
                         "\(a(kAXMinimizedAttribute) as? Bool ?? false)", String(title)))
        }
    }
    exit(0)
}

// Brings quadrant N's front window forward now, exactly as holding up N fingers does, and prints the
// window order before and after. Only run when asked: it changes which app is in front.
if args.count >= 3, args[1] == "--raise-quadrant", let q = Int(args[2]), (1...4).contains(q) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    func order() -> String { QuadrantTarget.listed().prefix(4).map { "\($0.name)@\(Int($0.bounds.minX)),\(Int($0.bounds.minY))" }.joined(separator: " > ") }
    print("before: " + order())
    guard let t = QuadrantTarget.find(q) else { print("no window in quadrant \(q)"); exit(1) }
    print("quadrant \(q): \(t.appName)")
    t.raise()
    RunLoop.main.run(until: Date() + 0.6)
    print("after:  " + order())
    let front = QuadrantTarget.listed().first
    let area = QuadrantTarget.cg(QuadrantTarget.rect(q), top: NSScreen.screens[0].frame.maxY)
    let ok = front.map { $0.pid == t.pid && area.contains(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY)) } ?? false
    print(ok ? "PASS  quadrant \(q)'s window is in front of every other window" : "FAIL  quadrant \(q)'s window is not in front")
    exit(ok ? 0 : 1)
}

// Tiles your real windows into the quadrants now, as switching into Quadrants does, and reports
// what each window did. Only run when asked: it moves and resizes windows.
if args.count >= 2, args[1] == "--arrange" {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let quads = (1...4).map(QuadrantTarget.rect)
    let top = NSScreen.screens[0].frame.maxY
    let apps = QuadrantTarget.regularApps()
    var done = false
    DispatchQueue.global().async {
        let placed = QuadrantTarget.arrange(quadrants: quads, screenTop: top, apps: apps, log: { print("  " + $0) })
        print("placed: " + placed.sorted { $0.key < $1.key }.map { "Q\($0.key) \($0.value.app) +\($0.value.behind)" }.joined(separator: ", "))
        done = true
    }
    let deadline = Date() + 30
    while !done && Date() < deadline { RunLoop.main.run(until: Date() + 0.05) }
    exit(0)
}

// Tiling into quadrants: the plan (which window goes where), then the real Accessibility moves on four
// nearly invisible windows of this test's own. Nobody else's windows are touched.
if args.count >= 2, args[1] == "--test-arrange" {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()   // without this the process does not answer Accessibility about its own windows
    var failures = 0
    func expect(_ what: String, _ ok: Bool, _ detail: String = "") {
        print("\(ok ? "PASS" : "FAIL")  \(what)\(ok || detail.isEmpty ? "" : "  (\(detail))")"); if !ok { failures += 1 }
    }
    let q = [CGRect(x: 0, y: 0, width: 500, height: 400), CGRect(x: 500, y: 0, width: 500, height: 400),
             CGRect(x: 0, y: 400, width: 500, height: 400), CGRect(x: 500, y: 400, width: 500, height: 400)]
    func show(_ p: [(window: Int, quadrant: Int)]) -> String { p.sorted { $0.window < $1.window }.map { "\($0.window)>\($0.quadrant + 1)" }.joined(separator: " ") }
    let loose = CGRect(x: 120, y: 90, width: 700, height: 500)
    let six = QuadrantTarget.plan(Array(repeating: loose, count: 6), into: q)
    expect("every window is placed, not just four", six.count == 6)
    expect("the four frontmost each get their own quadrant", Set(six.prefix(4).map(\.quadrant)).count == 4, show(six))
    let loads = (0..<4).map { k in six.filter { $0.quadrant == k }.count }
    expect("the rest spread out, never three in one while one has one", (loads.max() ?? 0) - (loads.min() ?? 0) <= 1, "\(loads)")
    expect("a window already in a quadrant keeps it", show(QuadrantTarget.plan([loose, q[3], loose], into: q)).contains("1>4"),
           show(QuadrantTarget.plan([loose, q[3], loose], into: q)))
    let right = CGRect(x: 520, y: 20, width: 460, height: 700)
    expect("a new window goes to the nearest free quadrant", show(QuadrantTarget.plan([right], into: q)) == "0>2",
           show(QuadrantTarget.plan([right], into: q)))
    let big = CGRect(x: 1000 - 600, y: 800 - 450, width: 600, height: 450)   // a window with a minimum size, pinned to Q4's corner
    expect("a window the app pinned (too big for a quarter) counts as placed", QuadrantTarget.sits(big, in: q, 3, pinned: [big]))
    let maximized = CGRect(x: 0, y: 0, width: 1000, height: 800)
    expect("a maximized window is not 'already placed', it gets resized", !q.indices.contains { QuadrantTarget.sits(maximized, in: q, $0, pinned: []) })
    let three = QuadrantTarget.plan([maximized, maximized, maximized], into: q, pinned: [])
    expect("several maximized windows spread out instead of stacking in 1", Set(three.map(\.quadrant)).count == 3, show(three))

    guard AXIsProcessTrusted() else {
        print("SKIP  live tiling: this binary has no Accessibility access")
        exit(failures == 0 ? 0 : 1)
    }
    let quads = (1...4).map(QuadrantTarget.rect)
    let top = NSScreen.screens[0].frame.maxY
    let area = quads.reduce(NSRect.null) { $0.union($1) }
    var windows: [NSWindow] = []
    for i in 0..<6 {
        let w = NSWindow(contentRect: NSRect(x: area.midX - 260 + CGFloat(i) * 41, y: area.midY - 170 + CGFloat(i) * 27, width: 420, height: 300),
                         styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        w.title = "Tiling test \(i)"
        w.alphaValue = 0.02
        w.isReleasedWhenClosed = false
        if i == 5 { w.minSize = NSSize(width: quads[0].width + 150, height: quads[0].height + 100) }   // cannot shrink to a quarter
        if i == 4 { w.setFrame(area, display: false) }   // maximized: fills the screen, touching every corner
        w.orderFrontRegardless()
        windows.append(w)
    }
    RunLoop.main.run(until: Date() + 0.4)
    func tile() -> [Int: (app: String, behind: Int)] {
        var placed: [Int: (app: String, behind: Int)] = [:]
        var finished = false
        DispatchQueue.global().async {
            let p = QuadrantTarget.arrange(quadrants: quads, screenTop: top, apps: [(getpid(), "test")])
            DispatchQueue.main.async { placed = p; finished = true }
        }
        let deadline = Date() + 10
        while !finished && Date() < deadline { RunLoop.main.run(until: Date() + 0.05) }
        RunLoop.main.run(until: Date() + 0.3)
        return placed
    }
    let t0 = Date()
    let placed = tile()
    let ms = Int(Date().timeIntervalSince(t0) * 1000)
    let cgq = quads.map { QuadrantTarget.cg($0, top: top) }
    func where_(_ w: NSWindow) -> Int? { cgq.indices.first { QuadrantTarget.sits(QuadrantTarget.cg(w.frame, top: top), in: cgq, $0) } }
    let spots = windows.map(where_)
    expect("all six windows tiled into quadrants (\(ms) ms)", spots.allSatisfy { $0 != nil }, windows.map { NSStringFromRect($0.frame) }.joined(separator: ", "))
    expect("the four frontmost windows land in four different quadrants", Set(spots[2...5].compactMap { $0 }).count == 4, "\(spots)")
    expect("the one that cannot shrink stays on screen, pinned to its corner",
           NSScreen.screens[0].visibleFrame.contains(windows[5].frame), NSStringFromRect(windows[5].frame))
    expect("each quadrant reports its front app and how many wait behind",
           placed.count == 4 && placed.values.map(\.behind).reduce(0, +) == 2, "\(placed.mapValues { $0.behind })")
    let before = windows.map(\.frame)
    windows[0].orderFrontRegardless()   // bring another one forward, as using the Mac would
    RunLoop.main.run(until: Date() + 0.2)
    _ = tile()
    expect("tiling again moves nothing, whichever window is in front", windows.map(\.frame) == before)
    windows.forEach { $0.close() }
    print("  quadrant size here: \(Int(quads[0].width)) x \(Int(quads[0].height)) points")
    print(failures == 0 ? "All arrange checks passed" : "\(failures) arrange check(s) failed")
    exit(failures == 0 ? 0 : 1)
}

// Shelf self-check on a private pasteboard: files, images, and the item limit. Touches no real shelf.
if args.count >= 2, args[1] == "--test-shelf" {
    let shelf = ShelfStore(persists: false)
    var failures = 0
    func expect(_ what: String, _ ok: Bool) { print("\(ok ? "PASS" : "FAIL")  \(what)"); if !ok { failures += 1 } }
    let pb = NSPasteboard(name: NSPasteboard.Name("gw-shelf-test-\(UUID().uuidString)"))
    defer { pb.releaseGlobally() }
    let readme = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    pb.clearContents(); pb.writeObjects([readme as NSURL])
    expect("accepts a dropped file", ShelfStore.canAccept(pb) && shelf.accept(pb) && shelf.items.first == readme)
    pb.clearContents(); pb.writeObjects([readme as NSURL])
    shelf.accept(pb)
    expect("the same file is not shelved twice", shelf.items.count == 1)
    let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { r in NSColor.orange.setFill(); r.fill(); return true }
    pb.clearContents(); pb.writeObjects([image])
    let tookImage = shelf.accept(pb)
    let saved = shelf.items.first
    expect("accepts a pasted image and saves it as a PNG", tookImage && saved?.pathExtension == "png" &&
           saved.map { FileManager.default.fileExists(atPath: $0.path) } == true)
    pb.clearContents(); pb.setString("just text", forType: .string)
    expect("ignores plain text", !ShelfStore.canAccept(pb) && !shelf.accept(pb))
    for i in 0..<12 { shelf.add(URL(fileURLWithPath: "/tmp/gw-shelf-\(i)")) }
    expect("keeps at most \(ShelfStore.maxItems), newest first", shelf.items.count == ShelfStore.maxItems &&
           shelf.items.first?.lastPathComponent == "gw-shelf-11")
    shelf.prune()
    expect("drops files that no longer exist", shelf.items.isEmpty)
    if let saved, saved.pathExtension == "png" { try? FileManager.default.removeItem(at: saved) }
    print(failures == 0 ? "All shelf checks passed" : "\(failures) shelf check(s) failed")
    exit(failures == 0 ? 0 : 1)
}

// Plan limits parsing on canned responses (no network), plus a live read with --live.
if args.count >= 2, args[1] == "--test-plan-usage" {
    var failures = 0
    func expect(_ what: String, _ ok: Bool) { print("\(ok ? "PASS" : "FAIL")  \(what)"); if !ok { failures += 1 } }
    let claude = #"{"five_hour":{"utilization":26.0,"resets_at":"2026-10-01T00:59:59.912253+00:00"},"seven_day":{"utilization":29.0,"resets_at":"2026-10-03T22:59:59+00:00"},"seven_day_opus":null}"#
    let c = PlanUsage.parseClaude(Data(claude.utf8)) ?? []
    expect("Claude: 5-hour then weekly", c.map(\.label) == ["5H", "WEEK"] && c.map(\.percent) == [26, 29])
    expect("Claude: reset times with and without fractional seconds", c.allSatisfy { $0.resets != nil })
    let codex = #"{"rate_limit":{"primary_window":{"used_percent":40,"limit_window_seconds":604800,"reset_at":1791085345},"secondary_window":{"used_percent":7,"limit_window_seconds":18000,"reset_at":1790900000}}}"#
    let x = PlanUsage.parseCodex(Data(codex.utf8)) ?? []
    expect("Codex: short window first, weekly last", x.map(\.label) == ["5H", "WEEK"] && x.last?.percent == 40)
    expect("Codex: reset time from epoch", x.last?.resets == Date(timeIntervalSince1970: 1791085345))
    expect("Codex: weekly-only plan", PlanUsage.parseCodex(Data(#"{"rate_limit":{"primary_window":{"used_percent":40,"limit_window_seconds":604800},"secondary_window":null}}"#.utf8))?.map(\.label) == ["WEEK"])
    expect("unknown shapes are rejected, not guessed", PlanUsage.parseClaude(Data(#"{"error":"x"}"#.utf8)) == nil &&
           PlanUsage.parseCodex(Data("<html>".utf8)) == nil)
    let now = Date(timeIntervalSince1970: 1_790_800_000)
    expect("reset text: time today, weekday later", PlanUsage.resetText(now + 3600, now: now).contains(":") &&
           !PlanUsage.resetText(now + 3 * 86_400, now: now).contains(":"))
    if args.contains("--live") {
        runAndExit {
            for p in await PlanUsage.fetchAll() {
                print("LIVE  \(p.name): " + (p.error ?? p.windows.map { "\($0.label) \(Int($0.percent))% resets \(PlanUsage.resetText($0.resets))" }.joined(separator: ", ")))
            }
            print(failures == 0 ? "All plan usage checks passed" : "\(failures) plan usage check(s) failed")
            exit(failures == 0 ? 0 : 1)
        }
    }
    print(failures == 0 ? "All plan usage checks passed" : "\(failures) plan usage check(s) failed")
    exit(failures == 0 ? 0 : 1)
}

// Work page: draft status, the Needs-you ranking, ps and git parsing, and the motion curves. No network.
if args.count >= 2, args[1] == "--test-work" {
    var failures = 0
    func expect(_ what: String, _ ok: Bool) { print("\(ok ? "PASS" : "FAIL")  \(what)"); if !ok { failures += 1 } }
    expect("pending drafts: drafted, not sent, awaiting approval", [
        "# Reply (status: drafted, pending approval)", "Status: Drafted 2026-09-29 for you to send. Not sent.",
        "Status: Draft, not sent. Revised after feedback", "Status: draft preview only, not published"].allSatisfy(WorkData.draftIsPending))
    expect("closed drafts: sent, superseded, published, no status line", ![
        "Status: Sent 2026-09-28 at 5:17 PM HST", "Status: superseded 2026-09-18.", "Status: published. Already live",
        "# Just notes with no status"].contains(where: WorkData.draftIsPending))
    expect("draft title drops the status", WorkData.draftTitle("# Draft reply to Sam: port back (status: drafted)\n\nHi", fallback: "x") == "Draft reply to Sam: port back")
    var a = Agenda(today: "2026-09-30")
    func task(_ id: String, _ title: String, status: String = "ready", due: String? = nil, pri: String? = nil) -> BoardTask {
        BoardTask(["id": id, "title": title, "revision": "r", "status": status, "due_on": due as Any, "priority": pri as Any])!
    }
    a.due = [task("d1", "Due today", due: "2026-09-30"), task("d2", "Overdue thing", due: "2026-09-20")]
    a.focus = [task("f1", "Focus low", pri: "low"), task("f2", "Focus high", pri: "high")]
    a.approvals = [task("a1", "Send Pat the TLS certificate reply", status: "approval")]
    let now = Date()
    let drafts = [WorkData.Draft(path: "/x/2026-09-30-sam-port-out-reply.md", title: "Sam port", to: "Sam", modified: now),
                  WorkData.Draft(path: "/x/2026-09-28-tls-certificate-reply.md", title: "TLS", to: "Pat", modified: now)]
    let n = WorkData.needsYou(agenda: a, drafts: drafts, now: now)
    expect("ranking: draft, overdue, due, focus high, focus low, approval (\(n.rows.map(\.title)))",
           n.rows.map(\.title) == ["Sam port", "Overdue thing", "Due today", "Focus high", "Focus low", "Send Pat the TLS certificate reply"])
    expect("a draft its task already tracks shows once", !n.rows.contains { $0.title == "TLS" } && n.count == 6)
    expect("overdue is red", n.rows[1].tone == .red && n.rows[1].meta == "OVERDUE")
    let ps = WorkData.parsePS("58421 ttys002      26:46   270496 /opt/tools/python3\n 49259 ??  1-01:43:17 20000 llama-server\n junk\n")
    expect("ps rows parse, with day-long elapsed times", ps.count == 2 && ps[0].seconds == 26 * 60 + 46 && ps[1].seconds == 86_400 + 6197 && ps[0].name == "python3")
    expect("model names read well", WorkData.prettyModel("claude-opus-5-5") == "Opus 5.5" && WorkData.prettyModel("gpt-6") == "gpt-6")
    let g = WorkData.groupStatus(" M docs/a.md\n M docs/b.md\n M docs/c.md\n M app/README.md\n?? app/Sources/WorkData.swift\n M NOTES.md\nR  old.md -> server/new/x.py\n")
    expect("git status groups by area, biggest first", g.map(\.area) == ["docs", "app", "app/Sources", "Top level", "server/new"])
    expect("new files are counted and marked", g[2].added == 1 && g[2].files == ["+ WorkData.swift"])
    expect("ago reads short", WorkData.ago(45) == "45s" && WorkData.ago(720) == "12m" && WorkData.ago(7300) == "2h" && WorkData.ago(3 * 86_400) == "3d")
    var snap = WorkSnapshot(loaded: true)
    snap.needs = n.rows; snap.needsCount = n.count; snap.repoChanged = 0
    expect("badges only where there's a count", snap.badge(.needs) == "6" && snap.badge(.repo) == nil && snap.badge(.today) == nil)
    let v = ControlCenterView()
    v.page = .controls
    v.pageAnim = (.controls, 100)
    expect("page slide eases from 0 to 1 in \(ControlCenterView.pageDuration) s",
           v.pageProgress(now: 100) == 0 && v.pageProgress(now: 100 + ControlCenterView.pageDuration / 2) > 0.8 &&
           v.pageProgress(now: 100 + ControlCenterView.pageDuration) == 1)
    v.pageAnim = nil; v.detail = .cpu
    let tall = v.intrinsicContentSize.height
    v.page = .work
    expect("the work page never carries the gauge dropdown's height", v.intrinsicContentSize.height == tall - ControlCenterView.detailHeight)
    print(failures == 0 ? "All work checks passed" : "\(failures) work check(s) failed")
    exit(failures == 0 ? 0 : 1)
}

// Control center gauge details: the ps parser, the top-five sort, and the panel growing for the dropdown.
if args.count >= 2, args[1] == "--test-control-center" {
    var failures = 0
    func expect(_ what: String, _ ok: Bool) { print("\(ok ? "PASS" : "FAIL")  \(what)"); if !ok { failures += 1 } }
    let sample = "  604  10.1 225664 WindowServer\n58323   8.5 264128 iTerm2\n  900  55.0   1024 Google Chrome Helper (Renderer)\n garbage line\n"
    let procs = TopProcesses.parse(sample)
    expect("parses ps lines, keeps names with spaces, skips junk", procs.count == 3 && procs[2].name == "Google Chrome Helper (Renderer)")
    expect("rss is KB, stored as bytes", procs[0].mem == 225664 * 1024)
    expect("top by CPU", TopProcesses.top(procs, by: .cpu).map(\.pid) == [900, 604, 58323])
    expect("top by memory", TopProcesses.top(procs, by: .memory).map(\.pid) == [58323, 604, 900])
    expect("top keeps five", TopProcesses.top(Array(repeating: procs[0], count: 9), by: .cpu).count == 5)
    let live = TopProcesses.read()
    expect("live ps returns processes (\(live.count))", live.count > 20 && live.contains { $0.name == "GoldWareOS" || $0.pid == getpid() })
    let v = ControlCenterView()
    let base = v.intrinsicContentSize.height
    v.detail = .cpu
    expect("panel grows by the dropdown height", v.intrinsicContentSize.height == base + ControlCenterView.detailHeight)
    let visible = NSScreen.main?.visibleFrame.height ?? 0
    expect("open panel fits the screen (\(Int(v.intrinsicContentSize.height)) of \(Int(visible)) pt)", visible == 0 || v.intrinsicContentSize.height + 6 <= visible)
    let s = SystemStats(); _ = s.sample(); usleep(200_000)
    let x = s.sample()
    expect("CPU split adds up (user + system = busy)", abs(x.user + x.system - x.cpu) < 0.001)
    expect("memory split adds up to Memory Used", abs(x.app + x.wired + x.compressed - x.memUsed) < 1 && x.load.count == 3)
    print(failures == 0 ? "All control center checks passed" : "\(failures) control center check(s) failed")
    exit(failures == 0 ? 0 : 1)
}

// Face ID: the hand-to-face rule, setup rules, and (given photo folders) the real model end to end.
//   --test-faceid [lfw dir] [hagrid dir]
// LFW: same person matches, different people do not. HaGRID: two gesture photos side by side, Face ID
// on with the left person enrolled, read through VisionCamera.read: no right-hand hand may survive.
if args.count >= 2, args[1] == "--test-faceid" {
    var failures = 0
    func expect(_ name: String, _ ok: Bool) { print((ok ? "PASS " : "FAIL ") + name); if !ok { failures += 1 } }
    let face = CGRect(x: 0.45, y: 0.55, width: 0.12, height: 0.2)
    let aspect: CGFloat = 16.0 / 9.0
    let fw = face.width * aspect
    let below = CGPoint(x: face.midX, y: face.midY - 1.8 * fw)
    func hand(_ ratio: CGFloat) -> CGFloat { ratio * fw }
    let owner = FaceID.Face(box: face, isOwner: true)
    let farSide = CGPoint(x: face.midX + 2.0 * face.width, y: face.midY - 0.6 * fw)
    expect("strict (someone else seen lately): a hand far out to the side is not counted", FaceID.owner(wrist: farSide, handSize: hand(0.6), faces: [owner], aspect: aspect, strict: true) == nil)
    expect("relaxed (alone): the same hand out to the side still counts", FaceID.owner(wrist: farSide, handSize: hand(0.6), faces: [owner], aspect: aspect) == 0)
    let strictClock = FaceMatcher()
    _ = strictClock.remembered(100, current: [owner, FaceID.Face(box: face.offsetBy(dx: 0.42, dy: 0), isOwner: false)])
    expect("strict for 10 s after someone else is seen, then relaxed", strictClock.isStrict(at: 109) && !strictClock.isStrict(at: 111))
    let memory = FaceMatcher()
    _ = memory.remembered(10, current: [FaceID.Face(box: face.offsetBy(dx: 0.42, dy: 0), isOwner: false)])
    let later = memory.remembered(11, current: [owner])
    expect("a stranger's face missed for a moment still claims their hands", later.count == 2 && later.contains { !$0.isOwner })
    expect("a stranger's face is forgotten after 1.5 s", memory.remembered(12, current: [owner]).count == 1)
    expect("a hand below one face belongs to it", FaceID.owner(wrist: below, handSize: hand(0.6), faces: [owner], aspect: aspect) == 0)
    for corner in [CGPoint(x: 0.02, y: 0.02), CGPoint(x: 0.98, y: 0.02), CGPoint(x: 0.02, y: 0.98), CGPoint(x: 0.98, y: 0.98)] {
        expect("alone: a hand at the frame corner \(corner) still counts (the whole frame is the zone)", FaceID.owner(wrist: corner, handSize: hand(0.6), faces: [owner], aspect: aspect) == 0)
    }
    expect("strict (someone else seen lately): a hand in the far corner is not counted", FaceID.owner(wrist: CGPoint(x: 0.02, y: 0.02), handSize: hand(0.6), faces: [owner], aspect: aspect, strict: true) == nil)
    expect("two faces: a hand far from both belongs to nobody", FaceID.owner(wrist: CGPoint(x: 0.02, y: 0.02), handSize: hand(0.6), faces: [owner, FaceID.Face(box: face.offsetBy(dx: 0.42, dy: 0), isOwner: false)], aspect: aspect) == nil)
    expect("a hand much bigger than the face (nearer the camera) is not that face's", FaceID.owner(wrist: below, handSize: hand(1.6), faces: [owner], aspect: aspect) == nil)
    expect("a hand much smaller than the face (far behind) is not that face's", FaceID.owner(wrist: below, handSize: hand(0.15), faces: [owner], aspect: aspect) == nil)
    let other = FaceID.Face(box: face.offsetBy(dx: 0.42, dy: 0), isOwner: false)   // 3.5 face widths apart, like two people side by side
    let byOther = CGPoint(x: other.box.midX, y: other.box.midY - 1.8 * fw)
    expect("with two faces, a hand under the other face is theirs", FaceID.owner(wrist: byOther, handSize: hand(0.6), faces: [owner, other], aspect: aspect) == 1)
    expect("the other person's hand is not your", !FaceID.isOwners(wrist: byOther, handSize: hand(0.6), faces: [owner, other], aspect: aspect))
    expect("your hand next to a stranger is still your", FaceID.isOwners(wrist: below, handSize: hand(0.6), faces: [owner, other], aspect: aspect))
    let between = CGPoint(x: (face.midX + other.box.midX) / 2, y: below.y)
    expect("a hand halfway between two faces belongs to nobody", FaceID.owner(wrist: between, handSize: hand(0.6), faces: [owner, other], aspect: aspect) == nil)
    expect("no faces: no hand counts", !FaceID.isOwners(wrist: below, handSize: hand(0.6), faces: [], aspect: aspect))
    expect("recognised: next face check only after 5 s", !FaceMatcher.isDue(now: 104.9, lastCheck: 100, recognised: true) && FaceMatcher.isDue(now: 105, lastCheck: 100, recognised: true))
    expect("not recognised: checks again within 0.2 s", FaceMatcher.isDue(now: 100.2, lastCheck: 100, recognised: false))
    expect("a match holds longer than one recheck", FaceID.hold > FaceID.recheckEvery)
    expect("setup needs a solid handful of looks", FaceSetup.outcome(samples: FaceSetup.minimumSamples - 1) == .tooFew && FaceSetup.outcome(samples: FaceSetup.minimumSamples) == .saved)
    expect("only one face may be you (overlap math)", abs(FaceMatcher.overlap(face, face) - 1) < 1e-6 && FaceMatcher.overlap(face, other.box) == 0)
    guard let model = FaceAligner.loadModel() else {
        expect("the fingerprint model loads", false); exit(1)
    }
    expect("the fingerprint model loads", true)
    func load(_ p: String) -> CGImage? {
        guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(s, 0, nil)
    }
    let fm = FileManager.default
    if args.count >= 3, let names = try? fm.contentsOfDirectory(atPath: args[2]) {
        // Ten people with 12+ photos: enroll 5, check the rest against themselves and everyone else.
        let people = names.sorted().compactMap { n -> [String]? in
            let f = ((try? fm.contentsOfDirectory(atPath: "\(args[2])/\(n)")) ?? []).filter { $0.hasSuffix(".jpg") }.sorted()
            return f.count >= 12 ? f.prefix(12).map { "\(args[2])/\(n)/\($0)" } : nil
        }.prefix(10)
        var refs: [[Float]] = [], tests: [[[Float]]] = []
        for files in people {
            let prints = files.compactMap { load($0).flatMap { FaceAligner.prints(in: $0, model: model).max { $0.box.width < $1.box.width }?.print } }
            refs.append(FaceID.mean(Array(prints.prefix(5))) ?? []); tests.append(Array(prints.dropFirst(5)))
        }
        var same = 0, sameOK = 0, diff = 0, diffBad = 0
        for i in refs.indices { for j in tests.indices { for t in tests[j] {
            let ok = FaceID.cosine(refs[i], t) >= FaceID.threshold
            if i == j { same += 1; if ok { sameOK += 1 } } else { diff += 1; if ok { diffBad += 1 } }
        } } }
        print("  LFW: \(sameOK)/\(same) own photos matched, \(diffBad)/\(diff) other people matched")
        expect("LFW: at least 97% of a person's own photos match", same > 0 && Double(sameOK) / Double(same) >= 0.97)
        expect("LFW: no other person matches", diff > 0 && diffBad == 0)
    } else { print("  (no LFW folder given: skipping the face-match check)") }
    if args.count >= 4 {
        // Side by side, enroll the left person from their own photo, run the real frame reader.
        FaceID.testOverride = true
        let cam = VisionCamera()
        var paths: [String] = []
        for d in ["palm", "one", "peace", "stop", "three", "four", "ok"] {
            let dir = "\(args[3])/\(d)"
            paths += ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".jpg") }.sorted().prefix(30).map { "\(dir)/\($0)" }
        }
        // Relaxed (nobody else seen lately) and strict (someone else seen in the last 10 s).
        for strict in [false, true] {
        var pairs = 0, kept = 0, dropped = 0, leaked = 0
        for i in stride(from: 0, to: paths.count - 1, by: 2) {
            guard let a = load(paths[i]), let b = load(paths[i + 1]),
                  let leftPrint = FaceAligner.prints(in: a, model: model).max(by: { $0.box.width < $1.box.width })?.print else { continue }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 1024, 512, kCVPixelFormatType_32BGRA, [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pb)
            guard let pb else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: 1024, height: 512, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.draw(a, in: CGRect(x: 0, y: 0, width: 512, height: 512)); ctx.draw(b, in: CGRect(x: 512, y: 0, width: 512, height: 512))
            CVPixelBufferUnlockBaseAddress(pb, [])
            let cam = VisionCamera()   // fresh per pair: no face memory carried between photos
            cam.debugSetFace(reference: leftPrint)
            cam.debugSetOtherSeen(strict ? CACurrentMediaTime() : -.infinity)
            let f = cam.read(pb, faceNow: true)
            guard f.face == .you else { continue }   // the left face was not found or did not match itself
            pairs += 1
            let wrists = f.hands.compactMap { $0.first ?? nil }
            kept += wrists.filter { $0.x < 0.5 }.count
            leaked += wrists.filter { $0.x >= 0.5 }.count
            dropped += f.ignoredHands
        }
        let mode = strict ? "strict (someone else seen lately)" : "relaxed"
        _ = mode
        print("  HaGRID side by side, \(mode): \(pairs) pairs with the left face recognised; left hands kept \(kept), hands dropped \(dropped), right-person hands that got through \(leaked)")
        if strict {
            // A person whose face never shows (cut off at the seam) can still reach in beside the enrolled
            // face; strict mode narrows that to at most 1 in 20 of what was dropped.
            expect("strict: the other person's hands almost never get through (at most 1 in 20)", pairs >= 10 && leaked * 20 <= max(1, dropped))
        } else {
            // Alone, the whole frame is the zone: a second person whose face is never found (HaGRID cuts
            // it at the seam) gets through until their face is seen once, which turns strict mode on.
            // So here only the enrolled person's hands are checked; strict mode carries the leak check.
            expect("relaxed: the enrolled person's hands still drive", pairs >= 10 && kept >= pairs * 3 / 4)
        }
        expect("\(strict ? "strict" : "relaxed"): the other person's hands are dropped", dropped >= pairs / 2)
        }
        // Cost: one 1280x720 frame through the real reader, hands only vs hands plus a face check.
        if let a = load(paths[0]) {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA, [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pb)
            if let pb {
                CVPixelBufferLockBaseAddress(pb, [])
                let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: 1280, height: 720, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
                ctx.draw(a, in: CGRect(x: 280, y: 0, width: 720, height: 720))
                CVPixelBufferUnlockBaseAddress(pb, [])
                let cam = VisionCamera()
                cam.debugSetFace(reference: FaceAligner.prints(in: a, model: model).first?.print)
                func cpu(_ n: Int, _ body: () -> Void) -> Double {
                    body(); let c0 = clock(); for _ in 0..<n { body() }
                    return Double(clock() - c0) / Double(CLOCKS_PER_SEC) / Double(n) * 1000
                }
                FaceID.testOverride = false
                let plain = cpu(30) { _ = cam.read(pb) }
                FaceID.testOverride = true
                let check = cpu(30) { _ = cam.read(pb, faceNow: true) }
                let frames = Int(FaceID.recheckEvery * 30)
                let extra = (check - plain) / Double(frames)
                print(String(format: "  cost per frame: hands %.1f ms CPU; a face check adds %.1f ms; at one check every %.0f s (%d frames) that is %.2f ms a frame (about %.1f%% of a core at 30 fps)",
                             plain, check - plain, FaceID.recheckEvery, frames, extra, extra * 30 / 10))
                expect("a face check every 5 s costs under 1% of a core at 30 fps", extra * 30 / 1000 < 0.01)
            }
        }
        FaceID.testOverride = nil
    } else { print("  (no HaGRID folder given: skipping the side-by-side check)") }
    print(failures == 0 ? "All Face ID checks passed" : "\(failures) Face ID check(s) failed")
    exit(failures == 0 ? 0 : 1)
}

// Draws the notch badges (style on the left, lock on the right) on a menu-bar strip to a PNG, and
// checks when and where they show.
if args.count >= 3, args[1] == "--render-notch-badges" {
    var failures = 0
    func expect(_ name: String, _ ok: Bool) { print((ok ? "PASS " : "FAIL ") + name); if !ok { failures += 1 } }
    expect("shows while Vision is on", NotchBadge.visible(modeOn: true))
    expect("hidden while Vision is off", !NotchBadge.visible(modeOn: false))
    expect("closed lock while locked", NotchBadge.lockSymbol(locked: true) == "lock.fill")
    expect("open lock once unlocked", NotchBadge.lockSymbol(locked: false) == "lock.open.fill")
    expect("pointer arrow in the pointer style", NotchBadge.styleSymbol(.pointer) == "cursorarrow")
    expect("grid in Quadrants", NotchBadge.styleSymbol(.quadrants) == "square.grid.2x2.fill")
    let badge = NotchBadge(side: .left)
    badge.set(false, symbol: NotchBadge.styleSymbol(.quadrants), label: "", notch: nil)
    expect("badge tracks a switch to Quadrants", badge.symbol == "square.grid.2x2.fill")
    badge.set(false, symbol: NotchBadge.styleSymbol(.pointer), label: "", notch: nil)
    expect("badge tracks a switch back to the pointer", badge.symbol == "cursorarrow")
    let notch = NSRect(x: 660, y: 1050, width: 190, height: 32)
    let r = NotchBadge.frame(notch: notch, menuBar: 24, side: .right)
    let l = NotchBadge.frame(notch: notch, menuBar: 24, side: .left)
    expect("lock sits just right of the notch", r.minX > notch.maxX && r.minX - notch.maxX < 12)
    expect("style sits just left of the notch", l.maxX < notch.minX && notch.minX - l.maxX < 12)
    expect("both centred in the menu bar", abs(r.midY - notch.midY) <= 1 && r.maxY <= notch.maxY && l.midY == r.midY)
    let symbols = ["cursorarrow", "square.grid.2x2.fill", "lock.fill", "lock.open.fill", NotchBadge.notYouSymbol]
    expect("every glyph loads", symbols.allSatisfy { NotchBadge.image($0) != nil })
    // Two strips: pointer and locked, then Quadrants and unlocked.
    let size = NSSize(width: 360, height: 72)
    let img = NSImage(size: size)
    img.lockFocus()
    NSColor(white: 0.12, alpha: 1).setFill(); NSRect(origin: .zero, size: size).fill()
    for (row, pair) in [(1, ("cursorarrow", "lock.fill")), (0, ("square.grid.2x2.fill", "lock.open.fill"))] {
        let n = NSRect(x: 85, y: CGFloat(row) * 40, width: 190, height: 32)
        NSColor.black.setFill(); NSBezierPath(roundedRect: NSRect(x: n.minX, y: n.minY, width: n.width, height: n.height + 8), xRadius: 8, yRadius: 8).fill()
        for (sym, side) in [(pair.0, NotchBadge.Side.left), (pair.1, .right)] {
            if let g = NotchBadge.image(sym) { g.draw(in: NotchBadge.glyphRect(g.size, in: NotchBadge.frame(notch: n, menuBar: 24, side: side))) }
        }
    }
    img.unlockFocus()
    if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[2]))
    }
    print(failures == 0 ? "All notch badge checks passed" : "\(failures) notch badge check(s) failed")
    exit(failures == 0 ? 0 : 1)
}

// Draws the control center (live stats after two samples) to a PNG, to check the design without clicking.
if args.count >= 3, args[1] == "--render-control-center" {
    let cc = ControlCenter()
    let detail: ControlCenterView.Detail? = args.contains("--detail-cpu") ? .cpu : args.contains("--detail-memory") ? .memory : nil
    let work: WorkTab? = args.firstIndex(of: "--work").flatMap { i in
        i + 1 < args.count ? WorkTab.allCases.first { $0.label.lowercased().hasPrefix(args[i + 1].lowercased()) } : nil }
    if work != nil {
        cc.actions.agenda = { await TaskBoard(url: Assistant().commandCenter).agenda() }
        cc.loadWorkForDebug()
    }
    let v = cc.debugView(speed: args.contains("--with-speed"), detail: detail, work: work)
    if args.contains("--mid-slide") { v.pageAnim = (work == nil ? .work : .controls, CACurrentMediaTime() - ControlCenter.slideFreeze) }
    let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
    v.cacheDisplay(in: v.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[2]))
    print("Wrote \(args[2]) \(Int(v.bounds.width))x\(Int(v.bounds.height))")
    exit(0)
}

// Vision scan on an image file: document detection, OCR, and the model's filing plan. Files nothing.
if args.count >= 3, args[1] == "--scan" {
    runAndExit {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, nil),
              var image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("ERROR: can't read image"); return }
        let detect = VNDetectDocumentSegmentationRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([detect])
        if let d = detect.results?.first {
            print(String(format: "DOCUMENT: confidence %.2f, area %.2f", d.confidence, VisionCamera.area(d)))
            if let flat = VisionCamera.flatten(CIImage(cgImage: image), to: d) { image = flat }
        } else {
            print("DOCUMENT: none detected, reading the whole image")
        }
        let scanner = VisionScanner()
        let agent = Assistant()
        agent.context = VaultContext.load()
        scanner.agent = agent
        let t0 = Date()
        let (r, text) = try await scanner.read(image)
        print("OCR:\n\(text)\n")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print("PLAN (\(Int(Date().timeIntervalSince(t0) * 1000)) ms, \(scanner.model)):")
        print(String(data: try enc.encode(r), encoding: .utf8) ?? "")
    }
}

if args.count >= 3, args[1] == "--assistant" || args[1] == "--assistant-text" {
    runAndExit {
        let agent = Assistant()
        agent.context = VaultContext.load()
        let library = Library()
        library.root = VaultContext.resolveRoot()
        library.refresh()
        agent.library = library
        var spoken = args[2]
        if args[1] == "--assistant" {
            spoken = try await WhisperEngine().transcribe(URL(fileURLWithPath: args[2]), vocabulary: Vocabulary.load())
            print("HEARD: \(spoken)")
        }
        if LetsWork.matches(spoken) {
            let s = LetsWork.settings
            print("WOULD OPEN LET'S WORK: four iTerm windows (\(s.profile.isEmpty ? "default profile" : "profile " + s.profile)) running \(s.command.isEmpty ? "a plain shell" : s.command)")
            return
        }
        if TerminalCommands.matchesFinishUp(spoken) {
            print("WOULD FINISH UP: type \"\(TerminalCommands.finishLine)\" into \(TerminalCommands.hermesTTYs().count) Hermes terminal(s)")
            return
        }
        if TerminalCommands.matchesLockUp(spoken) {
            let (close, kept, err) = TerminalCommands.lockUp(dryRun: true)
            print(err.map { "LOCK UP ERROR: \($0)" } ?? "WOULD LOCK UP: close \(close) stagnant terminal(s), keep \(kept) with an agent working")
            return
        }
        if TerminalCommands.matchesClearOut(spoken) {
            let (close, left, err) = TerminalCommands.clearOut(dryRun: true)
            print(err.map { "CLEAR OUT ERROR: \($0)" } ?? "WOULD CLEAR OUT: close \(close) unused Hermes terminal(s), leave \(left)")
            return
        }
        let t0 = Date()
        let intent = try await agent.interpret(spoken, model: model)
        print("UNDERSTOOD (\(Int(Date().timeIntervalSince(t0) * 1000)) ms):")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(data: try enc.encode(intent), encoding: .utf8) ?? "")
        if args.contains("--execute") {
            let result = await agent.perform(intent, spoken: spoken, store: Store())
            print("DID: [\(result.action)] \(result.summary) \(result.reference)")
        } else if intent.intent.hasPrefix("vision_") {
            print(Assistant.asksForVision(spoken) ? "WOULD TURN VISION MODE \(intent.intent == "vision_on" ? "ON (locked until the passcode)" : "OFF")"
                                                   : "WOULD FILE A TASK (the words do not name Vision)")
        } else if ["agenda", "complete", "undo"].contains(intent.intent) {
            print("WOULD \(intent.intent.uppercased())\(intent.task_query.isEmpty ? "" : ": \(intent.task_query)")")
            if intent.intent == "complete", let m = await TaskBoard(url: agent.commandCenter).bestMatch(for: intent.task_query) {
                print("  best open task: \(m.0.title) (score \(String(format: "%.2f", m.1)))")
            }
        } else if intent.intent == "recall" {
            print("WOULD SHOW: \(library.item(named: intent.paste_label)?.title ?? "no match") in the pill")
        } else if intent.intent == "paste" {
            let item = library.item(named: intent.paste_label)
            print("WOULD PASTE: \(item.map { "\($0.title) (\($0.value.isEmpty ? "empty" : "\($0.value.count) characters"))" } ?? "no match")")
        } else if intent.intent != "draft" {
            let payload = agent.capturePayload(intent, spoken: spoken)
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            print("WOULD POST /api/work:\n" + (String(data: data, encoding: .utf8) ?? ""))
        } else {
            print("WOULD SAVE a draft under \(agent.draftsDir?.path ?? "(no data folder)") and copy it")
        }
    }
}

// Verifies the orb engine port against upstream thinking-orbs spec/orbs-golden.json.
if args.count >= 3, args[1] == "--orb-golden" {
    guard let data = FileManager.default.contents(atPath: args[2]),
          let golden = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let cases = golden["cases"] as? [[String: Any]], let resolved = golden["resolved"] as? [String: [String: Any]]
    else { print("Could not read \(args[2])"); exit(1) }
    let tol = golden["tolerance"] as? Double ?? 1e-4
    var failures = 0, worst = 0.0, checked = 0
    for (key, ref) in resolved {
        let parts = key.split(separator: "-")
        guard let state = OrbState(rawValue: String(parts[0])), let size = Int(parts[1]) else { continue }
        let mine = OrbEngine.resolve(state, size: size)
        let refOpts = (ref["opts"] as? [String: Double]) ?? [:]
        let same = mine.mode.rawValue == ref["mode"] as? String && abs(mine.speed - (ref["speed"] as? Double ?? -1)) < 1e-9
            && refOpts.allSatisfy { k, v in abs((mine.opts[k] ?? .nan) - v) < 1e-9 } && refOpts.count == mine.opts.count
        if !same { failures += 1; print("PRESET MISMATCH \(key): \(mine.opts) vs \(refOpts)") }
    }
    for c in cases {
        let key = c["key"] as? String ?? "?"
        guard let state = OrbState(rawValue: c["state"] as? String ?? ""), let size = c["size"] as? Int, let t = c["t"] as? Double,
              let refDots = c["dots"] as? [Double], let refLines = c["lines"] as? [Double] ?? Optional([]) else { continue }
        let r = OrbEngine.resolve(state, size: size)
        let f = OrbEngine.frame(r.mode, size: Double(size), t: t, opts: r.opts)
        let mineDots = f.dots.flatMap { [$0.x, $0.y, $0.z, $0.r, $0.white, $0.a] }
        let mineLines = f.lines.flatMap { [$0.x1, $0.y1, $0.x2, $0.y2, $0.white, $0.a, $0.w] }
        guard mineDots.count == refDots.count, mineLines.count == refLines.count else {
            failures += 1
            print("COUNT MISMATCH \(key): dots \(mineDots.count / 6) vs \(refDots.count / 6), lines \(mineLines.count / 7) vs \(refLines.count / 7)")
            continue
        }
        let err = zip(mineDots + mineLines, refDots + refLines).map { abs($0 - $1) }.max() ?? 0
        checked += 1
        if err > tol {
            // Dots whose depths tie to within float noise may legitimately swap draw order.
            // Accept that only if the same dots are present and every swap is between near-equal z.
            let chunk = { (a: [Double]) in stride(from: 0, to: a.count, by: 6).map { Array(a[$0..<$0 + 6]) } }
            let key6 = { (d: [Double]) in (d[2] * 1e6).rounded() * 1e12 + (d[0] * 1e4).rounded() * 1e4 + (d[1] * 1e4).rounded() }
            let a = chunk(mineDots).sorted { key6($0) < key6($1) }, b = chunk(refDots).sorted { key6($0) < key6($1) }
            let setErr = zip(a, b).map { zip($0, $1).map { abs($0 - $1) }.max() ?? 0 }.max() ?? 0
            let zErr = zip(chunk(mineDots), chunk(refDots)).map { abs($0[2] - $1[2]) }.max() ?? 0
            if setErr <= tol && zErr <= tol {
                print("ORDER-ONLY \(key): same dots, near-tied depths drawn in a different order (z error \(zErr))")
            } else {
                failures += 1
                print("VALUE MISMATCH \(key): max error \(err), as a set \(setErr), depth order error \(zErr)")
            }
        } else { worst = max(worst, err) }
    }
    print("orb golden: \(checked)/\(cases.count) frames compared, \(resolved.count) presets, worst error \(worst), \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

// Renders every orb state the HUD uses, in both tints, to a PNG contact sheet.
if args.count >= 3, args[1] == "--orb-sheet" {
    let states: [(OrbState, String)] = [(.listening, "Listening"), (.composing, "Transcribing"), (.weaving, "Cleaning up"),
                                        (.connecting, "\(GWConfig.name) thinking"), (.breathing, "Done"), (.shaping, "Warning")]
    let cell = 150.0, orb = 96.0
    let w = cell * Double(states.count), h = cell * 2 + 10
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * 2), pixelsHigh: Int(h * 2), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(white: 0.11, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill()
    for (row, tint) in [NSColor.white, HUD.gold].enumerated() {
        for (i, (state, name)) in states.enumerated() {
            let view = OrbView(frame: NSRect(x: 0, y: 0, width: orb, height: orb))
            view.state = state
            view.tint = tint
            let image = NSImage(size: view.bounds.size)
            image.lockFocusFlipped(false)
            view.draw(view.bounds)
            image.unlockFocus()
            let x = Double(i) * cell + (cell - orb) / 2, y = h - Double(row + 1) * cell + 18
            image.draw(in: NSRect(x: x, y: y, width: orb, height: orb))
            (name as NSString).draw(at: NSPoint(x: Double(i) * cell + 12, y: y - 16),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 0.7, alpha: 1)])
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[2]))
    print("wrote \(args[2])")
    exit(0)
}

// Renders the indicator (history list, idle orb, active pills) to a PNG for review.
if args.count >= 2, args[1] == "--test-agent-peek" {
    var failures = 0
    func expect(_ what: String, _ ok: Bool) { print("\(ok ? "PASS" : "FAIL")  \(what)"); if !ok { failures += 1 } }
    expect("a lease means working", AgentPeek.state(activity: "your_turn", working: true, tool: nil, question: true) == .working)
    expect("a busy activity means working", AgentPeek.state(activity: "typing", working: false, tool: nil, question: false) == .working)
    expect("a closing question means a question", AgentPeek.state(activity: "your_turn", working: false, tool: nil, question: true) == .question)
    expect("clarify means a question", AgentPeek.state(activity: "asleep", working: false, tool: "clarify", question: false) == .question)
    expect("finished without a question is ready", AgentPeek.state(activity: "your_turn", working: false, tool: nil, question: false) == .ready)
    let json = """
    {"agents":[{"id":"r","name":"Mocha","activity":"idle","working":false,"closing":{"text":"Done.","question":false},"tty":"ttys001"},
               {"id":"w","name":"Bolt","activity":"reading","working":true,"closing":null,"tty":"ttys002"},
               {"id":"q","name":"Pixel","activity":"your_turn","working":false,"closing":{"text":"Which one?","question":true},"tty":"ttys003"}]}
    """
    let parsed = AgentPeek.parse(Data(json.utf8)) ?? []
    expect("parses every agent", parsed.count == 3)
    expect("questions first, then working, then ready", parsed.map(\.id) == ["q", "w", "r"])
    expect("keeps the tty for focusing", parsed.first?.tty == "ttys003")
    expect("a broken feed reads as nothing", AgentPeek.parse(Data("oops".utf8)) == nil)
    let cast = AgentPeek.castNames
    expect("reads the whole Office cast (\(cast.count) characters)", cast.count >= 10)
    expect("every cast character draws a sprite", !cast.isEmpty && cast.allSatisfy { AgentPeek.sprite($0) != nil })
    expect("a sprite is the mirrored grid (even width)", AgentPeek.sprite(cast.first ?? "").map { Int($0.size.width) % 2 == 0 } ?? false)
    // custom/office-cast.js restyles the pill exactly as it restyles the Office.
    let castJS = VaultContext.resolveRoot().flatMap { try? String(contentsOf: $0.appendingPathComponent("dashboard/office-cast.js"), encoding: .utf8) } ?? ""
    let plain = AgentPeek.loadCast(builtIn: castJS, custom: nil)
    let mine = AgentPeek.loadCast(builtIn: castJS, custom: "OfficeCast.customize({ Bolt: { pal: { b: '#ff0000' } }, Mocha: { rows: ['bb', 'bb'] }, Nobody: { color: '#000000' } })")
    expect("the custom file keeps every character", mine.names == plain.names && mine.looks.count == plain.looks.count)
    expect("a custom palette colour reaches the pill", mine.looks["Bolt"]?.pal["b"] == AgentPeek.color("#ff0000") && plain.looks["Bolt"]?.pal["b"] != AgentPeek.color("#ff0000"))
    expect("a custom palette merges (other colours kept)", mine.looks["Bolt"]?.pal["o"] == plain.looks["Bolt"]?.pal["o"])
    expect("custom rows replace the grid", mine.looks["Mocha"]?.rows == ["bb", "bb"])
    let broken = AgentPeek.loadCast(builtIn: castJS, custom: "this is not javascript {{{")
    expect("a broken custom file keeps the built-in looks", broken.looks.count == plain.looks.count && broken.looks["Bolt"]?.pal["b"] == plain.looks["Bolt"]?.pal["b"])
    let pill = PillView()
    pill.mode = .mini
    let bare = pill.preferredSize.width
    pill.agents = parsed
    expect("the resting pill grows to hold the agents", pill.preferredSize.width >= bare + 3 * AgentPeek.slot)
    pill.frame = NSRect(origin: .zero, size: pill.preferredSize)
    expect("one click target per agent", pill.agentRects().count == 3)
    expect("sprites are big enough to read (about 1.8x the first cut)", AgentPeek.slot >= 40 && pill.preferredSize.height >= AgentPeek.slot)
    pill.agents = (0..<9).map { AgentPeek(id: "\($0)", name: "Bolt", title: "", tty: "", state: .ready) }
    pill.frame = NSRect(origin: .zero, size: pill.preferredSize)
    expect("caps the row and counts the rest", pill.agentRects().count == AgentPeek.maxShown)
    pill.mode = .active(text: "Listening", assistant: false)
    expect("no agents while dictating", pill.agentRects().isEmpty)
    // History hover: the highlight glides to the hovered row and settles; leaving fades it out.
    var g: (y: CGFloat, alpha: CGFloat)? = HistoryView.step(nil, to: (34, 1))
    expect("first hover fades in on the row itself", g?.y == 34 && (g?.alpha ?? 1) < 1)
    var frames = 0
    var mid: CGFloat = 0
    while frames < 120, !(g?.y == 134 && g?.alpha == 1) {
        g = HistoryView.step(g, to: (134, 1)); frames += 1
        if frames == 3 { mid = g?.y ?? 0 }
    }
    expect("moving rows glides through the rows between (smooth, not a jump)", mid > 34 && mid < 134)
    expect("settles in about a quarter second (\(frames) frames at 60 Hz)", frames >= 8 && frames <= 30)
    var out = 0
    while g != nil, out < 120 { g = HistoryView.step(g, to: nil); out += 1 }
    expect("leaving fades it out", g == nil && out <= 30)
    pill.mode = .mini
    pill.agents = parsed
    pill.frame = NSRect(origin: .zero, size: pill.preferredSize)
    expect("only the orb opens the history, not the agents", pill.orbZone.maxX <= (pill.agentRects().first?.1.minX ?? 0))
    // Agent hover: the hovered sprite eases up over several frames and back down after.
    var v: CGFloat = 0, steps = 0, firstStep: CGFloat = 0
    while v != 1, steps < 120 { v = AgentPeek.easeHover(v, to: 1); steps += 1; if steps == 1 { firstStep = v } }
    expect("agent hover eases in (no jump)", firstStep > 0 && firstStep < 0.5)
    expect("agent hover settles in about a quarter second (\(steps) frames)", steps >= 8 && steps <= 30)
    pill.mode = .mini
    pill.agents = parsed
    pill.setHoveredAgent(parsed[1])
    for _ in 0..<60 { pill.stepLift() }
    expect("hovered agent fully lifted, others resting", pill.lift[parsed[1].id] == 1 && pill.lift[parsed[0].id] == nil)
    pill.setHoveredAgent(nil)
    pill.stepLift()
    let leaving = pill.lift[parsed[1].id] ?? 0
    for _ in 0..<60 { pill.stepLift() }
    expect("leaving glides back down", leaving > 0 && leaving < 1 && pill.lift.isEmpty)
    print(failures == 0 ? "All agent peek checks passed." : "\(failures) agent peek check(s) FAILED.")
    exit(failures == 0 ? 0 : 1)
}

if args.count >= 3, args[1] == "--indicator-sheet" {
    let now = Date()
    func row(_ text: String, _ app: String, _ ago: Double, _ mode: String = "dictate") -> Dictation {
        Dictation(createdAt: now.addingTimeInterval(-ago), appName: app, durationSec: 3, audioPath: "", rawText: text,
                  finalText: text, asrMs: 0, cleanupMs: 0, mode: mode)
    }
    let rows = [row("Can we move the call to Thursday at 3? Friday is packed for me.", "Messages", 60),
                row("Remind me Friday to renew the domain", "Safari", 600, "assistant"),
                row("The draft looks good. Ship it after the copy pass.", "Slack", 3_600),
                row("Pick up oat milk and coffee filters on the way home", "Notes", 7_200)]
    HUD.renderSheet(to: URL(fileURLWithPath: args[2]), rows: rows)
    print("wrote \(args[2])")
    exit(0)
}

if args.count >= 2, args[1] == "--sanitize-check" {
    let cases: [(String, String)] = [("*music*", ""), ("-", ""), ("...", ""), ("[BLANK_AUDIO]", ""), ("(upbeat music)", ""),
        ("♪ la la la ♪", ""), ("Thank you.", ""), ("(sighs) okay send it", "okay send it"),
        ("Call Sam *music* tomorrow", "Call Sam tomorrow"), ("Remind me (maybe Friday) to call", "Remind me (maybe Friday) to call"),
        ("Test, test, test.", "Test, test, test.")]
    var bad = 0
    for (input, want) in cases {
        let got = WhisperEngine.sanitize(input)
        if got != want { bad += 1; print("FAIL \(input.debugDescription) -> \(got.debugDescription), wanted \(want.debugDescription)") }
    }
    print("sanitize: \(cases.count - bad)/\(cases.count) passed")
    exit(bad == 0 ? 0 : 1)
}

if args.count >= 2, args[1] == "--learn-check" {
    let cases: [(String, String, [String])] = [
        ("Call Dana Smithe about the invoice today", "Call Dana Smythe about the invoice today", ["Smythe"]),
        ("Send the ess ell ay form to Sam", "Send the SLA form to Sam", ["SLA"]),
        ("Thanks for the quick call this morning", "Thanks so much for the call this morning!", []),
        ("Tell nova the site is live", "Tell Nova the site is live", ["Nova"]),
        ("Hello there friend", "Completely different text in this field", []),
        ("Meet at gold ware tomorrow", "Earlier notes. Meet at GoldWare tomorrow. More text after.", ["GoldWare"]),
    ]
    var bad = 0
    for (pasted, edited, want) in cases {
        let got = Learner.corrections(pasted: pasted, edited: edited)
        if got != want { bad += 1; print("FAIL \(pasted) -> \(edited): \(got), wanted \(want)") }
    }
    print("learn: \(cases.count - bad)/\(cases.count) passed")
    exit(bad == 0 ? 0 : 1)
}

// Round-trips 16 kHz PCM through the in-memory recorder's WAV writer and Whisper.
if args.count >= 3, args[1] == "--wav-check" {
    runAndExit {
        let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
        let pcm = data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let r = Recorder()
        r.loadForTest(pcm)
        let out = Paths.dataDir.appendingPathComponent("wav-check.wav")
        guard r.writeWAV(to: out) else { print("could not write"); return }
        print("wrote \(pcm.count) samples; Whisper heard: \(try await WhisperEngine().transcribe(out, vocabulary: []))")
        try? FileManager.default.removeItem(at: out)
    }
}

// Undo and done-by-voice against the local server (point GOLDWARE_WORK_URL at a fake one).
if args.count >= 3, args[1] == "--tasks-check" {
    runAndExit {
        let m = TaskBoard(url: Assistant().commandCenter)
        let a = await m.agenda()
        print("AGENDA: \(a.summary)")
        if let t = await m.task(forCapture: args[2]) {
            print("FOUND capture: \(t.title) [\(t.id)]")
            print("DROP: \(await m.setStatus(t, to: "dropped") ?? "ok")")
        } else { print("capture not found") }
        if args.count >= 4, let (t, score) = await m.bestMatch(for: args[3]) {
            print("MATCH \"\(args[3])\" -> \(t.title) (\(String(format: "%.2f", score)))")
        }
    }
}

// Registers the installed app as a login item. Run from inside the .app so macOS sees the bundle.
if args.count >= 2, args[1] == "--enable-login-item" {
    do { try SMAppService.mainApp.register() } catch { print("ERROR: \(error.localizedDescription)") }
    let status: String = {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .requiresApproval: return "needs approval in System Settings > General > Login Items"
        case .notRegistered: return "not registered"
        default: return "not found"
        }
    }()
    print("login item: \(status)")
    exit(0)
}

// Starts the server the way the app does, checks it answers, then stops it. Use a spare port.
if args.count >= 2, args[1] == "--cc-check" {
    runAndExit {
        let cc = CommandCenter()
        let t0 = Date()
        let problem = await cc.ensureRunning(root: VaultContext.resolveRoot(), log: Paths.dataDir.appendingPathComponent("server-check.log"))
        print("port \(cc.port): \(problem ?? "up") after \(String(format: "%.1f", Date().timeIntervalSince(t0))) s, started here: \(cc.startedHere)")
        print("answers /api/work: \(await cc.isUp())")
        cc.stopIfStartedHere()
        try? await Task.sleep(nanoseconds: 800_000_000)
        print("after stop, answers: \(await cc.isUp())")
    }
}

if args.count >= 2, args[1] == "--disable-login-item" {
    try? SMAppService.mainApp.unregister()
    print("login item: \(SMAppService.mainApp.status == .enabled ? "still enabled" : "off")")
    exit(0)
}

if args.count >= 2, args[1] == "--flush-outbox" {
    runAndExit {
        let store = Store()
        let sent = await Assistant().flushOutbox(store)
        print("DELIVERED \(sent), STILL WAITING \(store.pendingOutbox().count)")
    }
}

// Apps opened by macOS (at login, from Finder) get a bare PATH. Match the terminal, so the
// server uses the same Python.
setenv("PATH", "/opt/homebrew/bin:/usr/local/bin:" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"), 1)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)   // the app lives in the Dock, with Voice in the menu bar
app.run()
