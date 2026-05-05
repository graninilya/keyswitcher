import Foundation
import Sparkle

/// Биндинг для SwiftUI поверх SPUUpdater. Sparkle сам сохраняет состояние
/// в UserDefaults — мы только проксируем чтение/запись и notify SwiftUI.
final class UpdaterPreferences: ObservableObject {
    static let shared = UpdaterPreferences()

    private var updater: SPUUpdater {
        UpdaterController.shared.controller.updater
    }

    @Published var autoCheckEnabled: Bool {
        didSet { updater.automaticallyChecksForUpdates = autoCheckEnabled }
    }

    @Published var autoInstallEnabled: Bool {
        didSet { updater.automaticallyDownloadsUpdates = autoInstallEnabled }
    }

    private init() {
        let u = UpdaterController.shared.controller.updater
        self.autoCheckEnabled = u.automaticallyChecksForUpdates
        self.autoInstallEnabled = u.automaticallyDownloadsUpdates
    }

    var lastCheckText: String? {
        guard let date = updater.lastUpdateCheckDate else { return nil }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.unitsStyle = .short
        return "Последняя проверка: " + f.localizedString(for: date, relativeTo: Date())
    }
}
