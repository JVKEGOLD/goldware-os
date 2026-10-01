import AppKit
import CoreML
import Vision

/// Face ID for Vision: only hands that belong to your face may drive. Off by default.
///
/// Every 5 s while you are recognised (sooner while you are not, see `FaceMatcher.isDue`) Apple Vision finds the faces and their landmarks; each
/// face is aligned to 112x112 and turned into a 128-number fingerprint by SFace (MobileFaceNet,
/// OpenCV Zoo, Apache 2.0, bundled as Core ML int8, about 9 MB). A face is you when its fingerprint is
/// within `threshold` of the saved one. Each hand is tied to the nearest face (`owner`); hands tied to
/// someone else, or to nobody, are dropped before any gesture is read. Fingerprints are numbers, never
/// photos, and stay in Application Support (`faceid.json`).
enum FaceID {
    static let key = "visionFaceIDEnabled"
    static var enabled: Bool {
        get { testOverride ?? UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    /// Self-tests switch Face ID on here, never in the real settings.
    static var testOverride: Bool?
    static var menuTitle: String { "Face ID: only your hands drive" }

    /// Cosine similarity to count as you. On LFW (158 people, 5 photos enrolled): the right person is
    /// turned away 0.55% of checks, someone else let in 0.023% (79 of 342,888).
    static let threshold: Float = 0.45
    /// While you is recognised, his face is checked again this often.
    static let recheckEvery: CFTimeInterval = 5
    /// While he is not (away, or not matched yet), this often, so control comes back quickly.
    static let retryEvery: CFTimeInterval = 0.2
    /// A face that matched keeps counting for this long at the same place, longer than one recheck,
    /// so one turned head or blink at a check does not drop control.
    static let hold: CFTimeInterval = 6.0

    static var store: URL { Paths.dataDir.appendingPathComponent("faceid.json") }
    static var isEnrolled: Bool { FileManager.default.fileExists(atPath: store.path) }

    /// The enrolled fingerprint (unit length), or nil.
    static func loadReference() -> [Float]? {
        guard let d = try? Data(contentsOf: store),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let v = j["reference"] as? [Double], v.count == 128 else { return nil }
        return v.map(Float.init)
    }

    static func save(samples: [[Float]]) -> [Float]? {
        guard let ref = mean(samples) else { return nil }
        let j: [String: Any] = ["version": 1, "model": "sface-2021dec-int8", "samples": samples.count,
                                "created": ISO8601DateFormatter().string(from: Date()), "reference": ref.map(Double.init)]
        guard let d = try? JSONSerialization.data(withJSONObject: j) else { return nil }
        try? d.write(to: store, options: .atomic)
        return ref
    }

    static func forget() { try? FileManager.default.removeItem(at: store) }

    static func mean(_ s: [[Float]]) -> [Float]? {
        guard let first = s.first else { return nil }
        var m = [Float](repeating: 0, count: first.count)
        for v in s { for i in m.indices { m[i] += v[i] } }
        return normalized(m)
    }
    static func normalized(_ v: [Float]) -> [Float] {
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return n > 0 ? v.map { $0 / n } : v
    }
    static func cosine(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }

    // MARK: Whose hand

    /// A face in view: box in normalized image coordinates and whether it is you.
    struct Face: Equatable { var box: CGRect; var isOwner: Bool }

    /// Index of the face a hand belongs to, or nil when it cannot be told. Distances are squared to
    /// true proportions (x times the aspect) and measured in that face's widths:
    ///   - alone (one face in view, nobody else seen lately): the whole camera frame is the zone, so a
    ///     hand anywhere in view belongs to that face; only the size test below still applies
    ///   - wrist within 2.5 face widths of the face centre (own hands: median 2.0, p95 3.0)
    ///   - hand size (wrist to middle knuckle) 0.25 to 1.2 face widths (own: p5 0.42, p95 1.0), so a
    ///     hand much nearer or farther from the camera than the face is someone else's
    ///   - no other face within twice that distance, or the hand is too close to call
    ///   - `strict` (someone else was seen in the last 10 s) and only one face in view: the wrist within
    ///     1.6 face widths sideways of it, since a second person whose face the camera missed reaches
    ///     in from the side
    /// On HaGRID (226 hands alone, 960 in side-by-side pairs, incl. a smaller person behind): relaxed,
    /// 92% of a person's own hands kept and 24 of 469 other-person hands tied to the wrong face; strict,
    /// 77% kept and 11 wrong. Every wrong one had that person's face missed; with both faces found,
    /// none went wrong.
    static let oneFaceMaxSideways: CGFloat = 1.6
    static func owner(wrist: CGPoint, handSize: CGFloat, faces: [Face], aspect: CGFloat, strict: Bool = false) -> Int? {
        func sq(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * aspect, y: p.y) }
        let w = sq(wrist)
        let ranked = faces.indices.map { i -> (i: Int, d: CGFloat, ratio: CGFloat) in
            let b = faces[i].box, c = sq(CGPoint(x: b.midX, y: b.midY)), fw = max(0.001, b.width * aspect)
            return (i, hypot(c.x - w.x, c.y - w.y) / fw, handSize / fw)
        }.sorted { $0.d < $1.d }
        let alone = faces.count == 1 && !strict
        guard let best = ranked.first(where: { (alone || $0.d < 2.5) && $0.ratio > 0.25 && $0.ratio < 1.2 }) else { return nil }
        if ranked.contains(where: { $0.i != best.i && $0.d < best.d * 2 }) { return nil }
        if strict, faces.count == 1 {
            let c = sq(CGPoint(x: faces[best.i].box.midX, y: 0))
            if abs(c.x - w.x) / max(0.001, faces[best.i].box.width * aspect) > oneFaceMaxSideways { return nil }
        }
        return best.i
    }

    /// True when a hand belongs to you.
    static func isOwners(wrist: CGPoint, handSize: CGFloat, faces: [Face], aspect: CGFloat, strict: Bool = false) -> Bool {
        owner(wrist: wrist, handSize: handSize, faces: faces, aspect: aspect, strict: strict).map { faces[$0].isOwner } ?? false
    }
}

/// Runs face checks on the camera queue and remembers who is where between checks.
final class FaceMatcher {
    enum State: Equatable { case off, notEnrolled, you, notYou }

    private var model: MLModel?
    private var reference: [Float]?
    private var referenceLoaded = false
    private(set) var faces: [FaceID.Face] = []
    /// Where your face last matched, and when (for `FaceID.hold`).
    private var ownerBox: CGRect?
    private var ownerAt: CFTimeInterval = 0
    private var enrolling: (until: CFTimeInterval, samples: [[Float]], done: ([[Float]]) -> Void)?
    /// Other people's faces seen lately. One the detector drops for a moment still claims its hands.
    private var recentOthers: [(box: CGRect, at: CFTimeInterval)] = []
    static let rememberOthers: CFTimeInterval = 1.5
    /// When someone else's face was last seen. For 10 s after, hands are tied to faces strictly.
    private(set) var otherSeenAt: CFTimeInterval = -.infinity
    static let strictFor: CFTimeInterval = 10
    func isStrict(at now: CFTimeInterval) -> Bool { now - otherSeenAt < Self.strictFor }
    var lastCheckCost: CFTimeInterval = 0
    private var lastCheckAt: CFTimeInterval = -.infinity

    /// Whether a face check is due: every 5 s while you are recognised, every 0.2 s otherwise.
    static func isDue(now: CFTimeInterval, lastCheck: CFTimeInterval, recognised: Bool) -> Bool {
        now - lastCheck >= (recognised ? FaceID.recheckEvery : FaceID.retryEvery)
    }
    func isDue(_ now: CFTimeInterval) -> Bool {
        enrolling != nil || Self.isDue(now: now, lastCheck: lastCheckAt, recognised: state == .you)
    }

    var state: State {
        guard FaceID.enabled else { return .off }
        guard reference != nil else { return .notEnrolled }
        return faces.contains(where: \.isOwner) ? .you : .notYou
    }

    /// Re-reads the saved fingerprint (after setup or forget).
    func reload() { referenceLoaded = false }

    /// Collects fingerprints from the next `seconds` of frames with exactly one face in view.
    func enroll(seconds: Double, now: CFTimeInterval, done: @escaping ([[Float]]) -> Void) {
        enrolling = (now + seconds, [], done)
    }
    var isEnrolling: Bool { enrolling != nil }

    /// One check on a frame. Call every few frames from the camera queue.
    func check(_ handler: VNImageRequestHandler, imageSize: CGSize, cgImage: () -> CGImage?, now: CFTimeInterval) {
        if !referenceLoaded { reference = FaceID.loadReference(); referenceLoaded = true }
        guard FaceID.enabled || enrolling != nil else { faces = []; return }
        lastCheckAt = now
        let t0 = CACurrentMediaTime()
        defer { lastCheckCost = CACurrentMediaTime() - t0 }
        let req = VNDetectFaceLandmarksRequest()
        try? handler.perform([req])
        let found = (req.results ?? []).filter { $0.boundingBox.width > 0.04 }
        guard !found.isEmpty else { faces = remembered(now, current: []); finishEnrollIfDue(now); return }
        guard let image = cgImage(), let model = loadModel() else {
            faces = found.map { FaceID.Face(box: $0.boundingBox, isOwner: false) }
            return
        }
        var next: [FaceID.Face] = []
        for f in found {
            let print = FaceAligner.landmarks(f, imageSize: imageSize).flatMap { FaceAligner.embed(image, points: $0, model: model) }
            var isOwner = false
            if let print, let reference { isOwner = FaceID.cosine(print, reference) >= FaceID.threshold }
            if isOwner { ownerBox = f.boundingBox; ownerAt = now }
            else if let box = ownerBox, now - ownerAt < FaceID.hold, Self.overlap(box, f.boundingBox) > 0.3 {
                isOwner = true   // same place as a recent match: a turned head, not a new person
            }
            next.append(FaceID.Face(box: f.boundingBox, isOwner: isOwner))
            if found.count == 1, let print, var e = enrolling {
                e.samples.append(print); enrolling = e
            }
        }
        // Only one face may be you: the best placed recent one.
        if next.filter(\.isOwner).count > 1 {
            let keep = next.indices.filter { next[$0].isOwner }.max { Self.overlap(next[$0].box, ownerBox ?? .zero) < Self.overlap(next[$1].box, ownerBox ?? .zero) }
            for i in next.indices where i != keep { next[i].isOwner = false }
        }
        faces = remembered(now, current: next)
        finishEnrollIfDue(now)
    }

    /// The current faces plus other people's faces seen in the last 1.5 s that no current face covers.
    func remembered(_ now: CFTimeInterval, current: [FaceID.Face]) -> [FaceID.Face] {
        recentOthers.removeAll { r in now - r.at > Self.rememberOthers || current.contains { Self.overlap($0.box, r.box) > 0.3 } }
        for f in current where !f.isOwner { recentOthers.append((f.box, now)); otherSeenAt = now }
        var out = current
        for r in recentOthers.reversed() where !out.contains(where: { Self.overlap($0.box, r.box) > 0.3 }) {
            out.append(FaceID.Face(box: r.box, isOwner: false))
        }
        return out
    }

    private func finishEnrollIfDue(_ now: CFTimeInterval) {
        guard let e = enrolling, now >= e.until else { return }
        enrolling = nil
        e.done(e.samples)
    }

    static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull, a.width > 0, b.width > 0 else { return 0 }
        return (i.width * i.height) / min(a.width * a.height, b.width * b.height)
    }

    private func loadModel() -> MLModel? {
        if model == nil { model = FaceAligner.loadModel() }
        return model
    }

    /// Test hook: set the reference and faces directly.
    func debugSet(reference: [Float]?) { self.reference = reference; referenceLoaded = true }
    func debugSet(otherSeenAt t: CFTimeInterval) { otherSeenAt = t; recentOthers = [] }
}

/// Face alignment and the fingerprint model, shared by the app and its self-tests.
enum FaceAligner {
    /// ArcFace / SFace 112x112 template (left eye, right eye, nose tip, mouth left, mouth right), flipped
    /// to a bottom-left origin like Vision.
    static let template: [CGPoint] = [(38.2946, 51.6963), (73.5318, 51.5014), (56.0252, 71.7366),
                                      (41.5493, 92.3655), (70.7299, 92.2041)].map { CGPoint(x: $0.0, y: 112 - $0.1) }

    static func modelURL() -> URL? {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("FaceID/SFace.mlmodelc"),
           FileManager.default.fileExists(atPath: r.path) { return r }
        // Running from .build (self-tests): compile the package from the source tree.
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        for base in [exe.deletingLastPathComponent(), URL(fileURLWithPath: FileManager.default.currentDirectoryPath)] {
            var dir = base
            for _ in 0..<5 {
                let p = dir.appendingPathComponent("Resources/FaceID/SFace.mlpackage")
                if FileManager.default.fileExists(atPath: p.path) { return try? MLModel.compileModel(at: p) }
                dir = dir.deletingLastPathComponent()
            }
        }
        return nil
    }

    static func loadModel() -> MLModel? {
        guard let url = modelURL() else { return nil }
        let c = MLModelConfiguration(); c.computeUnits = .all
        return try? MLModel(contentsOf: url, configuration: c)
    }

    static func centroid(_ p: [CGPoint]) -> CGPoint {
        CGPoint(x: p.reduce(0) { $0 + $1.x } / CGFloat(p.count), y: p.reduce(0) { $0 + $1.y } / CGFloat(p.count))
    }

    /// The five alignment points in image pixels (bottom-left origin), or nil.
    static func landmarks(_ f: VNFaceObservation, imageSize: CGSize) -> [CGPoint]? {
        guard let lm = f.landmarks, let le = lm.leftEye, let re = lm.rightEye, let lips = lm.outerLips else { return nil }
        let eyes = [centroid(le.pointsInImage(imageSize: imageSize)), centroid(re.pointsInImage(imageSize: imageSize))].sorted { $0.x < $1.x }
        let nose: CGPoint
        if let crest = lm.noseCrest?.pointsInImage(imageSize: imageSize), let low = crest.min(by: { $0.y < $1.y }) { nose = low }
        else if let n = lm.nose?.pointsInImage(imageSize: imageSize), !n.isEmpty { nose = centroid(n) }
        else { return nil }
        let mouth = lips.pointsInImage(imageSize: imageSize)
        guard let ml = mouth.min(by: { $0.x < $1.x }), let mr = mouth.max(by: { $0.x < $1.x }) else { return nil }
        return [eyes[0], eyes[1], nose, ml, mr]
    }

    /// Least-squares similarity (scale, rotation, shift) taking `src` onto `dst`.
    static func similarity(_ src: [CGPoint], _ dst: [CGPoint]) -> CGAffineTransform {
        let ms = centroid(src), md = centroid(dst)
        var a: CGFloat = 0, b: CGFloat = 0, v: CGFloat = 0
        for (s, d) in zip(src, dst) {
            let sx = s.x - ms.x, sy = s.y - ms.y, dx = d.x - md.x, dy = d.y - md.y
            a += sx * dx + sy * dy; b += sx * dy - sy * dx; v += sx * sx + sy * sy
        }
        guard v > 0 else { return .identity }
        let ca = a / v, sb = b / v
        return CGAffineTransform(a: ca, b: sb, c: -sb, d: ca, tx: md.x - (ca * ms.x - sb * ms.y), ty: md.y - (sb * ms.x + ca * ms.y))
    }

    /// The aligned face's fingerprint (unit length).
    static func embed(_ image: CGImage, points: [CGPoint], model: MLModel) -> [Float]? {
        guard let ctx = CGContext(data: nil, width: 112, height: 112, bitsPerComponent: 8, bytesPerRow: 112 * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let arr = try? MLMultiArray(shape: [1, 3, 112, 112], dataType: .float32) else { return nil }
        ctx.interpolationQuality = .high
        ctx.concatenate(similarity(points, template))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let raw = ctx.data else { return nil }
        let px = raw.assumingMemoryBound(to: UInt8.self)
        let out = arr.dataPointer.assumingMemoryBound(to: Float.self)
        for y in 0..<112 { for x in 0..<112 { for c in 0..<3 { out[c * 12544 + y * 112 + x] = Float(px[(y * 112 + x) * 4 + c]) } } }
        guard let res = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["face": arr])),
              let e = res.featureValue(for: "embedding")?.multiArrayValue, e.count == 128 else { return nil }
        return FaceID.normalized((0..<128).map { Float(truncating: e[$0]) })
    }

    /// Every face in a still image with its fingerprint (self-tests and `--face-check`).
    static func prints(in image: CGImage, model: MLModel) -> [(box: CGRect, print: [Float])] {
        let req = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cgImage: image).perform([req])
        let size = CGSize(width: image.width, height: image.height)
        return (req.results ?? []).compactMap { f in
            guard let pts = landmarks(f, imageSize: size), let p = embed(image, points: pts, model: model) else { return nil }
            return (f.boundingBox, p)
        }
    }
}
