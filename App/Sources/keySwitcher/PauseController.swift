import Foundation

/// Временная пауза на N минут — чтобы не выключать приложение целиком ради
/// одного созвона или сессии в чужой раскладке.
final class PauseController: ObservableObject {
    static let shared = PauseController()

    @Published private(set) var pausedUntil: Date?

    private var timer: Timer?

    private init() {}

    var isPaused: Bool {
        guard let until = pausedUntil else { return false }
        if Date() >= until {
            // Срок вышел, а таймер мог не сработать (сон системы) — снимаем на месте.
            DispatchQueue.main.async { [weak self] in self?.resume() }
            return false
        }
        return true
    }

    var remainingDescription: String? {
        guard let until = pausedUntil, until > Date() else { return nil }
        return Stats.humanDuration(until.timeIntervalSinceNow)
    }

    func pause(minutes: Int) {
        let until = Date().addingTimeInterval(TimeInterval(minutes * 60))
        pausedUntil = until
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            self?.resume()
        }
        Log.hotkey.info("пауза на \(minutes, privacy: .public) мин")
    }

    func resume() {
        guard pausedUntil != nil else { return }
        pausedUntil = nil
        timer?.invalidate()
        timer = nil
        Log.hotkey.info("пауза снята")
    }
}
