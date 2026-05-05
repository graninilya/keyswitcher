import Carbon
import Foundation

enum InputLanguage: String {
    case russian = "ru"
    case english = "en"
}

enum InputSourceSwitcher {

    static func current() -> TISInputSource? {
        TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    }

    static func switchTo(_ lang: InputLanguage) {
        guard let source = findSource(forLanguage: lang.rawValue) else {
            Log.auto.info("switchTo(\(lang.rawValue, privacy: .public)): no matching source found")
            return
        }
        let status = TISSelectInputSource(source)
        Log.auto.info("switchTo(\(lang.rawValue, privacy: .public)): TISSelectInputSource → \(status)")
    }

    static func restore(_ source: TISInputSource) {
        let status = TISSelectInputSource(source)
        Log.auto.info("restore: TISSelectInputSource → \(status)")
    }

    private static func findSource(forLanguage code: String) -> TISInputSource? {
        // includeAllInstalled=false — только раскладки, которые юзер сам активировал
        guard let cfList = TISCreateInputSourceList(nil, false)?.takeRetainedValue(),
              let sources = cfList as? [TISInputSource] else {
            return nil
        }
        for source in sources {
            guard isKeyboardSource(source) else { continue }
            if primaryLanguage(of: source) == code {
                return source
            }
        }
        return nil
    }

    private static func isKeyboardSource(_ source: TISInputSource) -> Bool {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceCategory) else {
            return false
        }
        let value = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        return value == (kTISCategoryKeyboardInputSource as String)
    }

    private static func primaryLanguage(of source: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else {
            return nil
        }
        let langs = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String] ?? []
        return langs.first
    }
}


extension String {
    /// nil если текст без букв или смешанный.
    var inputLanguageForLayout: InputLanguage? {
        var cyr = 0
        var lat = 0
        for scalar in unicodeScalars {
            let ch = Character(scalar)
            if ch.isLetter {
                if ("а"..."я").contains(ch) || ch == "ё" ||
                   ("А"..."Я").contains(ch) || ch == "Ё" {
                    cyr += 1
                } else if ("a"..."z").contains(ch) || ("A"..."Z").contains(ch) {
                    lat += 1
                }
            }
        }
        if cyr > lat, cyr > 0 { return .russian }
        if lat > cyr, lat > 0 { return .english }
        return nil
    }
}
