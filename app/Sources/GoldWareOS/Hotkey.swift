import AppKit

enum TalkMode: String {
    case dictate    // Right Option: paste what you say
    case assistant      // Right Command: hand it to the assistant
}

/// Command + Option pressed together and let go, with nothing else: the Vision Mode shortcut. It fires
/// on release, so Command-Option shortcuts keep working: any key or click while the modifiers are down
/// voids it, as do Shift and Control, and so does holding it longer than a moment. Keys the system keeps
/// for itself (Command-Option-Esc opens Force Quit and never reaches an app) are caught by comparing the
/// system's key and click counters from the first modifier to the release.
struct ModifierChord {
    static let window: TimeInterval = 1.2
    private var inSession = false, void = false
    private var chordAt: TimeInterval?
    private var activityAtStart: UInt32 = 0

    /// A key or click arrived while modifiers were down.
    mutating func interrupt() { if inSession { void = true } }

    /// Feeds the modifier state after a change; true when the chord completes.
    mutating func flags(_ raw: NSEvent.ModifierFlags, at t: TimeInterval, activity: UInt32) -> Bool {
        let m = raw.intersection([.command, .option, .shift, .control])
        if m.isEmpty {
            defer { inSession = false; void = false; chordAt = nil }
            guard inSession, !void, let at = chordAt, activity == activityAtStart else { return false }
            return t - at <= Self.window
        }
        if !inSession { inSession = true; void = false; chordAt = nil; activityAtStart = activity }
        if !m.isDisjoint(with: [.shift, .control]) { void = true }
        if m == [.command, .option], chordAt == nil { chordAt = t }
        return false
    }
}

/// Reports talk-key activity; the app decides what it means (hold to talk,
/// double-tap for hands-free, Escape to cancel). Also reports the Command + Option shortcut.
final class HotkeyMonitor {
    var onPress: (TalkMode) -> Void = { _ in }
    var onRelease: (TalkMode, TimeInterval) -> Void = { _, _ in }
    /// Another key was pressed. `whileHeld` is true when a talk key was down at the
    /// time, which means a shortcut like Option+letter, so the hold is abandoned.
    var onOtherKey: (_ keyCode: UInt16, _ whileHeld: Bool) -> Void = { _, _ in }
    /// Command + Option pressed together and let go.
    var onChord: () -> Void = {}
    /// A real key press or click (not one GoldWare posted): the text box may have changed.
    var onUserInput: () -> Void = {}
    /// Key presses and clicks the system has counted, including ones it kept for itself.
    var activity: () -> UInt32 = {
        [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            .reduce(UInt32(0)) { $0 &+ CGEventSource.counterForEventType(.combinedSessionState, eventType: $1) }
    }

    static let escape: UInt16 = 53
    /// Reported through `onOtherKey` when Command + Option cuts off a talk key (not a real key code).
    static let chordCode: UInt16 = 0xFFFF

    private let keys: [UInt16: (TalkMode, NSEvent.ModifierFlags)] = [
        61: (.dictate, .option),   // Right Option
        54: (.assistant, .command),    // Right Command
    ]
    private var active: TalkMode?
    private var pressedAt = Date()
    private var monitors: [Any] = []
    private var chord = ModifierChord()

    func start() {
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0) }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0); return $0 }) {
            monitors.append(local)
        }
    }

    /// Monitors installed before Accessibility was granted never fire, so reinstall them.
    func restart() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        active = nil
        start()
    }

    func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            chord.interrupt()   // Command-Option-click and -drag belong to Finder and the Dock
            onUserInput()
            return
        case .keyDown:
            chord.interrupt()
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Paster.marker { onUserInput() }
            let held = active != nil
            active = nil
            onOtherKey(event.keyCode, held)
            return
        default:
            break
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if chord.flags(flags, at: event.timestamp, activity: activity()) { onChord() }
        // Command and Option together are the Vision shortcut, not talking: drop a talk key in progress,
        // and do not start one while both are down.
        let chordHeld = flags.contains([.command, .option])
        if chordHeld, active != nil {
            active = nil
            onOtherKey(Self.chordCode, true)
        }
        guard let (mode, flag) = keys[event.keyCode] else {
            // Shift or Control joining a held talk key means a shortcut, not talking.
            if active != nil, !flags.intersection([.shift, .control]).isEmpty {
                active = nil
                onOtherKey(event.keyCode, true)
            }
            return
        }
        let pressed = flags.contains(flag)
        if pressed && active == nil && !chordHeld {
            active = mode
            pressedAt = Date()
            onPress(mode)
        } else if !pressed && active == mode {
            active = nil
            onRelease(mode, Date().timeIntervalSince(pressedAt))
        }
    }
}
