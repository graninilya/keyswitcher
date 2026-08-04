import AppKit

final class ClipboardConverter {

    func smartConvert(_ transform: @escaping (String) -> String?) {
        let buffer = KeystrokeBuffer.shared
        let hasBuffer = !buffer.currentWord.isEmpty || !buffer.lastWord.isEmpty
        let selection = SelectionDetector.currentSelectionInfo()
        Log.clipboard.info("smartConvert: hasBuffer=\(hasBuffer) cur='\(Log.redact(buffer.currentWord), privacy: .public)' last='\(Log.redact(buffer.lastWord), privacy: .public)' selection=\(Log.redact(selection?.text ?? ""), privacy: .public)")

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
            Log.clipboard.info("  fallback: copied '\(Log.redact(original), privacy: .public)'")
            self.replaceSelection(original: original, transform: transform,
                                  pasteboard: pb, savedItems: savedItems)
        }
    }

    /// Строго по выделению: без него ничего не делаем. Нужен для действий, которым
    /// путь «последнее слово» не подходит — он завязан на конверсию раскладки.
    func applyToSelectionOnly(_ transform: @escaping (String) -> String?) {
        guard let original = SelectionDetector.currentSelectedText(), !original.isEmpty else {
            Log.clipboard.info("нет выделения — действие пропущено")
            return
        }
        let pasteboard = NSPasteboard.general
        let savedItems = backupPasteboard(pasteboard)
        replaceSelection(original: original, transform: transform,
                         pasteboard: pasteboard, savedItems: savedItems,
                         countsAsLayoutSwap: false)
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

    /// `onNoText` вызывается, если текст добыть не удалось ни одним способом:
    /// без этого плашка оставалась со спиннером, хотя ждать уже было нечего.
    func polishCurrentTargetAsync(transform: @escaping (String) async -> String?,
                                  onNoText: @escaping () -> Void = {}) {
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

        // Первым делом — просто скопировать то, что человек уже выделил. В полях на
        // web-технологиях (Electron, браузер) система выделение не показывает, но
        // копирование в них работает. Раньше этот путь был только у обычного свапа,
        // а полировка сразу бралась выделять строку сама — и в таких полях сдавалась.
        let strategySelection: PolishStrategy = .init(name: "копия выделения", send: {}, maxChars: 8000)
        let strategyL: PolishStrategy = .init(name: "Cmd+L", send: sendCmdL, maxChars: 8000)
        let strategyArrow: PolishStrategy = .init(name: "Cmd+→ Cmd+Shift+←", send: sendArrowExpand, maxChars: 8000)

        let chain: [PolishStrategy] = preferCmdL
            ? [strategySelection, strategyL, strategyArrow]
            : [strategySelection, strategyArrow, strategyL]
        runStrategy(chain, index: 0,
                    pb: pb, savedItems: savedItems, transform: transform, onNoText: onNoText)
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
        /// Ничего не нажимает — работает с уже существующим выделением.
        var isPassive: Bool { name == "копия выделения" }
    }

    private func runStrategy(_ chain: [PolishStrategy],
                             index: Int,
                             pb: NSPasteboard,
                             savedItems: PasteboardSnapshot,
                             transform: @escaping (String) async -> String?,
                             onNoText: @escaping () -> Void) {
        guard index < chain.count else {
            Log.clipboard.info("polish: текст добыть не удалось ни одним способом")
            restorePasteboard(pb, items: savedItems)
            onNoText()
            return
        }
        let strat = chain[index]
        strat.send()
        // Ждём, только если что-то нажимали: у копии выделения ждать нечего.
        let settle = strat.isPassive ? 0.0 : 0.18
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
            guard let self = self else { return }
            let cc = pb.changeCount
            self.sendCommand(keyCode: 8)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard let self = self else { return }
                let copied = pb.string(forType: .string) ?? ""
                let valid = pb.changeCount > cc && !copied.isEmpty && copied.count <= strat.maxChars
                if valid {
                    Log.clipboard.info("polish: \(strat.name, privacy: .public) → \(copied.count) символов")
                    self.polishWithText(copied, pb: pb, savedItems: savedItems, transform: transform)
                    return
                }
                let reason = copied.count > strat.maxChars
                    ? "слишком много (\(copied.count))"
                    : (pb.changeCount == cc
                        ? "буфер не изменился (⌘C не сработал, changeCount=\(cc))"
                        : "скопировалась пустота")
                Log.clipboard.info("polish: \(strat.name, privacy: .public) \(reason, privacy: .public), пробую следующий")
                self.runStrategy(chain, index: index + 1,
                                 pb: pb, savedItems: savedItems,
                                 transform: transform, onNoText: onNoText)
            }
        }
    }

    private func polishWithText(_ original: String,
                                pb: NSPasteboard,
                                savedItems: PasteboardSnapshot,
                                transform: @escaping (String) async -> String?) {
        Log.clipboard.info("polish input: '\(Log.redact(original), privacy: .public)'")
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
            Log.clipboard.info("polish output: '\(Log.redact(new), privacy: .public)'")
            self.typeUnicode(new)
            AutoConverter.shared.record(
                original: original, converted: new, tail: "",
                originalLayout: savedLayout
            )
            KeystrokeBuffer.shared.clearContext()
            Stats.shared.notePolish()
            History.shared.add(original: original, converted: new, kind: .polish)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.restorePasteboard(pb, items: savedItems)
            }
        }
    }

    /// `countsAsLayoutSwap` разделяет смену раскладки и прочие правки: типографика
    /// не должна попадать в счётчик замен, в историю как конверсия и тем более
    /// предлагаться в Правила свапа.
    private func replaceSelection(original: String, transform: (String) -> String?,
                                  pasteboard: NSPasteboard,
                                  savedItems: PasteboardSnapshot,
                                  countsAsLayoutSwap: Bool = true) {
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
            if countsAsLayoutSwap, let lang = new.inputLanguageForLayout {
                InputSourceSwitcher.switchTo(lang)
            }
            AutoConverter.shared.record(
                original: original, converted: new, tail: "", originalLayout: savedLayout
            )
            // Заменили выделение — прежние lastWord/lastTail к экрану больше не относятся.
            KeystrokeBuffer.shared.clearContext()
            if countsAsLayoutSwap {
                Stats.shared.noteManualConversion()
                History.shared.add(original: original, converted: new, kind: .manual)
                Self.maybePromoteToRule(original: original, converted: new)
            } else {
                History.shared.add(original: original, converted: new, kind: .polish)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.restorePasteboard(pasteboard, items: savedItems)
            }
        }
    }

    /// Свапает «сырой сегмент с последнего пробела» — для случаев `0ю2ю8` где
    /// обычный word+tail видит только часть.
    private func convertSegment(_ segment: String, transform: (String) -> String?) {
        guard let converted = transform(segment), converted != segment else {
            Log.clipboard.info("  segment unchanged, skip")
            return
        }
        Log.clipboard.info("  → segment '\(Log.redact(segment), privacy: .public)' → '\(Log.redact(converted), privacy: .public)'")
        let savedLayout = InputSourceSwitcher.current()
        for _ in 0..<segment.count {
            sendKey(keyCode: 51)
        }
        typeUnicode(converted)
        if let lang = converted.inputLanguageForLayout {
            InputSourceSwitcher.switchTo(lang)
        }
        AutoConverter.shared.record(
            original: segment, converted: converted, tail: "", originalLayout: savedLayout
        )
        Self.maybePromoteToRule(original: segment, converted: converted)
        KeystrokeBuffer.shared.clearContext()
    }

    /// Считаем single-word ручные свапы — после порога предлагаем добавить в Правила.
    /// Multi-word / выделения с пробелами не учитываем (там разумнее не лезть).
    static func maybePromoteToRule(original: String, converted: String) {
        let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(" "), !trimmed.contains("\n"), !trimmed.contains("\t"),
              trimmed.count >= 2 else { return }
        let (count, promoted) = Settings.shared.recordManualSwap(trimmed)
        Log.clipboard.info("manual swap: '\(Log.redact(trimmed), privacy: .public)' count=\(count) promoted=\(promoted)")
        if promoted {
            RulePromoter.propose(original: trimmed, converted: converted)
        }
    }

    private func convertLastWord(transform: (String) -> String?) {
        let buffer = KeystrokeBuffer.shared
        let isMidTyping = !buffer.currentWord.isEmpty
        let word = isMidTyping ? buffer.currentWord : buffer.lastWord
        Log.clipboard.info("convertLastWord: word='\(Log.redact(word), privacy: .public)' midTyping=\(isMidTyping) lastTrigger=\(Log.redact(buffer.lastTrigger), privacy: .public) segment='\(Log.redact(buffer.lastSegment), privacy: .public)'")

        // Если сегмент с последнего пробела «богаче» чем word+tail (содержит
        // больше символов из-за цифр/пунктуации в середине — `0ю2ю8`), свапаем
        // его целиком. Иначе — стандартный путь word + tail.
        let segment = buffer.lastSegment
        let wordTailLen = word.count + (isMidTyping ? 0 : buffer.lastTail.count)
        if !segment.isEmpty, segment.count > wordTailLen {
            convertSegment(segment, transform: transform)
            return
        }
        guard !word.isEmpty else {
            Log.clipboard.info("  word empty, skip")
            return
        }

        let rawTail = isMidTyping ? "" : buffer.lastTail
        let lowerWord = word.lowercased()

        // Если автоконвертер сам бы не тронул слово — оно «реально» для своей
        // раскладки (или базовая форма в словаре, или хорошие триграммы).
        // Тогда не свапаем его, только tail. Лечит `сочетанием 5:` → `сочетанием 5%`.
        let autoWouldConvert = LayoutMap.shared.autoConvert(word) != nil
        let isMonoCyr = lowerWord.allSatisfy { ("а"..."я").contains($0) || $0 == "ё" }
        let isMonoLat = lowerWord.allSatisfy { ("a"..."z").contains($0) }
        let isRealRussian = isMonoCyr && !autoWouldConvert
        let isRealEnglish = isMonoLat && !autoWouldConvert

        // Хвост свапаем вместо слова только когда он ДЕЙСТВИТЕЛЬНО меняется
        // (`сочетанием 5:` → `сочетанием 5%`). Если хвост — обычный пробел, он при
        // свапе остаётся собой, и раньше здесь стоял выход: хоткей после пробела
        // молча не делал ничего. Теперь такой случай уходит на обычный свап слова.
        let tailWouldChange = !rawTail.isEmpty
            && LayoutMap.shared.swapDirectional(rawTail, toCyrillic: !isRealRussian) != rawTail

        if (isRealRussian || isRealEnglish) && tailWouldChange {
            let convertedIsCyrillic = !isRealRussian
            let mappedTail = LayoutMap.shared.swapDirectional(rawTail, toCyrillic: convertedIsCyrillic)
            Log.clipboard.info("  word is real, swap only tail '\(Log.redact(rawTail), privacy: .public)' → '\(Log.redact(mappedTail), privacy: .public)'")
            for _ in 0..<rawTail.count {
                sendKey(keyCode: 51)
            }
            typeUnicode(mappedTail)
            // Хвост на экране уже другой. Без синхронизации повторный ⌥ удалил бы
            // символы по старому rawTail и съел кусок слова.
            buffer.syncAfterExternalReplacement(word: word, tail: mappedTail)
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
        Log.clipboard.info("  → converting '\(Log.redact(word), privacy: .public)' to '\(Log.redact(converted), privacy: .public)'")

        // Свапаем tail в ту же сторону что и слово: если "раскладке" → "hfcrkflrt",
        // то ` 5:` тоже идёт через ruToEn → ` 5%`.
        let convertedIsCyrillic = converted.lowercased().contains { ("а"..."я").contains($0) || $0 == "ё" }
        let tail = LayoutMap.shared.swapDirectional(rawTail, toCyrillic: convertedIsCyrillic)
        let toDelete = word.count + rawTail.count
        Log.clipboard.info("  backspaces=\(toDelete) typing='\(Log.redact(converted + tail), privacy: .public)' (tail='\(Log.redact(tail), privacy: .public)' rawTail='\(Log.redact(rawTail), privacy: .public)')")

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
        Stats.shared.noteManualConversion()
        History.shared.add(original: word, converted: converted, kind: .manual)

        buffer.clearContext()
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

    /// Снимок буфера обмена. Пустой буфер отличается от нечитаемого: у промисов
    /// (файлы из Finder) данных нет до запроса, и стирать такой буфер нельзя.
    ///
    /// Признак пустоты хранится в самом снимке, а не в поле объекта: предпросмотр
    /// держит снимок десятками секунд, и за это время успевает начаться другая
    /// операция — общее поле приводило к стиранию свежей копии пользователя.
    struct PasteboardSnapshot {
        var entries: [(NSPasteboard.PasteboardType, Data)]
        var wasEmpty: Bool
        /// Состояние на момент снимка: если буфер с тех пор изменил кто-то другой,
        /// возвращать старое содержимое нельзя.
        var changeCount: Int

        var isEmpty: Bool { entries.isEmpty }
    }

    /// Каждый элемент — отдельно. Плоский список схлопывал многоэлементную копию
    /// (например несколько файлов из Finder) в один элемент.
    private func backupPasteboard(_ pb: NSPasteboard) -> PasteboardSnapshot {
        let items = pb.pasteboardItems ?? []

        var saved: [(NSPasteboard.PasteboardType, Data)] = []
        for (index, item) in items.enumerated() {
            for type in item.types {
                if let data = item.data(forType: type) {
                    // Индекс элемента прячем в тип, чтобы восстановить исходную группировку.
                    saved.append((NSPasteboard.PasteboardType("\(index)\u{1}\(type.rawValue)"), data))
                }
            }
        }
        return PasteboardSnapshot(entries: saved, wasEmpty: items.isEmpty, changeCount: pb.changeCount)
    }

    private func restorePasteboard(_ pb: NSPasteboard, items snapshot: PasteboardSnapshot) {
        let items = snapshot.entries
        guard !items.isEmpty else {
            // Был действительно пуст — возвращаем пустоту, иначе наш скопированный
            // текст остался бы у пользователя. Было непусто, но нечитаемо — не трогаем.
            if snapshot.wasEmpty { pb.clearContents() }
            return
        }
        var grouped: [Int: [(NSPasteboard.PasteboardType, Data)]] = [:]
        for (tagged, data) in items {
            let parts = tagged.rawValue.split(separator: "\u{1}", maxSplits: 1)
            guard parts.count == 2, let index = Int(parts[0]) else { continue }
            let type = NSPasteboard.PasteboardType(String(parts[1]))
            grouped[index, default: []].append((type, data))
        }
        guard !grouped.isEmpty else {
            pb.clearContents()
            return
        }
        pb.clearContents()
        let restored: [NSPasteboardItem] = grouped.keys.sorted().compactMap { index in
            guard let entries = grouped[index] else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in entries {
                item.setData(data, forType: type)
            }
            return item
        }
        pb.writeObjects(restored)
    }
}
