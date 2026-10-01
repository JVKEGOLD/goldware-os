import AppKit
import Vision

/// Scanning in the mirror: hold a card, receipt, or page up; a gold outline closes as you hold
/// still, GoldWare reads it, and a held gesture decides what happens to it:
///   thumbs up   file it as one inbox task
///   2 fingers   copy what it read
///   fist        discard
/// Every gesture must be held (a gold ring shows progress) so a passing hand never acts.

/// A scan in the mirror, from "hold still" to filed.
enum ScanPhase {
    case steadying
    case reading
    case ready(ScanResult)
    case done(String, ok: Bool)
    case failed(String)
}

struct BoardState {
    var hold: (gesture: HandGesture, progress: Double)?
    var scan: ScanPhase?
}

/// How long each scan gesture must be held. Longer for the one that files something.
private func holdSeconds(_ g: HandGesture) -> Double { g == .thumbsUp ? 0.7 : 0.6 }

/// The scan card under the live view, drawn with the dashboard's tokens. Only shown during a scan.
final class MirrorBoard: CALayer {
    var state = BoardState() { didSet { setNeedsDisplay() } }
    private static let header: CGFloat = 28
    private static let body: CGFloat = 136      // title, meta line, and up to five fields
    private static let legend: CGFloat = 60     // gesture keys and the footnote
    static let height: CGFloat = header + body + legend

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }
    override class func defaultAction(forKey event: String) -> CAAction? { NSNull() }

    override func draw(in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        if let scan = state.scan { drawScan(scan) }
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    private func drawScan(_ scan: ScanPhase) {
        let w = bounds.width
        Theme.drawSectionTitle("Scan", at: NSPoint(x: 2, y: 8))
        if let hold = state.hold {
            let label = Self.scanHoldLabel(hold.gesture)
            let f = Theme.sans(11, "Medium")
            let size = Theme.size(label, font: f)
            Theme.draw(label, at: NSPoint(x: w - size.width - 4, y: 8), font: f, color: Theme.goldHi)
            drawRing(center: NSPoint(x: w - size.width - 16, y: 15), progress: hold.progress)
        }
        var y = Self.header
        func line(_ text: String, _ font: NSFont, _ color: NSColor, gap: CGFloat = 20) {
            Self.drawTruncated(text, at: NSPoint(x: 4, y: y), width: w - 8, font: font, color: color)
            y += gap
        }
        switch scan {
        case .steadying:
            line("Hold it still…", Theme.display(18, italic: true), Theme.text, gap: 26)
            line("\(GWConfig.name) reads it on this Mac. The image is never saved.", Theme.sans(11.5), Theme.textMuted)
        case .reading:
            line("Reading…", Theme.display(18, italic: true), Theme.text, gap: 26)
            line("Text first, then the local model decides where it goes.", Theme.sans(11.5), Theme.textMuted)
        case .failed(let m):
            line(m, Theme.display(16, italic: true), Theme.textDim, gap: 26)
            line("Fist to dismiss, or hold it up again.", Theme.sans(11.5), Theme.textMuted)
        case .done(let m, let ok):
            line(m, Theme.sans(13, "SemiBold"), ok ? Theme.green : Theme.red, gap: 22)
        case .ready(let r):
            line(r.title, Theme.sans(13.5, "SemiBold"), Theme.goldHi, gap: 20)
            var meta = [r.kind.uppercased()]
            if !r.due_on.isEmpty { meta.append("DUE \(r.due_on.suffix(5))") }
            Theme.draw(meta.joined(separator: " · "), at: NSPoint(x: 4, y: y), font: Theme.mono(10, "Regular"), color: Theme.textMuted)
            y += 20
            let lf = Theme.sans(11.5, "Medium"), vf = Theme.sans(12)
            for f in r.fields.prefix(5) {
                Theme.draw(f.label, at: NSPoint(x: 4, y: y), font: lf, color: Theme.textMuted)
                Self.drawTruncated(f.value, at: NSPoint(x: 86, y: y), width: w - 96, font: vf, color: Theme.text)
                y += 18
            }
            if r.fields.count > 5 {
                Theme.draw("+\(r.fields.count - 5) more in the capture", at: NSPoint(x: 86, y: y), font: Theme.sans(11), color: Theme.textMuted)
            }
        }
        guard case .ready = scan else { return }
        y = Self.header + Self.body
        Theme.goldGradient.draw(in: NSRect(x: 2, y: y, width: 90, height: 1), angle: 0)
        var x: CGFloat = 2
        for (key, what) in [("Thumbs up", "File it"), ("2", "Copy"), ("Fist", "Discard")] {
            let kw = Theme.drawKey(key, at: NSPoint(x: x, y: y + 12), height: 20, gold: key == "Thumbs up")
            let lw = Theme.draw(what, at: NSPoint(x: x + kw + 6, y: y + 14.5), font: Theme.sans(11.5), color: Theme.textDim).width
            x += kw + 6 + lw + 14
        }
        Theme.draw("Files one inbox task. Nothing is sent.",
                   at: NSPoint(x: 2, y: y + 40), font: Theme.sans(10.5), color: Theme.textMuted)
    }

    private static func scanHoldLabel(_ g: HandGesture) -> String {
        switch g {
        case .thumbsUp: return "Filing"
        case .fist: return "Discard"
        case .count(2): return "Copying"
        default: return ""
        }
    }

    private func drawRing(center c: NSPoint, progress: Double) {
        let track = NSBezierPath()
        track.appendArc(withCenter: c, radius: 6, startAngle: 0, endAngle: 360)
        track.lineWidth = 2
        Theme.border.setStroke(); track.stroke()
        let arc = NSBezierPath()
        // Flipped context: clockwise from 12 o'clock.
        arc.appendArc(withCenter: c, radius: 6, startAngle: -90, endAngle: -90 + 360 * progress, clockwise: false)
        arc.lineWidth = 2
        arc.lineCapStyle = .round
        Theme.goldHi.setStroke(); arc.stroke()
    }

    /// One line, ending in an ellipsis when it does not fit (as the HUD card draws its rows).
    private static func drawTruncated(_ s: String, at p: NSPoint, width: CGFloat, font: NSFont, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        (s as NSString).draw(with: NSRect(x: p.x, y: p.y, width: width, height: font.boundingRectForFont.height),
                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                             attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }
}

/// Follows a held-up document, runs the scan, and turns held gestures into its outcome.
final class MirrorScan {
    let board = MirrorBoard()
    var scanner: VisionScanner?
    var store: Store?
    /// Set by the mirror so a scan can take a still.
    weak var scannerCamera: VisionCamera?
    /// A scan finished (filed, discarded, or failed and dismissed).
    var onScanDone: (() -> Void)?
    /// The card appeared or went away, so the mirror should resize.
    var onActiveChange: ((Bool) -> Void)?
    var isActive: Bool { board.state.scan != nil }
    private(set) var trackedDocument: VNRectangleObservation?
    private(set) var scanProgress: Double = 0
    private var steadySince: CFTimeInterval = 0
    private var lastDocSeen: CFTimeInterval = 0
    private var pendingText = ""
    private var candidate: HandGesture?
    private var since: CFTimeInterval = 0
    private var fired = false
    private var lastSeen: CFTimeInterval = 0
    private var busy = false
    private var scanStarted = Date.distantPast
    /// Things GoldWare was shown and told to drop (or that sit still in the background): not scanned
    /// again until they move away, so a poster or monitor behind you cannot loop scans.
    private var ignored: [VNRectangleObservation] = []
    /// The document most recently scanned, remembered so it is not scanned twice in a row.
    private var lastScanned: VNRectangleObservation?

    private func setScan(_ phase: ScanPhase?) {
        let was = isActive
        board.state.scan = phase
        if was != isActive { onActiveChange?(isActive) }
    }

    func closed() {
        resetScan()
        candidate = nil
        board.state.hold = nil
    }

    /// One camera frame, on the main queue: follows a held-up document, then reads gestures.
    func observe(_ f: VisionFrame) {
        followDocument(f)
        guard isActive else { candidate = nil; setHold(nil); return }
        observe(f.gesture)
    }

    /// The board redraws on every state write, so only write when the hold actually changes.
    private func setHold(_ hold: (gesture: HandGesture, progress: Double)?) {
        let old = board.state.hold
        if old?.gesture == hold?.gesture && old?.progress == hold?.progress { return }
        board.state.hold = hold
    }

    /// Tracks a document across frames and starts the scan once it has been held steady.
    private func followDocument(_ f: VisionFrame) {
        let now = f.time
        switch board.state.scan {
        case .reading, .ready, .done: return
        default: break
        }
        // Forget ignored rectangles once nothing like them is in view any more.
        ignored.removeAll { old in f.document.map { Self.moved(old, $0) > 0.08 } ?? true }
        guard let d = f.document.flatMap({ d in ignored.contains { Self.moved($0, d) < 0.08 } ? nil : d }) else {
            // Tolerate a few dropped detections before giving up on the document.
            if trackedDocument != nil && now - lastDocSeen > 0.5 {
                trackedDocument = nil
                scanProgress = 0
                if case .steadying = board.state.scan {
                    setScan(nil)
                    onScanDone?()   // a pinned mirror closes when the page is taken away
                }
            }
            return
        }
        lastDocSeen = now
        if let old = trackedDocument, Self.moved(old, d) < 0.025 {
            scanProgress = min(1, (now - steadySince) / 1.1)
        } else {
            steadySince = now
            scanProgress = 0
        }
        trackedDocument = d
        // A glimpse is not a scan: the card only appears once the page has been still a moment.
        if scanProgress > 0.15, !isActive { setScan(.steadying) }
        if scanProgress >= 1, isActive { startScan(d) }
    }

    private static func moved(_ a: VNRectangleObservation, _ b: VNRectangleObservation) -> CGFloat {
        [(a.topLeft, b.topLeft), (a.topRight, b.topRight), (a.bottomLeft, b.bottomLeft), (a.bottomRight, b.bottomRight)]
            .map { hypot($0.0.x - $0.1.x, $0.0.y - $0.1.y) }.max() ?? 1
    }

    private func startScan(_ d: VNRectangleObservation) {
        guard let scanner, let image = scannerCamera?.still(cropTo: d) else {
            setScan(.failed("Couldn't take a still. Try again."))
            return
        }
        lastScanned = d
        setScan(.reading)
        Sounds.play(.assistantStart)
        Task {
            do {
                let (r, text) = try await scanner.read(image)
                await MainActor.run {
                    guard case .reading = self.board.state.scan else { return }   // closed meanwhile
                    self.pendingText = text
                    self.setScan(.ready(r))
                    Sounds.play(.done)
                    self.expire(after: 45)
                }
            } catch {
                await MainActor.run {
                    guard case .reading = self.board.state.scan else { return }
                    self.setScan(.failed(error.localizedDescription))
                    Sounds.play(.error)
                    self.expire(after: 8)
                }
            }
        }
    }

    /// An unanswered result or error is discarded on its own, so a pinned mirror never lingers.
    private func expire(after seconds: Double) {
        let started = Date()
        scanStarted = started
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.scanStarted == started, !self.busy else { return }
            switch self.board.state.scan {
            case .ready, .failed:
                if let d = self.lastScanned { self.ignored.append(d) }
                self.resetScan(); self.onScanDone?()
            default: break
            }
        }
    }

    private func resetScan() {
        setScan(nil)
        trackedDocument = nil
        scanProgress = 0
        pendingText = ""
    }

    private func finishScan(after seconds: Double) {
        if let d = lastScanned { ignored.append(d) }   // filed or copied: wait for it to leave first
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            self.resetScan()
            self.onScanDone?()
        }
    }

    private func observe(_ g: HandGesture?) {
        let now = CACurrentMediaTime()
        guard let g else {
            if candidate != nil && now - lastSeen > 0.25 {
                candidate = nil
                setHold(nil)
            }
            return
        }
        lastSeen = now
        if g != candidate {
            candidate = g
            since = now
            fired = false
        }
        guard !fired, !busy, let scan = board.state.scan else { return }
        switch (scan, g) {
        case (.ready, .thumbsUp), (.ready, .count(2)), (.ready, .fist), (.failed, .fist): break
        default: setHold(nil); return
        }
        let progress = min(1, (now - since) / holdSeconds(g))
        setHold((g, progress))
        if progress >= 1 {
            fired = true
            setHold(nil)
            performScan(g, scan)
        }
    }

    private func performScan(_ g: HandGesture, _ scan: ScanPhase) {
        switch (scan, g) {
        case (.ready(let r), .thumbsUp):
            guard let scanner, let store else { return }
            busy = true
            setScan(.reading)
            let text = pendingText
            Task {
                let result = await scanner.file(r, text: text, store: store)
                await MainActor.run {
                    self.busy = false
                    let ok = result.action != "failed"
                    Sounds.play(ok ? .done : .error)
                    self.setScan(.done(result.summary, ok: ok))
                    self.finishScan(after: ok ? 1.8 : 4)
                }
            }
        case (.ready(let r), .count(2)):
            Paster.copy(VisionScanner.clipboardText(r, text: pendingText))
            Sounds.play(.done)
            setScan(.done("Copied to the clipboard", ok: true))
            finishScan(after: 1.4)
        case (.ready, .fist), (.failed, .fist):
            Sounds.play(.stop)
            if let d = lastScanned { ignored.append(d) }
            resetScan()
            onScanDone?()
        default:
            break
        }
    }
}
