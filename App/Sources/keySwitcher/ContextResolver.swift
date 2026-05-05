import Foundation
import ApplicationServices

enum ContextResolver {

    static func dominantLanguageInFocusedElement() -> InputLanguage? {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, focusedRef != nil else { return nil }
        let element = focusedRef as! AXUIElement

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &valueRef
        ) == .success, let text = valueRef as? String, !text.isEmpty else {
            return nil
        }

        var cyr = 0, lat = 0
        for ch in text {
            if ("а"..."я").contains(ch) || ch == "ё"
               || ("А"..."Я").contains(ch) || ch == "Ё" {
                cyr += 1
            } else if ("a"..."z").contains(ch) || ("A"..."Z").contains(ch) {
                lat += 1
            }
        }
        guard cyr + lat >= 3 else { return nil }
        if cyr > lat { return .russian }
        if lat > cyr { return .english }
        return nil
    }
}
