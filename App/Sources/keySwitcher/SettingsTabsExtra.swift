import SwiftUI

// MARK: - Статистика

struct StatsTab: View {
    @ObservedObject private var stats = Stats.shared
    @ObservedObject private var history = History.shared
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(stats.savedTimeDescription)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tint)
                Text("столько времени ты не потратил на возню с раскладкой")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            HStack(spacing: 10) {
                StatCard(value: "\(stats.autoConversions)", caption: "автоматически")
                StatCard(value: "\(stats.manualConversions)", caption: "по хоткею")
                StatCard(value: "\(stats.retroWords)", caption: "цепочкой")
                if let acc = stats.accuracy {
                    StatCard(value: "\(Int((acc * 100).rounded()))%", caption: "без отката")
                }
            }
            .padding(.horizontal, 20)

            HStack(spacing: 10) {
                StatCard(value: "\(stats.polishRuns)", caption: "AI-правок")
                StatCard(value: "\(stats.transliterations)", caption: "транслитераций")
                StatCard(value: "\(stats.reverts)", caption: "откатов")
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            Text(footnote)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.top, 12)

            HStack {
                Text("Последние замены")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .tracking(0.4)
                Spacer()
                if !history.entries.isEmpty {
                    Button("Очистить") { history.clear() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if history.entries.isEmpty {
                        Text("Пока пусто. Здесь появятся последние правки — список живёт до перезапуска и на диск не пишется.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                    }
                    ForEach(history.entries) { e in
                        HStack(spacing: 8) {
                            Text(e.kind.rawValue)
                                .font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            Text(e.original)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                            Text(e.converted)
                                .font(.system(size: 12, design: .monospaced))
                            Spacer()
                            if !e.appName.isEmpty {
                                Text(e.appName)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 20)
                        Divider().opacity(0.4)
                    }
                }
            }

            Divider()

            HStack {
                Button("Сбросить счётчики") { confirmReset = true }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .alert("Сбросить статистику?", isPresented: $confirmReset) {
            Button("Сбросить", role: .destructive) { stats.reset() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Счётчики начнутся с нуля. Настройки, исключения и правила останутся на месте.")
        }
    }

    private var footnote: String {
        let perFix = Int(Stats.secondsPerFix)
        return "Считаем по \(perFix) секунды на слово — примерно столько уходит, чтобы заметить промах, "
             + "стереть, переключиться и набрать заново. Слова, подхваченные цепочкой заодно, идут по полторы. "
             + "Откаченные правки не в счёт. Цифры никуда не уходят с этого компьютера."
    }
}

private struct StatCard: View {
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .medium, design: .rounded))
            Text(caption)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}


// MARK: - Правила по приложениям

struct AppsTab: View {
    @ObservedObject private var rules = AppRules.shared
    @State private var picking = false

    /// Имя запрашивается у LaunchServices, поэтому считаем его один раз на строку,
    /// а не внутри компаратора.
    private var sorted: [(id: String, name: String, mode: AppMode)] {
        rules.rules
            .map { (id: $0.key, name: AppRules.displayName(for: $0.key), mode: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Где вести себя тише")
                    .font(.system(size: 13, weight: .medium))
                Text("В терминале ты набираешь команды, а не слова — там правки только мешают. Режим «только по хоткею» отключает автоматику, но Option продолжает работать. Терминалы, которые нашлись на этом компьютере, уже в списке.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            if !rules.currentBundleID.isEmpty {
                HStack(spacing: 8) {
                    Text("Сейчас активно:")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text(rules.currentAppName.isEmpty ? rules.currentBundleID : rules.currentAppName)
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Picker("", selection: Binding(
                        get: { rules.currentMode },
                        set: { rules.setMode($0, for: rules.currentBundleID) }
                    )) {
                        ForEach(AppMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }
                .padding(.horizontal, 20)
            }

            HStack {
                Button("Добавить программу…") { pickApp() }
                Spacer()
            }
            .padding(.horizontal, 20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if sorted.isEmpty {
                        Text("Список пуст — значит, везде работает как обычно.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                    }
                    ForEach(sorted, id: \.id) { row in
                        HStack(spacing: 8) {
                            Text(row.name)
                                .font(.system(size: 13))
                            Spacer()
                            Picker("", selection: Binding(
                                get: { row.mode },
                                set: { rules.setMode($0, for: row.id) }
                            )) {
                                ForEach(AppMode.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 170)
                            Button {
                                rules.setMode(.normal, for: row.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                                    .font(.system(size: 14))
                            }
                            .buttonStyle(.plain)
                            .help("Убрать из списка")
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 20)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let bundle = Bundle(url: url)?.bundleIdentifier else { return }
            rules.setMode(.manualOnly, for: bundle)
        }
    }
}


// MARK: - Обслуживание: перенос настроек, диагностика, обратная связь

struct MaintenanceTab: View {
    // Пустая строка, а не отчёт: TabView конструирует все вкладки сразу, и отчёт
    // при инициализации тянул бы чтение связки ключей на каждое открытие настроек.
    @State private var diagnostics = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Перенести на другой компьютер")
                    .font(.system(size: 13, weight: .medium))
                Text("В файл попадут хоткеи, исключения, правила и настройки программ. Ключ от своего AI останется здесь — он хранится в связке ключей и в файл не пишется.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Сохранить в файл…") { SettingsTransfer.runExportPanel() }
                    Button("Загрузить из файла…") { SettingsTransfer.runImportPanel() }
                }
                .padding(.top, 2)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Если что-то пошло не так")
                    .font(.system(size: 13, weight: .medium))
                Text("В отчёте только техника: версия, состояние, счётчики и настройки. Ничего из того, что ты печатал, туда не попадает — можно смело отправлять.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Сохранить отчёт…") { SettingsTransfer.saveDiagnostics() }
                    Button("Скопировать отчёт") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(AppHealth.diagnosticsReport(), forType: .string)
                    }
                    Button("Сообщить о проблеме") {
                        openIssue()
                    }
                }
                .padding(.top, 2)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Состояние")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .tracking(0.4)
                    Spacer()
                    Button("Обновить") { diagnostics = AppHealth.diagnosticsReport() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                ScrollView {
                    Text(diagnostics)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(20)
        .onAppear { diagnostics = AppHealth.diagnosticsReport() }
    }

    /// Отчёт кладём в буфер обмена и открываем форму — вставить его юзеру проще,
    /// чем нам угадать длину URL, который GitHub примет.
    private func openIssue() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AppHealth.diagnosticsReport(), forType: .string)
        if let url = URL(string: "https://github.com/graninilya/keyswitcher/issues/new") {
            NSWorkspace.shared.open(url)
        }
    }
}
