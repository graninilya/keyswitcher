import AppKit
import ApplicationServices

/// Определение наличия выделения через Accessibility API.
/// Без симуляции Cmd+C — это спасает от приложений, где Cmd+C без выделения
/// копирует всю текущую строку (Word, Pages, Notes и многие другие).
/// Информация о выделении.
struct SelectionInfo {
    let text: String
    let length: Int
    /// Общее число символов в фокусном элементе. nil если приложение не отдаёт.
    let totalCharacters: Int?

    /// Это «настоящее частичное» выделение (часть содержимого), а не вся строка/документ.
    /// Когда AX в проблемных приложениях врёт что выделена вся строка — totalCharacters == length,
    /// и мы не считаем это надёжным сигналом.
    var isPartial: Bool {
        guard let total = totalCharacters else { return true }  // total неизвестен — доверяем
        return length < total
    }
}

enum SelectionDetector {

    /// Полная информация о текущем выделении.
    static func currentSelectionInfo() -> SelectionInfo? {
        let system = AXUIElementCreateSystemWide()

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, focusedRef != nil else {
            return nil
        }
        let element = focusedRef as! AXUIElement

        // Длина выделения через range
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

        // Сам текст
        var selRef: CFTypeRef?
        let rSel = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &selRef
        )
        guard rSel == .success, let text = selRef as? String, !text.isEmpty else {
            return nil
        }

        // Общее число символов (если приложение отдаёт)
        var totalRef: CFTypeRef?
        var total: Int? = nil
        if AXUIElementCopyAttributeValue(
            element, kAXNumberOfCharactersAttribute as CFString, &totalRef
        ) == .success, let n = totalRef as? Int {
            total = n
        }

        Log.selection.info("range loc=\(range.location) len=\(range.length) total=\(String(describing: total), privacy: .public) text='\(text, privacy: .public)'")
        return SelectionInfo(text: text, length: range.length, totalCharacters: total)
    }

    /// Совместимость: возвращает только текст, если есть выделение (любое — partial или нет).
    static func currentSelectedText() -> String? {
        return currentSelectionInfo()?.text
    }

    private static func _legacyCurrentSelectedText_unused() -> String? {
        let system = AXUIElementCreateSystemWide()

        var focusedRef: CFTypeRef?
        let r1 = AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedRef
        )
        guard r1 == .success, focusedRef != nil else {
            Log.selection.info("focus query failed: \(r1.rawValue, privacy: .public)")
            return nil
        }
        let element = focusedRef as! AXUIElement

        var rangeRef: CFTypeRef?
        let r2 = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        )
        if r2 == .success, let raw = rangeRef, CFGetTypeID(raw) == AXValueGetTypeID() {
            let axValue = raw as! AXValue
            var range = CFRange(location: 0, length: 0)
            if AXValueGetValue(axValue, .cfRange, &range) {
                Log.selection.info("range loc=\(range.location) len=\(range.length)")
                if range.length == 0 {
                    return nil
                }
            }
        } else {
            Log.selection.info("range query failed: \(r2.rawValue, privacy: .public) — bail")
            return nil
        }

        var selected: CFTypeRef?
        let r3 = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &selected
        )
        guard r3 == .success, let text = selected as? String, !text.isEmpty else {
            Log.selection.info("text query failed or empty: \(r3.rawValue, privacy: .public)")
            return nil
        }
        Log.selection.info("got selected text: '\(text, privacy: .public)' (\(text.count) chars)")
        return text
    }
}
