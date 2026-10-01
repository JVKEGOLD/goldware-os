import AVFoundation
import CoreImage
import Vision

/// A hand shape read from one frame: fingers held up (thumb included), a thumbs up, or a fist.
enum HandGesture: Equatable {
    case count(Int), thumbsUp, fist

    typealias Joints = [VNHumanHandPoseObservation.JointName: CGPoint]
    static let joints: [VNHumanHandPoseObservation.JointName] = [
        .wrist, .thumbTip, .thumbIP, .indexMCP, .indexPIP, .indexTip, .middleMCP, .middlePIP, .middleTip,
        .ringPIP, .ringTip, .littlePIP, .littleTip,
    ]

    /// Which fingers are straight: thumb, then index, middle, ring, little. nil when unreadable.
    /// A finger is up when its tip is 12% further from the wrist than its middle joint (on 2,100
    /// straight fingers in HaGRID photos the lowest is 1.20; on 430 curled ones the highest is 0.86).
    /// With `last` (the previous frame's reading) a finger already up stays up until it drops below
    /// 0.98, so one hovering at the line does not flicker between counts.
    static func extended(_ j: Joints, last: [Bool]? = nil) -> (thumb: Bool, fingers: [Bool], size: CGFloat)? {
        guard let w = j[.wrist], let mid = j[.middleMCP], let imcp = j[.indexMCP],
              let t = j[.thumbTip], let tip = j[.thumbIP] else { return nil }
        func d(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        let size = d(w, mid)
        guard size > 0.03 else { return nil }   // too far away to read reliably
        let pairs: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName)] =
            [(.indexTip, .indexPIP), (.middleTip, .middlePIP), (.ringTip, .ringPIP), (.littleTip, .littlePIP)]
        var fingers: [Bool] = []
        for (i, (a, b)) in pairs.enumerated() {
            guard let tp = j[a], let pp = j[b] else { return nil }
            fingers.append(d(w, tp) > d(w, pp) * (last?[i] == true ? 0.98 : 1.12))
        }
        let thumbOut = d(t, imcp) > size * 0.8 && d(t, imcp) > d(tip, imcp) * 1.15
        return (thumbOut, fingers, size)
    }

    /// Vision's points are fractions of the frame's width and of its height, so on a 16:9 camera a
    /// sideways distance reads 44% short and a spread thumb looks tucked. Scaling x by the aspect makes
    /// distances true. The mode gestures below expect squared joints.
    static func square(_ j: Joints, aspect: CGFloat) -> Joints {
        aspect == 1 ? j : j.mapValues { CGPoint(x: $0.x * aspect, y: $0.y) }
    }

    enum Thumb { case tucked, spread, unsure }

    /// Spread: thumb tip more than 0.6 hand sizes (wrist to middle knuckle) from the middle knuckle;
    /// every open palm but one in 132 HaGRID photos. Tucked: the tip folded across the palm, past the
    /// index knuckle toward the little finger (95% of fours with the thumb folded, 3% of open palms
    /// with the thumb resting beside the index, which the old distance test read as tucked 28% of the
    /// time). Anything else is neither.
    static func thumb(_ j: Joints) -> Thumb? {
        guard let w = j[.wrist], let m = j[.middleMCP], let i = j[.indexMCP], let t = j[.thumbTip] else { return nil }
        let size = hypot(w.x - m.x, w.y - m.y)
        let across = hypot(m.x - i.x, m.y - i.y)
        guard size > 0.03, across > 0 else { return nil }
        if hypot(t.x - m.x, t.y - m.y) / size > 0.6 { return .spread }
        let folded = ((t.x - i.x) * (m.x - i.x) + (t.y - i.y) * (m.y - i.y)) / across / size
        return folded > -0.1 ? .tucked : .unsure
    }

    /// All four fingers straight and the thumb spread wide: five.
    static func isOpenHand(_ j: Joints, last: [Bool]? = nil) -> Bool {
        extended(j, last: last)?.fingers == [true, true, true, true] && thumb(j) == .spread
    }

    /// Only the little finger up (index, middle, ring curled) with the thumb not spread out to the side
    /// (spread is the "call me" shape). Clears what GoldWare just pasted.
    static func isPinky(_ j: Joints, last: [Bool]? = nil) -> Bool {
        extended(j, last: last)?.fingers == [false, false, false, true] && thumb(j) != .spread
    }

    /// The OK sign: thumb and index tips touching in a ring, the other three fingers straight. On HaGRID
    /// photos this is 98% of OK signs and none of the other one-hand gestures.
    static func isOK(_ j: Joints) -> Bool {
        guard let e = extended(j), e.fingers[1], e.fingers[2], e.fingers[3],
              let t = j[.thumbTip], let i = j[.indexTip] else { return false }
        return hypot(t.x - i.x, t.y - i.y) / e.size < 0.35
    }

    /// Two hands measured against each other (squared joints), in their average hand size (wrist to
    /// middle knuckle). A gap is nil when either hand's joint was not seen.
    struct Pair {
        var index, thumb, palms, fingertips: CGFloat?

        init?(_ a: Joints, _ b: Joints) {
            guard let wa = a[.wrist], let ma = a[.middleMCP], let wb = b[.wrist], let mb = b[.middleMCP] else { return nil }
            let size = (hypot(wa.x - ma.x, wa.y - ma.y) + hypot(wb.x - mb.x, wb.y - mb.y)) / 2
            guard size > 0.02 else { return nil }
            func gap(_ k: VNHumanHandPoseObservation.JointName) -> CGFloat? {
                guard let p = a[k], let q = b[k] else { return nil }
                return hypot(p.x - q.x, p.y - q.y) / size
            }
            index = gap(.indexTip); thumb = gap(.thumbTip); palms = gap(.middleMCP); fingertips = gap(.middleTip)
        }

        // Calibrated on HaGRID v2 (253 two-hand photos): praying hands read "together" in 59% of photos
        // (nearly every one where both hands were found), index-and-thumb hearts read "diamond" in 81%,
        // and neither fires on any other two-hand gesture (frames, T, X, two Ls).
        /// Praying: fingertips and palms together.
        var together: Bool { (fingertips ?? 9) < 0.35 && (palms ?? 9) < 0.9 }
        /// Palms apart, index tips touching, thumb tips touching.
        var diamond: Bool { (index ?? 9) < 0.45 && (thumb ?? 9) < 0.45 && (palms ?? 0) > 1.0 }
        /// The index tips or thumb tips have come apart.
        var apart: Bool { (index ?? 0) > 0.6 || (thumb ?? 0) > 0.6 }
    }

    /// Reads a pose from normalized image points (Vision coordinates, y up; square them first).
    /// Thumbs up: no fingers up, the thumb tip 0.6 hand sizes above the index knuckle and the thumb
    /// pointing within about 50 degrees of straight up. On HaGRID that is 93% of thumbs-up photos and
    /// 2% of fists (the pose model invents a raised thumb on a fist that hides it; asking for the
    /// height and the direction together halves those). A fist is no fingers and no thumb like that.
    static func classify(_ j: Joints) -> HandGesture? {
        guard let e = extended(j), let t = j[.thumbTip], let tip = j[.thumbIP], let imcp = j[.indexMCP] else { return nil }
        let size = e.size, thumbOut = e.thumb
        let fingers = e.fingers.filter { $0 }.count
        if fingers == 0 {
            let up = CGPoint(x: t.x - tip.x, y: t.y - tip.y), len = hypot(up.x, up.y)
            if t.y > imcp.y + size * 0.6, len > 0, up.y / len > 0.6 { return .thumbsUp }
            return .fist
        }
        return .count(fingers + (thumbOut ? 1 : 0))
    }
}

/// One camera frame, read on device. Points are normalized image coordinates (Vision: origin
/// bottom-left, not mirrored). Nothing here is stored; the latest pixel buffer is kept only so a
/// scan can take a still.
struct VisionFrame {
    /// Each hand: wrist, then thumb, index, middle, ring, little tips (nil when unsure).
    var hands: [[CGPoint?]] = []
    /// The largest hand's joints, for gestures and hand control.
    var lead: HandGesture.Joints = [:]
    /// The next largest hand's, for two-hand gestures (the unlock).
    var second: HandGesture.Joints = [:]
    /// The same two hands keeping less certain joints (confidence above 0.15 instead of 0.3). Only the
    /// two-hand measures use them: praying hands hide parts of each other, and on HaGRID's praying
    /// photos that raises "together" from 64% to 82% with no new false reads on other two-hand poses.
    var leadLoose: HandGesture.Joints = [:]
    var secondLoose: HandGesture.Joints = [:]
    var gesture: HandGesture?
    /// A card, receipt, or page held up to the camera.
    var document: VNRectangleObservation?
    var imageSize = CGSize.zero
    var time: CFTimeInterval = 0
    /// The lead hand with true proportions (see `HandGesture.square`).
    var squared: HandGesture.Joints { HandGesture.square(lead, aspect: aspect) }
    /// The second hand, squared the same way.
    var secondSquared: HandGesture.Joints { HandGesture.square(second, aspect: aspect) }
    var pair: HandGesture.Pair? {
        HandGesture.Pair(HandGesture.square(leadLoose.isEmpty ? lead : leadLoose, aspect: aspect),
                         HandGesture.square(secondLoose.isEmpty ? second : secondLoose, aspect: aspect))
    }
    private var aspect: CGFloat { imageSize.height > 0 ? imageSize.width / imageSize.height : 1 }
}

/// The one camera session GoldWare Vision shares. It runs while anyone holds a claim on it:
/// the mirror while open, Vision Mode while switched on.
final class VisionCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "assistant.vision.camera")
    private let frameQueue = DispatchQueue(label: "assistant.vision.frames", qos: .userInteractive)
    private let output = AVCaptureVideoDataOutput()
    private var configured = false
    private var claims = Set<String>()
    private var releaseWork: [String: DispatchWorkItem] = [:]

    /// Frame readings, delivered on the main queue.
    var onFrame: ((VisionFrame) -> Void)?
    /// True while a reading waits for the main queue. Frames that arrive meanwhile are skipped, so a
    /// busy main thread falls behind by one frame instead of queueing a backlog.
    private var delivering = false
    private let deliveringLock = NSLock()

    private let handRequest: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 2
        return r
    }()
    private let docRequest = VNDetectDocumentSegmentationRequest()
    private var latest: CVPixelBuffer?
    private let latestLock = NSLock()
    private var frameCount = 0
    private var lastDocument: VNRectangleObservation?
    private static let tips: [VNHumanHandPoseObservation.JointName] = [.thumbTip, .indexTip, .middleTip, .ringTip, .littleTip]

    var isRunning: Bool { session.isRunning }

    /// Starts the camera for `who`. `ready` runs on main once frames can flow (false: no camera).
    func claim(_ who: String, ready: ((Bool) -> Void)? = nil) {
        releaseWork[who]?.cancel()
        releaseWork[who] = nil
        claims.insert(who)
        sessionQueue.async {
            self.configure()
            let ok = !self.session.inputs.isEmpty
            if ok, !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async { ready?(ok) }
        }
    }

    /// Drops `who`'s claim after `grace` seconds; the camera stops when no claims remain.
    func release(_ who: String, after grace: TimeInterval = 0) {
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.releaseWork[who] = nil
            self.claims.remove(who)
            guard self.claims.isEmpty else { return }
            self.sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
            self.latestLock.lock(); self.latest = nil; self.latestLock.unlock()
        }
        releaseWork[who]?.cancel()
        releaseWork[who] = w
        DispatchQueue.main.asyncAfter(deadline: .now() + grace, execute: w)
    }

    private func configure() {
        guard !configured else { return }
        configured = true
        session.beginConfiguration()
        session.sessionPreset = .high
        // Prefer the built-in FaceTime camera over a Continuity iPhone.
        let builtIn = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera],
                                                       mediaType: .video, position: .unspecified).devices.first
        if let device = builtIn ?? AVCaptureDevice.default(for: .video),
           let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
        }
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: frameQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
    }

    /// The latest frame, perspective-corrected to `document` when given.
    func still(cropTo document: VNRectangleObservation?) -> CGImage? {
        latestLock.lock(); let buffer = latest; latestLock.unlock()
        guard let buffer else { return nil }
        return Self.flatten(CIImage(cvPixelBuffer: buffer), to: document)
    }

    private static let ciContext = CIContext()

    /// Crops an image to a detected document and straightens it (shared with `--scan`).
    static func flatten(_ image: CIImage, to document: VNRectangleObservation?) -> CGImage? {
        var image = image
        if let d = document {
            let e = image.extent
            func pt(_ p: CGPoint) -> CIVector { CIVector(x: p.x * e.width, y: p.y * e.height) }
            image = image.applyingFilter("CIPerspectiveCorrection", parameters: [
                "inputTopLeft": pt(d.topLeft), "inputTopRight": pt(d.topRight),
                "inputBottomLeft": pt(d.bottomLeft), "inputBottomRight": pt(d.bottomRight),
            ])
        }
        return ciContext.createCGImage(image, from: image.extent)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        latestLock.lock(); latest = pixels; latestLock.unlock()
        deliveringLock.lock(); let busy = delivering; deliveringLock.unlock()
        if busy { return }
        frameCount += 1
        var frame = VisionFrame()
        frame.imageSize = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        frame.time = CACurrentMediaTime()

        // Documents barely move between frames, so every third frame is plenty.
        let docsNow = frameCount % 3 == 0
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up)
        try? handler.perform(docsNow ? [handRequest, docRequest] : [handRequest])

        let results = handRequest.results ?? []
        frame.hands = results.map { hand in
            guard let all = try? hand.recognizedPoints(.all) else { return [] }
            return ([.wrist] + Self.tips).map { name in
                guard let p = all[name], p.confidence > 0.3 else { return nil }
                return p.location
            }
        }
        // Gestures read the largest hand in view (the one nearest the camera); the unlock reads two.
        let bySize = results.sorted { Self.span($0) > Self.span($1) }
        func joints(_ o: VNHumanHandPoseObservation) -> (sure: HandGesture.Joints, loose: HandGesture.Joints) {
            var sure: HandGesture.Joints = [:], loose: HandGesture.Joints = [:]
            for name in HandGesture.joints {
                guard let p = try? o.recognizedPoint(name), p.confidence > 0.15 else { continue }
                loose[name] = p.location
                if p.confidence > 0.3 { sure[name] = p.location }
            }
            return (sure, loose)
        }
        if let lead = bySize.first {
            (frame.lead, frame.leadLoose) = joints(lead)
            frame.gesture = HandGesture.classify(frame.squared)
        }
        if bySize.count > 1 { (frame.second, frame.secondLoose) = joints(bySize[1]) }
        if docsNow {
            // Held up close, not a picture on the wall behind.
            lastDocument = (docRequest.results ?? []).first.flatMap { $0.confidence > 0.7 && Self.area($0) > 0.08 ? $0 : nil }
        }
        frame.document = lastDocument
        deliveringLock.lock(); delivering = true; deliveringLock.unlock()
        DispatchQueue.main.async {
            self.onFrame?(frame)
            self.deliveringLock.lock(); self.delivering = false; self.deliveringLock.unlock()
        }
    }

    private static func span(_ hand: VNHumanHandPoseObservation) -> CGFloat {
        guard let w = try? hand.recognizedPoint(.wrist), let m = try? hand.recognizedPoint(.middleMCP) else { return 0 }
        return hypot(w.location.x - m.location.x, w.location.y - m.location.y)
    }

    static func area(_ r: VNRectangleObservation) -> CGFloat {
        // Shoelace over the four corners.
        let p = [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft]
        var s: CGFloat = 0
        for i in 0..<4 { let a = p[i], b = p[(i + 1) % 4]; s += a.x * b.y - b.x * a.y }
        return abs(s) / 2
    }
}
