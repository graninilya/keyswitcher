import CoreGraphics
import Foundation

/// Опознание собственных синтетических событий.
///
/// Наши backspace'ы и вставки уходят в `.cghidEventTap` — ниже session-тапа, поэтому
/// возвращаются в наш же колбэк. Раньше их «прятали» окном в 200 мс: на это время
/// буфер переставал принимать что-либо. Но окно не различает источник — реальные
/// нажатия за эти миллисекунды попадали на экран и терялись для модели, после чего
/// следующая замена считала неверное число символов и портила текст.
///
/// Метка в `.eventSourceUserData` решает это точно: своё видно по признаку, а не по времени.
enum SyntheticTag {
    static let magic: Int64 = 0x51_4B_42_01   // 'QKB' + версия

    private static let lock = NSLock()
    private static var posted = 0
    private static var observed = 0
    private static var verificationScheduled = false

    /// Если метка вдруг не переживёт путь HID → session, буфер начнёт съедать
    /// собственные backspace'ы. Это тихая порча текста, поэтому проверяем факт
    /// доставки и при провале возвращаемся к старому окну.
    private(set) static var unreliable = false

    static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: magic)
        lock.lock()
        posted += 1
        let needSchedule = !verificationScheduled
        if needSchedule { verificationScheduled = true }
        lock.unlock()

        if needSchedule { scheduleVerification() }
    }

    static func isSynthetic(_ event: CGEvent) -> Bool {
        guard event.getIntegerValueField(.eventSourceUserData) == magic else { return false }
        lock.lock(); observed += 1; lock.unlock()
        return true
    }

    private static func scheduleVerification() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            lock.lock()
            let p = posted, o = observed
            lock.unlock()
            guard p > 0, o == 0 else {
                Log.perf.info("метка синтетики подтверждена (отправлено \(p, privacy: .public), опознано \(o, privacy: .public))")
                return
            }
            lock.lock(); unreliable = true; lock.unlock()
            Log.perf.fault("метка синтетики НЕ возвращается (отправлено \(p, privacy: .public)) — включаю запасной режим окна")
        }
    }
}
