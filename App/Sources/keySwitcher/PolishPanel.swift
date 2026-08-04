import AppKit
import SwiftUI

/// Плашка AI-правки: показывает, что идёт работа, что получилось и что пошло не так.
///
/// Появляется рядом с кареткой — там, куда человек и так смотрит. В углу экрана её
/// приходилось искать глазами.
@MainActor
final class PolishPanel: ObservableObject {
    static let shared = PolishPanel()

    enum State {
        case working
        case preview(original: String, result: String)
        case failed(String)
        case done
    }

    /// Чем закончился предпросмотр.
    enum Decision {
        case accepted(String)
        case rejected
        case retry
    }

    @Published private(set) var state: State = .working
    @Published private(set) var visible = false

    private var window: NSPanel?
    private var autoClose: DispatchWorkItem?

    /// Кому вернуть фокус. Плашка забирает его только на предпросмотре, но печатать
    /// результат всё равно надо в исходное окно.
    private var previousApp: NSRunningApplication?

    /// Ровно один вызов на один показ: ожидающая сторона висит на continuation,
    /// и второй resume уронил бы приложение.
    private var decide: ((Decision) -> Void)?

    /// Растёт на каждый показ: ответ прошлой попытки не должен поднимать плашку,
    /// которую уже закрыли.
    private(set) var generation = 0

    private init() {}

    @discardableResult
    func beginSession() -> Int {
        generation += 1
        return generation
    }

    func showWorking() {
        finish(.rejected)
        state = .working
        // Без фокуса: захват текста ещё впереди, а ⌘C и чтение выделения работают
        // с активным окном. Забрав фокус здесь, плашка стала бы этим окном.
        present(takeFocus: false)
        scheduleAutoClose(after: 30)
    }

    func showPreview(generation token: Int, original: String, result: String,
                     decision: @escaping (Decision) -> Void) {
        guard token == generation else {
            decision(.rejected)
            return
        }
        finish(.rejected)
        decide = decision
        state = .preview(original: original, result: result)
        // Текст уже получен — теперь фокус нужен, иначе не работают Enter и Escape.
        present(takeFocus: true)
        scheduleAutoClose(after: 30)
    }

    func showError(_ message: String) {
        finish(.rejected)
        state = .failed(message)
        present(takeFocus: false)
        scheduleAutoClose(after: 5)
    }

    /// Короткая отметка об успехе вместо резкого исчезновения.
    func showDone() {
        finish(.rejected)
        state = .done
        present(takeFocus: false)
        scheduleAutoClose(after: 1.0)
    }

    func close() {
        generation += 1
        finish(.rejected)
        dismissWindow()
    }

    private func finish(_ decision: Decision) {
        guard let handler = decide else { return }
        decide = nil
        handler(decision)
    }

    private func dismissWindow() {
        autoClose?.cancel()
        autoClose = nil
        guard let closing = window else { return }
        window = nil

        // Гасим плавно, потом убираем окно — резкое исчезновение выглядит дёрганым.
        withAnimation(.easeIn(duration: 0.16)) { visible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.19) { closing.orderOut(nil) }

        previousApp?.activate()
        previousApp = nil
    }

    fileprivate func accept() {
        guard case .preview(_, let result) = state else { return }
        Log.clipboard.info("полировка принята")
        autoClose?.cancel()
        autoClose = nil

        let closing = window
        window = nil
        withAnimation(.easeIn(duration: 0.14)) { visible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { closing?.orderOut(nil) }

        restoreFocus { [weak self] in
            self?.finish(.accepted(result))
            self?.previousApp = nil
        }
    }

    fileprivate func reject() {
        Log.clipboard.info("полировка отклонена")
        finish(.rejected)
        dismissWindow()
    }

    fileprivate func retry() {
        finish(.retry)
        dismissWindow()
    }

    /// Вернуть фокус и дать системе время переключиться — только после этого можно
    /// печатать: иначе текст уйдёт в плашку, а не в поле пользователя.
    private func restoreFocus(then work: @escaping () -> Void) {
        guard let app = previousApp, !app.isActive else {
            work()
            return
        }
        app.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func scheduleAutoClose(after seconds: TimeInterval) {
        autoClose?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.close() }
        autoClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func present(takeFocus: Bool) {
        if previousApp == nil {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
                previousApp = front
            }
        }

        if let w = window {
            resize(w)
            positionNearCaret(w)
            if takeFocus { w.makeKeyAndOrderFront(nil) } else { w.orderFront(nil) }
            return
        }

        let hosting = NSHostingController(rootView: PolishPanelView(panel: self))
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: hosting.view.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false          // тень рисует SwiftUI, иначе видна вторая рамка
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        panel.animationBehavior = .none  // появление анимируем сами

        window = panel
        resize(panel)
        positionNearCaret(panel)
        if takeFocus { panel.makeKeyAndOrderFront(nil) } else { panel.orderFront(nil) }

        visible = false
        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) { visible = true }
    }

    /// Размер под текущее содержимое: состояния очень разные по объёму.
    private func resize(_ panel: NSPanel) {
        guard let view = panel.contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        guard size.width > 1, size.height > 1 else { return }
        panel.setContentSize(size)
    }

    /// Под кареткой и по возможности в пределах экрана.
    private func positionNearCaret(_ panel: NSPanel) {
        let anchor = CaretLocator.anchorPoint()
        let size = panel.frame.size
        let gap: CGFloat = 10

        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? .zero

        var x = anchor.x - 24
        var y = anchor.y - size.height - gap   // под строкой

        // Не влезает снизу — показываем над кареткой.
        if y < bounds.minY + 8 { y = anchor.y + gap * 2 }
        x = min(max(x, bounds.minX + 8), bounds.maxX - size.width - 8)
        y = min(max(y, bounds.minY + 8), bounds.maxY - size.height - 8)

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// Borderless-панель по умолчанию не может стать key-окном, а без этого
/// `keyboardShortcut` в SwiftUI не срабатывает.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}


// MARK: - Внешний вид

private struct PolishPanelView: View {
    @ObservedObject var panel: PolishPanel

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.regularMaterial)
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 0.6)
                }
            )
            .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
            .padding(12)                      // место для тени внутри окна
            .opacity(panel.visible ? 1 : 0)
            .scaleEffect(panel.visible ? 1 : 0.94, anchor: .top)
            .offset(y: panel.visible ? 0 : 6)
            .animation(.spring(response: 0.34, dampingFraction: 0.78), value: panel.visible)
    }

    @ViewBuilder
    private var content: some View {
        switch panel.state {
        case .working:
            HStack(spacing: 10) {
                PulsingDots()
                Text("Правлю")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }

        case .done:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.green)
                Text("Готово")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }

        case .failed(let message):
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 270, alignment: .leading)
            }

        case .preview(let original, let result):
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tint)
                    Text("Так лучше?")
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer(minLength: 12)
                }

                DiffRow(caption: "было", text: original, muted: true)
                DiffRow(caption: "стало", text: result, muted: false)

                HStack(spacing: 7) {
                    Spacer()
                    Button("Ещё раз") { panel.retry() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Button("Отклонить") { panel.reject() }
                        .keyboardShortcut(.escape, modifiers: [])
                        .controlSize(.small)
                    Button("Применить") { panel.accept() }
                        .keyboardShortcut(.return, modifiers: [])
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                .padding(.top, 1)
            }
            .frame(width: 330)
        }
    }
}

/// Три точки, перетекающие волной. Системный индикатор в маленькой плашке смотрится
/// инородно и не передаёт ощущение работы.
private struct PulsingDots: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 3.5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(.tint)
                    .frame(width: 5, height: 5)
                    .opacity(0.35 + wave(i) * 0.65)
                    .scaleEffect(0.82 + wave(i) * 0.32)
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }

    private func wave(_ index: Int) -> Double {
        let offset = Double(index) * 0.22
        return (sin((phase - offset) * .pi * 2) + 1) / 2
    }
}

private struct DiffRow: View {
    let caption: String
    let text: String
    let muted: Bool

    /// Длинный абзац в плашку не поместится — показываем начало и конец.
    private var displayText: String {
        let limit = 200
        guard text.count > limit else { return text }
        return text.prefix(limit / 2) + " … " + text.suffix(limit / 2 - 20)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.4)
            Text(displayText)
                .font(.system(size: 11.5))
                .foregroundStyle(muted ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.black.opacity(0.16))
                )
        }
    }
}
