import AppKit
import SwiftUI
import Sparkle

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private var rootView: SettingsRootHosting?

    private init() {}

    func show(initialTab: SettingsTab = .hotkeys) {
        if let w = window {
            rootView?.selection = initialTab
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = SettingsRootHosting(selection: initialTab)
        self.rootView = host
        let hosting = NSHostingController(rootView: SettingsRoot(host: host))
        let w = NSWindow(contentViewController: hosting)
        w.title = "Q*Й — настройки"
        w.styleMask = [.titled, .closable]
        w.setContentSize(NSSize(width: 560, height: 520))
        w.center()
        w.isReleasedWhenClosed = false
        self.window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}


enum SettingsTab: Hashable {
    case hotkeys, behavior, exceptions, updates, about
}

/// Класс-обёртка чтобы SettingsWindowController мог менять выбранный таб извне.
final class SettingsRootHosting: ObservableObject {
    @Published var selection: SettingsTab
    init(selection: SettingsTab) { self.selection = selection }
}

struct SettingsRoot: View {
    @ObservedObject var host: SettingsRootHosting
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        VStack(spacing: 0) {
            // Глобальный enable/disable — над табами, всегда виден.
            HStack(spacing: 10) {
                Toggle("", isOn: $settings.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Q*Й")
                        .font(.system(size: 14, weight: .semibold))
                    Text(settings.enabled ? "Активно" : "Выключено")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            TabView(selection: $host.selection) {
                HotkeysTab()
                    .tabItem { Label("Хоткеи", systemImage: "keyboard") }
                    .tag(SettingsTab.hotkeys)
                BehaviorTab()
                    .tabItem { Label("Поведение", systemImage: "slider.horizontal.3") }
                    .tag(SettingsTab.behavior)
                ExceptionsTab()
                    .tabItem { Label("Исключения", systemImage: "list.bullet.rectangle") }
                    .tag(SettingsTab.exceptions)
                UpdatesTab()
                    .tabItem { Label("Обновления", systemImage: "arrow.down.circle") }
                    .tag(SettingsTab.updates)
                AboutTab()
                    .tabItem { Label("О программе", systemImage: "info.circle") }
                    .tag(SettingsTab.about)
            }
            .padding(.top, 8)
        }
        .frame(width: 560, height: 520)
    }
}


// MARK: - Хоткеи

struct HotkeysTab: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HotkeyRow(
                    title: "Сменить раскладку",
                    subtitle: "Выделение / последнее слово; повторное нажатие в 5с — откат",
                    icon: "arrow.left.arrow.right",
                    binding: Binding(
                        get: { settings.hotkeys.smartConvert },
                        set: { settings.hotkeys.smartConvert = $0 }
                    ),
                    allowsModifierOnly: true
                )
                HotkeyRow(
                    title: "Принудительная смена",
                    subtitle: "Игнорирует детектор, всегда свапает",
                    icon: "bolt.fill",
                    binding: Binding(
                        get: { settings.hotkeys.forceSwap },
                        set: { settings.hotkeys.forceSwap = $0 }
                    ),
                    allowsModifierOnly: false
                )
                HotkeyRow(
                    title: "Транслитерация",
                    subtitle: "Кириллица → латиница (ГОСТ 7.79)",
                    icon: "character.book.closed",
                    binding: Binding(
                        get: { settings.hotkeys.transliterate },
                        set: { settings.hotkeys.transliterate = $0 }
                    ),
                    allowsModifierOnly: false
                )
                HotkeyRow(
                    title: "Включить / выключить Q*Й",
                    subtitle: "Работает даже когда приложение выключено",
                    icon: "power",
                    binding: Binding(
                        get: { settings.hotkeys.toggleEnabled },
                        set: { settings.hotkeys.toggleEnabled = $0 }
                    ),
                    allowsModifierOnly: true
                )

                HStack {
                    Spacer()
                    Button("Сбросить хоткеи") {
                        settings.hotkeys = HotkeyConfig.default
                    }
                    .controlSize(.small)
                }
                .padding(.top, 8)
            }
            .padding(20)
        }
    }
}

// MARK: - Поведение

struct BehaviorTab: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BehaviorRow(
                    icon: "speaker.wave.2",
                    title: "Звуковой сигнал на замену",
                    subtitle: "Короткий тик когда сработала автоконвертация"
                ) {
                    Toggle("", isOn: $settings.soundsEnabled).labelsHidden()
                }
                BehaviorRow(
                    icon: "power",
                    title: "Запускать при входе в систему",
                    subtitle: "Регистрирует app в Launch Services"
                ) {
                    Toggle("", isOn: $settings.launchAtLogin).labelsHidden()
                }
            }
            .padding(20)
        }
    }
}

private struct BehaviorRow<Trailing: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(.accentColor)
                .frame(width: 28, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            trailing()
        }
    }
}

// MARK: - Исключения

struct ExceptionsTab: View {
    @ObservedObject private var settings = Settings.shared
    @State private var newWord: String = ""

    private var sortedIgnored: [String] {
        settings.ignoredAutoSwap.sorted()
    }

    private var sortedPending: [(word: String, count: Int)] {
        settings.pendingReverts
            .map { (word: $0.key, count: $0.value) }
            .sorted { $0.word < $1.word }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Слова которые Q*Й не будет автоматически заменять")
                    .font(.system(size: 13, weight: .medium))
                Text("Слово попадёт сюда когда ты откатишь его авто-замену через Option \(settings.revertThreshold) раз. Или добавь вручную.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            HStack {
                TextField("новое слово", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addWord)
                Button("Добавить", action: addWord)
                    .disabled(newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 20)

            Divider()

            if sortedIgnored.isEmpty && sortedPending.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("Список пуст")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(sortedIgnored, id: \.self) { word in
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.system(size: 12))
                                Text(word)
                                    .font(.system(size: 13, design: .monospaced))
                                Spacer()
                                Button {
                                    settings.removeIgnored(word)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                        .font(.system(size: 14))
                                }
                                .buttonStyle(.plain)
                                .help("Удалить из исключений")
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 20)
                            Divider().opacity(0.4)
                        }

                        if !sortedPending.isEmpty {
                            HStack {
                                Text("Откатываются — пока ещё свапаются")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .tracking(0.4)
                                Spacer()
                            }
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                            .padding(.horizontal, 20)

                            ForEach(sortedPending, id: \.word) { row in
                                HStack {
                                    Image(systemName: "clock")
                                        .foregroundColor(.orange)
                                        .font(.system(size: 12))
                                    Text(row.word)
                                        .font(.system(size: 13, design: .monospaced))
                                    Spacer()
                                    Text("\(row.count) / \(settings.revertThreshold)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                    Button {
                                        settings.pendingReverts.removeValue(forKey: row.word)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.secondary)
                                            .font(.system(size: 14))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Сбросить счётчик")
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 20)
                                Divider().opacity(0.4)
                            }
                        }
                    }
                }
            }

            HStack {
                Text("В исключениях: \(sortedIgnored.count) · откатывается: \(sortedPending.count)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                if !sortedIgnored.isEmpty || !sortedPending.isEmpty {
                    Button("Очистить всё") {
                        settings.ignoredAutoSwap.removeAll()
                        settings.pendingReverts.removeAll()
                    }
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    private func addWord() {
        let trimmed = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        settings.addIgnored(trimmed)
        newWord = ""
    }
}

// MARK: - Обновления

struct UpdatesTab: View {
    @ObservedObject private var prefs = UpdaterPreferences.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BehaviorRow(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Проверять обновления автоматически",
                    subtitle: "Раз в сутки запрос к GitHub Releases"
                ) {
                    Toggle("", isOn: $prefs.autoCheckEnabled).labelsHidden()
                }
                BehaviorRow(
                    icon: "tray.and.arrow.down",
                    title: "Скачивать и ставить тихо",
                    subtitle: "Без подтверждающего диалога"
                ) {
                    Toggle("", isOn: $prefs.autoInstallEnabled).labelsHidden()
                }
                .opacity(prefs.autoCheckEnabled ? 1.0 : 0.5)
                .disabled(!prefs.autoCheckEnabled)

                Divider().padding(.vertical, 4)

                HStack {
                    Button {
                        UpdaterController.shared.checkForUpdates(nil)
                    } label: {
                        Label("Проверить сейчас", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)

                    Spacer()

                    if let last = prefs.lastCheckText {
                        Text(last)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(20)
        }
    }
}

// MARK: - О программе

struct AboutTab: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 8)

            iconView()
                .frame(width: 96, height: 96)

            Text("Версия \(version) (build \(build))")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Text("Smart keyboard layout switcher\nдля macOS на Apple Silicon")
                .multilineTextAlignment(.center)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .padding(.horizontal, 32)

            Divider().padding(.horizontal, 80)

            HStack(spacing: 18) {
                AboutLink(label: "GitHub", icon: "chevron.left.forwardslash.chevron.right",
                          url: "https://github.com/graninilya/keyswitcher")
                AboutLink(label: "Лицензия MIT", icon: "doc.text",
                          url: "https://github.com/graninilya/keyswitcher/blob/main/LICENSE")
                AboutLink(label: "Сообщить о баге", icon: "exclamationmark.bubble",
                          url: "https://github.com/graninilya/keyswitcher/issues")
            }

            Text("© 2026 Ilya Granin")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func iconView() -> some View {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: url) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
        } else if let url = Bundle.main.url(forResource: "StatusIcon", withExtension: "pdf"),
                  let img = NSImage(contentsOf: url) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
        } else {
            Image(systemName: "keyboard").font(.system(size: 64))
        }
    }
}

private struct AboutLink: View {
    let label: String
    let icon: String
    let url: String

    var body: some View {
        Button {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 18))
                Text(label).font(.system(size: 11))
            }
            .frame(width: 100)
        }
        .buttonStyle(.plain)
        .foregroundColor(.accentColor)
    }
}


// MARK: - Hotkey row (общий компонент)

struct HotkeyRow: View {
    let title: String
    var subtitle: String? = nil
    var icon: String? = nil
    @Binding var binding: HotkeyBinding
    let allowsModifierOnly: Bool

    @State private var isRecording = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(.accentColor)
                    .frame(width: 28, alignment: .center)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HotkeyRecorderButton(
                binding: $binding,
                isRecording: $isRecording,
                allowsModifierOnly: allowsModifierOnly
            )
            .frame(width: 170, height: 28)

            Button(action: { binding = .disabled }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .help("Отключить")
        }
    }
}


struct HotkeyRecorderButton: NSViewRepresentable {
    @Binding var binding: HotkeyBinding
    @Binding var isRecording: Bool
    let allowsModifierOnly: Bool

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let v = HotkeyRecorderNSView()
        v.allowsModifierOnly = allowsModifierOnly
        v.onRecorded = { newBinding in
            self.binding = newBinding
            self.isRecording = false
        }
        v.onStartRecording = { self.isRecording = true }
        v.onCancelRecording = { self.isRecording = false }
        v.binding = binding
        return v
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        nsView.binding = binding
        nsView.refresh()
    }
}


final class HotkeyRecorderNSView: NSView {
    var binding: HotkeyBinding = .disabled
    var allowsModifierOnly: Bool = false
    var onRecorded: ((HotkeyBinding) -> Void)?
    var onStartRecording: (() -> Void)?
    var onCancelRecording: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private var recording = false
    private var modifierPressTime: Date?
    private var trackedModifier: Int?
    private var modifierContaminated = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        label.alignment = .center
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refresh()
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if recording {
            stopRecording(commit: false)
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        recording = true
        modifierContaminated = false
        modifierPressTime = nil
        trackedModifier = nil
        window?.makeFirstResponder(self)
        label.stringValue = allowsModifierOnly
            ? "Нажмите хоткей или модификатор"
            : "Нажмите хоткей…"
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    private func stopRecording(commit: Bool) {
        recording = false
        layer?.borderColor = NSColor.separatorColor.cgColor
        if !commit {
            onCancelRecording?()
        }
        refresh()
    }

    func refresh() {
        if !recording {
            label.stringValue = binding.displayName
        }
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 {  // Esc — отмена записи
            stopRecording(commit: false)
            return
        }
        let combo = KeyCombo(modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask),
                             keyCode: Int(event.keyCode))
        binding = .combo(combo)
        onRecorded?(.combo(combo))
        stopRecording(commit: true)
    }

    override func flagsChanged(with event: NSEvent) {
        guard recording, allowsModifierOnly else { return }

        let keyCode = Int(event.keyCode)
        let isModifierKey = [54,55,56,58,59,60,61,62].contains(keyCode)
        guard isModifierKey else { return }

        let pressedNow = isModifierCurrentlyPressed(keyCode: keyCode, flags: event.modifierFlags)

        if pressedNow {
            modifierPressTime = Date()
            trackedModifier = keyCode
            modifierContaminated = false
        } else {
            if let t = modifierPressTime, let k = trackedModifier, k == keyCode,
               Date().timeIntervalSince(t) < 0.5, !modifierContaminated {
                let m = ModifierHotkey(keyCode: keyCode)
                binding = .modifier(m)
                onRecorded?(.modifier(m))
                stopRecording(commit: true)
            }
            modifierPressTime = nil
            trackedModifier = nil
        }
    }

    private func isModifierCurrentlyPressed(keyCode: Int, flags: NSEvent.ModifierFlags) -> Bool {
        switch keyCode {
        case 58, 61: return flags.contains(.option)
        case 55, 54: return flags.contains(.command)
        case 56, 60: return flags.contains(.shift)
        case 59, 62: return flags.contains(.control)
        default: return false
        }
    }
}
