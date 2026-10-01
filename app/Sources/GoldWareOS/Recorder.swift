import AVFoundation

/// Records the microphone into memory as 16 kHz mono 16-bit PCM, which is what Whisper wants.
/// Keeping the samples in memory lets the app transcribe the clip so far while you are
/// still talking (the live preview), and write the whole clip as a WAV when you stop.
final class Recorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private var samples: [Int16] = []
    private let lock = NSLock()
    private var startedAt = Date()
    private var running = false
    private var currentLevel: Float = 0
    private(set) var peakPower: Float = -160

    static func requestPermission(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { done(granted) }
        }
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let conv = AVAudioConverter(from: format, to: target) else {
            throw NSError(domain: "GoldWareOS", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input"])
        }
        converter = conv
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()
        peakPower = -160
        currentLevel = 0
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.consume(buffer, from: format)
        }
        engine.prepare()
        try engine.start()
        running = true
        startedAt = Date()
    }

    private func consume(_ buffer: AVAudioPCMBuffer, from format: AVAudioFormat) {
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
        var sumSquares: Float = 0
        var peak: Float = 0
        for i in 0..<n {
            let v = Float(data[i]) / 32768
            sumSquares += v * v
            peak = max(peak, abs(v))
        }
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: data, count: n))
        lock.unlock()
        let rms = n > 0 ? (sumSquares / Float(n)).squareRoot() : 0
        let db = 20 * log10(max(rms, 1e-6))
        currentLevel = max(0, min(1, (db + 50) / 50))
        peakPower = max(peakPower, 20 * log10(max(peak, 1e-6)))
    }

    /// 0...1 for the orb and GoldWare's bounce.
    func level() -> Float { currentLevel }

    var elapsed: TimeInterval { running ? Date().timeIntervalSince(startedAt) : 0 }

    /// Stops and writes the whole clip. Returns the duration in seconds.
    func stop(writingTo url: URL?) -> TimeInterval {
        guard running else { return 0 }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        let duration = Date().timeIntervalSince(startedAt)
        if let url { _ = writeWAV(to: url) }
        return duration
    }

    /// Test hook: load samples as if they had been recorded.
    func loadForTest(_ pcm: [Int16]) {
        lock.lock(); samples = pcm; lock.unlock()
    }

    /// Writes what has been heard so far, for the live preview.
    @discardableResult
    func writeWAV(to url: URL) -> Bool {
        lock.lock()
        let copy = samples
        lock.unlock()
        var data = Data(capacity: 44 + copy.count * 2)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(copy.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(bytes)
        copy.withUnsafeBytes { data.append(contentsOf: $0) }
        return (try? data.write(to: url)) != nil
    }
}
