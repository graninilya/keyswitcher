import AppKit

enum SoundFeedback {

    static let allSounds: [String] = [
        "Tink", "Pop", "Bottle", "Glass", "Hero",
        "Submarine", "Ping", "Funk", "Sosumi", "Blow",
        "Morse", "Frog", "Purr", "Basso",
    ]

    static let defaultVolume: Float = 0.45

    static func play() {
        let name = Settings.shared.soundName
        guard !name.isEmpty else { return }
        guard let s = NSSound(named: name) else { return }
        s.volume = defaultVolume
        s.play()
    }

    static func preview() {
        play()
    }
}
