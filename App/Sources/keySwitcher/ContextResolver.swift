import AppKit
import ApplicationServices

enum ContextResolver {

    /// AX-запрос синхронный и межпроцессный: по умолчанию ждёт ответа до 6 секунд.
    /// Зависшее приложение в фокусе означало бы зависший ввод у нас.
    private static let messagingTimeout: Float = 0.25

    private static let lock = NSLock()
    private static var cached: InputLanguage??
    private static var cachedAt: CFAbsoluteTime = 0
    /// Фокус может уехать без уведомления (Tab внутри окна) — держим верхнюю границу.
    private static let ttl: CFAbsoluteTime = 3.0
    private static var observing = false

    static func startObserving() {
        lock.lock()
        guard !observing else { lock.unlock(); return }
        observing = true
        lock.unlock()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { _ in invalidate() }

        NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { _ in invalidate() }
    }

    static func invalidate() {
        lock.lock(); cached = nil; lock.unlock()
    }

    /// Результат живёт до смены фокуса: язык уже набранного текста в поле не меняется
    /// от того, что пользователь напечатал ещё одну букву, а цена запроса высокая.
    static func dominantLanguageInFocusedElement() -> InputLanguage? {
        let now = CFAbsoluteTimeGetCurrent()

        lock.lock()
        if let c = cached, now - cachedAt < ttl { lock.unlock(); return c }
        lock.unlock()

        let value = query()

        lock.lock(); cached = .some(value); cachedAt = now; lock.unlock()
        return value
    }

    private static func query() -> InputLanguage? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, focusedRef != nil else { return nil }
        let element = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &valueRef
        ) == .success, let text = valueRef as? String, !text.isEmpty else {
            return nil
        }

        // Поле может содержать документ целиком — считаем по хвосту, он и есть контекст.
        let tail = text.count > 400 ? String(text.suffix(400)) : text

        var cyr = 0, lat = 0
        for ch in tail.unicodeScalars {
            switch ch.value {
            case 0x0410...0x044F, 0x0401, 0x0451: cyr += 1
            case 0x41...0x5A, 0x61...0x7A:        lat += 1
            default: break
            }
        }
        guard cyr + lat >= 3 else { return nil }
        if cyr > lat { return .russian }
        if lat > cyr { return .english }
        return nil
    }
}
