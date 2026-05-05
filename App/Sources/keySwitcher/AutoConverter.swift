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
        /// nil = замена без хвостового разделителя (например, выделение)
        let trigger: Character?
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
    /// Окно после синтетических действий, чтобы собственные key events
    /// не инвалидировали lastReplacement.
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
            let prevDelete = retroChain.reduce(0) { $0 + $1.orig.count + 1 }
            let toDelete = prevDelete + word.count + 1
            let prefix = retroChain.map { $0.conv }.joined(separator: " ")
            let toType = prefix + " " + converted + String(trigger)
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
            ignoreInvalidationsUntil = Date().addingTimeInterval(0.3)
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
            guard prev.count == 1 else { break }
            let prevLow = prev.lowercased()
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
        }
        return chain.reversed()
    }

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

    func canToggle() -> Bool {
        guard let last = lastReplacement else { return false }
        return Date().timeIntervalSince(last.lastChangeTime) < toggleWindow
    }

    func toggle() {
        guard let last = lastReplacement else { return }
        let target: DisplayState = (last.state == .converted) ? .original : .converted
        applyState(target)
    }

    private func applyState(_ target: DisplayState) {
        guard let last = lastReplacement else { return }

        let currentText = (last.state == .converted) ? last.converted : last.original
        let targetText  = (target      == .converted) ? last.converted : last.original
        let triggerStr = last.trigger.map(String.init) ?? ""

        let toDelete = currentText.count + triggerStr.count
        sendBackspaces(toDelete)
        typeUnicode(targetText + triggerStr)

        if target == .original, let layout = last.originalLayout {
            InputSourceSwitcher.restore(layout)
        } else if let lang = targetText.inputLanguageForLayout {
            InputSourceSwitcher.switchTo(lang)
        }

        last.state = target
        last.lastChangeTime = Date()
        ignoreInvalidationsUntil = Date().addingTimeInterval(0.3)
    }

    private func sendBackspaces(_ count: Int) {
        InputInjection.shared.sendBackspaces(count)
    }

    private func typeUnicode(_ text: String) {
        InputInjection.shared.typeUnicode(text)
    }
}
