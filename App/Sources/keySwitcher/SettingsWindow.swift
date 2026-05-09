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
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.setContentSize(NSSize(width: 640, height: 540))
        w.center()
        w.isReleasedWhenClosed = false
        self.window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}


enum SettingsTab: Hashable {
    case hotkeys, behavior, ai, exceptions, rules, updates, about
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
            HeroHeader(enabled: $settings.enabled)
                .ignoresSafeArea(edges: .top)

            Divider()

            TabView(selection: $host.selection) {
                HotkeysTab()
                    .tabItem { Label("Хоткеи", systemImage: "keyboard") }
                    .tag(SettingsTab.hotkeys)
                BehaviorTab()
                    .tabItem { Label("Поведение", systemImage: "slider.horizontal.3") }
                    .tag(SettingsTab.behavior)
                AITab()
                    .tabItem { Label("AI", systemImage: "wand.and.stars") }
                    .tag(SettingsTab.ai)
                ExceptionsTab()
                    .tabItem { Label("Исключения", systemImage: "list.bullet.rectangle") }
                    .tag(SettingsTab.exceptions)
                RulesTab()
                    .tabItem { Label("Правила", systemImage: "checklist") }
                    .tag(SettingsTab.rules)
                UpdatesTab()
                    .tabItem { Label("Обновления", systemImage: "arrow.down.circle") }
                    .tag(SettingsTab.updates)
                AboutTab()
                    .tabItem { Label("О программе", systemImage: "info.circle") }
                    .tag(SettingsTab.about)
            }
            .padding(.top, 8)
        }
        .frame(width: 640, height: 540)
    }
}


// MARK: - Hero header

private struct HeroHeader: View {
    @Binding var enabled: Bool

    @State private var customBG: Color? = nil
    @State private var logoHue: Angle = .zero

    private static let defaultBG = Color(red: 0.30, green: 0.74, blue: 0.55)
    private static let disabledBG = Color(red: 0.42, green: 0.42, blue: 0.46)

    private var bg: Color {
        if !enabled { return Self.disabledBG }
        return customBG ?? Self.defaultBG
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [bg, bg.opacity(0.78)],
                startPoint: .top, endPoint: .bottom
            )

            HStack(alignment: .center, spacing: 14) {
                logoView()
                    .frame(width: 56, height: 56)
                    .hueRotation(enabled ? logoHue : .zero)
                    .saturation(enabled ? 1.0 : 0.0)
                    .opacity(enabled ? 1.0 : 0.6)
                VStack(alignment: .leading, spacing: 4) {
                    Text("KEYSWITCHER")
                        .font(.system(size: 18, weight: .heavy))
                        .tracking(1.4)
                        .foregroundColor(.white)
                    Text(enabled ? "Активно" : "Выключено")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.85))
                }
                Spacer()
                Toggle("", isOn: $enabled)
                    .toggleStyle(.switch)
                    .controlSize(.large)
                    .labelsHidden()
            }
            .padding(.horizontal, 22)
            .padding(.top, 28)
            .padding(.bottom, 14)
        }
        .frame(height: 110)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.4)) {
                let hue = Double.random(in: 0...1)
                customBG = Color(hue: hue, saturation: 0.55, brightness: 0.72)
                logoHue = .degrees(Double.random(in: -180...180))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: enabled)
    }

    @ViewBuilder
    private func logoView() -> some View {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: url) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if let app = NSImage(named: NSImage.applicationIconName) {
            Image(nsImage: app)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            Image(systemName: "keyboard")
                .font(.system(size: 30))
                .foregroundColor(.white)
        }
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
                    title: "Расставить пунктуацию и опечатки",
                    subtitle: "Через AI: выделение или текущая строка",
                    icon: "wand.and.stars",
                    binding: Binding(
                        get: { settings.hotkeys.polishText },
                        set: { settings.hotkeys.polishText = $0 }
                    ),
                    allowsModifierOnly: true
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
                    subtitle: "Короткий тик после авто-замены или хоткея"
                ) {
                    Picker("", selection: $settings.soundName) {
                        Text("Без звука").tag("")
                        Divider()
                        ForEach(SoundFeedback.allSounds, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 140)
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

// MARK: - Правила (всегда свапать)

struct RulesTab: View {
    @ObservedObject private var settings = Settings.shared
    @State private var newWord: String = ""

    private var sortedCustom: [String] {
        settings.forceSwapWords.sorted()
    }

    private var sortedBuiltIn: [String] {
        LayoutMap.builtInForceSwap.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Слова которые Q*Й всегда свапает автоматически")
                    .font(.system(size: 13, weight: .medium))
                Text("Аббревиатуры без гласных (vpn, sql, dns) детектор не может уверенно различить — список говорит «всегда конвертируй». Печатаешь `мзт` в русской раскладке → получаешь `vpn`.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            HStack {
                TextField("например: k8s, pgsql, mqtt", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addWord)
                Button("Добавить", action: addWord)
                    .disabled(newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !sortedCustom.isEmpty {
                        HStack {
                            Text("Свои")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                                .tracking(0.4)
                            Spacer()
                        }
                        .padding(.top, 6)
                        .padding(.bottom, 4)
                        .padding(.horizontal, 20)

                        ForEach(sortedCustom, id: \.self) { word in
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.blue)
                                    .font(.system(size: 12))
                                Text(word)
                                    .font(.system(size: 13, design: .monospaced))
                                Spacer()
                                Button {
                                    settings.removeForceSwap(word)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                        .font(.system(size: 14))
                                }
                                .buttonStyle(.plain)
                                .help("Удалить из правил")
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 20)
                            Divider().opacity(0.4)
                        }
                    }

                    HStack {
                        Text("Встроенные")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                            .tracking(0.4)
                        Spacer()
                    }
                    .padding(.top, sortedCustom.isEmpty ? 6 : 14)
                    .padding(.bottom, 4)
                    .padding(.horizontal, 20)

                    ForEach(sortedBuiltIn, id: \.self) { word in
                        HStack {
                            Image(systemName: "lock.fill")
                                .foregroundColor(.secondary.opacity(0.6))
                                .font(.system(size: 11))
                            Text(word)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 20)
                        Divider().opacity(0.3)
                    }
                }
            }

            HStack {
                Text("Своих: \(sortedCustom.count) · встроенных: \(sortedBuiltIn.count)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                if !sortedCustom.isEmpty {
                    Button("Очистить свои") {
                        settings.forceSwapWords.removeAll()
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
        settings.addForceSwap(trimmed)
        newWord = ""
    }
}

// MARK: - AI

struct AIModelOption: Identifiable, Hashable {
    let id: String
    let label: String
    let note: String
}

struct AITab: View {
    @ObservedObject private var settings = Settings.shared

    private let models: [AIModelOption] = [
        .init(id: "@cf/google/gemma-3-12b-it",
              label: "Gemma 3 (12B)",
              note: "Рекомендуется. Быстрая (~400мс), лучший русский на тестах."),
        .init(id: "@cf/meta/llama-3.3-70b-instruct-fp8-fast",
              label: "Llama 3.3 (70B fast)",
              note: "Мощнее, медленнее (~600мс). Лучше для сложных длинных текстов."),
        .init(id: "@cf/mistralai/mistral-small-3.1-24b-instruct",
              label: "Mistral Small 3.1 (24B)",
              note: "Альтернатива. Иногда ставит точки вместо запятых."),
        .init(id: "@cf/qwen/qwq-32b",
              label: "Qwen QwQ (32B)",
              note: "Reasoning-модель. Медленнее, для самых сложных случаев."),
        .init(id: "@cf/meta/llama-3.1-8b-instruct-fast",
              label: "Llama 3.1 (8B fast)",
              note: "Самая быстрая (~200мс), но русский знает плохо."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BehaviorRow(
                    icon: "wand.and.stars",
                    title: "Расстановка пунктуации и опечаток",
                    subtitle: "Хоткей в разделе Хоткеи. По умолчанию — правый Option."
                ) {
                    Toggle("", isOn: $settings.aiEnabled).labelsHidden()
                }

                Divider().padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Модель (встроенный сервер)")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        if settings.useCustomAPI {
                            Text("не используется")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    Picker("", selection: $settings.aiModel) {
                        ForEach(models) { m in
                            Text(m.label).tag(m.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(!settings.aiEnabled || settings.useCustomAPI)

                    if let current = models.first(where: { $0.id == settings.aiModel }) {
                        Text(current.note)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider().padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Свой API (OpenAI-совместимый)")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        if settings.useCustomAPI {
                            Text("активен")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.green)
                        }
                    }
                    Text("Если заполнены URL, ключ и модель — текст уйдёт на твой сервер вместо Cloudflare. Подойдёт OpenAI, Groq, OpenRouter, Together, локальный Ollama / LM Studio и любой другой совместимый эндпоинт.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 6) {
                        TextField("URL (например https://api.openai.com/v1/chat/completions)",
                                  text: $settings.customApiEndpoint)
                            .textFieldStyle(.roundedBorder)
                            .disabled(!settings.aiEnabled)
                        SecureField("API key (sk-...)",
                                    text: $settings.customApiKey)
                            .textFieldStyle(.roundedBorder)
                            .disabled(!settings.aiEnabled)
                        TextField("Модель (например gpt-4o-mini)",
                                  text: $settings.customApiModel)
                            .textFieldStyle(.roundedBorder)
                            .disabled(!settings.aiEnabled)
                    }

                    if !settings.customApiKey.isEmpty || !settings.customApiEndpoint.isEmpty {
                        HStack {
                            Spacer()
                            Button("Очистить") {
                                settings.customApiEndpoint = ""
                                settings.customApiKey = ""
                                settings.customApiModel = ""
                            }
                            .controlSize(.small)
                        }
                    }
                }

                Divider().padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text("О приватности")
                        .font(.system(size: 13, weight: .medium))
                    Text(settings.useCustomAPI
                         ? "Текст уходит на указанный тобой эндпоинт. Q*Й ничего не логирует и не пересылает на свои серверы."
                         : "Текст отправляется на сервер Cloudflare Workers AI и обрабатывается на их серверах. Запросы не логируются и не используются для обучения. Все остальные функции Q*Й работают локально.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
        }
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
