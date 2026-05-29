import AppKit
import SwiftUI

enum RulePromoter {
    private static var window: NSWindow?

    static func propose(original: String, converted: String) {
        DispatchQueue.main.async {
            present(original: original, converted: converted)
        }
    }

    @MainActor
    private static func present(original: String, converted: String) {
        let view = RulePromoterView(
            original: original,
            converted: converted,
            onAccept: {
                Settings.shared.addForceSwap(original)
                Settings.shared.dismissForceSwapCandidate(original)
                close()
            },
            onDismiss: {
                Settings.shared.dismissForceSwapCandidate(original)
                close()
            }
        )

        let hosting = NSHostingController(rootView: view)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 170),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]

        if let screen = NSScreen.main {
            let rect = screen.visibleFrame
            let x = rect.maxX - 380
            let y = rect.maxY - 200
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window = panel
        panel.orderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            if self.window === panel { self.close() }
        }
    }

    @MainActor
    private static func close() {
        window?.orderOut(nil)
        window = nil
    }
}

private struct RulePromoterView: View {
    let original: String
    let converted: String
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text("Добавить в Правила?")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                Text(original)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.secondary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.7))
                Text(converted)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            Text("Ты уже 3 раза вручную свапал это слово. Если добавить в Правила — будет конвертиться автоматически.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Не сейчас", action: onDismiss)
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Добавить", action: onAccept)
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 4)
        )
        .frame(width: 360)
    }
}
