import AppKit
import SwiftUI

/// Окно настроек. Показываем отдельным NSWindow, но контент — SwiftUI.
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    private init() {}

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsView()
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.title = "Q*Й — настройки"
        w.styleMask = [.titled, .closable]
        w.setContentSize(NSSize(width: 520, height: 420))
        w.center()
        w.isReleasedWhenClosed = false
        self.window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}


// MARK: - SwiftUI views

struct SettingsView: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Toggle("", isOn: $settings.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                Text("Включено")
                    .font(.system(size: 14, weight: .medium))
                Spacer()
            }
            .padding(.bottom, 18)

            sectionHeader("Горячие клавиши")

            VStack(spacing: 8) {
                HotkeyRow(
                    title: "Умная конверсия",
                    subtitle: "Выделение или последнее слово",
                    binding: Binding(
                        get: { settings.hotkeys.smartConvert },
                        set: { settings.hotkeys.smartConvert = $0 }
                    ),
                    allowsModifierOnly: true
                )
                HotkeyRow(
                    title: "Принудительная смена раскладки",
                    subtitle: "Без проверки детектором",
                    binding: Binding(
                        get: { settings.hotkeys.forceSwap },
                        set: { settings.hotkeys.forceSwap = $0 }
                    ),
                    allowsModifierOnly: false
                )
                HotkeyRow(
                    title: "Транслитерация",
                    subtitle: "Кириллица → латиница (по ГОСТ)",
                    binding: Binding(
                        get: { settings.hotkeys.transliterate },
                        set: { settings.hotkeys.transliterate = $0 }
                    ),
                    allowsModifierOnly: false
                )
                HotkeyRow(
                    title: "Включить / выключить Q*Й",
                    subtitle: nil,
                    binding: Binding(
                        get: { settings.hotkeys.toggleEnabled },
                        set: { settings.hotkeys.toggleEnabled = $0 }
                    ),
                    allowsModifierOnly: true
                )
            }
            .padding(.bottom, 18)

            sectionHeader("Поведение")

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Звуковой сигнал на замену", isOn: $settings.soundsEnabled)
                Toggle("Запускать при входе в систему", isOn: $settings.launchAtLogin)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Сбросить хоткеи") {
                    settings.hotkeys = HotkeyConfig.default
                }
                .controlSize(.small)
            }
            .padding(.top, 12)
        }
        .padding(24)
        .frame(width: 540, height: 460)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .tracking(0.5)
            .padding(.bottom, 8)
    }
}


struct HotkeyRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var binding: HotkeyBinding
    let allowsModifierOnly: Bool

    @State private var isRecording = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
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
        .padding(.vertical, 2)
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


/// NSView, которая ловит клавиши когда «в режиме записи».
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
        if event.keyCode == 53 {  // Esc — отмена
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
            // Отпустили — если это тот же модификатор и быстро — записываем
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
