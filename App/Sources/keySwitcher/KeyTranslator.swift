import Carbon
import AppKit

/// В отличие от NSEvent.charactersIgnoringModifiers — игнорирует dead key state,
/// поэтому возвращает `'` даже если это dead key для accented букв.
enum KeyTranslator {

    static func character(for event: CGEvent) -> Character? {
        let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        guard let layoutDataPtr = TISGetInputSourceProperty(
            source, kTISPropertyUnicodeKeyLayoutData
        ) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPtr).takeUnretainedValue() as Data

        let flags = event.flags
        var mods: UInt32 = 0
        if flags.contains(.maskShift)     { mods |= UInt32(shiftKey)   >> 8 }
        if flags.contains(.maskAlternate) { mods |= UInt32(optionKey)  >> 8 }
        if flags.contains(.maskControl)   { mods |= UInt32(controlKey) >> 8 }
        if flags.contains(.maskCommand)   { mods |= UInt32(cmdKey)     >> 8 }

        var deadKeyState: UInt32 = 0
        let maxLen = 4
        var buf = [UniChar](repeating: 0, count: maxLen)
        var actualLen = 0

        let status = layoutData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return -1
            }
            return UCKeyTranslate(
                layout, keycode, UInt16(kUCKeyActionDisplay),
                mods, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState, maxLen, &actualLen, &buf
            )
        }
        guard status == noErr, actualLen > 0 else { return nil }
        let str = String(utf16CodeUnits: buf, count: actualLen)
        return str.first
    }
}
