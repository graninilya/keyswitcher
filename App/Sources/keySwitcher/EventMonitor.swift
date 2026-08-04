import AppKit
import Carbon.HIToolbox

final class EventMonitor {
    static let shared = EventMonitor()

    typealias KeyHandler = (CGEvent) -> Void
    typealias FlagsHandler = (CGEvent) -> Void

    /// Массив, а не словарь: порядок обхода словаря не определён, а обработчики
    /// не независимы — буфер должен обновиться раньше тех, кто читает его состояние.
    /// Порядок = порядок регистрации в AppDelegate.startMonitorsOrPoll().
    private var keyHandlers: [(id: UUID, run: KeyHandler)] = []
    private var flagsHandlers: [(id: UUID, run: FlagsHandler)] = []

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
        // Живой пробник для меню: «работает ли перехват сейчас», а не «стартовал когда-то».
        AppHealth.isEngineLive = { [weak self] in
            guard let t = self?.tap else { return false }
            return CGEvent.tapIsEnabled(tap: t)
        }
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

    /// Система вырубает tap, если колбэк не вернулся вовремя. Инструментуем, чтобы
    /// увидеть приближение к порогу до того, как начнут теряться нажатия.
    private static let slowCallbackMs: Double = 15

    private func dispatch(type: CGEventType, event: CGEvent) {
        let t0 = CFAbsoluteTimeGetCurrent()
        defer {
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            if ms > Self.slowCallbackMs {
                Log.perf.error("медленный колбэк tap: \(String(format: "%.1f", ms), privacy: .public) мс — риск отключения")
            }
        }

        // Наша собственная синтетика (backspace'ы и вставки) возвращается сюда через
        // .cghidEventTap. Отсеиваем её ДО обработчиков: иначе буфер съедал бы свои же
        // нажатия, а ModifierHotkeyMonitor помечал бы удерживаемый модификатор как
        // «загрязнённый» — из-за чего ⌥-хоткей после каждой замены молча не срабатывал.
        if type == .keyDown || type == .flagsChanged, SyntheticTag.isSynthetic(event) {
            return
        }

        switch type {
        case .keyDown:
            for h in keyHandlers { h.run(event) }
        case .flagsChanged:
            for h in flagsHandlers { h.run(event) }
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            let reason = type == .tapDisabledByTimeout ? "таймаут колбэка" : "ввод пользователя"
            Log.perf.fault("tap отключён системой (\(reason, privacy: .public)) — нажатия за этот промежуток потеряны")
            // Пока tap был мёртв, нажатия дошли до экрана мимо нас: буфер разошёлся
            // с реальным текстом, и следующая замена стёрла бы неверное число символов.
            KeystrokeBuffer.shared.clearContext()
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
        default:
            break
        }
    }

    @discardableResult
    func onKeyDown(_ handler: @escaping KeyHandler) -> UUID {
        let id = UUID()
        keyHandlers.append((id: id, run: handler))
        return id
    }

    @discardableResult
    func onFlagsChanged(_ handler: @escaping FlagsHandler) -> UUID {
        let id = UUID()
        flagsHandlers.append((id: id, run: handler))
        return id
    }

    func remove(_ id: UUID) {
        keyHandlers.removeAll { $0.id == id }
        flagsHandlers.removeAll { $0.id == id }
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

    /// Растёт на каждом реальном нажатии. Отложенная замена сверяется с этим счётчиком,
    /// чтобы не переписывать текст, который пользователь уже успел продолжить.
    private(set) var sequence: UInt64 = 0

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

    private var secureInputWasOn = false

    /// Порог дребезга. Поднимать не следует: съесть настоящую двойную букву хуже,
    /// чем пропустить дребезг — первое портит текст молча, второе человек видит сам.
    private static let chatterWindow: CFAbsoluteTime = 0.030
    private var lastKeyCode: Int = -1
    private var lastKeyAt: CFAbsoluteTime = 0

    /// Привести модель к тому, что реально на экране после замены, сделанной в обход
    /// обычного набора (выделение, полировка, откат). Без этого следующая замена
    /// считает backspace'ы по устаревшему состоянию.
    func syncAfterExternalReplacement(word: String, tail: String) {
        lastWord = word
        lastTail = tail
        lastTrigger = nil
        currentWord = ""
        lastSegment = ""
        if !recentWords.isEmpty {
            recentWords[recentWords.count - 1] = word
        }
    }

    var onWordCompleted: ((String, Character) -> Void)?

    private init() {}

    private var installed = false

    func install() {
        guard !installed else { return }
        installed = true
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
        // В полях паролей буфер не работает — чтобы не утечь пароль через recentWords/lastWord.
        // На обоих переходах чистим целиком: пока шёл ввод пароля, каретка ушла, и
        // сохранённые lastWord/lastTail описывают текст в другом месте экрана.
        let secureNow = SecureInput.isEnabled
        if secureNow != secureInputWasOn {
            secureInputWasOn = secureNow
            clearContext()
            Log.buffer.info("secure input \(secureNow ? "включён" : "выключен", privacy: .public) — буфер очищен")
        }
        if secureNow { return }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))

        // Дребезг механической клавиатуры: одно нажатие приходит дважды. 30 мс — это
        // 33 повтора той же клавиши в секунду, человек так не печатает даже на «сс».
        // Автоповтор исключаем по флагу события, а не по времени: его интервал
        // настраивается и попадает в то же окно.
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            let now = CFAbsoluteTimeGetCurrent()
            if keyCode == lastKeyCode, now - lastKeyAt < Self.chatterWindow {
                Log.buffer.info("дребезг: повтор клавиши быстрее \(Int(Self.chatterWindow * 1000)) мс — игнорирую")
                // Окно НЕ продлеваем: иначе серия быстрых событий глохла бы целиком,
                // а не только её дубликат.
                return
            }
            lastKeyCode = keyCode
            lastKeyAt = now
        }

        sequence &+= 1

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

        // Стрелки / Forward Delete / Escape — каретка уехала. Чистим ВСЁ, а не только
        // currentWord: иначе ⌥ посчитает backspace'ы по lastWord/lastTail от прежнего
        // места и сотрёт чужой текст у нового курсора.
        let arrowKeys: Set<Int> = [123, 124, 125, 126]
        if arrowKeys.contains(keyCode) || keyCode == 117 || keyCode == 53 {
            clearContext()
            return
        }

        // Tab / Return — фиксируем lastWord (для ручного хоткея), но без авто-замены.
        // Хвост обнуляем: он остался от ПРЕДЫДУЩЕГО слова и на экране к новому не примыкает.
        if keyCode == 48 || keyCode == 36 {
            // Tab/Return часто и есть переход в поле пароля, а кэш secure-input живёт
            // короткое время — заставляем перепроверить до следующего символа.
            SecureInput.forceRecheck()
            if !currentWord.isEmpty {
                lastWord = currentWord
                lastTrigger = nil
                currentWord = ""
            }
            lastTail = ""
            lastSegment = ""
            return
        }

        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            clearContext()
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
            // dominantContext здесь не читаем: его AX-ветка делает два синхронных
            // межпроцессных вызова и копирует весь текст фокусированного поля.
            // Ради строки лога это неприемлемо.
            Log.buffer.info("flush: lastWord=\(Log.redact(completed), privacy: .public) trigger=\(Log.redact(trigger), privacy: .public)")
            if let trigger = trigger {
                // Замена уходит из колбэка tap: дальше идут словари, TIS-переключение,
                // звук и десятки синтетических событий. Внутри колбэка это упирается
                // в системный дедлайн, после которого tap отключают вместе с вводом.
                let stamp = sequence
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    // Пользователь успел напечатать ещё — слово уже не последнее на
                    // экране, и backspace'ы стёрли бы не его. Пропустить безопаснее.
                    guard self.sequence == stamp else {
                        Log.auto.info("замена отменена: ввод продолжился (Δ\(self.sequence - stamp))")
                        return
                    }
                    self.onWordCompleted?(completed, trigger)
                }
            }
        }
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
    private var installed = false

    func install() {
        guard !installed else { return }
        installed = true
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
