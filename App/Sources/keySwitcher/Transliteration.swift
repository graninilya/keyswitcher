import Foundation

/// Простая транслитерация ru ↔ en по таблице ГОСТ 7.79-2000 (упрощённая).
enum Transliteration {

    private static let ruToLatin: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d",
        "е": "e", "ё": "yo", "ж": "zh", "з": "z", "и": "i",
        "й": "j", "к": "k", "л": "l", "м": "m", "н": "n",
        "о": "o", "п": "p", "р": "r", "с": "s", "т": "t",
        "у": "u", "ф": "f", "х": "kh", "ц": "ts", "ч": "ch",
        "ш": "sh", "щ": "shch", "ъ": "''", "ы": "y", "ь": "'",
        "э": "e", "ю": "yu", "я": "ya"
    ]

    static func apply(_ text: String) -> String {
        // если текст в основном латиница — не трогаем (обратная транслит. неоднозначна)
        let cyrCount = text.unicodeScalars.filter { ("а"..."я").contains(Character($0)) || $0 == "ё" }.count
        guard cyrCount > 0 else { return text }

        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            let lower = Character(ch.lowercased())
            if let mapped = ruToLatin[lower] {
                let isUpper = ch.isUppercase
                if isUpper {
                    out.append(mapped.prefix(1).uppercased())
                    out.append(contentsOf: mapped.dropFirst())
                } else {
                    out.append(mapped)
                }
            } else {
                out.append(ch)
            }
        }
        return out
    }
}
