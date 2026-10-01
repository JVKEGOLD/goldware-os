import AppKit
import Vision

/// What the assistant read from something held up to the camera.
struct ScanResult: Codable {
    var kind: String            // contact | receipt | document | note | other
    var title: String           // imperative, what to do with it
    var summary: String         // one line for the card
    var due_on: String
    var fields: [Field]
    var action: String          // task | note

    struct Field: Codable { var label: String; var value: String }
}

/// Show the assistant anything: a still from the camera, read on this Mac (Apple text recognition plus the
/// local vision model), becomes one inbox task after the user confirms. The image itself is
/// never saved or sent anywhere; only the words it read go into the capture.
final class VisionScanner {
    var agent: Assistant?
    var model: String { UserDefaults.standard.string(forKey: "visionModel") ?? UserDefaults.standard.string(forKey: "cleanupModel") ?? GWConfig.current.localModel }

    /// Apple's on-device OCR, accurate mode, top to bottom.
    static func recognizeText(_ image: CGImage) -> String {
        let r = VNRecognizeTextRequest()
        r.recognitionLevel = .accurate
        r.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([r])
        return (r.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func jpeg(_ image: CGImage, maxSide: CGFloat = 1280) -> Data? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let s = min(1, maxSide / max(w, h))
        let size = NSSize(width: (w * s).rounded(), height: (h * s).rounded())
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: image, size: NSSize(width: w, height: h)).draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }

    func read(_ image: CGImage) async throws -> (ScanResult, text: String) {
        let text = Self.recognizeText(image)
        guard let agent else { throw EngineError.message("\(GWConfig.name) is not ready") }
        let day = DateFormatter(); day.dateFormat = "EEEE, yyyy-MM-dd"
        let system = """
        You are \(GWConfig.name), a local assistant on this Mac. The user just held something up to the Mac's camera for you to file. Read the image (and the OCR text, which is more exact for spelling and digits) and decide the single most useful capture.

        Today is \(day.string(from: Date())).

        kind: "contact" for a business card or anything whose point is a person's details; "receipt" for a receipt or invoice; "document" for a letter, form, bill, or notice; "note" for handwriting or a whiteboard; "other" otherwise.
        title: a short imperative, at most 12 words, no trailing period. Contact: "Add <Name> (<Company>) to contacts". Receipt: "Log <vendor> receipt, <amount>". Document: what the user needs to do about it ("Pay the electric bill by Oct 12"). Note: "Review note: <topic>".
        summary: one plain sentence describing what it is.
        due_on: YYYY-MM-DD only when the item states a deadline or due date. Otherwise empty.
        fields: the useful facts, copied exactly from the OCR text where possible (Name, Title, Company, Phone, Email, Website, Address, Vendor, Date, Total, Account, Due, and so on). Never invent a value. Leave out anything you cannot read.
        action: "task" when there is something to do, otherwise "note".
        Never use em dashes.

        """
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "kind": ["type": "string", "enum": ["contact", "receipt", "document", "note", "other"]],
                "title": ["type": "string"], "summary": ["type": "string"],
                "due_on": ["type": "string"],
                "action": ["type": "string", "enum": ["task", "note"]],
                "fields": ["type": "array", "items": [
                    "type": "object", "properties": ["label": ["type": "string"], "value": ["type": "string"]],
                    "required": ["label", "value"]]],
            ],
            "required": ["kind", "title", "summary", "due_on", "fields", "action"],
        ]
        var message: [String: Any] = ["role": "user", "content": "OCR text:\n\(text.isEmpty ? "(none found)" : text)"]
        if let jpg = Self.jpeg(image) { message["images"] = [jpg.base64EncodedString()] }
        guard var r = try await agent.structured(ScanResult.self, model: model, system: system, user: message,
                                                 schema: schema, temperature: 0.1, timeout: 120)
        else { throw EngineError.message("\(GWConfig.name) couldn't read that. Try holding it closer and still.") }
        // Same guards as a voice capture: valid dates only, no em dashes.
        r.title = Assistant.cleanTitle(r.title)
        r.summary = Assistant.noDash(r.summary)
        r.fields = r.fields.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { .init(label: Assistant.noDash($0.label), value: Assistant.noDash($0.value)) }
        if r.due_on.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) == nil { r.due_on = "" }
        if r.title.isEmpty { r.title = "Review scanned item" }
        return (r, text)
    }

    /// Files the scan as one inbox capture, through the same path (and offline outbox) as voice.
    func file(_ r: ScanResult, text: String, store: Store) async -> AssistantResult {
        guard let agent else { return AssistantResult(summary: "\(GWConfig.name) is not ready", action: "failed", reference: "") }
        var details = r.summary
        if !r.fields.isEmpty { details += "\n\n" + r.fields.map { "\($0.label): \($0.value)" }.joined(separator: "\n") }
        if !text.isEmpty { details += "\n\nText read from the image:\n" + String(text.prefix(2500)) }
        let intent = AssistantIntent(intent: r.action, title: r.title,
                                 due_on: r.due_on, priority: "", details: details,
                                 draft: .init(channel: "", to: "", subject: "", body: ""), paste_label: "", task_query: "")
        let payload = agent.capturePayload(intent, spoken: "(shown to \(GWConfig.name) Vision: \(r.kind))")
        let requestID = payload["request_id"] as? String ?? ""
        switch await agent.post(payload) {
        case .saved: return AssistantResult(summary: "Filed: \(r.title)", action: r.action, reference: requestID)
        case .rejected(let m): return AssistantResult(summary: "The task list refused it: \(m)", action: "failed", reference: requestID)
        case .offline:
            store.enqueue(payload: payload, title: r.title)
            return AssistantResult(summary: "Saved \"\(r.title)\". It reaches the task list when the server is back.",
                               action: "queued", reference: requestID)
        }
    }

    /// Plain text for the clipboard: the fields, then everything read.
    static func clipboardText(_ r: ScanResult, text: String) -> String {
        let f = r.fields.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
        return f.isEmpty ? text : f
    }
}
