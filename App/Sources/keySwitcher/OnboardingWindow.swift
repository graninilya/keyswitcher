import AppKit
import SwiftUI
import ApplicationServices

private let onboardingDoneKey = "hasOnboarded"
private let starPromptShownKey = "hasShownStarPrompt"

final class OnboardingWindowController {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?
    private init() {}

    /// true если первый запуск ещё не отметили как пройденный
    static var shouldShow: Bool {
        !UserDefaults.standard.bool(forKey: onboardingDoneKey)
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: onboardingDoneKey)
        // Полный онбординг включает Star-шаг, отдельно показывать не надо
        UserDefaults.standard.set(true, forKey: starPromptShownKey)
    }

    /// Показываем «звёздное» окно один раз для существующих юзеров после
    /// апдейта на версию с этой фичей. Не показываем если: онбординг ещё не
    /// пройден (там Star-шаг и так будет), или этот prompt уже показывали.
    static func showStarPromptIfNeeded() {
        guard UserDefaults.standard.bool(forKey: onboardingDoneKey),
              !UserDefaults.standard.bool(forKey: starPromptShownKey) else { return }
        UserDefaults.standard.set(true, forKey: starPromptShownKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            shared.showStarOnly()
        }
    }

    func show() {
        if window != nil { return }
        let view = OnboardingRoot { [weak self] in
            OnboardingWindowController.markCompleted()
            self?.close()
        }
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.title = "Добро пожаловать"
        w.styleMask = [.titled, .closable]
        w.setContentSize(NSSize(width: 640, height: 480))
        w.center()
        w.isReleasedWhenClosed = false
        self.window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showStarOnly() {
        if window != nil { return }
        let view = StarOnlyWindow { [weak self] in self?.close() }
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.title = "Q*Й обновился"
        w.styleMask = [.titled, .closable]
        w.setContentSize(NSSize(width: 440, height: 380))
        w.center()
        w.isReleasedWhenClosed = false
        self.window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func close() {
        window?.close()
        window = nil
    }
}

private struct StarOnlyWindow: View {
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            StarStep()
            Divider()
            HStack {
                Spacer()
                Button("Закрыть", action: onClose)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(20)
        }
        .frame(width: 440, height: 380)
    }
}


private struct OnboardingRoot: View {
    let onFinish: () -> Void
    @State private var step = 0
    private let total = 4

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if step == 0 { WelcomeStep() }
                else if step == 1 { DemoStep() }
                else if step == 2 { PermissionStep() }
                else { StarStep() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity.combined(with: .move(edge: .trailing)))

            Divider()

            HStack {
                // Шаг-индикатор
                HStack(spacing: 6) {
                    ForEach(0..<total, id: \.self) { i in
                        Circle()
                            .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                    }
                }

                Spacer()

                if step > 0 {
                    Button("Назад") { withAnimation { step -= 1 } }
                }

                Button(step == total - 1 ? "Готово" : "Дальше") {
                    if step == total - 1 {
                        onFinish()
                    } else {
                        withAnimation { step += 1 }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            }
            .padding(20)
        }
        .frame(width: 640, height: 480)
    }
}


// MARK: - Шаг 1: приветствие

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            iconImage()
                .frame(width: 120, height: 120)
            Text("Умный переключатель раскладок\nдля macOS")
                .multilineTextAlignment(.center)
                .font(.system(size: 16))
                .foregroundColor(.secondary)
            Text("Не нужно переключаться вручную — программа\nсама поймёт когда раскладка не та и исправит.")
                .multilineTextAlignment(.center)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .padding(.top, 8)
                .padding(.horizontal, 40)
            Spacer()
        }
    }

    @ViewBuilder
    private func iconImage() -> some View {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: url) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        } else {
            Image(systemName: "keyboard").font(.system(size: 80)).foregroundColor(.accentColor)
        }
    }
}


// MARK: - Шаг 2: демонстрация (4 сцены, авто-переключение)

private struct DemoFrame {
    let text: String
    let caption: String
    /// Промежуток символов в text который надо подсветить как «выделение».
    var selection: NSRange? = nil
    /// Имя клавиши для всплывающего «попа». Например "⌥" или "⌥⇧T".
    var keyPress: String? = nil
    /// Подсветить рамку поля (после успешной операции).
    var highlighted: Bool = false
    /// Зелёная вспышка + зум — нативный «approved»-сигнал на финале.
    var celebrate: Bool = false
    /// Метка-подпись над полем — "ВВОД", "ВЫДЕЛЕНИЕ", "✓ РЕЗУЛЬТАТ" и т.д.
    var phase: String? = nil
    /// Длительность кадра в секундах. Дефолт 0.6.
    var duration: Double = 0.6
}

private struct DemoScene {
    let title: String
    let frames: [DemoFrame]
}

private struct DemoStep: View {

    private let scenes: [DemoScene] = [
        // СЦЕНА 1: автозамена при пробеле
        DemoScene(
            title: "Автоматическая замена",
            frames: [
                .init(text: "",         caption: "Забыл переключить раскладку — печатай как есть",
                      phase: "ВВОД", duration: 1.0),
                .init(text: "g",        caption: "Печатаешь то что хотел сказать по-русски",
                      phase: "ВВОД", duration: 0.35),
                .init(text: "gh",       caption: "Печатаешь то что хотел сказать по-русски",
                      phase: "ВВОД", duration: 0.35),
                .init(text: "ghb",      caption: "Печатаешь то что хотел сказать по-русски",
                      phase: "ВВОД", duration: 0.35),
                .init(text: "ghbd",     caption: "Печатаешь то что хотел сказать по-русски",
                      phase: "ВВОД", duration: 0.35),
                .init(text: "ghbdt",    caption: "Печатаешь то что хотел сказать по-русски",
                      phase: "ВВОД", duration: 0.35),
                .init(text: "ghbdtn",   caption: "Это «привет», но в английской раскладке",
                      phase: "ВВОД", duration: 1.8),
                .init(text: "ghbdtn ",  caption: "Поставил пробел…",
                      phase: "ПРОБЕЛ", duration: 1.0),
                .init(text: "привет ",  caption: "Q*Й переключил раскладку и переписал слово",
                      highlighted: true, celebrate: true, phase: "✓ РЕЗУЛЬТАТ", duration: 3.0),
            ]
        ),

        // СЦЕНА 2: переключение между оригиналом и заменой
        DemoScene(
            title: "Если нужно — переключи обратно",
            frames: [
                .init(text: "Скажи привет ",
                      caption: "Q*Й только что заменил слово автоматически",
                      highlighted: true, phase: "АВТОЗАМЕНА", duration: 2.4),
                .init(text: "Скажи привет ",
                      caption: "Не то что хотел? Жми Option в течение 5 секунд",
                      keyPress: "⌥", phase: "OPTION", duration: 2.0),
                .init(text: "Скажи ghbdtn ",
                      caption: "Слово вернулось как ты его печатал",
                      highlighted: true, celebrate: true, phase: "✓ ОРИГИНАЛ", duration: 2.6),
                .init(text: "Скажи ghbdtn ",
                      caption: "Передумал? Option ещё раз — снова замена",
                      keyPress: "⌥", phase: "OPTION", duration: 2.0),
                .init(text: "Скажи привет ",
                      caption: "Можешь переключаться туда-сюда сколько нужно",
                      highlighted: true, celebrate: true, phase: "✓ ЗАМЕНА", duration: 3.0),
            ]
        ),

        // СЦЕНА 3: три способа выделить + замена
        DemoScene(
            title: "Поменять уже написанное",
            frames: [
                .init(text: "Из чата: ghbdtn rfr ltkf",
                      caption: "Прислали текст в неправильной раскладке",
                      phase: "ИСХОДНЫЙ ТЕКСТ", duration: 2.0),

                // Способ 1: мышка — селекция растёт от 0
                .init(text: "Из чата: ghbdtn rfr ltkf",
                      caption: "Способ 1 — выделить мышкой",
                      phase: "СПОСОБ 1: МЫШКА", duration: 0.6),
                .init(text: "Из чата: ghbdtn rfr ltkf",
                      caption: "Способ 1 — выделить мышкой",
                      selection: NSRange(location: 9, length: 3),
                      phase: "СПОСОБ 1: МЫШКА", duration: 0.18),
                .init(text: "Из чата: ghbdtn rfr ltkf",
                      caption: "Способ 1 — выделить мышкой",
                      selection: NSRange(location: 9, length: 7),
                      phase: "СПОСОБ 1: МЫШКА", duration: 0.18),
                .init(text: "Из чата: ghbdtn rfr ltkf",
                      caption: "Способ 1 — выделить мышкой",
                      selection: NSRange(location: 9, length: 11),
                      phase: "СПОСОБ 1: МЫШКА", duration: 0.18),
                .init(text: "Из чата: ghbdtn rfr ltkf",
                      caption: "Способ 1 — выделить мышкой",
                      selection: NSRange(location: 9, length: 16),
                      phase: "СПОСОБ 1: МЫШКА", duration: 1.4),

                // Способ 2: Shift+стрелка — растущее выделение с key badge
                .init(text: "Из чата: ghbdtn rfr ltkf",
                      caption: "Способ 2 — Shift со стрелкой",
                      phase: "СПОСОБ 2: SHIFT+→", duration: 0.5),
                .init(text: "Из чата: ghbdtn rfr ltkf",
                      caption: "Способ 2 — Shift со стрелкой",
                      selection: NSRange(location: 9, length: 4),
                      keyPress: "⇧→",
                      phase: "СПОСОБ 2: SHIFT+→", duration: 0.4),
                .init(text: "Из чата: ghbdtn rfr ltkf",
                      caption: "Способ 2 — Shift со стрелкой",
                      selection: NSRange(location: 9, length: 9),
                      keyPress: "⇧→",
                      phase: "СПОСОБ 2: SHIFT+→", duration: 0.4),
                .init(text: "Из чата: ghbdtn rfr ltkf",
                      caption: "Способ 2 — Shift со стрелкой",
                      selection: NSRange(location: 9, length: 16),
                      keyPress: "⇧→",
                      phase: "СПОСОБ 2: SHIFT+→", duration: 1.2),

                // Способ 3: Cmd+A — мгновенное выделение
                .init(text: "Из чата: ghbdtn rfr ltkf",
                      caption: "Способ 3 — Cmd+A: всё разом",
                      phase: "СПОСОБ 3: CMD+A", duration: 0.5),
                .init(text: "Из чата: ghbdtn rfr ltkf",
                      caption: "Способ 3 — Cmd+A: всё разом",
                      selection: NSRange(location: 0, length: 25),
                      keyPress: "⌘A",
                      phase: "СПОСОБ 3: CMD+A", duration: 1.6),

                // Действие — Option на полное выделение (как в способах 1 и 2)
                .init(text: "Из чата: ghbdtn rfr ltkf",
                      caption: "Выделил — теперь жми Option",
                      selection: NSRange(location: 9, length: 16),
                      keyPress: "⌥",
                      phase: "OPTION", duration: 2.0),

                // Результат
                .init(text: "Из чата: привет как дела",
                      caption: "Выделенное переведено — остальной текст не тронут",
                      highlighted: true, celebrate: true,
                      phase: "✓ РЕЗУЛЬТАТ", duration: 3.2),
            ]
        ),

        // СЦЕНА 4: транслитерация
        DemoScene(
            title: "Имя латиницей одной кнопкой",
            frames: [
                .init(text: "Иванов Иван",
                      caption: "Нужно написать имя латиницей — для визы или формы",
                      phase: "ИСХОДНЫЙ ТЕКСТ", duration: 1.8),
                .init(text: "Иванов Иван",
                      caption: "Выдели имя",
                      selection: NSRange(location: 0, length: 4),
                      phase: "ВЫДЕЛЕНИЕ", duration: 0.18),
                .init(text: "Иванов Иван",
                      caption: "Выдели имя",
                      selection: NSRange(location: 0, length: 8),
                      phase: "ВЫДЕЛЕНИЕ", duration: 0.18),
                .init(text: "Иванов Иван",
                      caption: "Выдели имя",
                      selection: NSRange(location: 0, length: 11),
                      phase: "ВЫДЕЛЕНИЕ", duration: 1.2),
                .init(text: "Иванов Иван",
                      caption: "Нажми Option+Shift+T",
                      selection: NSRange(location: 0, length: 11),
                      keyPress: "⌥⇧T",
                      phase: "ХОТКЕЙ", duration: 1.8),
                .init(text: "Ivanov Ivan",
                      caption: "Получилось латиницей — паспортные органы такое принимают",
                      highlighted: true, celebrate: true,
                      phase: "✓ РЕЗУЛЬТАТ", duration: 3.0),
            ]
        ),

        // СЦЕНА 5: расстановка пунктуации и опечаток через AI
        DemoScene(
            title: "Пунктуация и опечатки одной кнопкой",
            frames: [
                .init(text: "купил масло хлеб молоко",
                      caption: "Написал быстро, без знаков препинания",
                      phase: "ИСХОДНЫЙ ТЕКСТ", duration: 1.8),
                .init(text: "купил масло хлеб молоко",
                      caption: "Не нужно ничего выделять — Q*Й сам возьмёт строку",
                      phase: "БЕЗ ВЫДЕЛЕНИЯ", duration: 1.8),
                .init(text: "купил масло хлеб молоко",
                      caption: "Жми правый Option",
                      keyPress: "⌥",
                      phase: "ХОТКЕЙ", duration: 1.8),
                .init(text: "Купил масло, хлеб, молоко.",
                      caption: "AI расставил запятые и заглавные. Если что-то не так — левый Option откатит",
                      highlighted: true, celebrate: true,
                      phase: "✓ РЕЗУЛЬТАТ", duration: 3.2),
            ]
        ),
    ]

    @State private var sceneIndex: Int = 0
    @State private var frameIndex: Int = 0
    @State private var timer: Timer?
    @State private var fieldScale: CGFloat = 1.0
    @State private var greenTint: Double = 0  // 0..1 — насыщенность зелёной заливки

    var body: some View {
        VStack(spacing: 14) {
            Spacer().frame(height: 4)

            VStack(spacing: 4) {
                Text("Как это работает")
                    .font(.system(size: 20, weight: .semibold))
                Text(currentScene.title)
                    .font(.system(size: 13))
                    .foregroundColor(.accentColor)
                    .id(sceneIndex)
                    .transition(.opacity)
            }

            // Фаза-метка над полем — подсказка что сейчас происходит
            Text(currentFrame.phase ?? " ")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.5)
                .foregroundColor(currentFrame.celebrate ? .green : .secondary)
                .id(currentFrame.phase ?? "")
                .transition(.opacity)

            // «Окно ввода» с overlay-keypress + green flash при celebrate
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.green.opacity(greenTint))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(borderColor, lineWidth: borderWidth)
                    )
                    .shadow(color: shadowColor, radius: 12, x: 0, y: 0)
                    .animation(.easeInOut(duration: 0.25), value: currentFrame.highlighted)

                HStack(spacing: 0) {
                    AnimatedTextLine(frame: currentFrame, greenTint: greenTint)
                        .padding(.horizontal, 14)
                    Spacer()

                    // ✓ Чек-марк появляется при celebrate-кадре
                    if currentFrame.celebrate {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.green)
                            .padding(.trailing, 14)
                            .transition(.opacity.combined(with: .scale))
                    }
                }

                // Всплывающая пилюля «нажата клавиша»
                if let key = currentFrame.keyPress {
                    KeyPressBadge(key: key)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.bottom, 56)
                        .transition(.opacity.combined(with: .scale))
                }
            }
            .scaleEffect(fieldScale)
            .frame(height: 70)
            .padding(.horizontal, 32)

            Text(currentFrame.caption)
                .multilineTextAlignment(.center)
                .font(.system(size: 12.5))
                .foregroundColor(.secondary)
                .frame(height: 36)
                .padding(.horizontal, 32)
                .id(currentFrame.caption)
                .transition(.opacity)

            // Управление сценами — стрелки, точки, счётчик
            HStack(spacing: 14) {
                Button {
                    goToScene(sceneIndex - 1)
                } label: {
                    Image(systemName: "chevron.left.circle.fill")
                        .font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .foregroundColor(sceneIndex > 0 ? .accentColor : .secondary.opacity(0.4))
                .disabled(sceneIndex == 0)

                HStack(spacing: 6) {
                    ForEach(0..<scenes.count, id: \.self) { i in
                        Capsule()
                            .fill(i == sceneIndex ? Color.accentColor : Color.secondary.opacity(0.25))
                            .frame(width: i == sceneIndex ? 22 : 8, height: 6)
                            .animation(.easeInOut(duration: 0.3), value: sceneIndex)
                            .onTapGesture { goToScene(i) }
                    }
                }

                Button {
                    goToScene(sceneIndex + 1)
                } label: {
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .foregroundColor(sceneIndex < scenes.count - 1 ? .accentColor : .secondary.opacity(0.4))
                .disabled(sceneIndex >= scenes.count - 1)
            }
            .padding(.top, 2)

            Text("Сцена \(sceneIndex + 1) из \(scenes.count) · нажми ▶ для следующей")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            Spacer()
        }
        .onAppear { startScene() }
        .onDisappear { stopTimer() }
        .onChange(of: frameIndex) { _ in
            if currentFrame.celebrate { triggerApproval() }
        }
    }

    private var currentScene: DemoScene { scenes[sceneIndex] }
    private var currentFrame: DemoFrame { currentScene.frames[frameIndex] }

    private var borderColor: Color {
        if currentFrame.celebrate || greenTint > 0.05 { return .green }
        return currentFrame.highlighted ? .accentColor : .secondary.opacity(0.3)
    }

    private var borderWidth: CGFloat {
        currentFrame.highlighted || currentFrame.celebrate ? 2 : 1
    }

    private var shadowColor: Color {
        if currentFrame.celebrate { return .green.opacity(0.45) }
        return currentFrame.highlighted ? .accentColor.opacity(0.3) : .clear
    }

    private func triggerApproval() {
        // Зелёная заливка + лёгкий зум — нативный «approved»-сигнал.
        fieldScale = 1.0
        greenTint = 0
        withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) {
            fieldScale = 1.05
            greenTint = 0.28
        }
        withAnimation(.easeOut(duration: 0.55).delay(0.35)) {
            fieldScale = 1.0
            greenTint = 0
        }
    }

    private func startScene() {
        frameIndex = 0
        scheduleNextFrame()
        if currentFrame.celebrate { triggerApproval() }
    }

    private func goToScene(_ idx: Int) {
        guard idx >= 0, idx < scenes.count, idx != sceneIndex else { return }
        timer?.invalidate()
        withAnimation {
            sceneIndex = idx
            frameIndex = 0
        }
        scheduleNextFrame()
        if currentFrame.celebrate { triggerApproval() }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func scheduleNextFrame() {
        let dur = currentFrame.duration
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: dur, repeats: false) { _ in
            DispatchQueue.main.async {
                advanceFrame()
            }
        }
    }

    /// Авто-проигрывание кадров. Сцена крутится в цикле — после
    /// последнего кадра возвращаемся к первому. Сцены меняются только вручную.
    private func advanceFrame() {
        let next = (frameIndex + 1) % currentScene.frames.count
        withAnimation { frameIndex = next }
        scheduleNextFrame()
        if currentScene.frames[next].celebrate {
            triggerApproval()
        }
    }
}


private struct AnimatedTextLine: View {
    let frame: DemoFrame
    var greenTint: Double = 0  // подкрашиваем текст в зелёный во время approval-вспышки

    private var textColor: Color {
        if greenTint > 0.05 { return .green }
        return .primary
    }

    var body: some View {
        HStack(spacing: 0) {
            highlightedText
            if !frame.text.hasSuffix(" ") && !frame.text.isEmpty {
                BlinkingCaret().padding(.leading, 1)
            }
        }
    }

    @ViewBuilder
    private var highlightedText: some View {
        let text = frame.text
        if let sel = frame.selection,
           sel.location >= 0,
           sel.location + sel.length <= text.count {
            let chars = Array(text)
            let before = String(chars[0..<sel.location])
            let inside = String(chars[sel.location..<(sel.location + sel.length)])
            let after = String(chars[(sel.location + sel.length)..<chars.count])
            HStack(spacing: 0) {
                Text(before).demoTextStyle().foregroundColor(textColor)
                Text(inside).demoTextStyle().foregroundColor(textColor)
                    .padding(.horizontal, 0)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentColor.opacity(0.4))
                    )
                Text(after).demoTextStyle().foregroundColor(textColor)
            }
        } else {
            Text(text).demoTextStyle().foregroundColor(textColor)
        }
    }
}

private extension Text {
    func demoTextStyle() -> Text {
        self.font(.system(size: 22, weight: .medium, design: .monospaced))
    }
}

private struct KeyPressBadge: View {
    let key: String
    @State private var scale: CGFloat = 0.6
    @State private var opacity: Double = 0

    var body: some View {
        Text(key)
            .font(.system(size: 18, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: Color.accentColor.opacity(0.6), radius: 8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.accentColor, lineWidth: 1.5)
                    )
            )
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    scale = 1.0
                    opacity = 1.0
                }
            }
    }
}

private struct BlinkingCaret: View {
    @State private var on = true
    var body: some View {
        Rectangle()
            .fill(Color.primary)
            .frame(width: 2, height: 26)
            .opacity(on ? 1 : 0)
            .onAppear {
                Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                    on.toggle()
                }
            }
    }
}


// MARK: - Шаг 3: разрешения + хоткеи

private struct PermissionStep: View {
    @State private var trusted: Bool = AXIsProcessTrusted()
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            VStack(spacing: 6) {
                Text("Последний шаг")
                    .font(.system(size: 22, weight: .semibold))
                Text("Q*Й нужны два уровня доступа чтобы ловить нажатия и менять текст")
                    .multilineTextAlignment(.center)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 40)
            }

            VStack(spacing: 10) {
                PermissionRow(
                    icon: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    iconColor: trusted ? .green : .orange,
                    title: "Универсальный доступ (Accessibility)",
                    subtitle: trusted
                        ? "Разрешение получено — Q*Й видит нажатия клавиш"
                        : "Открой Системные настройки → Конфиденциальность → Универсальный доступ и добавь Q*Й",
                    actionLabel: trusted ? nil : "Открыть настройки",
                    action: trusted ? nil : openAccessibility
                )
            }
            .padding(.horizontal, 40)

            Divider().padding(.horizontal, 80)

            VStack(alignment: .leading, spacing: 8) {
                Text("Хоткеи по умолчанию")
                    .font(.system(size: 13, weight: .semibold))
                HotkeyHint(symbol: "⌥", desc: "Сменить раскладку выделения / последнего слова. Повторное нажатие в 5с — откат.")
                HotkeyHint(symbol: "⌥⇧S", desc: "Принудительный свап.")
                HotkeyHint(symbol: "⌥⇧T", desc: "Транслитерация русского в латиницу.")
            }
            .padding(.horizontal, 40)

            Spacer()
        }
        .onAppear {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                let now = AXIsProcessTrusted()
                if now != trusted { trusted = now }
            }
        }
        .onDisappear { pollTimer?.invalidate() }
    }

    private func openAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Шаг 4: звезда на GitHub

private struct StarStep: View {
    @State private var opened = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.yellow.opacity(0.15))
                    .frame(width: 110, height: 110)
                Image(systemName: opened ? "star.fill" : "star")
                    .font(.system(size: 56, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.yellow, Color.orange],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .scaleEffect(opened ? 1.15 : 1.0)
                    .animation(.spring(response: 0.4, dampingFraction: 0.55), value: opened)
            }

            VStack(spacing: 8) {
                Text("Готово!")
                    .font(.system(size: 22, weight: .semibold))
                Text("Q*Й — открытое и бесплатное приложение. Если оно тебе полезно — поддержи звездой на GitHub. Это самое простое спасибо автору.")
                    .multilineTextAlignment(.center)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 50)
            }

            Button {
                if let url = URL(string: "https://github.com/graninilya/keyswitcher") {
                    NSWorkspace.shared.open(url)
                    opened = true
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "star.fill")
                    Text(opened ? "Спасибо!" : "Поставить звезду")
                }
                .padding(.horizontal, 6)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.yellow)
            .disabled(opened)

            Spacer()
        }
    }
}

private struct PermissionRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundColor(iconColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let label = actionLabel, let action = action {
                    Button(label, action: action)
                        .controlSize(.small)
                        .padding(.top, 4)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}

private struct HotkeyHint: View {
    let symbol: String
    let desc: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(symbol)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.secondary.opacity(0.15))
                )
                .frame(minWidth: 50, alignment: .leading)
            Text(desc)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }
}
