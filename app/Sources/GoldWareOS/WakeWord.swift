import AVFoundation
import Speech

/// The wake phrase: listens with Apple's on-device speech recognizer, so nothing leaves the Mac. The last
/// few seconds of audio are always kept, so "Hey GoldWare, remind me..." said in one breath loses nothing.
/// On the wake phrase it keeps recording until you stop talking, then hands the clip (wake phrase
/// included; `stripWake` removes it after Whisper) to the same pipeline as holding Right Command.
final class WakeWord {
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "wakeWordEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "wakeWordEnabled") }
    }

    enum State { case off, listening, capturing }
    private(set) var state = State.off

    /// The wake phrase was heard; a request is being recorded.
    var onWake: (() -> Void)?
    var onLevel: ((Float) -> Void)?
    /// A finished request: the clip, its length, and its loudest moment (dBFS).
    var onRequest: ((URL, TimeInterval, Float) -> Void)?
    /// The wake phrase with nothing after it.
    var onNothing: (() -> Void)?
    var onError: ((String) -> Void)?

    private var engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var taskStarted = Date()
    private var generation = 0      // callbacks from a cancelled task are ignored
    private var failures = 0
    private var configObserver: Any?

    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var ring: [Int16] = []                  // the last `preroll` seconds, always
    private var clip: [Int16]?                      // non-nil while capturing
    private var endpoint = Endpointer()
    private var peak: Float = -160
    private var words = WordEndpointer()
    private static let preroll = 2.5

    // MARK: Switching

    /// Asks for speech recognition access, then reports whether it was granted.
    static func authorize(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { done(status == .authorized) }
        }
    }

    /// Listens when `want`, otherwise lets go of the microphone. A request being recorded finishes first.
    func setActive(_ want: Bool) {
        if want, state == .off { start() }
        if !want, state == .listening { stop() }
    }

    /// Esc: drop the request being recorded.
    func cancelCapture() {
        guard state == .capturing else { return }
        lock.lock(); clip = nil; lock.unlock()
        stop()
    }

    /// Tapping Right Command while the assistant is listening ends the request now.
    func finishCapture() {
        guard state == .capturing else { return }
        complete(.done)
    }

    private func start() {
        guard let recognizer, recognizer.isAvailable else { onError?("Speech recognition is not available right now"); return }
        engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let conv = AVAudioConverter(from: format, to: target) else {
            onError?("No microphone input"); return
        }
        converter = conv
        lock.lock(); ring.removeAll(keepingCapacity: true); clip = nil; lock.unlock()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.consume(buffer, format: format)
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            onError?("Mic error: \(error.localizedDescription)")
            return
        }
        state = .listening
        // AirPods connecting or the input changing stops the engine; pick the new mic up.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                                queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.state == .capturing { self.complete(.done); return }
            guard self.state == .listening else { return }
            self.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if Self.enabled { self.setActive(true) } }
        }
        startRecognition()
    }

    private func stop() {
        endRecognition()
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        state = .off
    }

    // MARK: Recognition

    private func startRecognition() {
        guard state != .off, let recognizer else { return }
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.requiresOnDeviceRecognition = true
        r.shouldReportPartialResults = true
        r.contextualStrings = Self.contextualStrings
        r.taskHint = .search
        lock.lock(); request = r; lock.unlock()
        taskStarted = Date()
        generation += 1
        let mine = generation
        task = recognizer.recognitionTask(with: r) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.generation == mine else { return }
                self.recognized(result, error: error)
            }
        }
    }

    private func endRecognition() {
        generation += 1
        task?.cancel()
        lock.lock(); request?.endAudio(); request = nil; lock.unlock()
        task = nil
    }

    private func recognized(_ result: SFSpeechRecognitionResult?, error: Error?) {
        if state == .capturing {
            if let text = result?.bestTranscription.formattedString { words.heard(text, at: Date().timeIntervalSinceReferenceDate) }
            return
        }
        guard state == .listening else { return }
        if let text = result?.bestTranscription.formattedString, Self.heardWake(text) {
            failures = 0
            wake()
            return
        }
        // A task ends on its own after a long silence or about a minute; start a fresh one.
        if error != nil || result?.isFinal == true {
            // A quiet room ends tasks with a "no speech" error; only a task that fails right away is broken.
            let quick = Date().timeIntervalSince(taskStarted) < 3
            if error != nil && quick { failures += 1 } else { failures = 0 }
            endRecognition()
            if failures >= 5 {
                stop()
                Self.enabled = false
                onError?("\(GWConfig.wakePhrase) stopped: speech recognition keeps failing. Turn it on again to retry.")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (failures == 0 ? 0.1 : 1.5)) { [weak self] in self?.startRecognition() }
        } else if Date().timeIntervalSince(taskStarted) > 50 {
            endRecognition()
            startRecognition()
        }
    }

    private func wake() {
        endRecognition()   // a fresh transcript later, so this wake phrase cannot fire again
        lock.lock()
        clip = ring
        endpoint = Endpointer(floor: endpoint.floor)
        peak = -160
        lock.unlock()
        state = .capturing
        // A second transcript for the request itself: when its words stop changing, you are done,
        // however noisy the room is.
        words = WordEndpointer(start: Date().timeIntervalSinceReferenceDate)
        startRecognition()
        onWake?()
    }

    // MARK: Audio (tap thread)

    private func consume(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        lock.lock(); let r = request; lock.unlock()
        r?.append(buffer)
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard let data = out.int16ChannelData?[0] else { return }
        let n = Int(out.frameLength)
        guard n > 0 else { return }
        let chunk = Array(UnsafeBufferPointer(start: data, count: n))
        var sum: Float = 0, top: Float = 0
        for v in chunk { let f = Float(v) / 32768; sum += f * f; top = max(top, abs(f)) }
        let db = 20 * log10(max((sum / Float(n)).squareRoot(), 1e-6))

        lock.lock()
        ring.append(contentsOf: chunk)
        let keep = Int(Self.preroll * 16_000)
        if ring.count > keep { ring.removeFirst(ring.count - keep) }
        var verdict = Endpointer.Verdict.listening
        if clip != nil {
            clip?.append(contentsOf: chunk)
            peak = max(peak, 20 * log10(max(top, 1e-6)))
            verdict = endpoint.feed(db: db, seconds: Double(n) / 16_000)
        } else {
            endpoint.track(idle: db)
        }
        let capturing = clip != nil
        lock.unlock()

        guard capturing else { return }
        let level = max(0, min(1, (db + 50) / 50))
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state == .capturing else { return }
            self.onLevel?(level)
            if verdict != .listening { self.complete(verdict); return }
            let byWords = self.words.verdict(at: Date().timeIntervalSinceReferenceDate)
            if byWords != .listening { self.complete(byWords) }
        }
    }

    private func complete(_ verdict: Endpointer.Verdict) {
        lock.lock()
        let samples = clip ?? []
        let loudest = peak
        clip = nil
        lock.unlock()
        stop()
        guard verdict == .done, !samples.isEmpty else { onNothing?(); return }
        let url = Paths.audioDir.appendingPathComponent("wake-\(Int(Date().timeIntervalSince1970 * 1000)).wav")
        guard Self.writeWAV(samples, to: url) else { onError?("Could not save the recording"); return }
        onRequest?(url, Double(samples.count) / 16_000, loudest)
    }

    // MARK: Text

    private static let greetings = ["hey", "hi", "hay", "okay", "ok"]
    private static let greetingPattern = "(?:hey|hi|hay|okay|ok)"
    private static let separator = #"[\s,.!-]+"#

    /// Splits a spoken name into its words, also at lowercase-to-uppercase joins ("GoldWare" -> Gold, Ware).
    private static func nameParts(_ text: String) -> [String] {
        var parts: [String] = []
        for word in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            var cur = ""
            var prev: Character?
            for ch in word {
                if let p = prev, p.isLowercase, ch.isUppercase { parts.append(cur); cur = "" }
                cur.append(ch)
                prev = ch
            }
            if !cur.isEmpty { parts.append(cur) }
        }
        return parts
    }

    /// One phrase as a regex fragment: an optional-free greeting when the phrase starts with one,
    /// then the name words with flexible spacing ("gold ware", "goldware", "gold-ware").
    private static func fragment(for phrase: String) -> (full: String, name: String)? {
        var words = phrase.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        var hasGreeting = false
        if let first = words.first, greetings.contains(first.lowercased()), words.count > 1 { words.removeFirst(); hasGreeting = true }
        let parts = nameParts(words.joined(separator: " "))
        guard !parts.isEmpty else { return nil }
        // "ware" is often heard as "wear", so a trailing ware accepts both.
        let name = parts.map { part -> String in
            let esc = NSRegularExpression.escapedPattern(for: part)
            return part.lowercased().hasSuffix("ware") ? String(esc.dropLast(4)) + "w(?:are|ear)" : esc
        }.joined(separator: #"[\s-]*"#)
        return (hasGreeting ? greetingPattern + separator + name : name, name)
    }

    /// The wake matcher for a phrase and its aliases. Pure, so it can be tested with any name.
    /// `full` finds the phrase anywhere; `bare` finds just the name at the start of a request.
    static func buildWakeRegex(phrase: String, aliases: [String]) -> (full: NSRegularExpression, bare: NSRegularExpression?) {
        let frags = ([phrase] + aliases).compactMap(fragment(for:))
        let bodies = Array(NSOrderedSet(array: frags.map(\.full))) as? [String] ?? []
        let full = bodies.isEmpty ? #"(?!x)x"# : #"\b(?:"# + bodies.joined(separator: "|") + #")\b[\s,.!?:-]*"#
        let bare = fragment(for: phrase).map { try? NSRegularExpression(pattern: #"^\s*"# + $0.name + #"\b[\s,.!?:-]*"#, options: [.caseInsensitive]) } ?? nil
        return (try! NSRegularExpression(pattern: full, options: [.caseInsensitive]), bare)
    }

    private static var cachedRegex: (key: String, value: (full: NSRegularExpression, bare: NSRegularExpression?))?
    private static var wake: (full: NSRegularExpression, bare: NSRegularExpression?) {
        let c = GWConfig.current
        let key = ([c.wakePhrase] + c.wakeAliases).joined(separator: "\u{1}")
        if let cached = cachedRegex, cached.key == key { return cached.value }
        let built = buildWakeRegex(phrase: c.wakePhrase, aliases: c.wakeAliases)
        cachedRegex = (key, built)
        return built
    }

    /// The phrases handed to the recognizer as hints.
    static var contextualStrings: [String] { [GWConfig.wakePhrase, GWConfig.name] + GWConfig.current.wakeAliases }

    /// True when the recognizer's words contain the configured wake phrase or one of its aliases.
    static func heardWake(_ text: String) -> Bool { heardWake(text, using: wake) }

    static func heardWake(_ text: String, using m: (full: NSRegularExpression, bare: NSRegularExpression?)) -> Bool {
        m.full.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The request without the wake phrase or anything said before it: "so yeah. Hey GoldWare, remind me
    /// to call Sam" becomes "Remind me to call Sam".
    static func stripWake(_ text: String) -> String { stripWake(text, using: wake) }

    static func stripWake(_ text: String, using m: (full: NSRegularExpression, bare: NSRegularExpression?)) -> String {
        let ns = text as NSString
        var rest = text
        if let hit = m.full.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            rest = ns.substring(from: hit.range.location + hit.range.length)
        } else if let hit = m.bare?.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            rest = ns.substring(from: hit.range.length)
        }
        rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = rest.first else { return "" }
        return first.uppercased() + rest.dropFirst()
    }

    static func writeWAV(_ pcm: [Int16], to url: URL) -> Bool {
        var data = Data(capacity: 44 + pcm.count * 2)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(pcm.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(bytes)
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return (try? data.write(to: url)) != nil
    }
}

/// Decides when a spoken request is over from the words: 1.5 s after the transcript last changed.
/// Loudness alone never ends in a noisy room (a fan or music keeps resetting its silence timer).
/// No words at all within 6 s means nothing was asked.
struct WordEndpointer {
    private(set) var start = 0.0
    private var lastText = ""
    private var lastChange: Double?

    init(start: Double = 0) { self.start = start }

    mutating func heard(_ text: String, at t: Double) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != lastText else { return }
        lastText = text
        lastChange = t
    }

    func verdict(at t: Double) -> Endpointer.Verdict {
        if let c = lastChange { return t - c >= 1.5 ? .done : .listening }
        return t - start >= 6 ? .nothing : .listening
    }
}

/// Decides when a spoken request is over, from loudness alone. Speech is anything 10 dB over the room's
/// noise floor (tracked while idle). The request ends 1.2 s after you stop talking, gives you 5 s to
/// start after the wake phrase (a pause for the chime is fine), and never runs past 30 s. The first 0.6 s
/// is ignored: the tail of the name and the chime itself are not the request.
struct Endpointer {
    enum Verdict { case listening, done, nothing }
    private(set) var floor: Float = -60
    private var speech = 0.0, silence = 0.0, elapsed = 0.0
    private(set) var heardSpeech = false

    init(floor: Float = -60) { self.floor = floor }

    /// Follows the room's quiet level: drops quickly, rises slowly (so talking does not raise it much).
    mutating func track(idle db: Float) {
        floor = db < floor ? floor + (db - floor) * 0.3 : floor + (db - floor) * 0.01
    }

    mutating func feed(db: Float, seconds dt: Double) -> Verdict {
        elapsed += dt
        if elapsed < 0.6 { return .listening }
        if db > max(floor + 10, -55) {
            speech += dt
            silence = 0
            if speech >= 0.3 { heardSpeech = true }
        } else {
            silence += dt
            if !heardSpeech { speech = 0 }
        }
        if elapsed >= 30 { return .done }
        if heardSpeech && silence >= 1.2 { return .done }
        if !heardSpeech && elapsed >= 5 { return .nothing }
        return .listening
    }
}
