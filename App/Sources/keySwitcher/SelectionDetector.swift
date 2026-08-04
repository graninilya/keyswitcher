import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// AX вместо симуляции Cmd+C: иначе в Word/Pages/Notes Cmd+C без выделения
/// копирует всю текущую строку — и мы получаем ложное «выделение».
struct SelectionInfo {
    let text: String
    let length: Int
    /// nil если приложение не отдаёт.
    let totalCharacters: Int?
}

enum SelectionDetector {

    /// Буфер набора защищён отдельно, а этот путь читает текст напрямую из поля —
    /// без такой же проверки пароль утёк бы через выделение.
    static var isSecureFieldFocused: Bool { SecureInput.isEnabled }

    /// AX-запрос синхронный: без ограничения зависшее приложение в фокусе
    /// подвесило бы хоткей вместе с собой.
    private static let messagingTimeout: Float = 0.25

    static func currentSelectionInfo() -> SelectionInfo? {
        guard !isSecureFieldFocused else {
            Log.selection.info("secure input активен — выделение не читаем")
            return nil
        }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, focusedRef != nil else {
            return nil
        }
        let element = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)

        var rangeRef: CFTypeRef?
        let rRange = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        )
        guard rRange == .success, let raw = rangeRef,
              CFGetTypeID(raw) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = raw as! AXValue
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        guard range.length > 0 else { return nil }

        var selRef: CFTypeRef?
        let rSel = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &selRef
        )
        guard rSel == .success, let text = selRef as? String, !text.isEmpty else {
            return nil
        }

        var totalRef: CFTypeRef?
        var total: Int? = nil
        if AXUIElementCopyAttributeValue(
            element, kAXNumberOfCharactersAttribute as CFString, &totalRef
        ) == .success, let n = totalRef as? Int {
            total = n
        }

        Log.selection.info("range loc=\(range.location) len=\(range.length) total=\(String(describing: total), privacy: .public) text='\(Log.redact(text), privacy: .public)'")
        return SelectionInfo(text: text, length: range.length, totalCharacters: total)
    }

    static func currentSelectedText() -> String? {
        return currentSelectionInfo()?.text
    }

    static func expandToParagraphAndReturnText() -> String? {
        guard !isSecureFieldFocused else {
            Log.selection.info("secure input активен — параграф не читаем")
            return nil
        }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, focusedRef != nil else { return nil }
        let element = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &valueRef
        ) == .success, let text = valueRef as? String else { return nil }

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        ) == .success, let raw = rangeRef,
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let axValue = raw as! AXValue
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }

        let ns = text as NSString

        var totalRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXNumberOfCharactersAttribute as CFString, &totalRef
        ) == .success, let total = totalRef as? Int, total != ns.length {
            Log.selection.info("AX value truncated: total=\(total) value-len=\(ns.length) — bail")
            return nil
        }

        var paraStart = max(0, min(range.location, ns.length))
        while paraStart > 0 {
            if ns.character(at: paraStart - 1) == 0x0A { break }
            paraStart -= 1
        }
        var paraEnd = max(0, min(range.location + range.length, ns.length))
        while paraEnd < ns.length {
            if ns.character(at: paraEnd) == 0x0A { break }
            paraEnd += 1
        }
        guard paraEnd > paraStart else { return nil }

        let hasNewlineBefore = paraStart > 0
        let hasNewlineAfter = paraEnd < ns.length
        if !hasNewlineBefore && !hasNewlineAfter && (paraEnd - paraStart) < 200 {
            Log.selection.info("AX value spans short text without \\n bounds — likely visible-line-only — bail")
            return nil
        }

        var newRange = CFRange(location: paraStart, length: paraEnd - paraStart)
        guard let newAX = AXValueCreate(.cfRange, &newRange) else { return nil }
        let setResult = AXUIElementSetAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, newAX
        )
        guard setResult == .success else { return nil }

        var verifyRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &verifyRef
        ) == .success,
              let vRaw = verifyRef,
              CFGetTypeID(vRaw) == AXValueGetTypeID() else { return nil }
        var verified = CFRange(location: 0, length: 0)
        guard AXValueGetValue(vRaw as! AXValue, .cfRange, &verified) else { return nil }
        guard verified.location == paraStart, verified.length == paraEnd - paraStart else {
            Log.selection.info("AX setSelectedTextRange ignored by app — fallback")
            return nil
        }

        return ns.substring(with: NSRange(location: paraStart, length: paraEnd - paraStart))
    }
}
