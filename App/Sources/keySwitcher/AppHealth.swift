import AppKit
import Carbon.HIToolbox

/// Отвечает на вопрос «работает ли перехват ПРЯМО СЕЙЧАС».
///
/// AXIsProcessTrusted() отвечает на другой — «выдавали ли разрешение когда-то».
/// Он кэшируется системой и остаётся true даже после того, как tap уже мёртв,
/// поэтому в меню показывать надо не его.
enum AppHealth {
    /// Живой пробник, выставляется EventMonitor'ом.
    static var isEngineLive: (() -> Bool)?

    enum State {
        case ok
        case noPermission
        case engineDown
        case paused(String)
        case disabled

        var title: String {
            switch self {
            case .ok:            return "Всё работает"
            case .noPermission:  return "Нужно разрешение системы"
            case .engineDown:    return "Не вижу нажатия — попробуй перезапустить"
            case .paused(let t): return "На паузе, ещё \(t)"
            case .disabled:      return "Выключен"
            }
        }

        var isProblem: Bool {
            switch self {
            case .ok, .paused, .disabled: return false
            case .noPermission, .engineDown: return true
            }
        }
    }

    static var state: State {
        if !Settings.shared.enabled { return .disabled }
        if let left = PauseController.shared.remainingDescription { return .paused(left) }
        guard AXIsProcessTrusted() else { return .noPermission }
        guard isEngineLive?() ?? false else { return .engineDown }
        return .ok
    }

    /// Сводка для отправки в поддержку — только техника, без текста пользователя.
    static func diagnosticsReport() -> String {
        let s = Settings.shared
        let stats = Stats.shared
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

        var lines: [String] = []
        lines.append("Q*Й \(version) (\(build))")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Состояние: \(state.title)")
        lines.append("")
        lines.append("Включено: \(s.enabled)")
        lines.append("Автозамена: \(s.autoConvertEnabled)")
        lines.append("AI: \(s.aiEnabled), свой endpoint: \(s.useCustomAPI)")
        lines.append("Звук: \(s.soundName.isEmpty ? "выкл" : s.soundName)")
        lines.append("Прогрев завершён: \(Warm.isReady)")
        lines.append("Метка синтетики ненадёжна: \(SyntheticTag.unreliable)")
        lines.append("")
        lines.append("Исключений: \(s.ignoredAutoSwap.count)")
        lines.append("Правил свапа: \(s.forceSwapWords.count)")
        lines.append("Правил по приложениям: \(AppRules.shared.rules.count)")
        lines.append("")
        lines.append("Замен авто: \(stats.autoConversions), вручную: \(stats.manualConversions)")
        lines.append("Откатов: \(stats.reverts), цепочкой: \(stats.retroWords)")
        lines.append("AI-правок: \(stats.polishRuns), транслитераций: \(stats.transliterations)")
        lines.append("")
        lines.append("Активное приложение: \(AppRules.shared.currentBundleID)")
        lines.append("Режим для него: \(AppRules.shared.currentMode.rawValue)")
        return lines.joined(separator: "\n")
    }
}
