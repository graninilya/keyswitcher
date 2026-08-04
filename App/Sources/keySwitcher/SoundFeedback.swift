import AppKit

enum SoundFeedback {

    static let allSounds: [String] = [
        "Tink", "Pop", "Bottle", "Glass", "Hero",
        "Submarine", "Ping", "Funk", "Sosumi", "Blow",
        "Morse", "Frog", "Purr", "Basso",
    ]

    static let defaultVolume: Float = 0.45

    /// NSSound конструировался на каждую замену — это загрузка файла на горячем пути.
    private static var cache: [String: NSSound] = [:]
    private static let cacheLock = NSLock()

    private static func sound(named name: String) -> NSSound? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let s = cache[name] { return s }
        guard let s = NSSound(named: name) else { return nil }
        s.volume = defaultVolume
        cache[name] = s
        return s
    }

    static func preload() {
        let name = Settings.shared.soundName
        guard !name.isEmpty else { return }
        _ = sound(named: name)
    }

    static func invalidateCache() {
        cacheLock.lock(); cache.removeAll(); cacheLock.unlock()
    }

    static func play() {
        let name = Settings.shared.soundName
        guard !name.isEmpty else { return }
        guard let s = sound(named: name) else { return }
        // Переиспользуемый NSSound нужно перемотать, иначе быстрый повтор молчит.
        if s.isPlaying { s.stop() }
        s.currentTime = 0
        s.play()
    }

    static func preview() {
        play()
    }
}
