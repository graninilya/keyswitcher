import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var hotkeys: HotkeyManager!
    private var modifierMonitor: ModifierHotkeyMonitor!
    private var converter: ClipboardConverter!
    private var settings: Settings { .shared }
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        converter = ClipboardConverter()
        hotkeys = HotkeyManager()
        modifierMonitor = ModifierHotkeyMonitor()

        setupMenuBar()
        ensureAccessibility()

        // Запускаем CGEventTap (нужен для KeystrokeBuffer и modifier-only хоткеев)
        let started = EventMonitor.shared.start()
        if started {
            KeystrokeBuffer.shared.install()
            modifierMonitor.install()
            AutoConverter.shared.install()
        } else {
            print("EventMonitor не стартовал — нет AX permission?")
        }

        rebindHotkeys()

        // Перебиндить при изменении настроек
        settings.$hotkeys
            .dropFirst()
            .sink { [weak self] _ in self?.rebindHotkeys() }
            .store(in: &cancellables)
        settings.$enabled
            .sink { [weak self] newValue in self?.updateStatusIcon(enabled: newValue) }
            .store(in: &cancellables)
    }

    // MARK: - Menu bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            // title как страховка — даже если символа нет, иконка не пропадёт
            button.title = "Q*Й"
            button.imagePosition = .imageOnly
        }

        let menu = NSMenu()
        let toggleItem = makeItem("Включено", action: #selector(toggleEnabled))
        toggleItem.state = settings.enabled ? .on : .off
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(makeItem("Настройки…", action: #selector(openSettings)))
        menu.addItem(makeItem("Проверить разрешения", action: #selector(showAccessibilityHelp)))
        menu.addItem(.separator())
        menu.addItem(makeItem("Выйти из Q*Й", action: #selector(quit)))

        statusItem.menu = menu
        updateStatusIcon()
    }

    private func makeItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func updateStatusIcon(enabled: Bool? = nil) {
        guard let button = statusItem.button else { return }
        let isOn = enabled ?? settings.enabled

        // Обновим чекмарк рядом с пунктом «Включено» в меню
        if let menu = statusItem.menu, let toggleItem = menu.items.first {
            toggleItem.state = isOn ? .on : .off
        }

        // Берём цветной лого из бандла. Не template — наш бренд цветной.
        let image: NSImage?
        if let url = Bundle.main.url(forResource: "StatusIcon", withExtension: "pdf") {
            image = NSImage(contentsOf: url)
        } else if let url = Bundle.main.url(forResource: "StatusIcon", withExtension: "png") {
            image = NSImage(contentsOf: url)
        } else {
            image = nil
        }

        if let image = image {
            // Подгоняем по высоте menu bar (~22pt), ширина — по пропорциям
            let targetH: CGFloat = 22
            let aspect = image.size.width / image.size.height
            image.size = NSSize(width: round(targetH * aspect), height: targetH)
            // Template image — macOS сама инвертирует под текущую тему
            // (светлая = чёрный, тёмная = белый). Выкл состояние — приглушим тинтом.
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
            button.contentTintColor = isOn ? nil : .tertiaryLabelColor
        } else {
            // Fallback — текст
            button.image = nil
            button.title = isOn ? "Q*Й" : "Q*Й off"
            button.contentTintColor = isOn ? nil : .tertiaryLabelColor
        }
    }

    // MARK: - Hotkey binding

    private func rebindHotkeys() {
        hotkeys.unregisterAll()
        modifierMonitor.unbindAll()

        bind(settings.hotkeys.smartConvert,        action: { [weak self] in self?.smartConvert() })
        bind(settings.hotkeys.forceSwap,           action: { [weak self] in self?.forceSwap() })
        bind(settings.hotkeys.transliterate,       action: { [weak self] in self?.transliterate() })
        bindToggleEnabled(settings.hotkeys.toggleEnabled)
    }

    private func bind(_ binding: HotkeyBinding, action: @escaping () -> Void) {
        switch binding {
        case .modifier(let m):
            modifierMonitor.bind(m) { [weak self] in
                guard self?.settings.enabled == true else { return }
                action()
            }
        case .combo(let c):
            hotkeys.register(modifiers: c.modifiers, keyCodeRaw: UInt32(c.keyCode)) { [weak self] in
                guard self?.settings.enabled == true else { return }
                action()
            }
        case .disabled:
            break
        }
    }

    /// Хоткей вкл/выкл — работает всегда, даже когда keySwitcher выключен.
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

    // MARK: - Actions

    @objc private func toggleEnabled() {
        settings.enabled.toggle()
    }

    private func logHotkey(_ name: String) {
        Log.hotkey.info("ACTION: \(name, privacy: .public)")
    }

    @objc private func smartConvert() {
        logHotkey("smartConvert")
        // 1. Если в окне тоггла — переворачиваем состояние.
        if AutoConverter.shared.canToggle() {
            AutoConverter.shared.toggle()
            return
        }
        // 2. Иначе — конвертим:
        //    - Многословное выделение → каждое слово через строгий детектор.
        //    - Одно слово (или буфер) → строгий детектор + fallback на свап для mixed.
        converter.smartConvert { text in
            // Многословный текст (есть пробелы) — обрабатываем по-словно
            if text.contains(" ") || text.contains("\n") {
                return Self.convertMultiWord(text)
            }
            // Одно слово
            if let result = LayoutMap.shared.autoConvert(text) {
                return result
            }
            // Fallback: для слов с layout-mapped пунктуацией нормализуем
            let cyrLet = text.filter { ("а"..."я").contains($0) || $0 == "ё"
                                     || ("А"..."Я").contains($0) || $0 == "Ё" }.count
            let latLet = text.filter { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }.count
            let hasLayoutPunct = text.contains { ";[],.'`\\".contains($0) }
            let mixed = (cyrLet > 0 && latLet > 0)
                     || (hasLayoutPunct && (cyrLet > 0 || latLet > 0))
            guard mixed else { return nil }
            let candidate = LayoutMap.shared.swap(text)
            return candidate != text ? candidate : nil
        }
    }

    /// Конвертация многословного выделения: каждое слово свапается отдельно
    /// (кириллица → латинская, латинская → кириллица). Хвостовая пунктуация сохраняется.
    /// Это force-режим: пользователь явно нажал хоткей на выделении.
    private static func convertMultiWord(_ text: String) -> String? {
        let trailingPunctChars: Set<Character> = [",", ".", "!", "?", ";", ":", ")", "]", "}", "—", "-"]
        var result = ""
        var current = ""
        var anyChanged = false

        func swapWord(_ word: String) -> String {
            // Отделим хвостовую пунктуацию — её не трогаем
            var trailCount = 0
            for ch in word.reversed() {
                if trailingPunctChars.contains(ch) { trailCount += 1 } else { break }
            }
            let core = String(word.prefix(word.count - trailCount))
            let trail = String(word.suffix(trailCount))
            guard !core.isEmpty else { return word }
            let swapped = LayoutMap.shared.swap(core)
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
        converter.convertSelectionOnly { LayoutMap.shared.swap($0) }
    }

    @objc private func transliterate() {
        logHotkey("transliterate")
        converter.convertSelectionOnly { Transliteration.apply($0) }
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
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

    // MARK: - Accessibility

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
