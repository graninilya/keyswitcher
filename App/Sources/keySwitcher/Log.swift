import Foundation
import os.log

/// `log show --predicate 'subsystem == "com.granin.keyswitcher"' --info --last 5m`
enum Log {
    private static let subsystem = "com.granin.keyswitcher"

    static let buffer    = Logger(subsystem: subsystem, category: "Buffer")
    static let selection = Logger(subsystem: subsystem, category: "Selection")
    static let clipboard = Logger(subsystem: subsystem, category: "Clipboard")
    static let auto      = Logger(subsystem: subsystem, category: "Auto")
    static let hotkey    = Logger(subsystem: subsystem, category: "Hotkey")
    static let detector  = Logger(subsystem: subsystem, category: "Detector")
    static let perf      = Logger(subsystem: subsystem, category: "Perf")

    /// `defaults write com.granin.keyswitcher QKBVerboseLogging -bool YES` — вернуть открытый текст.
    private static let verbose = UserDefaults.standard.bool(forKey: "QKBVerboseLogging")

    /// Текст пользователя не должен лежать в системном журнале открытым.
    /// Форма и длина сохраняются — этого хватает для разбора решений детектора.
    static func redact(_ s: String) -> String {
        if verbose { return s }
        if s.isEmpty { return "<empty>" }
        var cyr = 0, lat = 0, other = 0
        for ch in s {
            if ("а"..."я").contains(ch) || ch == "ё" || ("А"..."Я").contains(ch) || ch == "Ё" {
                cyr += 1
            } else if ("a"..."z").contains(ch) || ("A"..."Z").contains(ch) {
                lat += 1
            } else {
                other += 1
            }
        }
        return "<\(s.count)ch cyr=\(cyr) lat=\(lat) etc=\(other)>"
    }

    static func redact(_ ch: Character?) -> String {
        guard let ch = ch else { return "<nil>" }
        return redact(String(ch))
    }
}
