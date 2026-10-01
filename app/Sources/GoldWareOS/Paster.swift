import AppKit

/// Puts text into whatever field has focus by pasting, then restores the clipboard.
enum Paster {
    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }

        pb.clearContents()
        pb.setString(text, forType: .string)

        post(keystroke(9, .maskCommand))

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard pb.string(forType: .string) == text else { return }
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
    }

    /// Return in the app in front, to send what was pasted.
    static func pressReturn() {
        post(keystroke(36, []))
    }

    /// Cmd+Z in the app in front, to take back a paste.
    static func sendUndo() {
        post(keystroke(6, .maskCommand))
    }

    /// Backspace `count` times in the app in front, to clear what was just pasted.
    /// Paced a little (off the main thread) so a long paste is not dropped by a busy app.
    static func deleteBack(_ count: Int) {
        DispatchQueue.global(qos: .userInitiated).async {
            for _ in 0..<max(0, count) { post(keystroke(51, [])); usleep(2_000) }
        }
    }

    /// Stamped on every key GoldWare posts, so the key monitor can tell them from real typing.
    static let marker: Int64 = 0x414C4E

    /// One key press with exactly `flags` held, then released with nothing held.
    /// A private source and explicit flags, because a Command-flagged key-up left Command stuck in the
    /// session's modifier state, and the next Return inherited it and went out as Cmd+Return (which makes
    /// iTerm go full screen instead of sending). The clean key-up clears that state again.
    static func keystroke(_ key: CGKeyCode, _ flags: CGEventFlags) -> [CGEvent] {
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return [] }
        down.flags = flags
        up.flags = []
        for e in [down, up] { e.setIntegerValueField(.eventSourceUserData, value: marker) }
        return [down, up]
    }

    private static func post(_ events: [CGEvent]) {
        events.forEach { $0.post(tap: .cghidEventTap) }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
