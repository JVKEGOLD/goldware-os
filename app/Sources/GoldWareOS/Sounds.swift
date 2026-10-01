import AppKit

/// Soft cues so you know it is listening without looking. System sounds, kept quiet.
enum Sounds {
    enum Cue { case start, assistantStart, stop, done, error }

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "soundsEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "soundsEnabled") }
    }

    static func play(_ cue: Cue) {
        guard enabled else { return }
        let (name, volume): (String, Float) = {
            switch cue {
            case .start: return ("Tink", 0.28)
            case .assistantStart: return ("Bottle", 0.3)
            case .stop: return ("Pop", 0.22)
            case .done: return ("Glass", 0.18)
            case .error: return ("Funk", 0.22)
            }
        }()
        guard let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }
}
