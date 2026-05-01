import AppKit

/// Ручная конверсия:
///   - выделенного текста (через Cmd+C → подмена → Cmd+V), либо
///   - последнего набранного слова (через буфер + backspace + ввод).
/// После любой удачной замены регистрирует её в AutoConverter, чтобы хоткей мог тоггнуть туда-обратно.
final class ClipboardConverter {

    /// Умная конверсия. Логика как в Caramba:
    ///   1. Если буфер не пуст — ты только что печатал → конвертим последнее слово.
    ///   2. Иначе пробуем AX-выделение.
    ///   3. Иначе — ничего.
    /// Буфер очищается на: клик мышкой, переключение приложения, спецклавиши.
    /// Так что «не пуст» = «пользователь активно набирает прямо сейчас».
    func smartConvert(_ transform: @escaping (String) -> String?) {
        let buffer = KeystrokeBuffer.shared
        let hasBuffer = !buffer.currentWord.isEmpty || !buffer.lastWord.isEmpty
        let selection = SelectionDetector.currentSelectionInfo()
        let typingNow = Date().timeIntervalSince(buffer.lastActivity) < 2.0
        Log.clipboard.info("smartConvert: hasBuffer=\(hasBuffer) typingNow=\(typingNow) cur='\(buffer.currentWord, privacy: .public)' last='\(buffer.lastWord, privacy: .public)' selection=\(String(describing: selection?.text), privacy: .public) partial=\(selection?.isPartial ?? false)")

        // (1) Настоящее частичное выделение — приоритет всегда.
        if let sel = selection, sel.isPartial {
            Log.clipboard.info("→ SELECTION path (partial)")
            let pb = NSPasteboard.general
            let saved = backupPasteboard(pb)
            replaceSelection(original: sel.text, transform: transform,
                             pasteboard: pb, savedItems: saved)
            return
        }

        // (2) Selection-есть-но-он-«вся-строка»:
        //     - если ты ТОЛЬКО ЧТО печатал → доверяем буферу (Electron часто врёт что вся строка selected)
        //     - иначе доверяем selection (это реальный Cmd+A)
        if let sel = selection, !sel.isPartial {
            if typingNow && hasBuffer {
                Log.clipboard.info("→ BUFFER path (typing, ignoring whole-text selection as suspicious)")
                convertLastWord(transform: transform)
                return
            }
            Log.clipboard.info("→ SELECTION path (whole)")
            let pb = NSPasteboard.general
            let saved = backupPasteboard(pb)
            replaceSelection(original: sel.text, transform: transform,
                             pasteboard: pb, savedItems: saved)
            return
        }

        // (3) Нет selection вообще — пробуем буфер
        if hasBuffer {
            Log.clipboard.info("→ BUFFER path")
            convertLastWord(transform: transform)
            return
        }

        Log.clipboard.info("→ nothing")
    }

    /// Конвертация уже известного выделенного текста через буфер обмена.
    private func convertSelectedText(original: String, transform: @escaping (String) -> String?) {
        let pasteboard = NSPasteboard.general
        let savedItems = backupPasteboard(pasteboard)
        replaceSelection(original: original, transform: transform,
                         pasteboard: pasteboard, savedItems: savedItems)
    }

    /// Принудительная конверсия. Сначала пробует выделение, иначе — последнее слово.
    /// В отличие от smartConvert, не использует детектор — просто всегда применяет transform.
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

    // MARK: - Selection helper

    private func replaceSelection(original: String, transform: (String) -> String?,
                                  pasteboard: NSPasteboard,
                                  savedItems: [(NSPasteboard.PasteboardType, Data)]) {
        guard let new = transform(original), new != original else {
            DispatchQueue.main.async { self.restorePasteboard(pasteboard, items: savedItems) }
            return
        }
        let savedLayout = InputSourceSwitcher.current()
        DispatchQueue.main.async {
            pasteboard.clearContents()
            pasteboard.setString(new, forType: .string)
            self.sendCommand(keyCode: 9)  // Cmd+V
            if let lang = new.inputLanguageForLayout {
                InputSourceSwitcher.switchTo(lang)
            }
            // Регистрируем для тоггла. Trigger = nil (выделение, не было хвостового разделителя).
            AutoConverter.shared.record(
                original: original, converted: new, trigger: nil, originalLayout: savedLayout
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.restorePasteboard(pasteboard, items: savedItems)
            }
        }
    }

    // MARK: - Last word

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

        let trigger: Character? = isMidTyping ? nil : buffer.lastTrigger
        let triggerStr = trigger.map(String.init) ?? ""
        let toDelete = word.count + triggerStr.count
        Log.clipboard.info("  backspaces=\(toDelete) typing='\(converted + triggerStr, privacy: .public)'")

        let savedLayout = InputSourceSwitcher.current()

        for _ in 0..<toDelete {
            sendKey(keyCode: 51)
        }
        typeUnicode(converted + triggerStr)

        if let lang = converted.inputLanguageForLayout {
            InputSourceSwitcher.switchTo(lang)
        }

        // Регистрируем для тоггла
        AutoConverter.shared.record(
            original: word, converted: converted, trigger: trigger, originalLayout: savedLayout
        )

        buffer.clear()
    }

    // MARK: - Симуляция ввода

    private func sendCommand(keyCode: CGKeyCode) {
        InputInjection.shared.sendCommand(keyCode: keyCode)
    }

    private func sendKey(keyCode: CGKeyCode) {
        InputInjection.shared.sendKey(keyCode: keyCode)
    }

    private func typeUnicode(_ text: String) {
        InputInjection.shared.typeUnicode(text)
    }

    // MARK: - Pasteboard backup/restore

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
