import ApplicationServices
import AVFoundation
import EventKit
import Foundation
import Speech

/// The dashboard's first-run tour shows which permissions are on and ticks a step off the first time it
/// really happens ("say Let's work"). Both go into status.json in the app data folder, which the local
/// server reads for /api/onboarding. Nothing here asks for a permission; it only reads the current state.
enum Tour {
    static let key = "tourMilestones"
    /// The steps the tour can check. Anything else passed to `mark` is ignored.
    static let ids = ["dictated", "assistant", "wake", "vision-on", "vision-unlocked", "quadrants",
                      "scan-filed", "lets-work", "lock-up", "clear-out"]
    static var defaults: UserDefaults = .standard
    /// Called on the main queue after a first-time step, so status.json is rewritten at once.
    static var onChange: (() -> Void)?

    static var milestones: [String: String] { defaults.dictionary(forKey: key) as? [String: String] ?? [:] }

    /// Records the first time a step happens; later calls keep that first time.
    static func mark(_ id: String, now: Date = Date()) {
        guard ids.contains(id) else { return }
        var m = milestones
        guard m[id] == nil else { return }
        m[id] = ISO8601DateFormatter().string(from: now)
        defaults.set(m, forKey: key)
        DispatchQueue.main.async { onChange?() }
    }

    static func label(_ s: AVAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        default: return "not asked yet"
        }
    }

    static var camera: String { label(AVCaptureDevice.authorizationStatus(for: .video)) }

    static var speech: String {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        default: return "not asked yet"
        }
    }

    static var calendar: String {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return "granted"
        case .notDetermined: return "not asked yet"
        case .denied: return "denied"
        case .restricted: return "restricted"
        default: return "limited"
        }
    }

    /// Automation of iTerm (Let's work, Lock up, Clear out, the Office). Never prompts. macOS can only
    /// answer while iTerm is open.
    static func automation(bundle: String = "com.googlecode.iterm2") -> String {
        var addr = AEAddressDesc()
        let bytes = Array(bundle.utf8)
        let made = bytes.withUnsafeBufferPointer {
            AECreateDesc(DescType(typeApplicationBundleID), $0.baseAddress, $0.count, &addr)
        }
        guard made == noErr else { return "unknown" }
        defer { AEDisposeDesc(&addr) }
        let r = AEDeterminePermissionToAutomateTarget(&addr, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
        switch Int(r) {
        case Int(noErr): return "granted"
        case errAEEventNotPermitted: return "denied"
        case errAEEventWouldRequireUserConsent: return "not asked yet"
        case procNotFound: return "iterm closed"
        default: return "unknown"
        }
    }
}
