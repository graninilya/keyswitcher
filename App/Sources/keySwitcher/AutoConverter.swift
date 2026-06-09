import AppKit
import Carbon

final class AutoConverter {
    static let shared = AutoConverter()

    enum DisplayState {
        case original
        case converted
    }

    private final class Replacement {
        let original: String
        let converted: String
        /// Хвост после слова (trigger + последующие пробелы/пунктуация). "" для selection-replace.
        let tail: String
        let originalLayout: TISInputSource?
        var state: DisplayState
        var lastChangeTime: Date
        let isAutomatic: Bool

        init(original: String, converted: String, tail: String,
             originalLayout: TISInputSource?, state: DisplayState,
             isAutomatic: Bool = false) {
            self.original = original
            self.converted = converted
            self.tail = tail
            self.originalLayout = originalLayout
            self.state = state
            self.lastChangeTime = Date()
            self.isAutomatic = isAutomatic
        }
    }

    private var lastReplacement: Replacement?
    private let toggleWindow: TimeInterval = 5.0

    private init() {}

    func install() {
        KeystrokeBuffer.shared.onWordCompleted = { [weak self] word, trigger in
            self?.handleWordCompleted(word: word, trigger: trigger)
        }
        EventMonitor.shared.onKeyDown { [weak self] _ in
            guard let self = self else { return }
            // KeystrokeBuffer.muted = идёт наша же синтетическая инъекция (backspace+type).
            // Только настоящие пользовательские key-events должны сбрасывать lastReplacement.
            if !KeystrokeBuffer.shared.muted {
                self.lastReplacement = nil
            }
        }
        // Клик мышью = пользователь сдвинул каретку или сделал новое выделение.
        // Старый toggle становится бессмысленным — applyState затёр бы текст у нового курсора.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.lastReplacement = nil
        }
        // Смена активного приложения = почти наверняка новый контекст ввода.
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.lastReplacement = nil
        }
    }

    private func handleWordCompleted(word: String, trigger: Character) {
        guard Settings.shared.enabled else {
            Log.auto.info("disabled, skip word='\(word, privacy: .public)'")
            return
        }
        guard Settings.shared.autoConvertEnabled else {
            Log.auto.info("autoConvert disabled, skip word='\(word, privacy: .public)'")
            return
        }
        let result = LayoutMap.shared.autoConvert(word)
        Log.auto.info("word='\(word, privacy: .public)' → \(String(describing: result), privacy: .public)")
        guard let converted = result else { return }

        let savedLayout = InputSourceSwitcher.current()
        let buffer = KeystrokeBuffer.shared

        let retroChain = retroactiveChain(
            history: buffer.historySnapshot, currentConverted: converted
        )

        // Trigger тоже маппим в раскладку результата: `Ghbdtn&` (где `&` это
        // Shift+7 в EN) → `Привет` + остаётся `&`. Хотя юзер хотел `.` (Shift+7
        // в RU PC). swapChar делает enToRu или ruToEn в зависимости от target.
        let convertedIsCyrillic = converted.lowercased().contains { ("а"..."я").contains($0) || $0 == "ё" }
        let mappedTrigger = LayoutMap.shared.swapChar(trigger, toCyrillic: convertedIsCyrillic)
        let tailString = String(mappedTrigger)

        let replacement = Replacement(
            original: word, converted: converted, tail: tailString,
            originalLayout: savedLayout, state: .original,
            isAutomatic: true
        )
        lastReplacement = replacement

        if !retroChain.isEmpty {
            for r in retroChain {
                Log.auto.info("retro: '\(r.orig, privacy: .public)' → '\(r.conv, privacy: .public)'")
            }
            let prevDelete = retroChain.reduce(0) { $0 + $1.orig.count + 1 }
            let toDelete = prevDelete + word.count + 1
            let prefix = retroChain.map { $0.conv }.joined(separator: " ")
            let toType = prefix + " " + converted + tailString
            sendBackspaces(toDelete)
            typeUnicode(toType)
            if let lang = converted.inputLanguageForLayout {
                InputSourceSwitcher.switchTo(lang)
            }
            for (offsetFromEndOfRetro, r) in retroChain.enumerated() {
                let offsetFromEnd = retroChain.count - offsetFromEndOfRetro
                buffer.replaceFromEnd(offset: offsetFromEnd, with: r.conv)
            }
            buffer.replaceLastInHistory(with: converted)
        } else {
            applyState(.converted)
            buffer.replaceLastInHistory(with: converted)
        }
    }

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
            let prevLow = prev.lowercased()

            if prev.count == 1 {
                if isCyrConv && validRu.contains(prevLow) { break }
                if isLatConv && validEn.contains(prevLow) { break }

                let prevSwap = LayoutMap.shared.swap(prev)
                guard let firstSwap = prevSwap.first else { break }
                let swapIsCyrLetter = ("а"..."я").contains(firstSwap) || firstSwap == "ё"
                                    || ("А"..."Я").contains(firstSwap) || firstSwap == "Ё"
                let swapIsLatLetter = ("a"..."z").contains(firstSwap) || ("A"..."Z").contains(firstSwap)

                let valid = (isCyrConv && swapIsCyrLetter) || (isLatConv && swapIsLatLetter)
                if valid && prevSwap != prev {
                    chain.append((prev, prevSwap))
                    i -= 1
                } else {
                    break
                }
                continue
            }

            // Multi-letter retro: подхватываем `ye` → `ну`, `et` → `не`,
            // если их свап — реальное слово в целевом языке. Текущее
            // слово уже конвертилось → юзер давно в неправильной раскладке.
            let isPrevLat = prevLow.allSatisfy { ("a"..."z").contains($0) }
            let isPrevCyr = prevLow.allSatisfy { ("а"..."я").contains($0) || $0 == "ё" }
            guard isPrevLat || isPrevCyr else { break }
            // Идём назад только пока направление совпадает с текущим свапом.
            if isCyrConv && !isPrevLat { break }
            if isLatConv && !isPrevCyr { break }

            let prevSwap = LayoutMap.shared.swap(prev)
            let prevSwapLow = prevSwap.lowercased()
            guard prevSwap != prev else { break }

            let userForce = Settings.shared.forceSwapWords
            let isInRules = LayoutMap.builtInForceSwap.contains(prevSwapLow)
                         || userForce.contains(prevSwapLow)

            let swapIsValid: Bool
            if isCyrConv {
                swapIsValid = LayoutMap.shared.isValidRussian(prevSwapLow)
            } else {
                swapIsValid = LayoutMap.shared.isValidEnglish(prevSwapLow)
            }

            // Сам факт что текущее слово сконвертилось — сильный сигнал
            // wrong-layout серии. Достаточно чтобы swap был валидным словом
            // целевого языка ИЛИ слово было в Правилах. Триграммный гард
            // не сработал на 2-буквенных (триграмм нет → штраф съедает
            // разницу), а контекст в буфере отражает сырой ввод который
            // ещё латиница.
            let triggerSwap = isInRules || swapIsValid
            guard triggerSwap else { break }

            chain.append((prev, prevSwap))
            i -= 1
        }
        return chain.reversed()
    }

    func record(original: String, converted: String, tail: String,
                originalLayout: TISInputSource?) {
        let replacement = Replacement(
            original: original, converted: converted, tail: tail,
            originalLayout: originalLayout ?? InputSourceSwitcher.current(),
            state: .converted
        )
        lastReplacement = replacement
    }

    func canToggle() -> Bool {
        guard let last = lastReplacement else { return false }
        return Date().timeIntervalSince(last.lastChangeTime) < toggleWindow
    }

    func toggle() {
        guard let last = lastReplacement else { return }
        let target: DisplayState = (last.state == .converted) ? .original : .converted
        if target == .original, last.isAutomatic {
            let promoted = Settings.shared.recordRevert(last.original)
            let count = Settings.shared.pendingReverts[last.original.lowercased()] ?? 0
            Log.auto.info("revert '\(last.original, privacy: .public)' (count=\(count) promoted=\(promoted))")
        }
        applyState(target)
    }

    private func applyState(_ target: DisplayState) {
        guard let last = lastReplacement else { return }

        let currentText = (last.state == .converted) ? last.converted : last.original
        let targetText  = (target      == .converted) ? last.converted : last.original
        let tail = last.tail

        let toDelete = currentText.count + tail.count
        sendBackspaces(toDelete)
        typeUnicode(targetText + tail)

        if target == .original, let layout = last.originalLayout {
            InputSourceSwitcher.restore(layout)
        } else if let lang = targetText.inputLanguageForLayout {
            InputSourceSwitcher.switchTo(lang)
        }

        last.state = target
        last.lastChangeTime = Date()
    }

    private func sendBackspaces(_ count: Int) {
        InputInjection.shared.sendBackspaces(count)
    }

    private func typeUnicode(_ text: String) {
        InputInjection.shared.typeUnicode(text)
        SoundFeedback.play()
    }
}
