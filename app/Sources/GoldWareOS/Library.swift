import Foundation

/// Things the card (and "paste my ...") can put into the app you are in: prompts and personal snippets.
struct LibraryItem: Equatable {
    enum Kind { case prompt, command, snippet }
    let kind: Kind
    let group: String
    let title: String
    let detail: String
    let value: String
    /// Masked in the card. Still pasted in full when clicked.
    let isPrivate: Bool
}

final class Library {
    private(set) var prompts: [LibraryItem] = []
    private(set) var snippets: [LibraryItem] = []
    private var promptsStamp: Date?
    private var snippetsStamp: Date?
    var root: URL?

    static let snippetsFile = Paths.dataDir.appendingPathComponent("snippets.json")

    /// Starter prompts. Replace or add your own in prompts.json in the data folder
    /// (a list of {"title", "text", "category", "description"}).
    static let seedPrompts: [LibraryItem] = [
        LibraryItem(kind: .prompt, group: "Prompts", title: "Summarize this", detail: "Short summary of what is on screen",
                    value: "Summarize this in five bullet points. Keep every number and date.", isPrivate: false),
        LibraryItem(kind: .prompt, group: "Prompts", title: "Close out", detail: "Wrap up a work block",
                    value: "Close out this work block. List what was done, what is still open, and the next step for each open item.", isPrivate: false),
    ]

    /// Command words are not used by default.
    static let commands: [LibraryItem] = []

    var all: [LibraryItem] { prompts + Self.commands + snippets }

    /// Re-reads files only when they changed on disk.
    func refresh() {
        prompts = Self.seedPrompts
        let url = Paths.dataDir.appendingPathComponent("prompts.json")
        if let data = try? Data(contentsOf: url),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let own = list.compactMap { p -> LibraryItem? in
                guard let title = p["title"] as? String, let text = p["text"] as? String else { return nil }
                return LibraryItem(kind: .prompt, group: (p["category"] as? String) ?? "Prompts", title: title,
                                   detail: (p["description"] as? String) ?? "", value: text, isPrivate: false)
            }
            let own_titles = Set(own.map { $0.title.lowercased() })
            prompts = own + prompts.filter { !own_titles.contains($0.title.lowercased()) }
        }
        Self.seedSnippetsIfNeeded()
        let stamp = (try? FileManager.default.attributesOfItem(atPath: Self.snippetsFile.path))?[.modificationDate] as? Date
        if stamp != snippetsStamp, let data = try? Data(contentsOf: Self.snippetsFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = json["snippets"] as? [[String: Any]] {
            snippetsStamp = stamp
            snippets = list.compactMap { s in
                guard let label = s["label"] as? String else { return nil }
                return LibraryItem(kind: .snippet, group: (s["group"] as? String) ?? "Personal", title: label,
                                   detail: (s["note"] as? String) ?? "", value: (s["value"] as? String) ?? "",
                                   isPrivate: (s["private"] as? Bool) ?? false)
            }
        }
    }

    // MARK: Asking versus mentioning
    //
    // "Add my email" asks for the value. "I'll check my email later" only mentions it.
    // The model makes the first call; this local check has the final say, so nothing is ever
    // inserted unless the user said an insertion word and something that names the item.

    static let insertWords = #"\b(add|adding|insert|paste|put|type|drop|fill in|enter|include|stick|plug in|pop in)\b"#

    func keywords(_ item: LibraryItem) -> Set<String> {
        let stop: Set<String> = ["the", "my", "and", "for", "our", "prompt"]
        var words = Set((item.title + " " + item.group).lowercased()
            .split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 && !stop.contains($0) })
        if !words.isDisjoint(with: ["phone", "mobile", "number", "cell"]) { words.formUnion(["phone", "mobile", "cell", "number"]) }
        if words.contains("email") { words.formUnion(["e-mail", "mail"]) }
        return words
    }

    /// True when the words ask for the item to be inserted, not just talk about it.
    func isRequested(_ item: LibraryItem, in spoken: String) -> Bool {
        if isJustName(item, spoken) { return true }
        let lower = spoken.lowercased()
        guard lower.range(of: Self.insertWords, options: .regularExpression) != nil else { return false }
        return keywords(item).contains { lower.contains($0) }
    }

    /// A clip that is nothing but a snippet's name ("personal email", "my email") asks for it.
    /// In a noisy room the short verb in front ("paste", "add") is the word Whisper loses first,
    /// while the name itself comes through. Nobody dictates just "Personal email." as text.
    func standaloneItem(_ spoken: String) -> LibraryItem? {
        snippets.first { isJustName($0, spoken) }
    }

    private func isJustName(_ item: LibraryItem, _ spoken: String) -> Bool {
        func words(_ s: String) -> [String] { s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }
        let said = words(spoken).drop { ["my", "the", "our"].contains($0) }
        return !said.isEmpty && Array(said) == words(item.title)
    }

    /// Cheap pre-check so a short "add my email" still goes through cleanup.
    func mightRequestInsert(_ spoken: String) -> Bool {
        all.contains { !$0.value.isEmpty && isRequested($0, in: spoken) } || all.contains { $0.value.isEmpty && isRequested($0, in: spoken) }
    }

    struct Expansion {
        var text: String            // what gets pasted
        var historyText: String     // the same, with private values kept out of history
        var inserted: [String] = []
        var empty: [String] = []
    }

    /// Replaces the cleanup model's {{Label}} tokens with the saved values, but only where the
    /// raw transcript really asked for them. Anything else goes back to plain words.
    func expand(_ cleaned: String, raw: String) -> Expansion {
        var result = Expansion(text: cleaned, historyText: cleaned)
        let regex = try! NSRegularExpression(pattern: #"\{\{\s*([^{}]+?)\s*\}\}"#)
        let ns = cleaned as NSString
        var text = "", history = ""
        var last = 0
        for m in regex.matches(in: cleaned, range: NSRange(location: 0, length: ns.length)) {
            let before = ns.substring(with: NSRange(location: last, length: m.range.location - last))
            text += before
            history += before
            let label = ns.substring(with: m.range(at: 1))
            let found = item(named: label)
            if let item = found, isRequested(item, in: raw) {
                // The value replaces the whole instruction, so drop a leftover "add my" right before it.
                let lead = #"(?i)\b(?:and\s+|then\s+)?(?:add|insert|paste|put|type|drop|include|enter|stick|plug)(?:\s+in)?(?:\s+(?:my|the|our))?\s*$"#
                text = text.replacingOccurrences(of: lead, with: "", options: .regularExpression)
                history = history.replacingOccurrences(of: lead, with: "", options: .regularExpression)
                if text.hasSuffix(" ") == false && !text.isEmpty && !text.hasSuffix("\n") { text += " "; history += " " }
                if text.trimmingCharacters(in: .whitespaces).isEmpty { text = ""; history = "" }
                if item.value.isEmpty {
                    text += "[\(item.title)]"
                    history += "[\(item.title)]"
                    result.empty.append(item.title)
                } else {
                    text += item.value
                    history += item.isPrivate ? "[\(item.title)]" : item.value
                    result.inserted.append(item.title)
                }
            } else {
                let words = found.map { $0.kind == .snippet ? "my \($0.title.prefix(1).lowercased() + $0.title.dropFirst())" : $0.title } ?? label
                text += words
                history += words
            }
            last = m.range.location + m.range.length
        }
        text += ns.substring(from: last)
        history += ns.substring(from: last)
        result.text = text
        result.historyText = history
        return result
    }

    /// Drafts are saved into the repo, so only non-private values go in; private ones stay placeholders.
    func expandDraft(_ body: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"\{\{\s*([^{}]+?)\s*\}\}"#)
        var out = body
        for m in regex.matches(in: body, range: NSRange(location: 0, length: (body as NSString).length)).reversed() {
            let label = (body as NSString).substring(with: m.range(at: 1))
            let item = item(named: label)
            let value = item.flatMap { !$0.isPrivate && !$0.value.isEmpty ? $0.value : nil } ?? "[\(item?.title ?? label)]"
            out = (out as NSString).replacingCharacters(in: m.range, with: value)
        }
        return out
    }

    func item(named label: String) -> LibraryItem? {
        let l = label.lowercased().trimmingCharacters(in: .whitespaces)
        return all.first { $0.title.lowercased() == l } ?? all.first { $0.title.lowercased().contains(l) || l.contains($0.title.lowercased()) }
    }

    /// Personal details live only on this Mac, readable by this user only. Not in Git,
    /// not in the vault, never sent to a model (the assistant sees labels, not values).
    static func seedSnippetsIfNeeded() {
        guard !FileManager.default.fileExists(atPath: snippetsFile.path) else { return }
        let seed = """
        {
          "_about": "Snippets. Click one in the card to paste it, or say 'paste my <label>'. Stored only on this Mac. Set private to true to mask it in the card. Do not put passwords, card numbers, or SSNs here; use a password manager.",
          "snippets": [
            { "group": "Email", "label": "Email", "value": "" },
            { "group": "Address", "label": "Home address", "value": "", "private": true },
            { "group": "Address", "label": "Mailing address", "value": "", "private": true },
            { "group": "Phone", "label": "Phone", "value": "", "private": true }
          ]
        }

        """
        try? seed.write(to: snippetsFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snippetsFile.path)
    }
}
