import AppKit

final class InputInjection {
    static let shared = InputInjection()

    /// Запасной режим на случай, если метка синтетики не доедет обратно (см. SyntheticTag).
    private var muteRefCount = 0
    private let muteAfterInjection: TimeInterval = 0.2

    /// privateState вместо combinedSessionState — не наследует удерживаемые юзером
    /// модификаторы.
    ///
    /// Источник создаём заново на каждую отправку. Кэшированный экземпляр со временем
    /// перестаёт доставлять события приложениям: сами события создаются и даже
    /// возвращаются в наш перехватчик, но адресат их не получает.
    private var source: CGEventSource? { CGEventSource(stateID: .privateState) }

    private init() {}

    func sendCommand(keyCode: CGKeyCode) {
        sendChord(keyCode: keyCode, flags: .maskCommand, modifierKeys: [55])
    }

    func sendCommandShift(keyCode: CGKeyCode) {
        sendChord(keyCode: keyCode, flags: [.maskCommand, .maskShift], modifierKeys: [55, 56])
    }

    /// Полная последовательность аккорда: нажатие модификаторов, клавиша, отпускание.
    ///
    /// Раньше отправлялись только keyDown/keyUp с выставленным флагом. Нативные поля
    /// это принимают, а Chromium и Electron отслеживают состояние модификаторов по
    /// событиям flagsChanged и такое сочетание игнорируют — ⌘C в них не срабатывал.
    private func sendChord(keyCode: CGKeyCode, flags: CGEventFlags, modifierKeys: [CGKeyCode]) {
        emit { src in
            var events: [CGEvent] = []
            var accumulated: CGEventFlags = []

            for mod in modifierKeys {
                guard let down = CGEvent(keyboardEventSource: src, virtualKey: mod, keyDown: true) else { continue }
                down.type = .flagsChanged
                accumulated.insert(flagFor(mod))
                down.flags = accumulated
                events.append(down)
            }

            if let keyDown = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
               let keyUp = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
                keyDown.flags = flags
                keyUp.flags = flags
                events.append(keyDown)
                events.append(keyUp)
            }

            for mod in modifierKeys.reversed() {
                guard let up = CGEvent(keyboardEventSource: src, virtualKey: mod, keyDown: false) else { continue }
                up.type = .flagsChanged
                accumulated.remove(flagFor(mod))
                up.flags = accumulated
                events.append(up)
            }
            return events
        }
    }

    private func flagFor(_ modifierKey: CGKeyCode) -> CGEventFlags {
        switch modifierKey {
        case 55, 54: return .maskCommand
        case 56, 60: return .maskShift
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        default:     return []
        }
    }

    func sendKey(keyCode: CGKeyCode) {
        emit { src in
            let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
            // Очищаем флаги: удерживаемый юзером Option превратил бы Backspace в «удалить слово»
            down?.flags = []
            up?.flags = []
            return [down, up].compactMap { $0 }
        }
    }

    func sendBackspaces(_ count: Int) {
        guard count > 0 else { return }
        emit { src in
            var events: [CGEvent] = []
            events.reserveCapacity(count * 2)
            for _ in 0..<count {
                guard let down = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: true),
                      let up = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: false)
                else { continue }
                down.flags = []
                up.flags = []
                events.append(down)
                events.append(up)
            }
            return events
        }
    }

    func typeUnicode(_ text: String) {
        guard !text.isEmpty else { return }
        emit { src in
            let utf16: [UniChar] = Array(text.utf16)
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            else { return [] }
            utf16.withUnsafeBufferPointer { buf in
                down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            }
            down.flags = []
            up.flags = []
            return [down, up]
        }
    }

    /// Помечает каждое событие как наше и отправляет. Пока метка подтверждена,
    /// окно глушения не нужно — буфер отличает своё по признаку, а не по времени.
    private func emit(_ build: (CGEventSource?) -> [CGEvent]) {
        let events = build(source)
        guard !events.isEmpty else { return }

        for e in events { SyntheticTag.mark(e) }

        if SyntheticTag.unreliable { beginLegacyMute() }

        for e in events { e.post(tap: .cghidEventTap) }
    }

    private func beginLegacyMute() {
        let buf = KeystrokeBuffer.shared
        muteRefCount += 1
        buf.muted = true
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
