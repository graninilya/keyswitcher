import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var statusVisibilityObserver: NSObjectProtocol?
    private var hotkeys: HotkeyManager!
    private var modifierMonitor: ModifierHotkeyMonitor!
    private var converter: ClipboardConverter!
    private var settings: Settings { .shared }
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Warm.prepare()
        KeyboardLayoutCache.startObserving()
        SecureInput.startObserving()
        ContextResolver.startObserving()
        AppRules.shared.startObserving()
        AppRules.shared.undoMistakenSeed()
        AppRules.shared.seedDefaultsIfNeeded()

        converter = ClipboardConverter()
        hotkeys = HotkeyManager()
        modifierMonitor = ModifierHotkeyMonitor()

        applyStatusIconVisibility()
        statusVisibilityObserver = NotificationCenter.default.addObserver(
            forName: .qkbStatusIconVisibilityChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.applyStatusIconVisibility() }

        _ = UpdaterController.shared

        if OnboardingWindowController.shouldShow {
            // Первый запуск — показать наглядное вступление до запроса AX.
            OnboardingWindowController.shared.show()
        } else if settings.hideStatusIcon {
            // Иконка скрыта — единственный способ войти в настройки, кроме
            // переоткрытия .app — показать окно сразу при старте.
            SettingsWindowController.shared.show()
            ensureAccessibility()
        } else {
            ensureAccessibility()
            // Существующие юзеры после апдейта — однократное окошко со звездой.
            OnboardingWindowController.showStarPromptIfNeeded()
        }

        startMonitorsOrPoll()

        rebindHotkeys()

        settings.$hotkeys
            .dropFirst()
            .sink { [weak self] cfg in self?.rebindHotkeys(cfg) }
            .store(in: &cancellables)
        settings.$enabled
            .sink { [weak self] newValue in self?.updateStatusIcon(enabled: newValue) }
            .store(in: &cancellables)
    }

    /// Юзер открыл .app повторно (двойной клик из Applications, Spotlight) —
    /// показываем настройки. Особенно важно когда иконка в menu bar скрыта:
    /// это единственный способ вернуться.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            SettingsWindowController.shared.show()
        }
        return true
    }

    private func applyStatusIconVisibility() {
        if settings.hideStatusIcon {
            removeMenuBar()
        } else {
            setupMenuBar()
        }
    }

    private func removeMenuBar() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    private func setupMenuBar() {
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            // Страховка на случай отсутствия иконки в бандле
            button.title = "Q*Й"
            button.imagePosition = .imageOnly
        }

        let menu = NSMenu()
        menu.delegate = self  // состояние и счётчики обновляются при открытии

        // Состояние движка — отвечает на «работает ли прямо сейчас».
        let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusLine.identifier = NSUserInterfaceItemIdentifier("healthState")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        let savedLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        savedLine.identifier = NSUserInterfaceItemIdentifier("savedTime")
        savedLine.isEnabled = false
        menu.addItem(savedLine)

        menu.addItem(.separator())

        // Toggle включено
        let toggleItem = makeItem("Включено", action: #selector(toggleEnabled))
        toggleItem.identifier = NSUserInterfaceItemIdentifier("toggleEnabled")
        toggleItem.state = settings.enabled ? .on : .off
        menu.addItem(toggleItem)

        // Пауза на время
        let pauseItem = NSMenuItem(title: "Пауза", action: nil, keyEquivalent: "")
        pauseItem.identifier = NSUserInterfaceItemIdentifier("pause")
        pauseItem.image = menuIcon("pause.circle")
        let pauseMenu = NSMenu()
        for minutes in [15, 30, 60] {
            let item = NSMenuItem(title: "На \(minutes) мин", action: #selector(pauseFor(_:)), keyEquivalent: "")
            item.target = self
            item.tag = minutes
            pauseMenu.addItem(item)
        }
        pauseMenu.addItem(.separator())
        let resumeItem = NSMenuItem(title: "Продолжить", action: #selector(resumeFromPause), keyEquivalent: "")
        resumeItem.target = self
        resumeItem.identifier = NSUserInterfaceItemIdentifier("resume")
        pauseMenu.addItem(resumeItem)
        pauseItem.submenu = pauseMenu
        menu.addItem(pauseItem)

        menu.addItem(.separator())

        // Настройки + ⌘,
        let settingsItem = makeItem("Настройки…", action: #selector(openSettings),
                                    icon: "gearshape")
        settingsItem.keyEquivalent = ","
        settingsItem.keyEquivalentModifierMask = [.command]
        menu.addItem(settingsItem)

        // AX-разрешения — показываем только если не получены (динамически в menuWillOpen)
        let axItem = makeItem("Дать доступ Accessibility",
                              action: #selector(showAccessibilityHelp),
                              icon: "exclamationmark.triangle.fill")
        axItem.identifier = NSUserInterfaceItemIdentifier("axPermission")
        menu.addItem(axItem)

        menu.addItem(.separator())

        // Проверить обновления
        let updatesItem = NSMenuItem(title: "Проверить обновления…",
                                     action: #selector(UpdaterController.checkForUpdates(_:)),
                                     keyEquivalent: "")
        updatesItem.target = UpdaterController.shared
        updatesItem.image = menuIcon("arrow.down.circle")
        menu.addItem(updatesItem)

        // О программе
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let aboutItem = makeItem("Об Q*Й — \(version)", action: #selector(openAbout),
                                 icon: "info.circle")
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        // Выйти + ⌘Q
        let quitItem = makeItem("Выйти из Q*Й", action: #selector(quit),
                                icon: "power")
        quitItem.keyEquivalent = "q"
        quitItem.keyEquivalentModifierMask = [.command]
        menu.addItem(quitItem)

        statusItem.menu = menu
        updateStatusIcon()
    }

    private func makeItem(_ title: String, action: Selector, icon: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let icon = icon {
            item.image = menuIcon(icon)
        }
        return item
    }

    /// SF Symbol с консистентным размером для меню (16pt, regular).
    private func menuIcon(_ name: String) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
    }

    private func updateStatusIcon(enabled: Bool? = nil) {
        guard let item = statusItem, let button = item.button else { return }
        let isOn = enabled ?? settings.enabled

        // По идентификатору, а не по индексу: выше в меню появились строки состояния,
        // и галочка «Включено» уезжала на них.
        if let menu = item.menu,
           let toggleItem = menu.items.first(where: { $0.identifier?.rawValue == "toggleEnabled" }) {
            toggleItem.state = isOn ? .on : .off
        }

        if let image = Self.loadStatusBarIcon() {
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
            button.contentTintColor = isOn ? nil : .tertiaryLabelColor
        } else {
            button.image = nil
            button.title = isOn ? "Q*Й" : "Q*Й off"
            button.contentTintColor = isOn ? nil : .tertiaryLabelColor
        }
    }

    /// PDF в наших ресурсах — растр в обёртке (JPX), мылит на retina. Собираем
    /// NSImage из PNG @1x/@2x/@3x — macOS выберет нужный rep по плотности экрана.
    private static func loadStatusBarIcon() -> NSImage? {
        let pointSize = NSSize(width: 20, height: 22)
        let image = NSImage(size: pointSize)
        var anyLoaded = false
        for suffix in ["", "@2x", "@3x"] {
            guard let url = Bundle.main.url(forResource: "StatusIcon\(suffix)",
                                             withExtension: "png") else { continue }
            guard let data = try? Data(contentsOf: url),
                  let rep = NSBitmapImageRep(data: data) else { continue }
            rep.size = pointSize
            image.addRepresentation(rep)
            anyLoaded = true
        }
        guard anyLoaded else { return nil }
        image.isTemplate = true
        return image
    }

    /// Конфигурацию принимаем параметром: @Published публикует значение в willSet,
    /// поэтому подписчик, читающий settings.hotkeys, получал бы предыдущее — и новые
    /// хоткеи вступали бы в силу только со следующей правки.
    private func rebindHotkeys(_ config: HotkeyConfig? = nil) {
        let cfg = config ?? settings.hotkeys
        hotkeys.unregisterAll()
        modifierMonitor.unbindAll()

        bind(cfg.smartConvert,        action: { [weak self] in self?.smartConvert() })
        bind(cfg.forceSwap,           action: { [weak self] in self?.forceSwap() })
        bind(cfg.transliterate,       action: { [weak self] in self?.transliterate() })
        bind(cfg.polishText,          action: { [weak self] in self?.polishText() })
        bind(cfg.typography,          action: { [weak self] in self?.applyTypography() })
        bindToggleEnabled(cfg.toggleEnabled)
    }

    private func bind(_ binding: HotkeyBinding, action: @escaping () -> Void) {
        // Хоткеи работают в режиме «только по хоткею» — молчит там лишь автозамена.
        // Полностью выключено и пауза глушат и их.
        func allowed(_ enabled: Bool?) -> Bool {
            guard enabled == true else { return false }
            guard !PauseController.shared.isPaused else { return false }
            return AppRules.shared.currentMode != .off
        }
        switch binding {
        case .modifier(let m):
            modifierMonitor.bind(m) { [weak self] in
                guard allowed(self?.settings.enabled) else { return }
                action()
            }
        case .combo(let c):
            hotkeys.register(modifiers: c.modifiers, keyCodeRaw: UInt32(c.keyCode)) { [weak self] in
                guard allowed(self?.settings.enabled) else { return }
                action()
            }
        case .disabled:
            break
        }
    }

    /// Работает даже когда keySwitcher выключен — иначе нельзя было бы включить обратно.
    private func bindToggleEnabled(_ binding: HotkeyBinding) {
        switch binding {
        case .modifier(let m):
            modifierMonitor.bind(m) { [weak self] in self?.toggleEnabled() }
        case .combo(let c):
            hotkeys.register(modifiers: c.modifiers, keyCodeRaw: UInt32(c.keyCode)) { [weak self] in
                self?.toggleEnabled()
            }
        case .disabled:
            break
        }
    }

    @objc private func toggleEnabled() {
        settings.enabled.toggle()
    }

    private func logHotkey(_ name: String) {
        Log.hotkey.info("ACTION: \(name, privacy: .public)")
    }

    @objc private func smartConvert() {
        logHotkey("smartConvert")
        // Punto-style: повторное нажатие в окне ~5с откатывает последнюю замену
        if AutoConverter.shared.canToggle() {
            AutoConverter.shared.toggle()
            return
        }
        // Иначе — всегда принудительно свапаем. Пользователь жмёт Option потому что
        // знает: текущее слово/выделение в неправильной раскладке.
        converter.smartConvert { text in
            if text.contains(" ") || text.contains("\n") {
                if let multi = Self.convertMultiWord(text) { return multi }
            }
            let candidate = LayoutMap.shared.swap(text, preservePunct: true)
            return candidate != text ? candidate : nil
        }
    }

    private static func convertMultiWord(_ text: String) -> String? {
        let trailingPunctChars: Set<Character> = [",", ".", "!", "?", ";", ":", ")", "]", "}", "—", "-"]
        var result = ""
        var current = ""
        var anyChanged = false

        func swapWord(_ word: String) -> String {
            var trailCount = 0
            for ch in word.reversed() {
                if trailingPunctChars.contains(ch) { trailCount += 1 } else { break }
            }
            let core = String(word.prefix(word.count - trailCount))
            let trail = String(word.suffix(trailCount))
            guard !core.isEmpty else { return word }
            let swapped = LayoutMap.shared.swap(core, preservePunct: true)
            return swapped + trail
        }

        func flushWord() {
            if current.isEmpty { return }
            let conv = swapWord(current)
            if conv != current {
                result += conv
                anyChanged = true
            } else {
                result += current
            }
            current = ""
        }

        for ch in text {
            if ch == " " || ch == "\n" || ch == "\t" {
                flushWord()
                result.append(ch)
            } else {
                current.append(ch)
            }
        }
        flushWord()

        return anyChanged ? result : nil
    }

    @objc private func forceSwap() {
        logHotkey("forceSwap")
        converter.convertSelectionOnly { LayoutMap.shared.swap($0, preservePunct: true) }
    }

    @objc private func transliterate() {
        logHotkey("transliterate")
        converter.convertSelectionOnly { input in
            let out = Transliteration.apply(input)
            // Латиница возвращается как есть — считать это транслитерацией нельзя.
            guard out != input else { return out }
            Stats.shared.noteTransliteration()
            return out
        }
    }

    @objc private func polishText() {
        logHotkey("polishText")
        guard settings.aiEnabled else {
            Task { @MainActor in PolishPanel.shared.showError("AI выключен — включить можно в настройках") }
            return
        }
        let useTypography = settings.typographyBeforeAI
        let wantPreview = settings.polishPreview
        // Метка попытки: если человек закроет панель, поздний ответ её не поднимет.
        let session = MainActor.assumeIsolated { PolishPanel.shared.beginSession() }
        Task { @MainActor in PolishPanel.shared.showWorking() }

        converter.polishCurrentTargetAsync(transform: { text in
            // Механические правки делаем сами: модели остаётся смысловая часть,
            // а ёлочки и тире получаются одинаково предсказуемо каждый раз.
            let prepared = useTypography ? Typography.apply(text) : text

            switch await LLMPolisher.polish(prepared) {
            case .success(let polished):
                let final = useTypography ? Typography.apply(polished) : polished
                guard final != text else {
                    await MainActor.run { PolishPanel.shared.showError("Тут и так всё в порядке") }
                    return nil
                }
                // Без предпросмотра — прежнее поведение: заменяем сразу.
                guard wantPreview else {
                    // Короткая отметка вместо мгновенного исчезновения: видно, что
                    // правка прошла, и не нужно ничего нажимать.
                    await MainActor.run { PolishPanel.shared.showDone() }
                    return final
                }
                let decision = await withCheckedContinuation { continuation in
                    Task { @MainActor in
                        PolishPanel.shared.showPreview(
                            generation: session, original: text, result: final
                        ) { continuation.resume(returning: $0) }
                    }
                }
                switch decision {
                case .accepted(let value):
                    return value
                case .rejected:
                    return nil
                case .retry:
                    // Новый заход стартуем отдельно: этот вызов уже завершён,
                    // и текст трогать нельзя.
                    DispatchQueue.main.async { [weak self] in self?.polishText() }
                    return nil
                }
            case .failure(let err):
                Log.hotkey.info("polish error: \(err.localizedDescription, privacy: .public)")
                await MainActor.run { PolishPanel.shared.showError(err.userMessage) }
                return nil
            }
        }, onNoText: {
            // Частый случай — поле на web-технологиях (Electron, браузер): система
            // не отдаёт его содержимое, а выделить строку с клавиатуры там нечем.
            Task { @MainActor in
                PolishPanel.shared.showError(
                    "Не получилось забрать текст отсюда. Выдели нужный кусок мышью и нажми ещё раз"
                )
            }
        })
    }

    @objc private func applyTypography() {
        logHotkey("typography")
        // Только по выделению. Путь «последнее слово» ведёт в конверсию раскладки:
        // он умеет менять хвост через swapDirectional, и ⌥⇧P превращал `текст:`
        // в `текстЖ` вместо типографики. К отдельному слову правила и неприменимы.
        converter.applyToSelectionOnly { input in
            let out = Typography.apply(input)
            guard out != input else { return nil }
            Stats.shared.notePolish()
            return out
        }
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func openAbout() {
        SettingsWindowController.shared.show(initialTab: .about)
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        func item(_ id: String) -> NSMenuItem? {
            menu.items.first { $0.identifier?.rawValue == id }
        }

        // Скрываем AX-пункт когда разрешения уже даны — чтобы меню было чище.
        item("axPermission")?.isHidden = AXIsProcessTrusted()

        let health = AppHealth.state
        if let line = item("healthState") {
            line.title = health.isProblem ? "⚠︎ \(health.title)" : health.title
        }

        if let line = item("savedTime") {
            let stats = Stats.shared
            if stats.totalConversions > 0 {
                line.title = "Сберёг \(stats.savedTimeDescription) · правок: \(stats.totalConversions)"
            } else {
                line.title = "Правок пока не было"
            }
        }

        if let pause = item("pause") {
            if let left = PauseController.shared.remainingDescription {
                pause.title = "На паузе — ещё \(left)"
            } else {
                pause.title = "Пауза"
            }
            pause.submenu?.items.first { $0.identifier?.rawValue == "resume" }?
                .isHidden = !PauseController.shared.isPaused
        }
    }

    @objc private func pauseFor(_ sender: NSMenuItem) {
        PauseController.shared.pause(minutes: sender.tag)
        updateStatusIcon()
    }

    @objc private func resumeFromPause() {
        PauseController.shared.resume()
        updateStatusIcon()
    }

    @objc private func showAccessibilityHelp() {
        let trusted = AXIsProcessTrusted()
        let alert = NSAlert()
        alert.messageText = trusted ? "Разрешения на месте" : "Нужны разрешения Accessibility"
        alert.informativeText = trusted
            ? "Q*Й имеет нужный доступ. Если modifier-only хоткеи не работают — перезапусти приложение."
            : "Открой Системные настройки → Конфиденциальность → Универсальный доступ и добавь Q*Й."
        alert.addButton(withTitle: trusted ? "OK" : "Открыть настройки")
        if !trusted { alert.addButton(withTitle: "Позже") }
        let response = alert.runModal()
        if !trusted, response == .alertFirstButtonReturn {
            openAccessibilityPane()
        }
    }

    private var axPollTimer: Timer?

    /// Стартует EventMonitor если AX уже даны; иначе поллит каждые 1.5с —
    /// чтобы юзер дал разрешение в Onboarding и не пришлось перезапускать app.
    private func startMonitorsOrPoll() {
        if EventMonitor.shared.start() {
            KeystrokeBuffer.shared.install()
            modifierMonitor.install()
            AutoConverter.shared.install()
            return
        }
        Log.hotkey.info("AX not granted yet — polling")
        axPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            if EventMonitor.shared.start() {
                KeystrokeBuffer.shared.install()
                self.modifierMonitor.install()
                AutoConverter.shared.install()
                Log.hotkey.info("AX granted — monitors started")
                t.invalidate()
                self.axPollTimer = nil
            }
        }
    }

    private func ensureAccessibility() {
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
    }

    private func openAccessibilityPane() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
