import Foundation

/// Загруженная мапа физических клавиш ЙЦУКЕН ↔ QWERTY
/// плюс словари для определения «эта строка набрана не на той раскладке».
final class LayoutMap {
    static let shared = LayoutMap()

    private let enToRu: [Character: Character]
    private let ruToEn: [Character: Character]
    private var wordsRu: Set<String>
    private var wordsEn: Set<String>
    /// Все «плохие» подстроки латиницы (значит набирали кириллицу)
    private let badLatin: Set<String>
    /// Все «плохие» подстроки кириллицы (значит набирали латиницу)
    private let badCyrillic: Set<String>
    /// Длины триггеров — для эффективного substring matching
    private let badLatinLengths: [Int]
    private let badCyrillicLengths: [Int]

    private init() {
        // Сначала пробуем динамически прочитать актуальные раскладки пользователя
        // через UCKeyTranslate. Это покрывает любые варианты RU layout (Russian, Russian-PC,
        // Russian-Phonetic), а также любые EN layout (US, US-International, ABC и т.п.).
        // Если по какой-то причине не получилось — fallback на захардкоженный JSON.
        // Стандартная Apple-раскладка из JSON — fallback и оверрайд для битых маппингов
        let standardLayout: LayoutFile = LayoutMap.load("layout_map")
        let standardEnToRu = LayoutMap.charMap(standardLayout.en_to_ru)
        let standardRuToEn = LayoutMap.charMap(standardLayout.ru_to_en)

        if let dynamic = LayoutResolver.resolve() {
            Log.detector.info("Layout: dynamic (en2ru=\(dynamic.enToRu.count) ru2en=\(dynamic.ruToEn.count)), merging with standard")
            self.enToRu = LayoutMap.mergeMap(primary: dynamic.enToRu, fallback: standardEnToRu)
            self.ruToEn = LayoutMap.mergeMap(primary: dynamic.ruToEn, fallback: standardRuToEn)
        } else {
            Log.detector.info("Layout: dynamic resolve failed, using standard JSON")
            self.enToRu = standardEnToRu
            self.ruToEn = standardRuToEn
        }

        // Дамп ключевой пунктуации для дебага
        for k: Character in [".", ",", ";", "[", "]", "'", "`", "\\", "/"] {
            let mapped = self.enToRu[k].map(String.init) ?? "<no>"
            Log.detector.info("  EN '\(String(k), privacy: .public)' → RU '\(mapped, privacy: .public)'")
        }

        let ruWords: [String] = LayoutMap.load("words_ru")
        let enWords: [String] = LayoutMap.load("words_en")
        self.wordsRu = Set(ruWords)
        self.wordsEn = Set(enWords)

        let triggers: TriggersFile = LayoutMap.load("bad_ngrams")
        self.badLatin = Set(triggers.latin)
        self.badCyrillic = Set(triggers.cyrillic)
        self.badLatinLengths = Array(Set(triggers.latin.map { $0.count })).sorted()
        self.badCyrillicLengths = Array(Set(triggers.cyrillic.map { $0.count })).sorted()

        // Дополнительный whitelist: разговорные слова, заимствования, частые сокращения,
        // которых нет в hunspell base forms.
        let extraRu: Set<String> = [
            "ок", "окей", "норм", "лол", "оке", "пофиг", "плс",
            "спс", "пжл", "хм", "угу", "ага", "ню", "блин",
            "вау", "опа", "упс", "хех", "хах", "ыы",
        ]
        let extraEn: Set<String> = [
            "ok", "okay", "lol", "lmao", "omg", "wtf", "tbh", "imo", "imho",
            "btw", "fyi", "nvm", "thx", "pls", "yo", "huh", "uh", "yep", "nope",
        ]
        self.wordsRu.formUnion(extraRu)
        self.wordsEn.formUnion(extraEn)
    }

    // MARK: Public

    /// Преобразовать строку как если бы набрали на другой раскладке.
    ///
    /// - Чистая кириллица «привет» → «ghbdtn»
    /// - Чистая латиница «ghbdtn» → «привет»
    /// - Смешанная «тfr» (с любой кириллицей) → «так» (нормализация к кириллице)
    /// - «;му» (`;` на EN = `ж` на RU) → «жму»
    /// - «;ve» (всё промахнулось) → «жму»
    func swap(_ s: String) -> String {
        let cyrLetters = s.filter(isCyrillicLetter).count
        let latLetters = s.filter(isLatinLetter).count
        let hasEnLayoutPunct = s.contains { ch in
            guard !isLatinLetter(ch), !isCyrillicLetter(ch) else { return false }
            guard let mapped = enToRu[ch] else { return false }
            return isCyrillicLetter(mapped)
        }

        // Если есть кириллические буквы И что-то «латинское» (буквы или EN-пунктуация-к-RU-букве)
        // → нормализуем к кириллице. Кириллица «выигрывает» при любом количестве.
        if cyrLetters > 0 && (latLetters > 0 || hasEnLayoutPunct) {
            return String(s.map { enToRu[$0] ?? $0 })
        }

        // Только кириллические буквы → полный свап в латиницу
        if cyrLetters > 0 {
            return String(s.map { ruToEn[$0] ?? $0 })
        }

        // Только латинские буквы или EN-пунктуация-к-RU-букве → свап в кириллицу
        return String(s.map { enToRu[$0] ?? ruToEn[$0] ?? $0 })
    }

    private func isLatinLetter(_ c: Character) -> Bool {
        return ("a"..."z").contains(c) || ("A"..."Z").contains(c)
    }

    private func isCyrillicLetter(_ c: Character) -> Bool {
        return ("а"..."я").contains(c) || c == "ё" || ("А"..."Я").contains(c) || c == "Ё"
    }

    /// Решает, стоит ли переключить раскладку этой строки.
    /// Возвращает результат и направление, если уверенность достаточная.
    func detectAndConvert(_ text: String) -> ConversionResult {
        let candidate = swap(text)
        let originalScore = score(text)
        let candidateScore = score(candidate)

        // Конвертим только если новый вариант явно лучше.
        if candidateScore > originalScore + 0.15 {
            return .converted(candidate)
        }
        return .unchanged
    }

    enum ConversionResult {
        case converted(String)
        case unchanged
    }

    /// Детектор для авто-режима. Возвращает swap если уверен, что слово набрано не в той раскладке.
    ///
    /// Логика (в порядке приоритета):
    ///   1. Слово смешанное по алфавитам или слишком короткое → не трогаем
    ///   2. Слово целиком — валидное в текущем языке → не трогаем
    ///   3. Слово целиком есть в плохих триггерах текущего языка → SWAP
    ///   4. Свап — валидное слово в другом языке → SWAP
    ///   5. В слове есть подстрока из плохих триггеров (длина 3+) → SWAP
    ///   6. Иначе → не трогаем
    func autoConvert(_ word: String) -> String? {
        let lower = word.lowercased()

        // Одиночная буква-предлог: конвертим только если контекст совпадает с свапом.
        // Например, если ты пишешь в основном на русском (ctx=.russian) и ввёл `f`,
        // он свапается в `а`. Без контекста — не трогаем (могут быть и `a`, `i` английские).
        if lower.count == 1 {
            let singleRu: Set<String> = ["а","и","в","к","с","о","у","я"]
            let singleEn: Set<String> = ["a","i"]
            // Уже валидный предлог в каком-то языке → не трогаем
            if singleRu.contains(lower) || singleEn.contains(lower) { return nil }
            let swapped = swap(word)
            let swappedLow = swapped.lowercased()
            let context = KeystrokeBuffer.shared.dominantContext
            if singleRu.contains(swappedLow), context == .russian {
                return swapped
            }
            if singleEn.contains(swappedLow), context == .english {
                return swapped
            }
            return nil
        }

        guard lower.count >= 2 else { return nil }

        let isLatin = lower.allSatisfy { ("a"..."z").contains($0) }
        let isCyrillic = lower.allSatisfy { ("а"..."я").contains($0) || $0 == "ё" }

        if !isLatin && !isCyrillic {
            // Извлекаем чисто буквенные части по алфавитам
            let lettersLat = String(lower.filter { ("a"..."z").contains($0) })
            let lettersCyr = String(lower.filter { ("а"..."я").contains($0) || $0 == "ё" })
            let hasLat = !lettersLat.isEmpty
            let hasCyr = !lettersCyr.isEmpty
            let hasEnLayoutPunct = lower.contains { ";[]'`\\,.".contains($0) }
            let isCandidate = (hasLat && hasCyr)
                           || (hasEnLayoutPunct && (hasLat || hasCyr))
            guard isCandidate else { return nil }

            // Если layout-пунктуация только в КОНЦЕ слова (типа `Hello,`) — это, скорее
            // всего, настоящая пунктуация. И если буквенная часть валидна в исходном
            // языке — оставляем как есть.
            // Если же layout-пунктуация в НАЧАЛЕ (`.,rf`, `'kkf`) — это явный layout-промах,
            // продолжаем к нормализации даже если буквенная часть в словаре.
            let layoutPunct: Set<Character> = [";", "[", "]", "'", "`", "\\", ",", "."]
            let firstIsLayoutPunct = lower.first.map { layoutPunct.contains($0) } ?? false
            if !firstIsLayoutPunct {
                if !hasCyr && hasLat && wordsEn.contains(lettersLat) { return nil }
                if !hasLat && hasCyr && wordsRu.contains(lettersCyr) { return nil }
            }

            let normalized = swap(word)
            guard normalized.lowercased() != lower else { return nil }
            let normLow = normalized.lowercased()
            let normIsLat = normLow.allSatisfy { ("a"..."z").contains($0) }
            let normIsCyr = normLow.allSatisfy { ("а"..."я").contains($0) || $0 == "ё" }
            // Конвертим если нормализация дала чистый алфавит
            if normIsLat || normIsCyr {
                return normalized
            }
            return nil
        }

        // (2) Валидное слово в текущем языке — никогда не трогаем
        if isLatin && wordsEn.contains(lower) { return nil }
        if isCyrillic && wordsRu.contains(lower) { return nil }

        let candidate = swap(word)
        let candidateLower = candidate.lowercased()

        let triggers = isLatin ? badLatin : badCyrillic

        // (3) Точное совпадение со списком плохих триггеров
        if triggers.contains(lower) { return candidate }

        // (4) Свап — валидное слово
        if isLatin && wordsRu.contains(candidateLower) { return candidate }
        if isCyrillic && wordsEn.contains(candidateLower) { return candidate }

        // (5) Взвешенный скор по плохим подстрокам.
        let oppositeTriggers = isLatin ? badCyrillic : badLatin
        let wordScore = weightedBadScore(in: lower, triggers: triggers)
        let swapScore = weightedBadScore(in: candidateLower, triggers: oppositeTriggers)
        if wordScore >= 2 && Double(wordScore) >= Double(swapScore) * 1.8 {
            return candidate
        }

        // (6) Контекст-aware: если слово неоднозначное (есть мусор в подстроках),
        //     но контекст явно противоречит языку слова — конвертим.
        //     Пример: ты пишешь в RU и ввёл `rf` — без контекста бы не тронули
        //     (т.к. `rf` есть в EN dict), но в RU контексте это явно «к-а» промах.
        let context = KeystrokeBuffer.shared.dominantContext
        if wordScore >= 1 {
            if isLatin && context == .russian { return candidate }
            if isCyrillic && context == .english { return candidate }
        }

        return nil
    }

    /// Считает «уверенность что слово в неправильной раскладке»: сумма взвешенных
    /// плохих подстрок. Длинные подстроки весят больше — они более дискриминативны.
    private func weightedBadScore(in word: String, triggers: Set<String>) -> Int {
        let chars = Array(word)
        var score = 0
        for L in 3...6 where L <= chars.count {
            let weight = L - 2  // 3→1, 4→2, 5→3, 6→4
            let limit = chars.count - L
            for start in 0...limit {
                let sub = String(chars[start..<(start + L)])
                if triggers.contains(sub) {
                    score += weight
                }
            }
        }
        return score
    }

    // MARK: Scoring

    /// Доля «валидных» слов в строке (слова присутствуют в словаре RU или EN).
    /// Простая, но для MVP достаточно мощная эвристика.
    private func score(_ text: String) -> Double {
        let tokens = text
            .lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { $0.count >= 2 }

        guard !tokens.isEmpty else { return 0 }

        var hits = 0
        for w in tokens {
            if wordsRu.contains(w) || wordsEn.contains(w) {
                hits += 1
            }
        }
        return Double(hits) / Double(tokens.count)
    }

    // MARK: Loading

    private struct LayoutFile: Decodable {
        let en_to_ru: [String: String]
        let ru_to_en: [String: String]
    }

    private struct TriggersFile: Decodable {
        let latin: [String]
        let cyrillic: [String]
    }

    /// Сливает две мапы: предпочитает primary, но если primary мапит пунктуацию на пунктуацию
    /// (а не на букву) — берёт fallback (где есть буква). Это спасает от кастомных
    /// Ukelele-раскладок где `.` → `,` вместо `.` → `ю`.
    private static func mergeMap(primary: [Character: Character],
                                  fallback: [Character: Character]) -> [Character: Character] {
        func isLetter(_ c: Character) -> Bool { c.isLetter }
        var out = fallback
        for (k, v) in primary {
            if let f = fallback[k] {
                if isLetter(v) || !isLetter(f) {
                    out[k] = v
                }
                // else: primary даёт не-букву, а fallback букву — сохраняем fallback
            } else {
                out[k] = v
            }
        }
        return out
    }

    private static func charMap(_ src: [String: String]) -> [Character: Character] {
        var out: [Character: Character] = [:]
        for (k, v) in src where k.count == 1 && v.count == 1 {
            out[k.first!] = v.first!
        }
        return out
    }

    private static func load<T: Decodable>(_ name: String) -> T {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json") else {
            fatalError("Resource \(name).json not found in Bundle.main")
        }
        let data = try! Data(contentsOf: url)
        return try! JSONDecoder().decode(T.self, from: data)
    }
}
