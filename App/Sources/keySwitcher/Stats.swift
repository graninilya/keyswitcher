import Foundation

/// Локальные счётчики. Никуда не отправляются — только показываются пользователю.
final class Stats: ObservableObject {
    static let shared = Stats()

    /// Сколько времени занимает ручное исправление промаха раскладкой: заметить,
    /// стереть слово, переключить язык, набрать заново. Оценка намеренно скромная —
    /// завышенная цифра обесценивает счётчик.
    static let secondsPerFix: Double = 4.0

    /// Ретро-цепочка чинит несколько слов разом, но замечает человек это один раз,
    /// поэтому дополнительные слова считаем дешевле.
    static let secondsPerRetroWord: Double = 1.5

    @Published private(set) var autoConversions: Int
    @Published private(set) var manualConversions: Int
    @Published private(set) var retroWords: Int
    @Published private(set) var reverts: Int
    @Published private(set) var polishRuns: Int
    @Published private(set) var transliterations: Int
    @Published private(set) var firstUse: Date

    private let d = UserDefaults.standard

    private init() {
        autoConversions   = d.integer(forKey: "stats.autoConversions")
        manualConversions = d.integer(forKey: "stats.manualConversions")
        retroWords        = d.integer(forKey: "stats.retroWords")
        reverts           = d.integer(forKey: "stats.reverts")
        polishRuns        = d.integer(forKey: "stats.polishRuns")
        transliterations  = d.integer(forKey: "stats.transliterations")
        if let t = d.object(forKey: "stats.firstUse") as? Date {
            firstUse = t
        } else {
            firstUse = Date()
            d.set(firstUse, forKey: "stats.firstUse")
        }
    }

    /// Откаты вычитаются: если пользователь отменил замену, время она не сэкономила,
    /// а наоборот отняла.
    var savedSeconds: Double {
        let fixes = Double(max(0, autoConversions + manualConversions - reverts))
        return fixes * Self.secondsPerFix + Double(retroWords) * Self.secondsPerRetroWord
    }

    var totalConversions: Int { autoConversions + manualConversions }

    /// Доля замен, которые пользователь не стал откатывать.
    /// Одну замену можно откатить и вернуть несколько раз подряд, поэтому
    /// откатов бывает больше, чем замен — долю ограничиваем снизу нулём.
    var accuracy: Double? {
        guard totalConversions > 0 else { return nil }
        let kept = max(0, totalConversions - reverts)
        return Double(kept) / Double(totalConversions)
    }

    var savedTimeDescription: String {
        Self.humanDuration(savedSeconds)
    }

    static func humanDuration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) сек" }
        let m = s / 60
        if m < 60 { return "\(m) мин" }
        let h = m / 60, remM = m % 60
        if h < 24 { return remM > 0 ? "\(h) ч \(remM) мин" : "\(h) ч" }
        let days = h / 24, remH = h % 24
        return remH > 0 ? "\(days) д \(remH) ч" : "\(days) д"
    }

    // MARK: - Учёт

    func noteAutoConversion(retroWords extra: Int = 0) {
        bump(&autoConversions, key: "stats.autoConversions")
        if extra > 0 {
            retroWords += extra
            d.set(retroWords, forKey: "stats.retroWords")
        }
    }

    func noteManualConversion() { bump(&manualConversions, key: "stats.manualConversions") }
    func noteRevert()           { bump(&reverts, key: "stats.reverts") }
    func notePolish()           { bump(&polishRuns, key: "stats.polishRuns") }
    func noteTransliteration()  { bump(&transliterations, key: "stats.transliterations") }

    private func bump(_ value: inout Int, key: String) {
        value += 1
        d.set(value, forKey: key)
    }

    func reset() {
        autoConversions = 0; manualConversions = 0; retroWords = 0
        reverts = 0; polishRuns = 0; transliterations = 0
        firstUse = Date()
        for k in ["stats.autoConversions", "stats.manualConversions", "stats.retroWords",
                  "stats.reverts", "stats.polishRuns", "stats.transliterations"] {
            d.removeObject(forKey: k)
        }
        d.set(firstUse, forKey: "stats.firstUse")
    }
}
