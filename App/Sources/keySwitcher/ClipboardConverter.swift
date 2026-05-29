import AppKit

final class ClipboardConverter {

    func smartConvert(_ transform: @escaping (String) -> String?) {
        let buffer = KeystrokeBuffer.shared
        let hasBuffer = !buffer.currentWord.isEmpty || !buffer.lastWord.isEmpty
        let selection = SelectionDetector.currentSelectionInfo()
        Log.clipboard.info("smartConvert: hasBuffer=\(hasBuffer) cur='\(buffer.currentWord, privacy: .public)' last='\(buffer.lastWord, privacy: .public)' selection=\(String(describing: selection?.text), privacy: .public)")

        // 1. AX выдал текст выделения — самый дешёвый путь.
        if let sel = selection, !sel.text.isEmpty {
            Log.clipboard.info("→ SELECTION path (\(sel.text.count) chars)")
            let pb = NSPasteboard.general
            let saved = backupPasteboard(pb)
            replaceSelection(original: sel.text, transform: transform,
                             pasteboard: pb, savedItems: saved)
            return
        }

        // 2. AX молчит — пробуем Cmd+C ДО BUFFER, потому что в Electron/web AX врёт
        //    но выделение реально есть. Если Cmd+C ничего не скопировал → BUFFER.
        Log.clipboard.info("→ CLIPBOARD FALLBACK (Cmd+C)")
        clipboardFallbackConvert(transform: transform, onNoSelection: { [weak self] in
            guard let self = self else { return }
            if hasBuffer {
                Log.clipboard.info("→ BUFFER path (after Cmd+C miss)")
                self.convertLastWord(transform: transform)
            } else {
                Log.clipboard.info("→ nothing")
            }
        })
    }

    private func clipboardFallbackConvert(
        transform: @escaping (String) -> String?,
        onNoSelection: @escaping () -> Void
    ) {
        let pb = NSPasteboard.general
        let savedItems = backupPasteboard(pb)
        let prevChangeCount = pb.changeCount

        sendCommand(keyCode: 8)  // Cmd+C (kVK_ANSI_C)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self = self else { return }
            let copied = pb.string(forType: .string)
            guard pb.changeCount > prevChangeCount,
                  let original = copied, !original.isEmpty else {
                Log.clipboard.info("  fallback: no selection (changeCount unchanged or empty)")
                self.restorePasteboard(pb, items: savedItems)
                onNoSelection()
                return
            }
            Log.clipboard.info("  fallback: copied '\(original, privacy: .public)'")
            self.replaceSelection(original: original, transform: transform,
                                  pasteboard: pb, savedItems: savedItems)
        }
    }

    private func convertSelectedText(original: String, transform: @escaping (String) -> String?) {
        let pasteboard = NSPasteboard.general
        let savedItems = backupPasteboard(pasteboard)
        replaceSelection(original: original, transform: transform,
                         pasteboard: pasteboard, savedItems: savedItems)
    }

    func convertSelectionOnly(_ transform: @escaping (String) -> String?) {
        if let original = SelectionDetector.currentSelectedText() {
            let pasteboard = NSPasteboard.general
            let savedItems = backupPasteboard(pasteboard)
            replaceSelection(original: original, transform: transform,
                             pasteboard: pasteboard, savedItems: savedItems)
        } else {
            convertLastWord(transform: transform)
        }
    }

    func polishCurrentTargetAsync(_ transform: @escaping (String) async -> String?) {
        let pb = NSPasteboard.general
        let savedItems = backupPasteboard(pb)

        if let sel = SelectionDetector.currentSelectedText(), !sel.isEmpty {
            Log.clipboard.info("polish: AX selection (\(sel.count) chars)")
            polishWithText(sel, pb: pb, savedItems: savedItems, transform: transform)
            return
        }

        if let para = SelectionDetector.expandToParagraphAndReturnText(), !para.isEmpty {
            Log.clipboard.info("polish: AX paragraph (\(para.count) chars)")
            polishWithText(para, pb: pb, savedItems: savedItems, transform: transform)
            return
        }

        Log.clipboard.info("polish: AX unavailable → keyboard line fallback")
        let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let preferCmdL = bundleId.hasPrefix("com.sublimetext")
            || bundleId.hasPrefix("io.zed")
            || bundleId == "com.microsoft.VSCode"
            || bundleId == "com.todesktop.230313mzl4w4u92"

        let strategyL: PolishStrategy = .init(name: "Cmd+L", send: sendCmdL, maxChars: 8000)
        let strategyArrow: PolishStrategy = .init(name: "Cmd+→ Cmd+Shift+←", send: sendArrowExpand, maxChars: 8000)

        let chain: [PolishStrategy] = preferCmdL
            ? [strategyL, strategyArrow]
            : [strategyArrow, strategyL]
        runStrategy(chain, index: 0,
                    pb: pb, savedItems: savedItems, transform: transform)
    }

    private func sendCmdL() {
        InputInjection.shared.sendCommand(keyCode: 37)
    }

    private func sendArrowExpand() {
        InputInjection.shared.sendCommand(keyCode: 124)
        usleep(40_000)
        InputInjection.shared.sendCommandShift(keyCode: 123)
    }

    private struct PolishStrategy {
        let name: String
        let send: () -> Void
        let maxChars: Int
    }

    private func runStrategy(_ chain: [PolishStrategy],
                             index: Int,
                             pb: NSPasteboard,
                             savedItems: [(NSPasteboard.PasteboardType, Data)],
                             transform: @escaping (String) async -> String?) {
        guard index < chain.count else {
            Log.clipboard.info("polish: all strategies failed")
            restorePasteboard(pb, items: savedItems)
            return
        }
        let strat = chain[index]
        strat.send()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self = self else { return }
            let cc = pb.changeCount
            self.sendCommand(keyCode: 8)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard let self = self else { return }
                let copied = pb.string(forType: .string) ?? ""
                let valid = pb.changeCount > cc && !copied.isEmpty && copied.count <= strat.maxChars
                if valid {
                    Log.clipboard.info("polish: \(strat.name) → \(copied.count) chars")
                    self.polishWithText(copied, pb: pb, savedItems: savedItems, transform: transform)
                    return
                }
                let reason = copied.count > strat.maxChars
                    ? "too large (\(copied.count) > \(strat.maxChars))"
                    : "empty"
                Log.clipboard.info("polish: \(strat.name) \(reason), next")
                self.runStrategy(chain, index: index + 1,
                                 pb: pb, savedItems: savedItems, transform: transform)
            }
        }
    }

    private func polishWithText(_ original: String,
                                pb: NSPasteboard,
                                savedItems: [(NSPasteboard.PasteboardType, Data)],
                                transform: @escaping (String) async -> String?) {
        Log.clipboard.info("polish input: '\(original, privacy: .public)'")
        let savedLayout = InputSourceSwitcher.current()
        Task { @MainActor in
            guard let new = await transform(original) else {
                Log.clipboard.info("polish: transform returned nil")
                self.restorePasteboard(pb, items: savedItems)
                return
            }
            guard new != original else {
                Log.clipboard.info("polish: unchanged")
                self.restorePasteboard(pb, items: savedItems)
                return
            }
            Log.clipboard.info("polish output: '\(new, privacy: .public)'")
            self.typeUnicode(new)
            AutoConverter.shared.record(
                original: original, converted: new, tail: "",
                originalLayout: savedLayout
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.restorePasteboard(pb, items: savedItems)
            }
        }
    }

    private func replaceSelection(original: String, transform: (String) -> String?,
                                  pasteboard: NSPasteboard,
                                  savedItems: [(NSPasteboard.PasteboardType, Data)]) {
        guard let new = transform(original), new != original else {
            DispatchQueue.main.async { self.restorePasteboard(pasteboard, items: savedItems) }
            return
        }
        let savedLayout = InputSourceSwitcher.current()
        DispatchQueue.main.async {
            // typeUnicode шлёт один keyDown с готовой UTF-16 строкой — для активного
            // text-input это эквивалентно "пользователь печатает", что заменяет
            // выделение целиком (стандартное поведение всех NSText-полей).
            // Cmd+V менее надёжен: в Electron/Notes/Word иногда не перезаписывает selection.
            self.typeUnicode(new)
            if let lang = new.inputLanguageForLayout {
                InputSourceSwitcher.switchTo(lang)
            }
            AutoConverter.shared.record(
                original: original, converted: new, tail: "", originalLayout: savedLayout
            )
            Self.maybePromoteToRule(original: original, converted: new)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.restorePasteboard(pasteboard, items: savedItems)
            }
        }
    }

    /// Считаем single-word ручные свапы — после порога предлагаем добавить в Правила.
    /// Multi-word / выделения с пробелами не учитываем (там разумнее не лезть).
    static func maybePromoteToRule(original: String, converted: String) {
        let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(" "), !trimmed.contains("\n"), !trimmed.contains("\t"),
              trimmed.count >= 2 else { return }
        let (count, promoted) = Settings.shared.recordManualSwap(trimmed)
        Log.clipboard.info("manual swap: '\(trimmed, privacy: .public)' count=\(count) promoted=\(promoted)")
        if promoted {
            RulePromoter.propose(original: trimmed, converted: converted)
        }
    }

    private func convertLastWord(transform: (String) -> String?) {
        let buffer = KeystrokeBuffer.shared
        let isMidTyping = !buffer.currentWord.isEmpty
        let word = isMidTyping ? buffer.currentWord : buffer.lastWord
        Log.clipboard.info("convertLastWord: word='\(word, privacy: .public)' midTyping=\(isMidTyping) lastTrigger=\(String(describing: buffer.lastTrigger), privacy: .public)")
        guard !word.isEmpty else {
            Log.clipboard.info("  word empty, skip")
            return
        }
        guard let converted = transform(word) else {
            Log.clipboard.info("  transform returned nil, skip")
            return
        }
        guard converted != word else {
            Log.clipboard.info("  converted == word, skip")
            return
        }
        Log.clipboard.info("  → converting '\(word, privacy: .public)' to '\(converted, privacy: .public)'")

        // Tail = всё что юзер напечатал ПОСЛЕ слова (trigger + последующие пробелы/пунктуация),
        // если мы не в середине набора. Иначе ничего после слова нет.
        let tail = isMidTyping ? "" : buffer.lastTail
        let toDelete = word.count + tail.count
        Log.clipboard.info("  backspaces=\(toDelete) typing='\(converted + tail, privacy: .public)' (tail='\(tail, privacy: .public)')")

        let savedLayout = InputSourceSwitcher.current()

        for _ in 0..<toDelete {
            sendKey(keyCode: 51)
        }
        typeUnicode(converted + tail)

        if let lang = converted.inputLanguageForLayout {
            InputSourceSwitcher.switchTo(lang)
        }

        AutoConverter.shared.record(
            original: word, converted: converted, tail: tail, originalLayout: savedLayout
        )
        Self.maybePromoteToRule(original: word, converted: converted)

        buffer.clear()
    }

    private func sendCommand(keyCode: CGKeyCode) {
        InputInjection.shared.sendCommand(keyCode: keyCode)
    }

    private func sendKey(keyCode: CGKeyCode) {
        InputInjection.shared.sendKey(keyCode: keyCode)
    }

    private func typeUnicode(_ text: String) {
        InputInjection.shared.typeUnicode(text)
        SoundFeedback.play()
    }

    private func backupPasteboard(_ pb: NSPasteboard) -> [(NSPasteboard.PasteboardType, Data)] {
        var saved: [(NSPasteboard.PasteboardType, Data)] = []
        for item in pb.pasteboardItems ?? [] {
            for type in item.types {
                if let data = item.data(forType: type) {
                    saved.append((type, data))
                }
            }
        }
        return saved
    }

    private func restorePasteboard(_ pb: NSPasteboard, items: [(NSPasteboard.PasteboardType, Data)]) {
        guard !items.isEmpty else { return }
        pb.clearContents()
        let item = NSPasteboardItem()
        for (type, data) in items {
            item.setData(data, forType: type)
        }
        pb.writeObjects([item])
    }
}
