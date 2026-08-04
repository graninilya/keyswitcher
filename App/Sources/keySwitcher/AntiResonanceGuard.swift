import Foundation

/// Не даёт замене зациклиться.
///
/// Три сценария, каждый из которых приводит к бесконечной правке одного места:
/// обратная замена (A→B сразу после B→A), повтор той же замены подряд и просто
/// аномальная частота. Последнее — сеть безопасности на случай, если опознание
/// собственной синтетики где-то даст сбой.
final class AntiResonanceGuard {
    private struct Entry {
        let from: String
        let to: String
        let at: CFAbsoluteTime
    }

    private var history: [Entry] = []
    private let inverseWindow: CFAbsoluteTime = 2.0
    private let rateWindow: CFAbsoluteTime = 1.0
    private let maxPerWindow = 8

    func allow(from: String, to: String) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        history.removeAll { now - $0.at > max(inverseWindow, rateWindow) }

        let f = from.lowercased(), t = to.lowercased()

        if history.contains(where: { now - $0.at <= inverseWindow
                                  && $0.from.lowercased() == t
                                  && $0.to.lowercased() == f }) {
            Log.auto.error("anti-resonance: обратная замена подавлена")
            return false
        }

        // Повтор ОДНОЙ И ТОЙ ЖЕ пары не блокируем: человек пишет «не не», «да да»,
        // и второе слово имеет полное право сконвертироваться. Зацикливание ловят
        // проверка на обратную замену и ограничитель частоты.
        if history.filter({ now - $0.at <= rateWindow }).count >= maxPerWindow {
            Log.auto.fault("anti-resonance: превышена частота замен — подавляю")
            return false
        }

        history.append(Entry(from: from, to: to, at: now))
        return true
    }

    func reset() {
        history.removeAll()
    }
}
