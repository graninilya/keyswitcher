import Foundation

/// Прогрев тяжёлых синглтонов до первого нажатия.
///
/// `LayoutMap.init` читает ~4.7 МБ JSON и делает 512 UCKeyTranslate в LayoutResolver.
/// Без прогрева это выполнялось лениво — на первом же завершённом слове, то есть
/// внутри колбэка event tap. Система вырубает tap, если колбэк не вернулся вовремя,
/// и нажатия за этот промежуток теряются безвозвратно.
enum Warm {
    private static let lock = NSLock()
    private static var ready = false

    static var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return ready
    }

    static func prepare() {
        DispatchQueue.global(qos: .userInitiated).async {
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = LayoutMap.shared
            SoundFeedback.preload()
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            lock.lock(); ready = true; lock.unlock()
            Log.perf.info("прогрев завершён за \(String(format: "%.0f", ms), privacy: .public) мс")
        }
    }
}
