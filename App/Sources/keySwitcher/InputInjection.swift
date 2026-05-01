import AppKit

/// Единая точка для всей симуляции ввода (backspace, Cmd+C/V, набор Unicode).
/// Главная задача — мьютить KeystrokeBuffer чтобы наши же синтетические события
/// не попадали обратно в буфер и не «загрязняли» currentWord.
final class InputInjection {
    static let shared = InputInjection()

    private var muteRefCount = 0
    private let muteAfterInjection: TimeInterval = 0.2

    private init() {}

    func sendCommand(keyCode: CGKeyCode) {
        muteAndPost { src in
            let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    func sendKey(keyCode: CGKeyCode) {
        muteAndPost { src in
            let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
            // Принудительно очищаем флаги — иначе наследуются модификаторы пользователя
            // (например, удерживаемый Option превратит Backspace в Option+Backspace = удалить слово)
            down?.flags = []
            up?.flags = []
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    func sendBackspaces(_ count: Int) {
        muteAndPost { src in
            for _ in 0..<count {
                let down = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: true)
                let up = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: false)
                down?.flags = []
                up?.flags = []
                down?.post(tap: .cghidEventTap)
                up?.post(tap: .cghidEventTap)
            }
        }
    }

    func typeUnicode(_ text: String) {
        muteAndPost { src in
            let utf16: [UniChar] = Array(text.utf16)
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            else { return }
            utf16.withUnsafeBufferPointer { buf in
                down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            }
            down.flags = []
            up.flags = []
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    /// Мьютит буфер на время инжекции и 200 мс после (чтобы события успели прийти
    /// обратно через event tap). Поддерживает вложенные вызовы через ref count.
    /// Использует privateState — не наследует модификаторы пользователя.
    private func muteAndPost(_ work: (CGEventSource?) -> Void) {
        let buf = KeystrokeBuffer.shared
        muteRefCount += 1
        buf.muted = true

        // privateState вместо combinedSessionState — не тащит за собой удерживаемые
        // пользователем модификаторы (Option, Cmd, Shift и т.п.)
        let src = CGEventSource(stateID: .privateState)
        work(src)

        DispatchQueue.main.asyncAfter(deadline: .now() + muteAfterInjection) { [weak self] in
            guard let self = self else { return }
            self.muteRefCount -= 1
            if self.muteRefCount <= 0 {
                self.muteRefCount = 0
                buf.muted = false
            }
        }
    }
}
