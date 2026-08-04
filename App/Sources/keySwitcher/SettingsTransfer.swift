import AppKit

/// Перенос настроек между машинами и резервная копия.
/// Ключ от AI не экспортируется — он живёт в Keychain и не должен уезжать в файл.
enum SettingsTransfer {

    private struct Payload: Codable {
        var version: Int = 1
        var exportedAt: Date
        var soundName: String
        var autoConvertEnabled: Bool
        var hideStatusIcon: Bool
        var aiEnabled: Bool
        var aiWorkerURL: String
        var aiModel: String
        var customApiEndpoint: String
        var customApiModel: String
        var ignoredAutoSwap: [String]
        var forceSwapWords: [String]
        var appRules: [String: String]
        var hotkeys: Data?
    }

    static func export(to url: URL) throws {
        let s = Settings.shared
        let payload = Payload(
            exportedAt: Date(),
            soundName: s.soundName,
            autoConvertEnabled: s.autoConvertEnabled,
            hideStatusIcon: s.hideStatusIcon,
            aiEnabled: s.aiEnabled,
            aiWorkerURL: s.aiWorkerURL,
            aiModel: s.aiModel,
            customApiEndpoint: s.customApiEndpoint,
            customApiModel: s.customApiModel,
            ignoredAutoSwap: Array(s.ignoredAutoSwap).sorted(),
            forceSwapWords: Array(s.forceSwapWords).sorted(),
            appRules: AppRules.shared.rules.mapValues { $0.rawValue },
            hotkeys: UserDefaults.standard.data(forKey: "hotkeys")
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(payload).write(to: url)
        Log.hotkey.info("настройки выгружены")
    }

    /// Списки объединяются, а не заменяются: импорт не должен молча стирать то,
    /// чему приложение уже научилось на этой машине.
    static func importFrom(_ url: URL) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let p = try decoder.decode(Payload.self, from: Data(contentsOf: url))

        let s = Settings.shared
        s.soundName = p.soundName
        s.autoConvertEnabled = p.autoConvertEnabled
        s.hideStatusIcon = p.hideStatusIcon
        s.aiEnabled = p.aiEnabled
        s.aiWorkerURL = p.aiWorkerURL
        s.aiModel = p.aiModel
        s.customApiEndpoint = p.customApiEndpoint
        s.customApiModel = p.customApiModel
        // В файле регистр мог не сохраниться, а сравнение в детекторе идёт по нижнему.
        s.ignoredAutoSwap.formUnion(p.ignoredAutoSwap.map { $0.lowercased() })
        s.forceSwapWords.formUnion(p.forceSwapWords.map { $0.lowercased() })

        for (bundle, raw) in p.appRules {
            if let mode = AppMode(rawValue: raw) {
                AppRules.shared.setMode(mode, for: bundle)
            }
        }
        // Записываем только то, что разобралось: нечитаемый блоб в UserDefaults
        // молча сбросил бы хоткеи к умолчаниям при следующем запуске.
        if let h = p.hotkeys, let cfg = try? JSONDecoder().decode(HotkeyConfig.self, from: h) {
            s.hotkeys = cfg
        }
        Log.hotkey.info("настройки загружены")
    }

    // MARK: - Диалоги

    static func runExportPanel() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "keyswitcher-settings.json"
        panel.allowedContentTypes = [.json]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try export(to: url) } catch { present(error) }
        }
    }

    static func runImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try importFrom(url) } catch { present(error) }
        }
    }

    static func saveDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "keyswitcher-diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try AppHealth.diagnosticsReport().write(to: url, atomically: true, encoding: .utf8)
            } catch { present(error) }
        }
    }

    private static func present(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Не получилось"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
