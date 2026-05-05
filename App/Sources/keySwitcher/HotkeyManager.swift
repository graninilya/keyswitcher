import AppKit
import Carbon.HIToolbox

/// Carbon-хоткеи работают без AX-разрешений (в отличие от CGEventTap).
final class HotkeyManager {
    private var nextID: UInt32 = 1
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var installedHandler = false

    func register(modifiers: NSEvent.ModifierFlags, key: KeyCode, action: @escaping () -> Void) {
        register(modifiers: modifiers, keyCodeRaw: UInt32(key.rawValue), action: action)
    }

    func register(modifiers: NSEvent.ModifierFlags, keyCodeRaw: UInt32, action: @escaping () -> Void) {
        installHandlerIfNeeded()

        let id = nextID
        nextID += 1
        handlers[id] = action

        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4B53_5743), id: id)  // 'KSWC'
        let carbonMods = carbonFlags(modifiers)
        let status = RegisterEventHotKey(
            keyCodeRaw,
            carbonMods,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr, let ref = hotKeyRef else {
            print("HotkeyManager: register failed status=\(status)")
            return
        }
        refs.append(ref)
    }

    func unregisterAll() {
        for ref in refs {
            UnregisterEventHotKey(ref)
        }
        refs.removeAll()
        handlers.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard !installedHandler else { return }
        installedHandler = true

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let eventRef = eventRef, let userData = userData else { return noErr }
                var hkID = EventHotKeyID()
                let err = GetEventParameter(
                    eventRef,
                    OSType(kEventParamDirectObject),
                    OSType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                guard err == noErr else { return err }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.handlers[hkID.id]?()
                return noErr
            },
            1,
            &spec,
            selfPtr,
            nil
        )
    }

    private func carbonFlags(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command)  { result |= UInt32(cmdKey) }
        if flags.contains(.option)   { result |= UInt32(optionKey) }
        if flags.contains(.shift)    { result |= UInt32(shiftKey) }
        if flags.contains(.control)  { result |= UInt32(controlKey) }
        return result
    }
}

enum KeyCode: Int {
    case a = 0
    case s = 1
    case d = 2
    case f = 3
    case h = 4
    case g = 5
    case z = 6
    case x = 7
    case c = 8
    case v = 9
    case b = 11
    case q = 12
    case w = 13
    case e = 14
    case r = 15
    case y = 16
    case t = 17
    case l = 37
    case n = 45
    case m = 46
    case space = 49
    case escape = 53
    case f5 = 96
}
