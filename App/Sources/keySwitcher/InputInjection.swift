import AppKit

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
            // Очищаем флаги: удерживаемый юзером Option превратил бы Backspace в «удалить слово»
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

    /// Поддерживает вложенные вызовы через ref count; держит mute ещё 200 мс,
    /// чтобы синтетические события успели прилететь обратно через event tap.
    private func muteAndPost(_ work: (CGEventSource?) -> Void) {
        let buf = KeystrokeBuffer.shared
        muteRefCount += 1
        buf.muted = true

        // privateState вместо combinedSessionState — не наследует удерживаемые юзером модификаторы
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
