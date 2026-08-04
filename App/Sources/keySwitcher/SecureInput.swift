import AppKit
import Carbon.HIToolbox

/// Кэш состояния «активен ввод пароля».
///
/// IsSecureEventInputEnabled() вызывался на каждое нажатие внутри колбэка event tap,
/// а холодный вызов стоит десятки миллисекунд — этого достаточно, чтобы система сочла
/// колбэк зависшим и отключила tap.
///
/// TTL короткий намеренно: между попаданием в поле пароля и первым символом не должно
/// пройти больше одного окна, иначе пароль осядет в буфере. Дополнительно сбрасываем
/// кэш на всех событиях, которые предшествуют входу в такое поле.
enum SecureInput {
    private static let lock = NSLock()
    private static var cached = false
    private static var checkedAt: CFAbsoluteTime = 0
    private static let ttl: CFAbsoluteTime = 0.15
    private static var observing = false

    static var isEnabled: Bool {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        if now - checkedAt < ttl {
            let v = cached
            lock.unlock()
            return v
        }
        lock.unlock()

        let fresh = IsSecureEventInputEnabled()

        lock.lock()
        cached = fresh
        checkedAt = now
        lock.unlock()
        return fresh
    }

    static func forceRecheck() {
        lock.lock()
        checkedAt = 0
        lock.unlock()
    }

    /// Смена приложения и клик мышью — типичные предшественники входа в поле пароля.
    static func startObserving() {
        lock.lock()
        guard !observing else { lock.unlock(); return }
        observing = true
        lock.unlock()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { _ in forceRecheck() }

        NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { _ in forceRecheck() }
    }
}
