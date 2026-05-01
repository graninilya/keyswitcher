import AppKit
import Carbon.HIToolbox

/// Глобальный CGEventTap. Один экземпляр на приложение.
/// Подписывается на keyDown и flagsChanged, раздаёт событиям подписчикам.
final class EventMonitor {
    static let shared = EventMonitor()

    typealias KeyHandler = (CGEvent) -> Void
    typealias FlagsHandler = (CGEvent) -> Void

    private var keyHandlers: [UUID: KeyHandler] = [:]
    private var flagsHandlers: [UUID: FlagsHandler] = [:]

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private init() {}

    /// Запускает CGEventTap. Возвращает false если нет AX permission.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard AXIsProcessTrusted() else { return false }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userData in
                guard let userData = userData else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<EventMonitor>.fromOpaque(userData).takeUnretainedValue()
                monitor.dispatch(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)

        self.tap = newTap
        self.runLoopSource = source
        return true
    }

    func stop() {
        guard let tap = tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        self.tap = nil
        self.runLoopSource = nil
    }

    private func dispatch(type: CGEventType, event: CGEvent) {
        switch type {
        case .keyDown:
            for h in keyHandlers.values { h(event) }
        case .flagsChanged:
            for h in flagsHandlers.values { h(event) }
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
        default:
            break
        }
    }

    @discardableResult
    func onKeyDown(_ handler: @escaping KeyHandler) -> UUID {
        let id = UUID()
        keyHandlers[id] = handler
        return id
    }

    @discardableResult
    func onFlagsChanged(_ handler: @escaping FlagsHandler) -> UUID {
        let id = UUID()
        flagsHandlers[id] = handler
        return id
    }

    func remove(_ id: UUID) {
        keyHandlers.removeValue(forKey: id)
        flagsHandlers.removeValue(forKey: id)
    }
}


// MARK: - KeystrokeBuffer

/// Отслеживает последнее набираемое слово.
/// При не-буквенной клавише (пробел, Enter, пунктуация) фиксирует слово как "последнее".
/// Если включён Secure Input (поле пароля) — буфер отключается полностью.
final class KeystrokeBuffer {
    static let shared = KeystrokeBuffer()

    private(set) var currentWord: String = ""
    private(set) var lastWord: String = ""
    /// Какой разделитель завершил последнее слово (пробел, точка, запятая…).
    /// nil если слово ещё не закончено.
    private(set) var lastTrigger: Character? = nil
    /// Время последней пользовательской активности (любое нажатие).
    private(set) var lastActivity: Date = .distantPast

    /// Последние N набранных слов — для определения «доминирующего языка контекста».
    private var recentWords: [String] = []
    private let recentWordsCapacity = 5

    /// Доминирующий язык в контексте набора.
    /// Смотрит только на последние ~3 слова — отзывчиво при смене языка.
    var dominantContext: InputLanguage? {
        let recent = Array(recentWords.suffix(3))
        var cyr = 0, lat = 0
        for w in recent {
            cyr += w.filter { ("а"..."я").contains($0) || $0 == "ё"
                            || ("А"..."Я").contains($0) || $0 == "Ё" }.count
            lat += w.filter { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }.count
        }
        if cyr + lat >= 2 {
            if cyr > lat { return .russian }
            if lat > cyr { return .english }
        }

        // Если в последних словах буквы на полу — fallback на текст документа
        return ContextResolver.dominantLanguageInFocusedElement()
    }

    /// Заменить последнее слово в recentWords (вызывается после auto-conversion,
    /// чтобы контекст отражал то что ДЕЙСТВИТЕЛЬНО в документе).
    func replaceLastInHistory(with converted: String) {
        guard !recentWords.isEmpty else { return }
        recentWords[recentWords.count - 1] = converted
    }

    /// Доступ к истории слов для AutoConverter (нужен ретро-проверке предыдущего слова).
    var historySnapshot: [String] { recentWords }

    /// Заменить слово в recentWords по offset с конца (0 = последнее, 1 = предпоследнее, …).
    func replaceFromEnd(offset: Int, with converted: String) {
        guard recentWords.count > offset, offset >= 0 else { return }
        recentWords[recentWords.count - 1 - offset] = converted
    }

    /// Когда true, все входящие события игнорируются. Используется AutoConverter
    /// чтобы не «съесть» свои же синтетические нажатия.
    var muted: Bool = false

    /// Колбэк при завершении слова (нажат разделитель). Передаёт слово и символ-разделитель.
    var onWordCompleted: ((String, Character) -> Void)?

    private init() {}

    func install() {
        EventMonitor.shared.onKeyDown { [weak self] event in
            self?.handle(event: event)
        }
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                       object: nil, queue: .main) { [weak self] _ in
            self?.clearContext()
        }
        // Клик мышкой = пользователь больше не печатает + меняет место/контекст ввода.
        // Чистим всё включая recentWords (контекст языка).
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.clearContext()
            Log.buffer.info("context cleared by mouse click")
        }
    }

    private func handle(event: CGEvent) {
        if muted { return }
        // Защита: в полях паролей буфер не работает
        if IsSecureEventInputEnabled() {
            currentWord = ""
            return
        }

        lastActivity = Date()
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))

        // Backspace — удаляем последний символ
        if keyCode == 51 {
            if !currentWord.isEmpty {
                currentWord.removeLast()
            }
            return
        }

        // Стрелки / Forward Delete / Escape — пользователь редактирует или навигирует.
        // Молча сбрасываем накопление, без триггера авто-замены.
        let arrowKeys: Set<Int> = [123, 124, 125, 126]  // ←→↓↑
        if arrowKeys.contains(keyCode) || keyCode == 117 || keyCode == 53 {
            currentWord = ""
            return
        }

        // Tab / Return — фиксируем как последнее слово (для ручного хоткея),
        // но НЕ запускаем авто-замену.
        if keyCode == 48 || keyCode == 36 {
            if !currentWord.isEmpty {
                lastWord = currentWord
                lastTrigger = nil
                currentWord = ""
            }
            return
        }

        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            // Cmd+что-то / Ctrl+что-то — это шорткат (Cmd+A, Cmd+C, и т.п.).
            // Полностью обнуляем буфер — пользователь уже не «пишет слово».
            clear()
            return
        }

        // Используем UCKeyTranslate чтобы обойти dead-key state. NSEvent.characters
        // на dead-key возвращает пусто, а нам нужен сам символ.
        guard let ch = KeyTranslator.character(for: event) else { return }

        // Считаем «буквенными»: настоящие буквы, плюс все EN-side символы которые
        // на той же физической клавише дают русскую букву (`;`=ж, `[`=х, `]`=ъ, ' = э,
        // `,`=б, `.`=ю, `\`=ё). Они часто попадают по ошибке промаха раскладкой.
        // autoConvert разберётся: если итог не валидное слово — оставит как есть.
        let layoutMappedChars: Set<Character> = [";", "[", "]", "`", "\\", "'", ",", "."]
        if ch.isLetter || ch == "-" || layoutMappedChars.contains(ch) {
            currentWord.append(ch)
        } else {
            flushAndReset(trigger: ch)
        }
    }

    private func flushAndReset(trigger: Character?) {
        if !currentWord.isEmpty {
            let completed = currentWord
            lastWord = completed
            lastTrigger = trigger
            currentWord = ""
            // Запоминаем в ring buffer для контекста
            recentWords.append(completed)
            if recentWords.count > recentWordsCapacity {
                recentWords.removeFirst()
            }
            let ctx = self.dominantContext
            Log.buffer.info("flush: lastWord=\(completed, privacy: .public) trigger=\(String(describing: trigger), privacy: .public) ctx=\(String(describing: ctx), privacy: .public)")
            if let trigger = trigger {
                onWordCompleted?(completed, trigger)
            }
        }
    }

    func commitCurrent() {
        flushAndReset(trigger: nil)
    }

    func clear() {
        currentWord = ""
        lastWord = ""
        lastTrigger = nil
    }

    /// Полная очистка, включая контекст. Для перехода между «сессиями ввода»
    /// (клик мышкой, смена приложения).
    func clearContext() {
        clear()
        recentWords.removeAll()
    }
}


// MARK: - ModifierHotkey

/// Описание модификатор-only хоткея (только нажатие и отпускание модификатора, без других клавиш).
struct ModifierHotkey: Codable, Equatable {
    /// Виртуальный код модификатора. См. KeyCode.swift / kVK_*
    /// 58 = leftOption, 61 = rightOption, 55 = leftCommand, 54 = rightCommand,
    /// 56 = leftShift, 60 = rightShift, 59 = leftControl, 62 = rightControl
    var keyCode: Int

    var displayName: String {
        switch keyCode {
        case 58: return "⌥ (Option левый)"
        case 61: return "⌥ (Option правый)"
        case 55: return "⌘ (Command левый)"
        case 54: return "⌘ (Command правый)"
        case 56: return "⇧ (Shift левый)"
        case 60: return "⇧ (Shift правый)"
        case 59: return "⌃ (Control левый)"
        case 62: return "⌃ (Control правый)"
        default: return "modifier(\(keyCode))"
        }
    }

    static let leftOption = ModifierHotkey(keyCode: 58)
}


/// Детектор «нажал модификатор и отпустил без других клавиш».
final class ModifierHotkeyMonitor {

    private struct Tracking {
        let keyCode: Int
        let pressTime: Date
        var contaminated: Bool  // была нажата другая клавиша во время удержания
    }

    private var tracking: Tracking?
    private var bindings: [Int: () -> Void] = [:]
    private let timeout: TimeInterval = 0.5  // макс. время удержания для «короткого» нажатия

    func install() {
        EventMonitor.shared.onFlagsChanged { [weak self] event in
            self?.handleFlags(event: event)
        }
        EventMonitor.shared.onKeyDown { [weak self] _ in
            // Любое нажатие настоящей клавиши «загрязняет» удержание модификатора
            self?.tracking?.contaminated = true
        }
    }

    func bind(_ hotkey: ModifierHotkey, action: @escaping () -> Void) {
        bindings[hotkey.keyCode] = action
    }

    func unbindAll() {
        bindings.removeAll()
    }

    private func handleFlags(event: CGEvent) {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // Биты в flags для каждого модификатора
        let isPressed = isModifierPressed(keyCode: keyCode, flags: flags)

        if isPressed {
            // Нажали модификатор — стартуем трекинг (если ещё нет)
            if tracking?.keyCode != keyCode {
                tracking = Tracking(keyCode: keyCode, pressTime: Date(), contaminated: false)
            }
        } else {
            // Отпустили модификатор
            if let t = tracking, t.keyCode == keyCode {
                let held = Date().timeIntervalSince(t.pressTime)
                if !t.contaminated && held < timeout {
                    if let action = bindings[keyCode] {
                        DispatchQueue.main.async { action() }
                    }
                }
                tracking = nil
            }
        }
    }

    private func isModifierPressed(keyCode: Int, flags: CGEventFlags) -> Bool {
        // Проверяем что соответствующий бит сейчас установлен
        switch keyCode {
        case 58, 61: return flags.contains(.maskAlternate)
        case 55, 54: return flags.contains(.maskCommand)
        case 56, 60: return flags.contains(.maskShift)
        case 59, 62: return flags.contains(.maskControl)
        default: return false
        }
    }
}
