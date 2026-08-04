import AppKit

/// Режим работы в конкретном приложении.
enum AppMode: String, Codable, CaseIterable {
    /// Обычная работа.
    case normal
    /// Только ручные хоткеи, автозамена молчит. Для терминалов и IDE, где
    /// «слово» часто оказывается командой или идентификатором.
    case manualOnly
    /// Не трогать вообще.
    case off

    var title: String {
        switch self {
        case .normal:     return "Обычный"
        case .manualOnly: return "Только по хоткею"
        case .off:        return "Выключено"
        }
    }
}

/// Правила по приложениям.
///
/// Активное приложение опрашивается через NSWorkspace — вызов не из дешёвых, поэтому
/// значение кэшируется и пересчитывается по уведомлению о смене, а не на каждое слово.
final class AppRules: ObservableObject {
    static let shared = AppRules()

    @Published private(set) var rules: [String: AppMode] {
        didSet { persist(); recomputeCurrent() }
    }

    /// Публикуемые: список в настройках показывает активную программу и должен
    /// обновляться при переключении, а не только при правке правил.
    @Published private(set) var currentMode: AppMode = .normal
    @Published private(set) var currentBundleID: String = ""
    @Published private(set) var currentAppName: String = ""

    /// Только терминалы. Редакторы кода сюда НЕ входят намеренно: в них пишут не
    /// только код — чаты с ассистентом, коммиты, документацию, — и молча выключенная
    /// автозамена там выглядит как поломка. Кому мешает, тот добавит сам.
    private static let defaultManualOnly: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "co.zeit.hyper",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "io.alacritty",
    ]

    /// Раздавались автоматически в первой версии этой функции — снимаем, если
    /// пользователь их не трогал.
    private static let mistakenlySeeded: Set<String> = [
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",
        "com.jetbrains.intellij",
        "com.jetbrains.pycharm",
        "com.jetbrains.WebStorm",
        "com.apple.dt.Xcode",
        "io.zed.Zed",
        "com.sublimetext.4",
    ]

    private init() {
        if let raw = UserDefaults.standard.dictionary(forKey: "appRules") as? [String: String] {
            rules = raw.compactMapValues { AppMode(rawValue: $0) }
        } else {
            rules = [:]
        }
        recomputeCurrent()
    }

    func startObserving() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.recomputeCurrent() }
        // Уведомление не приходит для программы, которая уже была активна при
        // запуске: без этого автозамена работала бы в терминале до первого ⌘-Tab.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.recomputeCurrent() }
        }
        recomputeCurrent()
    }

    /// Снять режим с редакторов, которые прошлая версия добавляла автоматически.
    /// Трогаем только те, что остались ровно в засеянном состоянии — если человек
    /// сам выставил там режим, это его решение.
    func undoMistakenSeed() {
        guard !UserDefaults.standard.bool(forKey: "appRules.unseededEditors") else { return }
        UserDefaults.standard.set(true, forKey: "appRules.unseededEditors")

        var next = rules
        var removed = 0
        for id in Self.mistakenlySeeded where next[id] == .manualOnly {
            next.removeValue(forKey: id)
            removed += 1
        }
        guard removed > 0 else { return }
        rules = next
        Log.hotkey.info("правила по программам: снят авто-режим с \(removed, privacy: .public) редакторов")
    }

    /// Предзаполнить список терминалами, которые реально стоят у пользователя.
    /// Только установленные — иначе настройки превращаются в свалку.
    func seedDefaultsIfNeeded() {
        // Отдельный ключ: прошлая версия успела отметить засев старым списком,
        // куда ошибочно входили редакторы. Терминалы должны раздаться заново.
        guard !UserDefaults.standard.bool(forKey: "appRules.seededTerminals") else { return }
        UserDefaults.standard.set(true, forKey: "appRules.seededTerminals")

        DispatchQueue.global(qos: .utility).async {
            let installed = Self.defaultManualOnly.filter {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
            }
            guard !installed.isEmpty else { return }
            DispatchQueue.main.async {
                var merged = self.rules
                for id in installed where merged[id] == nil {
                    merged[id] = .manualOnly
                }
                self.rules = merged
                Log.hotkey.info("правила по приложениям: предзаполнено \(installed.count)")
            }
        }
    }

    func setMode(_ mode: AppMode, for bundleID: String) {
        var next = rules
        if mode == .normal {
            next.removeValue(forKey: bundleID)
        } else {
            next[bundleID] = mode
        }
        rules = next
    }

    func mode(for bundleID: String) -> AppMode {
        rules[bundleID] ?? .normal
    }

    /// Отображаемое имя по идентификатору — для списка в настройках.
    static func displayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return FileManager.default.displayName(atPath: url.path)
    }

    private func recomputeCurrent() {
        let app = NSWorkspace.shared.frontmostApplication
        let id = app?.bundleIdentifier ?? ""
        // Собственное окно настроек активируется поверх — но правило пользователь
        // хочет задать для той программы, где печатает, а не для нас.
        guard id != Bundle.main.bundleIdentifier else { return }
        currentBundleID = id
        currentAppName = app?.localizedName ?? ""
        currentMode = rules[id] ?? .normal
    }

    private func persist() {
        UserDefaults.standard.set(rules.mapValues { $0.rawValue }, forKey: "appRules")
    }
}
