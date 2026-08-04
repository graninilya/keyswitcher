import Carbon
import Foundation

/// Кэш данных текущей раскладки.
///
/// KeyTranslator дёргал TISCopyCurrentKeyboardInputSource + TISGetInputSourceProperty
/// и копировал uchr-блоб на КАЖДОЕ нажатие, внутри колбэка event tap. Раскладка меняется
/// несопоставимо реже, чем печатает человек, поэтому держим блоб у себя.
///
/// Инвалидация: системное уведомление о смене источника ввода, плюс явный сброс после
/// нашего собственного TISSelectInputSource (уведомление приходит с задержкой, а мы
/// обязаны декодировать следующее нажатие уже новой раскладкой). TTL — страховка.
enum KeyboardLayoutCache {
    private static let lock = NSLock()
    private static var layoutData: Data?
    private static var loadedAt: CFAbsoluteTime = 0
    /// Короткий намеренно: TISSelectInputSource применяется не мгновенно, и слишком
    /// долгий кэш закрепил бы прежнюю раскладку уже после переключения.
    private static let ttl: CFAbsoluteTime = 0.3
    private static var observing = false

    static func startObserving() {
        lock.lock()
        guard !observing else { lock.unlock(); return }
        observing = true
        lock.unlock()

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { _ in invalidate() }
    }

    static func invalidate() {
        lock.lock()
        layoutData = nil
        lock.unlock()
    }

    /// Повторный сброс с задержкой: сразу после TISSelectInputSource система ещё может
    /// отдавать прежний блоб, и мы закэшировали бы именно его.
    static func invalidateAfterSwitch() {
        invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { invalidate() }
    }

    static func currentLayoutData() -> Data? {
        let now = CFAbsoluteTimeGetCurrent()

        lock.lock()
        if let cached = layoutData, now - loadedAt < ttl {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data

        lock.lock()
        layoutData = data
        loadedAt = now
        lock.unlock()
        return data
    }
}
