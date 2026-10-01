import AppKit
import ApplicationServices

/// Learns names from the fixes you make after a paste. A few seconds after pasting it re-reads
/// the text field (through Accessibility), lines your version up against what was pasted, and
/// adds corrected proper nouns and terms ("Smythe", "SLA") to the vocabulary so Whisper
/// spells them right next time. Best effort: apps that hide their text are simply skipped.
final class Learner {
    var onLearned: ([String]) -> Void = { _ in }

    private var pending: (element: AXUIElement, pasted: String)?
    private var work: DispatchWorkItem?

    func watch(pasted: String) {
        checkNow()
        guard pasted.split(separator: " ").count >= 2 else { return }
        // Give the paste a moment to land before grabbing the focused field.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, let element = Self.focusedElement() else { return }
            self.pending = (element, pasted)
            let w = DispatchWorkItem { [weak self] in self?.checkNow() }
            self.work = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: w)
        }
    }

    /// Runs early when you start talking again, since that usually means you are done editing.
    func checkNow() {
        work?.cancel()
        guard let p = pending else { return }
        pending = nil
        guard let value = Self.stringValue(p.element) else { return }
        let learned = Self.corrections(pasted: p.pasted, edited: value)
        guard !learned.isEmpty else { return }
        Vocabulary.addLearned(learned)
        onLearned(learned)
    }

    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func stringValue(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func words(_ s: String) -> [String] {
        s.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
    }

    /// Word-level alignment (longest common subsequence) of the pasted text against the edited
    /// field. Short replaced runs that look like names or terms are the corrections worth keeping.
    static func corrections(pasted: String, edited: String) -> [String] {
        if edited.contains(pasted) { return [] }
        let p = words(pasted)
        let e = Array(words(edited).suffix(2500))
        let n = p.count, m = e.count
        guard n >= 2, m >= 2, n <= 200 else { return [] }
        let pl = p.map { $0.lowercased() }, el = e.map { $0.lowercased() }
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = pl[i] == el[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        // Most of the paste must still be there, or this is not the same text.
        guard Double(dp[0][0]) >= Double(n) * 0.5 else { return [] }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < n && j < m {
            if pl[i] == el[j] { pairs.append((i, j)); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 } else { j += 1 }
        }
        var found: [String] = []
        for k in 0..<max(0, pairs.count - 1) {
            let (i1, j1) = pairs[k], (i2, j2) = pairs[k + 1]
            let before = Array(p[(i1 + 1)..<i2]), after = Array(e[(j1 + 1)..<j2])
            guard (1...3).contains(before.count), (1...3).contains(after.count) else { continue }
            let fixed = after.joined(separator: " ")
            guard fixed != before.joined(separator: " "), fixed.count >= 3,
                  fixed.rangeOfCharacter(from: .uppercaseLetters.union(.decimalDigits)) != nil else { continue }
            found.append(fixed)
        }
        // Same idea for a word you only re-cased, like "nova" to "Nova".
        for (a, b) in pairs where p[a] != e[b] && p[a].lowercased() == e[b].lowercased() && e[b].count >= 4
            && e[b].first?.isUppercase == true && a > 0 {
            found.append(e[b])
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.lowercased()).inserted }
    }
}
