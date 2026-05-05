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
        _ = UpdaterController.shared

        let started = EventMonitor.shared.start()
        if started {
            KeystrokeBuffer.shared.install()
            modifierMonitor.install()
            AutoConverter.shared.install()
        } else {
            print("EventMonitor не стартовал — нет AX permission?")
        }

        rebindHotkeys()

        settings.$hotkeys
            .dropFirst()
            .sink { [weak self] _ in self?.rebindHotkeys() }
            .store(in: &cancellables)
        settings.$enabled
            .sink { [weak self] newValue in self?.updateStatusIcon(enabled: newValue) }
            .store(in: &cancellables)
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            // Страховка на случай отсутствия иконки в бандле
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
        let updatesItem = NSMenuItem(title: "Проверить обновления…",
                                     action: #selector(UpdaterController.checkForUpdates(_:)),
                                     keyEquivalent: "")
        updatesItem.target = UpdaterController.shared
        menu.addItem(updatesItem)
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

        if let menu = statusItem.menu, let toggleItem = menu.items.first {
            toggleItem.state = isOn ? .on : .off
        }

        let image: NSImage?
        if let url = Bundle.main.url(forResource: "StatusIcon", withExtension: "pdf") {
            image = NSImage(contentsOf: url)
        } else if let url = Bundle.main.url(forResource: "StatusIcon", withExtension: "png") {
            image = NSImage(contentsOf: url)
        } else {
            image = nil
        }

        if let image = image {
            let targetH: CGFloat = 22
            let aspect = image.size.width / image.size.height
            image.size = NSSize(width: round(targetH * aspect), height: targetH)
            // Template image — macOS сама инвертирует под текущую тему меню-бара
            image.isTemplate = true
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
        if AutoConverter.shared.canToggle() {
            AutoConverter.shared.toggle()
            return
        }
        converter.smartConvert { text in
            if text.contains(" ") || text.contains("\n") {
                return Self.convertMultiWord(text)
            }
            if let result = LayoutMap.shared.autoConvert(text) {
                return result
            }
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
