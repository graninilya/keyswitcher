import Foundation

/// Сетевой слой для AI-запросов.
///
/// Раньше использовался `URLSession.shared`: общий пул соединений и общий кэш.
/// Стоило одному соединению попасть в нерабочее состояние (провайдер оборвал,
/// DNS отдал заблокированный адрес) — оно переиспользовалось снова и снова, и
/// полировка «переставала работать до перезапуска приложения».
///
/// Здесь сессия своя, без кэша, и её можно выбросить целиком после сетевой ошибки:
/// следующий запрос пойдёт по новым соединениям и с новым резолвом имени.
enum LLMTransport {
    private static let lock = NSLock()
    private static var session: URLSession = makeSession()
    private static var consecutiveFailures = 0

    private static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        cfg.httpShouldUsePipelining = false
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }

    static func current() -> URLSession {
        lock.lock(); defer { lock.unlock() }
        return session
    }

    /// Выбрасывает сессию вместе со всеми её соединениями.
    static func reset(reason: String) {
        lock.lock()
        let old = session
        session = makeSession()
        consecutiveFailures = 0
        lock.unlock()

        old.invalidateAndCancel()
        Log.hotkey.info("сетевая сессия пересоздана: \(reason, privacy: .public)")
    }

    static func noteSuccess() {
        lock.lock(); consecutiveFailures = 0; lock.unlock()
    }

    /// Две неудачи подряд — соединение, скорее всего, отравлено. Не ждём перезапуска.
    static func noteFailure() {
        lock.lock()
        consecutiveFailures += 1
        let shouldReset = consecutiveFailures >= 2
        lock.unlock()
        if shouldReset { reset(reason: "две сетевые ошибки подряд") }
    }
}
