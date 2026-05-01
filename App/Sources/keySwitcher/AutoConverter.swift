import AppKit
import Carbon

/// Авто-конверсия и тоггл-история замен.
///
/// Любая замена (авто или ручная) регистрируется через `record(...)`. Пока окно тоггла открыто
/// (5 секунд после последнего изменения), нажатие хоткея вызывает `toggle()` —
/// печатает противоположную версию и переключает обратно раскладку.
final class AutoConverter {
    static let shared = AutoConverter()

    enum DisplayState {
        case original   // в документе сейчас исходный текст
        case converted  // в документе сейчас конвертированный текст
    }

    private final class Replacement {
        let original: String
        let converted: String
        /// Разделитель, идущий ЗА словом в документе (пробел, точка…).
        /// nil = замена не имеет хвостового разделителя (например, выделение).
        let trigger: Character?
        /// Раскладка, которая была активна до самой первой конверсии этого слова.
        let originalLayout: TISInputSource?
        var state: DisplayState
        var lastChangeTime: Date

        init(original: String, converted: String, trigger: Character?,
             originalLayout: TISInputSource?, state: DisplayState) {
            self.original = original
            self.converted = converted
            self.trigger = trigger
            self.originalLayout = originalLayout
            self.state = state
            self.lastChangeTime = Date()
        }
    }

    private var lastReplacement: Replacement?
    private let toggleWindow: TimeInterval = 5.0
    /// Окно после своих синтетических действий, в котором собственные key events
    /// не должны инвалидировать lastReplacement.
    private var ignoreInvalidationsUntil: Date = .distantPast

    private init() {}

    func install() {
        KeystrokeBuffer.shared.onWordCompleted = { [weak self] word, trigger in
            self?.handleWordCompleted(word: word, trigger: trigger)
        }
        EventMonitor.shared.onKeyDown { [weak self] _ in
            guard let self = self else { return }
            if Date() > self.ignoreInvalidationsUntil {
                self.lastReplacement = nil
            }
        }
    }

    // MARK: - Авто-замена при завершении слова пользователем

    private func handleWordCompleted(word: String, trigger: Character) {
        guard Settings.shared.enabled else {
            Log.auto.info("disabled, skip word='\(word, privacy: .public)'")
            return
        }
        let result = LayoutMap.shared.autoConvert(word)
        Log.auto.info("word='\(word, privacy: .public)' → \(String(describing: result), privacy: .public)")
        guard let converted = result else { return }

        let savedLayout = InputSourceSwitcher.current()
        let buffer = KeystrokeBuffer.shared

        // Цепочка ретро-конверсий: сколько идущих подряд одиночных слов перед текущим
        // тоже надо свапнуть. Возвращается от старого к новому.
        let retroChain = retroactiveChain(
            history: buffer.historySnapshot, currentConverted: converted
        )

        let replacement = Replacement(
            original: word, converted: converted, trigger: trigger,
            originalLayout: savedLayout, state: .original
        )
        lastReplacement = replacement

        if !retroChain.isEmpty {
            for r in retroChain {
                Log.auto.info("retro: '\(r.orig, privacy: .public)' → '\(r.conv, privacy: .public)'")
            }
            // Сколько символов удалить: для каждого retro слова + 1 пробел,
            // потом основное слово + trigger.
            let prevDelete = retroChain.reduce(0) { $0 + $1.orig.count + 1 }
            let toDelete = prevDelete + word.count + 1
            // Что напечатать: все retro_conv через пробел, потом converted + trigger
            let prefix = retroChain.map { $0.conv }.joined(separator: " ")
            let toType = prefix + " " + converted + String(trigger)
            sendBackspaces(toDelete)
            typeUnicode(toType)
            if let lang = converted.inputLanguageForLayout {
                InputSourceSwitcher.switchTo(lang)
            }
            // Обновляем историю
            for (offsetFromEndOfRetro, r) in retroChain.enumerated() {
                // retroChain[0] — самое старое, стоит на позиции (count - 1 - retroChain.count + 0)
                // т.е. offset с конца = retroChain.count - offsetFromEndOfRetro
                let offsetFromEnd = retroChain.count - offsetFromEndOfRetro
                buffer.replaceFromEnd(offset: offsetFromEnd, with: r.conv)
            }
            buffer.replaceLastInHistory(with: converted)
            ignoreInvalidationsUntil = Date().addingTimeInterval(0.3)
        } else {
            applyState(.converted)
            buffer.replaceLastInHistory(with: converted)
        }
    }

    /// Возвращает цепочку retro-конверсий: подряд идущие одиночные слова перед текущим,
    /// которые после swap становятся буквами языка converted.
    /// Возвращает в порядке от старого к новому.
    private func retroactiveChain(history: [String], currentConverted: String)
        -> [(orig: String, conv: String)] {
        let convertedLow = currentConverted.lowercased()
        let isCyrConv = convertedLow.allSatisfy { ("а"..."я").contains($0) || $0 == "ё" }
        let isLatConv = convertedLow.allSatisfy { ("a"..."z").contains($0) }
        guard isCyrConv || isLatConv else { return [] }

        let validRu: Set<String> = ["а","и","в","к","с","о","у","я"]
        let validEn: Set<String> = ["a","i"]

        var chain: [(String, String)] = []
        var i = history.count - 2
        while i >= 0 {
            let prev = history[i]
            guard prev.count == 1 else { break }
            let prevLow = prev.lowercased()
            // Если уже валидно в целевом языке — не трогаем и стопаем
            if isCyrConv && validRu.contains(prevLow) { break }
            if isLatConv && validEn.contains(prevLow) { break }

            let prevSwap = LayoutMap.shared.swap(prev)
            guard let firstSwap = prevSwap.first else { break }
            let swapIsCyrLetter = ("а"..."я").contains(firstSwap) || firstSwap == "ё"
                                || ("А"..."Я").contains(firstSwap) || firstSwap == "Ё"
            let swapIsLatLetter = ("a"..."z").contains(firstSwap) || ("A"..."Z").contains(firstSwap)

            // Свап должен дать букву ЦЕЛЕВОГО языка и быть отличен от оригинала
            let valid = (isCyrConv && swapIsCyrLetter) || (isLatConv && swapIsLatLetter)
            if valid && prevSwap != prev {
                chain.append((prev, prevSwap))
                i -= 1
            } else {
                break
            }
        }
        return chain.reversed()  // от старого к новому
    }

    // MARK: - Регистрация ручной замены, выполненной снаружи (ClipboardConverter)

    /// Зарегистрировать уже выполненную ручную замену.
    /// Текст в документе сейчас = converted (ClipboardConverter уже сделал замену).
    func record(original: String, converted: String, trigger: Character?,
                originalLayout: TISInputSource?) {
        let replacement = Replacement(
            original: original, converted: converted, trigger: trigger,
            originalLayout: originalLayout ?? InputSourceSwitcher.current(),
            state: .converted
        )
        lastReplacement = replacement
        ignoreInvalidationsUntil = Date().addingTimeInterval(0.3)
    }

    // MARK: - Тоггл

    /// Можно ли сейчас тоггнуть последнюю замену?
    func canToggle() -> Bool {
        guard let last = lastReplacement else { return false }
        return Date().timeIntervalSince(last.lastChangeTime) < toggleWindow
    }

    /// Перевернуть состояние: показать противоположный вариант.
    func toggle() {
        guard let last = lastReplacement else { return }
        let target: DisplayState = (last.state == .converted) ? .original : .converted
        applyState(target)
    }

    // MARK: - Применить заданное состояние к документу

    private func applyState(_ target: DisplayState) {
        guard let last = lastReplacement else { return }

        let currentText = (last.state == .converted) ? last.converted : last.original
        let targetText  = (target      == .converted) ? last.converted : last.original
        let triggerStr = last.trigger.map(String.init) ?? ""

        let toDelete = currentText.count + triggerStr.count
        sendBackspaces(toDelete)
        typeUnicode(targetText + triggerStr)

        // Переключаем раскладку
        if target == .original, let layout = last.originalLayout {
            InputSourceSwitcher.restore(layout)
        } else if let lang = targetText.inputLanguageForLayout {
            InputSourceSwitcher.switchTo(lang)
        }

        last.state = target
        last.lastChangeTime = Date()
        ignoreInvalidationsUntil = Date().addingTimeInterval(0.3)
    }

    // MARK: - Симуляция ввода (через единый InputInjection)

    private func sendBackspaces(_ count: Int) {
        InputInjection.shared.sendBackspaces(count)
    }

    private func typeUnicode(_ text: String) {
        InputInjection.shared.typeUnicode(text)
    }
}
