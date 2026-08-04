import Foundation

/// Типографика без сети и без модели.
///
/// Правила намеренно узкие. Текст, который правит человек, часто перемешан с кодом,
/// путями и ссылками, а «умная» типографика в них превращает `file.txt` в `file. txt`
/// и `{"a": 1}` в `{«a»: 1}`. Поэтому: сначала проверяем, что перед нами проза,
/// а каждое правило требует буквенного окружения.
enum Typography {

    struct Options {
        var dashes = true
        var quotes = true
        var spacing = true
        var ellipsis = true
        var nbsp = true

        static let all = Options()
    }

    /// Предлоги и союзы, после которых перенос строки выглядит неряшливо.
    private static let shortWords: Set<String> = [
        "а", "в", "и", "к", "о", "с", "у", "я", "б", "ж",
        "на", "не", "но", "за", "из", "по", "до", "от", "об", "во",
        "то", "же", "ли", "бы", "их", "он", "мы", "вы", "ты",
        "для", "или", "как", "что", "это", "при", "над", "под", "без",
    ]

    /// Сокращения, внутри которых точка не заканчивает предложение.
    private static let abbreviations: Set<String> = [
        "т", "д", "п", "к", "г", "гг", "в", "вв", "см", "стр", "рис", "табл",
        "им", "проф", "акад", "руб", "коп", "тыс", "млн", "млрд",
    ]

    /// Признаки того, что это не проза: трогать нельзя.
    static func looksLikeCode(_ text: String) -> Bool {
        if text.contains("://") || text.contains("@") { return true }
        if text.contains("{") || text.contains("}") { return true }
        if text.contains("</") || text.contains("/>") { return true }
        if text.contains(";") && text.contains("(") { return true }
        if text.contains("::") || text.contains("!=") || text.contains("==") { return true }
        if text.contains("=>") || text.contains("->") { return true }
        if text.contains("()") { return true }
        // Вызов метода или обращение к полю: `obj.method(`, `foo.bar.baz`.
        if text.range(of: #"\w\.\w+\("#, options: .regularExpression) != nil { return true }

        // Путь или имя файла: `слово/слово`, `имя.расширение`.
        if text.range(of: #"[\w~.-]+/[\w.-]+"#, options: .regularExpression) != nil { return true }
        if text.range(of: #"\b\w+\.(txt|md|json|swift|js|ts|py|sh|yml|yaml|png|jpg|pdf|csv|html|css|xml|log)\b"#,
                      options: [.regularExpression, .caseInsensitive]) != nil { return true }

        // Ключ командной строки: `-r`, `--force`.
        if text.range(of: #"(^|\s)--?[a-zA-Z]"#, options: .regularExpression) != nil { return true }

        return false
    }

    /// Правила рассчитаны на русский набор. В тексте без кириллицы пробел перед
    /// знаком и кавычки-лапки чаще всего осмысленны — это код, англоязычная фраза
    /// или тернарный оператор, и вмешиваться туда не наше дело.
    private static func hasCyrillic(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0410...0x044F).contains($0.value) || $0.value == 0x0401 || $0.value == 0x0451 }
    }

    static func apply(_ text: String, options: Options = .all) -> String {
        guard !text.isEmpty else { return text }
        guard !looksLikeCode(text) else { return text }
        guard hasCyrillic(text) else { return text }

        var s = text

        // Схлопывание пробелов идёт первым: иначе `текст  .` требует двух проходов,
        // и результат зависел бы от того, сколько раз нажали хоткей.
        if options.spacing { s = collapseSpaces(s) }
        if options.ellipsis { s = fixEllipsis(s) }
        if options.quotes   { s = fixQuotes(s) }
        if options.dashes   { s = fixDashes(s) }
        if options.spacing  { s = fixPunctuationSpacing(s) }
        if options.nbsp     { s = fixNonBreakingSpaces(s) }

        return s
    }

    // MARK: - Правила

    private static func collapseSpaces(_ s: String) -> String {
        var out = s
        while out.contains("  ") {
            out = out.replacingOccurrences(of: "  ", with: " ")
        }
        return out
    }

    private static func fixEllipsis(_ s: String) -> String {
        guard s.contains("...") else { return s }
        // Ровно три точки: `....` — это уже не многоточие, а опечатка или разделитель.
        return s.replacingOccurrences(
            of: #"(?<!\.)\.{3}(?!\.)"#, with: "…", options: .regularExpression
        )
    }

    /// Кавычки заменяем только в тексте без признаков кода (проверено выше) и только
    /// когда рядом с ними буквы — строковые литералы сюда не попадают.
    private static func fixQuotes(_ s: String) -> String {
        guard s.contains("\"") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var open = true
        var previous: Character? = nil

        for ch in s {
            guard ch == "\"" else {
                out.append(ch)
                previous = ch
                continue
            }
            // Открывающая — в начале, после пробела или открывающей скобки.
            let opensHere: Bool
            if let p = previous {
                opensHere = p.isWhitespace || p == "(" || p == "«" || p == "\u{00A0}"
            } else {
                opensHere = true
            }
            // Чередование как страховка: `"a"b"c"` не должно давать три закрывающих.
            let useOpening = opensHere || (!opensHere && open && previous == nil)
            out.append(useOpening ? "«" : "»")
            open = !useOpening
            previous = ch
        }
        return out
    }

    /// Дефис становится тире только между СЛОВАМИ. Числа не трогаем: `5 - 3` это
    /// вычитание, а `2020 - 2024` диапазон, и в обоих случаях тире меняет смысл.
    private static func fixDashes(_ s: String) -> String {
        var out = s.replacingOccurrences(
            of: #"(?<=\p{L}) +[-–] +(?=\p{L})"#, with: " — ", options: .regularExpression
        )
        // Тире в начале строки — прямая речь или пункт списка.
        out = out.replacingOccurrences(
            of: #"(?m)^[-–] (?=\p{L})"#, with: "— ", options: .regularExpression
        )
        return out
    }

    private static func fixPunctuationSpacing(_ s: String) -> String {
        var out = s

        // Пробел ПЕРЕД знаком не нужен — но только если знак завершает слово.
        out = out.replacingOccurrences(
            of: #"(?<=\p{L}) +([,.!?;:…])"#, with: "$1", options: .regularExpression
        )

        // Пробел ПОСЛЕ знака нужен, если по обе стороны буквы: `привет,как` → `привет, как`.
        // Числа, сокращения и инициалы под это не подпадают.
        out = out.replacingOccurrences(
            of: #"(?<=\p{L})([,;!?])(?=\p{L})"#, with: "$1 ", options: .regularExpression
        )
        out = insertSpaceAfterPeriod(out)

        // Скобки и кавычки не должны отлипать внутрь.
        out = out.replacingOccurrences(of: "( ", with: "(")
        out = out.replacingOccurrences(of: " )", with: ")")
        out = out.replacingOccurrences(of: "« ", with: "«")
        out = out.replacingOccurrences(of: " »", with: "»")

        return out
    }

    /// Точка отдельно: за ней прячутся сокращения (`т.д.`) и инициалы (`А.С.`),
    /// где пробел ставить нельзя.
    private static func insertSpaceAfterPeriod(_ s: String) -> String {
        let chars = Array(s)
        var out = ""
        out.reserveCapacity(chars.count)

        for (i, ch) in chars.enumerated() {
            out.append(ch)
            guard ch == "." else { continue }
            guard i + 1 < chars.count else { continue }
            let next = chars[i + 1]
            guard next.isLetter else { continue }

            // Слово перед точкой.
            var start = i
            while start > 0, chars[start - 1].isLetter { start -= 1 }
            let word = String(chars[start..<i]).lowercased()
            if abbreviations.contains(word) { continue }
            // Инициал: одна заглавная буква.
            if i - start == 1, chars[start].isUppercase { continue }
            // Следующее слово с маленькой буквы — вероятнее сокращение, чем предложение.
            if next.isLowercase && word.count <= 2 { continue }

            out.append(" ")
        }
        return out
    }

    /// Неразрывный пробел после коротких слов, чтобы они не висели в конце строки.
    private static func fixNonBreakingSpaces(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var word = ""

        func flush(_ separator: Character?) {
            // Только слова целиком строчными: в аббревиатуре «И В ЛЕСУ» это не предлоги.
            let isShort = !word.isEmpty
                && word == word.lowercased()
                && shortWords.contains(word)
            out += word
            if let sep = separator {
                out.append(isShort && sep == " " ? "\u{00A0}" : sep)
            }
            word = ""
        }

        for ch in s {
            if ch == " " || ch == "\n" || ch == "\t" {
                flush(ch)
            } else {
                word.append(ch)
            }
        }
        flush(nil)
        return out
    }
}
