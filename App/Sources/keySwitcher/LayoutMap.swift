import Foundation

final class LayoutMap {
    static let shared = LayoutMap()

    private let enToRu: [Character: Character]
    private let ruToEn: [Character: Character]
    private var wordsRu: Set<String>
    private var wordsEn: Set<String>
    private let badLatin: Set<String>
    private let badCyrillic: Set<String>
    private let badLatinLengths: [Int]
    private let badCyrillicLengths: [Int]
    private let trigramsRu: [String: Double]
    private let trigramsEn: [String: Double]
    /// Среднее лог-вероятностей триграмм. Пропуски штрафуются `missingTrigramPenalty`.
    /// Слова из реального языка обычно даёт −5…−15. Случайный мусор ≤ −20.
    private let plausibilityThreshold: Double = -20.0
    private let missingTrigramPenalty: Double = -25.0

    private init() {
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

        self.trigramsRu = LayoutMap.load("trigrams_ru")
        self.trigramsEn = LayoutMap.load("trigrams_en")

        // Разговорные слова и заимствования, которых нет в hunspell base forms
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

    /// Преобразует строку как если бы её набрали на другой раскладке.
    /// При смешанной строке кириллица побеждает (нормализуем к ней).
    func swap(_ s: String) -> String {
        let cyrLetters = s.filter(isCyrillicLetter).count
        let latLetters = s.filter(isLatinLetter).count
        let hasEnLayoutPunct = s.contains { ch in
            guard !isLatinLetter(ch), !isCyrillicLetter(ch) else { return false }
            guard let mapped = enToRu[ch] else { return false }
            return isCyrillicLetter(mapped)
        }

        if cyrLetters > 0 && (latLetters > 0 || hasEnLayoutPunct) {
            return String(s.map { enToRu[$0] ?? $0 })
        }

        if cyrLetters > 0 {
            return String(s.map { ruToEn[$0] ?? $0 })
        }

        return String(s.map { enToRu[$0] ?? ruToEn[$0] ?? $0 })
    }

    private func isLatinLetter(_ c: Character) -> Bool {
        return ("a"..."z").contains(c) || ("A"..."Z").contains(c)
    }

    private func isCyrillicLetter(_ c: Character) -> Bool {
        return ("а"..."я").contains(c) || c == "ё" || ("А"..."Я").contains(c) || c == "Ё"
    }

    func detectAndConvert(_ text: String) -> ConversionResult {
        let candidate = swap(text)
        let originalScore = score(text)
        let candidateScore = score(candidate)

        if candidateScore > originalScore + 0.15 {
            return .converted(candidate)
        }
        return .unchanged
    }

    enum ConversionResult {
        case converted(String)
        case unchanged
    }

    func autoConvert(_ word: String) -> String? {
        let lower = word.lowercased()

        // Одиночная буква-предлог: конвертим только при совпадении свапа с контекстом —
        // иначе одиночные `a` / `i` всегда бы конвертились в русские `ф` / `ш`
        if lower.count == 1 {
            let singleRu: Set<String> = ["а","и","в","к","с","о","у","я"]
            let singleEn: Set<String> = ["a","i"]
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
            let lettersLat = String(lower.filter { ("a"..."z").contains($0) })
            let lettersCyr = String(lower.filter { ("а"..."я").contains($0) || $0 == "ё" })
            let hasLat = !lettersLat.isEmpty
            let hasCyr = !lettersCyr.isEmpty
            let hasEnLayoutPunct = lower.contains { ";[]'`\\,.".contains($0) }
            let isCandidate = (hasLat && hasCyr)
                           || (hasEnLayoutPunct && (hasLat || hasCyr))
            guard isCandidate else { return nil }

            // Layout-пунктуация в конце (`Hello,`, `работает.`) = настоящая пунктуация.
            // В начале (`.,rf`, `'kkf`) = промах раскладкой → нормализуем.
            let layoutPunct: Set<Character> = [";", "[", "]", "'", "`", "\\", ",", "."]
            let firstIsLayoutPunct = lower.first.map { layoutPunct.contains($0) } ?? false
            if !firstIsLayoutPunct {
                // Ядро (без хвостовой layout-пунктуации) полностью одной алфавитной системы → НЕ трогаем.
                // Не зависит от словаря: словоформы (работает, букву) не лежат в hunspell base forms.
                let trailingPunctCount = lower.reversed().prefix { layoutPunct.contains($0) }.count
                if trailingPunctCount > 0 {
                    let core = String(lower.dropLast(trailingPunctCount))
                    if !core.isEmpty {
                        let coreAllCyr = core.allSatisfy { ("а"..."я").contains($0) || $0 == "ё" }
                        let coreAllLat = core.allSatisfy { ("a"..."z").contains($0) }
                        if coreAllCyr || coreAllLat { return nil }
                    }
                }
                if !hasCyr && hasLat && wordsEn.contains(lettersLat) { return nil }
                if !hasLat && hasCyr && wordsRu.contains(lettersCyr) { return nil }
            }

            let normalized = swap(word)
            guard normalized.lowercased() != lower else { return nil }
            let normLow = normalized.lowercased()
            let normIsLat = normLow.allSatisfy { ("a"..."z").contains($0) }
            let normIsCyr = normLow.allSatisfy { ("а"..."я").contains($0) || $0 == "ё" }
            if normIsLat || normIsCyr {
                return normalized
            }
            return nil
        }

        if isLatin && wordsEn.contains(lower) { return nil }
        if isCyrillic && wordsRu.contains(lower) { return nil }

        let candidate = swap(word)
        let candidateLower = candidate.lowercased()

        // Сравнительный триграммный фильтр: «куда лучше укладывается слово».
        // - буквы (ru=-13) vs ,erds (en=-15.5)         → ru лучше → keep
        // - руддщ (ru=-15.9) vs hello (en=-7.7)        → swap намного лучше → convert
        // - ghbdtn (en=-17.9) vs привет (ru=-7)        → swap → convert
        // Покрывает словоформы которых нет в плоском словаре.
        let originalScore: Double
        let swappedScore: Double
        if isCyrillic {
            originalScore = trigramPlausibility(lower, table: trigramsRu)
            swappedScore = trigramPlausibility(candidateLower, table: trigramsEn)
        } else {
            originalScore = trigramPlausibility(lower, table: trigramsEn)
            swappedScore = trigramPlausibility(candidateLower, table: trigramsRu)
        }
        // Запас 2.0 nat/триграмма — нужно «сильно лучше» чтобы свапнуть.
        // Без запаса возможны ложные свапы коротких/редких слов.
        if originalScore >= swappedScore - 2.0 {
            return nil
        }
        return candidate
    }

    /// Среднее лог-вероятностей триграмм (с " " по краям).
    /// Высокий результат = слово выглядит «как настоящее» в данном языке —
    /// покрывает падежи/спряжения которых нет в плоском словаре.
    private func trigramPlausibility(_ word: String, table: [String: Double]) -> Double {
        let padded = " " + word.lowercased() + " "
        let chars = Array(padded)
        guard chars.count >= 3 else { return -.infinity }
        var sum = 0.0
        var count = 0
        for i in 0...(chars.count - 3) {
            let tg = String(chars[i..<(i + 3)])
            sum += table[tg] ?? missingTrigramPenalty
            count += 1
        }
        return count > 0 ? sum / Double(count) : -.infinity
    }

    /// Длинные подстроки весят больше — они более дискриминативны (3→1, 4→2, 5→3, 6→4).
    private func weightedBadScore(in word: String, triggers: Set<String>) -> Int {
        let chars = Array(word)
        var score = 0
        for L in 3...6 where L <= chars.count {
            let weight = L - 2
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

    private struct LayoutFile: Decodable {
        let en_to_ru: [String: String]
        let ru_to_en: [String: String]
    }

    private struct TriggersFile: Decodable {
        let latin: [String]
        let cyrillic: [String]
    }

    /// Если primary мапит пунктуацию на пунктуацию вместо буквы — берём fallback.
    /// Спасает от кастомных Ukelele-раскладок где `.` → `,` вместо `.` → `ю`.
    private static func mergeMap(primary: [Character: Character],
                                  fallback: [Character: Character]) -> [Character: Character] {
        func isLetter(_ c: Character) -> Bool { c.isLetter }
        var out = fallback
        for (k, v) in primary {
            if let f = fallback[k] {
                if isLetter(v) || !isLetter(f) {
                    out[k] = v
                }
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
