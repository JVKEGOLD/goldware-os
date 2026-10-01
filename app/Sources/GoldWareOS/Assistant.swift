import Foundation

/// What the assistant understood from a spoken request.
struct AssistantIntent: Codable {
    var intent: String          // task | draft | note | paste | recall | agenda | complete | undo | closeout | vision_on | vision_off
    var title: String
    var due_on: String
    var priority: String
    var details: String
    var draft: DraftPart
    var paste_label: String
    var task_query: String

    struct DraftPart: Codable {
        var channel: String
        var to: String
        var subject: String
        var body: String
    }
}

/// The outcome shown in the HUD and saved to history.
struct AssistantResult {
    var summary: String         // one line for the HUD and the menu
    var action: String          // task | draft | note | queued | failed
    var reference: String       // request id or draft path
    var pasteValue: String? = nil
}

/// Turns spoken requests into inbox tasks and message drafts.
/// It only ever creates inbox tasks and drafted files. It never sends anything.
final class Assistant {
    let ollama = URL(string: "http://127.0.0.1:11434/api/chat")!
    let commandCenter = URL(string: ProcessInfo.processInfo.environment["GOLDWARE_WORK_URL"] ?? "http://127.0.0.1:\(GWConfig.port)/api/work")!
    var context: VaultContext = .empty
    /// Prompts, commands, and snippets that can be pasted. Only their labels reach the model.
    var library: Library?
    var root: URL? { context.root.isEmpty ? nil : URL(fileURLWithPath: context.root) }

    // MARK: Understand

    func interpret(_ spoken: String, model: String, now: Date = Date()) async throws -> AssistantIntent {
        let day = DateFormatter()
        day.dateFormat = "EEEE, yyyy-MM-dd"
        // Small models resolve "next Friday" far better from a list than from arithmetic.
        let cal = Calendar.current
        let calendar = (0..<15).compactMap { cal.date(byAdding: .day, value: $0, to: now) }
            .map { day.string(from: $0) + ($0 == now ? " (today)" : "") }.joined(separator: "\n")
        let name = GWConfig.name

        let system = """
        You are \(name), a local assistant on this Mac. The user held the talk key and said something to you. Turn it into exactly one action.

        Today is \(day.string(from: now)). The next two weeks:
        \(calendar)
        "This week" ends Sunday of this week, "next week" is the following Monday through Sunday, and "end of next week" is that Friday.

        intent:
        - "agenda" when the user asks what is on their plate, what is due, or what to work on.
        - "complete" when the user says they finished or are done with an existing task, or asks to mark one done. Put the words that identify the task in task_query.
        - "undo" when the user says undo, take that back, scratch that, or never mind about the last thing you did.
        - "vision_on" when the user asks to turn on, start, or open Vision Mode or hand tracking right now. "vision_off" when they ask to turn it off or stop it. A task about vision ("remind me to fix Vision Mode") is a task, not this.
        - "closeout" when the user recaps a work block or their day to close it out ("closing out", "wrap up", "end of day recap"). Put the full cleaned recap in details.
        - "paste" ONLY when the user is asking you to put one of the saved items listed under Paste items into what they are typing right now: "paste my email", "add my address", "put in my phone number". Put its exact label in paste_label.
        - "recall" when the user asks what a saved item is ("what's my email again") without asking to insert it. Put its label in paste_label.
          Talking ABOUT an item is not a paste. "Remind me to update my address with the DMV" is a task. "My mobile number changed, note that" is a note. "Draft an email to Sam with my email in it" is a draft. When unsure, it is not a paste.
        - "draft" when the user asks you to draft, write, or reply to a message for someone.
        - "task" when it is something to do, follow up on, or be reminded about.
        - "note" when it is an idea, observation, or fact worth keeping that is not an action.

        title: a short imperative starting with a verb, at most 12 words, no trailing period. For a note, start with "Review note:". For a draft, "Reply to <name> about <topic>".
        due_on: YYYY-MM-DD only when the user names a day or date, resolved against today. Otherwise empty.
        priority: "high" only when the user says it is urgent or important. Otherwise empty.
        details: what the user said, cleaned up, keeping every fact they gave.
        draft: only for intent "draft", otherwise empty strings.
          channel: "SMS" for a text or message, otherwise "Email".
          to: the recipient's name.
          subject: a short subject for email, empty for SMS.
          body: the message itself, written as the user. Where one of the Paste items belongs in the message (for example "tell him he can reach me at my email"), write the token {{Label}} with the exact label instead of guessing the value. Plain, warm, and human, with contractions. Answer early and end with one clear next step. No signature, greeting line only if natural. Never use em dashes. Never invent prices, dates, promises, or facts the user did not say.
        \(styleRules())

        paste_label: only for intent "paste" or "recall", the exact label from Paste items. Otherwise empty.
        task_query: only for intent "complete". Otherwise empty.

        Paste items (labels only):
        \((library?.all ?? []).map { "- \($0.title)" }.joined(separator: "\n"))
        """

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "intent": ["type": "string", "enum": ["task", "draft", "note", "paste", "recall", "agenda", "complete", "undo", "closeout", "vision_on", "vision_off"]],
                "task_query": ["type": "string"],
                "paste_label": ["type": "string"],
                "title": ["type": "string"],
                "due_on": ["type": "string"],
                "priority": ["type": "string"],
                "details": ["type": "string"],
                "draft": [
                    "type": "object",
                    "properties": ["channel": ["type": "string"], "to": ["type": "string"],
                                   "subject": ["type": "string"], "body": ["type": "string"]],
                    "required": ["channel", "to", "subject", "body"],
                ],
            ],
            "required": ["intent", "title", "due_on", "priority", "details", "draft", "paste_label", "task_query"],
        ]

        guard var intent = try await structured(AssistantIntent.self, model: model, system: system,
                                                user: ["role": "user", "content": spoken], schema: schema, temperature: 0.2)
        else { throw EngineError.message("\(GWConfig.name) could not understand that one") }
        return sanitize(&intent)
    }

    /// One schema-constrained chat with the local model, decoded as `T` (nil when the reply does not
    /// match). Shared by voice requests and Vision scans.
    func structured<T: Decodable>(_ type: T.Type, model: String, system: String, user: [String: Any], schema: [String: Any],
                                  temperature: Double, timeout: TimeInterval = 90) async throws -> T? {
        var req = URLRequest(url: ollama)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "stream": false, "think": false, "keep_alive": "60m",
            "format": schema, "options": ["temperature": temperature],
            "messages": [["role": "system", "content": system], user],
        ] as [String: Any])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = (json["message"] as? [String: Any])?["content"] as? String
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(content.utf8))
    }

    /// House style for anything a model writes: no em dashes.
    static func noDash(_ s: String) -> String { s.replacingOccurrences(of: "\u{2014}", with: ", ") }

    /// A model-written title: no em dashes, no trailing period, at most 150 characters.
    static func cleanTitle(_ s: String) -> String {
        String(noDash(s).trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "."))).prefix(150))
    }

    /// One generic style line for drafts.
    func styleRules() -> String {
        "          Style: short, warm, plain. Texts are one or two sentences. Contractions always. No emoji."
    }

    /// The model can be wrong about intent; only switch Vision when the words name it.
    static func asksForVision(_ spoken: String) -> Bool {
        let s = spoken.lowercased()
        return s.contains("vision") || s.contains("hand tracking") || s.contains("hand-tracking")
    }

    private func sanitize(_ i: inout AssistantIntent) -> AssistantIntent {
        i.title = Self.cleanTitle(i.title)
        i.details = Self.noDash(i.details)
        i.draft.body = Self.noDash(i.draft.body)
        i.draft.subject = Self.noDash(i.draft.subject)
        if i.due_on.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) == nil { i.due_on = "" }
        if !["high", "medium", "low"].contains(i.priority) { i.priority = "" }
        if i.title.isEmpty { i.title = "Review voice capture" }
        return i
    }

    // MARK: Act

    func perform(_ i: AssistantIntent, spoken: String, store: Store) async -> AssistantResult {
        if i.intent == "closeout" {
            var capture = i
            let time = DateFormatter()
            time.dateFormat = "h:mm a"
            capture.title = "Process the voice closeout from \(time.string(from: Date()))"
            capture.intent = "note"
            let payload = capturePayload(capture, spoken: spoken)
            let requestID = payload["request_id"] as? String ?? ""
            let prompt = library?.item(named: "Close out")?.value ?? "Close out this work block."
            Paster.copy(prompt + "\n\nWhat I did, dictated:\n" + i.details)
            switch await post(payload) {
            case .saved:
                return AssistantResult(summary: "Closeout saved to the inbox. The Close out prompt with your notes is on the clipboard.",
                                   action: "closeout", reference: requestID)
            case .rejected(let m):
                return AssistantResult(summary: "Closeout is on the clipboard, but the Task list refused it: \(m)", action: "failed", reference: "")
            case .offline:
                store.enqueue(payload: payload, title: capture.title)
                return AssistantResult(summary: "Closeout is on the clipboard and will reach the task list when the server is back.",
                                   action: "queued", reference: requestID)
            }
        }
        if i.intent == "recall" {
            guard let item = library?.item(named: i.paste_label) else {
                return AssistantResult(summary: "\(GWConfig.name) has no saved item called \"\(i.paste_label)\"", action: "failed", reference: "")
            }
            if item.value.isEmpty { return AssistantResult(summary: "\(item.title) is empty. Add it with Edit snippets.", action: "recall", reference: item.title) }
            let shown = item.isPrivate ? "saved (private). Say \"paste my \(item.title.lowercased())\" to insert it." : item.value
            return AssistantResult(summary: "\(item.title): \(shown)", action: "recall", reference: item.title)
        }
        if i.intent == "paste" {
            guard let item = library?.item(named: i.paste_label) else {
                return AssistantResult(summary: "\(GWConfig.name) has no saved item called \"\(i.paste_label)\"", action: "failed", reference: "")
            }
            // The model can be wrong about intent; only paste when the words really ask for it.
            guard library?.isRequested(item, in: spoken) == true else {
                return AssistantResult(summary: "Didn't paste. That sounded like talk about your \(item.title), not a request to insert it.",
                                   action: "skipped", reference: "")
            }
            guard !item.value.isEmpty else {
                return AssistantResult(summary: "\(item.title) is empty. Add it with Edit snippets.", action: "failed", reference: "")
            }
            return AssistantResult(summary: "Pasted \(item.title)", action: "paste", reference: item.title, pasteValue: item.value)
        }
        if i.intent == "draft" {
            return writeDraft(i, spoken: spoken)
        }
        let payload = capturePayload(i, spoken: spoken)
        let requestID = payload["request_id"] as? String ?? ""
        let label = i.intent == "note" ? "Note" : "Task"
        switch await post(payload) {
        case .saved:
            return AssistantResult(summary: "\(label) added to your tasks: \(i.title)", action: i.intent, reference: requestID)
        case .rejected(let message):
            return AssistantResult(summary: "\(GWConfig.name) could not save it: \(message)", action: "failed", reference: requestID)
        case .offline:
            store.enqueue(payload: payload, title: i.title)
            return AssistantResult(summary: "The server is offline. Saved \"\(i.title)\" and will retry.", action: "queued", reference: requestID)
        }
    }

    func capturePayload(_ i: AssistantIntent, spoken: String, now: Date = Date()) -> [String: Any] {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd h:mm a"
        var context = "Captured by \(GWConfig.name) Voice \(stamp.string(from: now)).\n\n\(i.details)\n\nSaid: \"\(spoken)\""
        let requestID = "voice-\(UUID().uuidString.lowercased())"
        context = String(context.prefix(4900)) + "\n\n(voice capture \(requestID))"
        var changes: [String: Any] = ["title": i.title, "context": context, "status": "inbox"]
        if !i.due_on.isEmpty { changes["due_on"] = i.due_on }
        if !i.priority.isEmpty { changes["priority"] = i.priority }
        return ["create": true, "request_id": requestID, "changes": changes]
    }

    enum PostOutcome { case saved, rejected(String), offline }

    func post(_ payload: [String: Any]) async -> PostOutcome {
        var req = URLRequest(url: commandCenter)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return .saved }
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            return .rejected(message ?? "HTTP \(status)")
        } catch {
            return .offline
        }
    }

    /// Retries captures saved while the server was down.
    func flushOutbox(_ store: Store) async -> Int {
        var sent = 0
        for item in store.pendingOutbox() {
            guard let payload = try? JSONSerialization.jsonObject(with: Data(item.payload.utf8)) as? [String: Any] else {
                store.markOutbox(id: item.id, state: "failed")
                continue
            }
            switch await post(payload) {
            case .saved: store.markOutbox(id: item.id, state: "sent"); sent += 1
            case .rejected: store.markOutbox(id: item.id, state: "failed")
            case .offline: return sent
            }
        }
        return sent
    }

    /// Where drafts are saved: <root>/data/drafts, or GOLDWARE_DATA_ROOT/drafts when set.
    var draftsDir: URL? {
        if let env = ProcessInfo.processInfo.environment["GOLDWARE_DATA_ROOT"] {
            return URL(fileURLWithPath: env, isDirectory: true).appendingPathComponent("drafts", isDirectory: true)
        }
        return root?.appendingPathComponent("data/drafts", isDirectory: true)
    }

    /// The file a draft result points at (a path relative to the root, or absolute).
    func draftURL(_ reference: String) -> URL? {
        if reference.hasPrefix("/") { return URL(fileURLWithPath: reference) }
        return root?.appendingPathComponent(reference)
    }

    /// Drafts are copied to the clipboard and saved as markdown. Sending always stays with the user.
    func writeDraft(_ i: AssistantIntent, spoken: String, now: Date = Date()) -> AssistantResult {
        let body = (library?.expandDraft(i.draft.body) ?? i.draft.body).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return AssistantResult(summary: "\(GWConfig.name) did not write a draft", action: "failed", reference: "") }
        Paster.copy(body)
        guard let dir = draftsDir else {
            return AssistantResult(summary: "Draft copied. Paste it where it goes.", action: "draft", reference: "")
        }
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd h:mm a"
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let slug = i.title.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(50)
        var file = dir.appendingPathComponent("\(day.string(from: now))-voice-\(slug).md")
        var n = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = dir.appendingPathComponent("\(day.string(from: now))-voice-\(slug)-\(n).md")
            n += 1
        }
        let text = """
        # \(i.title)

        Channel: \(i.draft.channel.isEmpty ? "Email" : i.draft.channel)
        To: \(i.draft.to)
        Subject: \(i.draft.subject)

        \(body)

        ---
        Status: drafted, not sent.
        Drafted by \(GWConfig.name) from dictation on \(stamp.string(from: now)) with a local model. Review the facts before sending.

        Said: "\(spoken)"

        """
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            return AssistantResult(summary: "Draft copied, but the file could not be saved", action: "draft", reference: "")
        }
        var reference = file.path
        if let root, file.path.hasPrefix(root.path + "/") { reference = String(file.path.dropFirst(root.path.count + 1)) }
        let who = i.draft.to.isEmpty ? "" : " for \(i.draft.to)"
        return AssistantResult(summary: "Draft\(who) saved and copied", action: "draft", reference: reference)
    }
}
