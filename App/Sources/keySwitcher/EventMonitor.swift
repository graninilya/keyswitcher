import AppKit
import Carbon.HIToolbox

final class EventMonitor {
    static let shared = EventMonitor()

    typealias KeyHandler = (CGEvent) -> Void
    typealias FlagsHandler = (CGEvent) -> Void

    private var keyHandlers: [UUID: KeyHandler] = [:]
    private var flagsHandlers: [UUID: FlagsHandler] = [:]

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private init() {}

    /// Возвращает false если нет AX permission.
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


final class KeystrokeBuffer {
    static let shared = KeystrokeBuffer()

    private(set) var currentWord: String = ""
    private(set) var lastWord: String = ""
    private(set) var lastTrigger: Character? = nil
    /// Все символы между концом lastWord и началом нового слова (включая trigger,
    /// последующие пробелы/знаки препинания). Нужен чтобы корректно посчитать
    /// сколько backspace'ов сделать перед re-typing.
    private(set) var lastTail: String = ""
    /// Сырой сегмент с момента последнего пробела/таба/новой строки — включает
    /// цифры, пунктуацию и буквы. Нужен для случаев типа `0ю2ю8` где обычный
    /// lastWord/lastTail видит только `ю` + `8`, а юзер хочет свапнуть весь
    /// сегмент → `0.2.8`.
    private(set) var lastSegment: String = ""
    private(set) var lastActivity: Date = .distantPast

    private var recentWords: [String] = []
    private let recentWordsCapacity = 5

    /// Смотрит только на последние ~3 слова — иначе слабая реакция на смену языка.
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

        return ContextResolver.dominantLanguageInFocusedElement()
    }

    func replaceLastInHistory(with converted: String) {
        guard !recentWords.isEmpty else { return }
        recentWords[recentWords.count - 1] = converted
    }

    var historySnapshot: [String] { recentWords }

    func replaceFromEnd(offset: Int, with converted: String) {
        guard recentWords.count > offset, offset >= 0 else { return }
        recentWords[recentWords.count - 1 - offset] = converted
    }

    /// AutoConverter выставляет true чтобы не съедать собственные синтетические нажатия.
    var muted: Bool = false

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
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.clearContext()
            Log.buffer.info("context cleared by mouse click")
        }
    }

    private func handle(event: CGEvent) {
        if muted { return }
        // В полях паролей буфер не работает — чтобы не утечь пароль через recentWords/lastWord
        if IsSecureEventInputEnabled() {
            currentWord = ""
            return
        }

        lastActivity = Date()
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))

        if keyCode == 51 {
            if !currentWord.isEmpty {
                currentWord.removeLast()
            } else if !lastTail.isEmpty {
                // currentWord уже пуст — backspace ест последний символ tail
                // (например после ` 5:` → backspace убирает `:`).
                lastTail.removeLast()
            }
            if !lastSegment.isEmpty {
                lastSegment.removeLast()
            }
            return
        }

        // Стрелки / Forward Delete / Escape — навигация/редактирование, не должны триггерить авто-замену
        let arrowKeys: Set<Int> = [123, 124, 125, 126]
        if arrowKeys.contains(keyCode) || keyCode == 117 || keyCode == 53 {
            currentWord = ""
            return
        }

        // Tab / Return — фиксируем lastWord (для ручного хоткея), но без авто-замены
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
            clear()
            return
        }

        // UCKeyTranslate — потому что NSEvent.characters на dead-key возвращает пусто
        guard let ch = KeyTranslator.character(for: event) else { return }

        // EN-side пунктуация (`;[]'\`\,.`) на той же физической клавише даёт русскую букву —
        // включаем в слово, чтобы автоконвертер мог распознать промах раскладки
        let layoutMappedChars: Set<Character> = [";", "[", "]", "`", "\\", "'", ",", "."]
        let isWhitespace = ch == " " || ch == "\t" || ch == "\n"
        if isWhitespace {
            lastSegment = ""
        } else {
            lastSegment.append(ch)
        }
        if ch.isLetter || ch == "-" || layoutMappedChars.contains(ch) {
            // Начало нового слова — сбрасываем накопленный tail
            if currentWord.isEmpty {
                lastTail = ""
            }
            currentWord.append(ch)
        } else {
            flushAndReset(trigger: ch)
            lastTail.append(ch)
        }
    }

    private func flushAndReset(trigger: Character?) {
        if !currentWord.isEmpty {
            let completed = currentWord
            lastWord = completed
            lastTrigger = trigger
            lastTail = ""
            currentWord = ""
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
        lastTail = ""
        lastSegment = ""
    }

    func clearContext() {
        clear()
        recentWords.removeAll()
    }
}


/// Хоткей в виде «нажал модификатор и отпустил без других клавиш».
struct ModifierHotkey: Codable, Equatable {
    /// kVK_* виртуальный код модификатора:
    /// 58/61 = Option L/R, 55/54 = Command L/R, 56/60 = Shift L/R, 59/62 = Control L/R
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
    static let rightOption = ModifierHotkey(keyCode: 61)
}


final class ModifierHotkeyMonitor {

    private struct Tracking {
        let keyCode: Int
        let pressTime: Date
        /// Была нажата другая клавиша во время удержания — отменяет срабатывание
        var contaminated: Bool
    }

    private var tracking: Tracking?
    private var bindings: [Int: () -> Void] = [:]
    private let timeout: TimeInterval = 0.5

    func install() {
        EventMonitor.shared.onFlagsChanged { [weak self] event in
            self?.handleFlags(event: event)
        }
        EventMonitor.shared.onKeyDown { [weak self] _ in
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

        let isPressed = isModifierPressed(keyCode: keyCode, flags: flags)

        if isPressed {
            if tracking?.keyCode != keyCode {
                tracking = Tracking(keyCode: keyCode, pressTime: Date(), contaminated: false)
            }
        } else {
            if let t = tracking, t.keyCode == keyCode {
                let held = Date().timeIntervalSince(t.pressTime)
                if !t.contaminated && held < timeout {
                    if let action = bindings[keyCode] {
                        Log.hotkey.info("modifier-hotkey kc=\(keyCode) held=\(String(format: "%.2f", held))s")
                        DispatchQueue.main.async { action() }
                    }
                }
                tracking = nil
            }
        }
    }

    private func isModifierPressed(keyCode: Int, flags: CGEventFlags) -> Bool {
        switch keyCode {
        case 58, 61: return flags.contains(.maskAlternate)
        case 55, 54: return flags.contains(.maskCommand)
        case 56, 60: return flags.contains(.maskShift)
        case 59, 62: return flags.contains(.maskControl)
        default: return false
        }
    }
}
