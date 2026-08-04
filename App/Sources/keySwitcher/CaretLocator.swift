import AppKit
import ApplicationServices

/// Где сейчас каретка — чтобы показывать плашку рядом с текстом, а не в углу экрана.
enum CaretLocator {

    private static let messagingTimeout: Float = 0.25

    /// Прямоугольник каретки в координатах экрана (начало отсчёта снизу, как у AppKit).
    /// nil, если приложение не отдаёт положение — тогда остаётся курсор мыши.
    static func caretRect() -> CGRect? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, focusedRef != nil else { return nil }
        let element = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        ) == .success, let rawRange = rangeRef,
              CFGetTypeID(rawRange) == AXValueGetTypeID() else { return nil }

        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rawRange as! AXValue, .cfRange, &range) else { return nil }

        // Нулевой диапазон: просим границы одного символа, иначе часть приложений
        // возвращает пустой прямоугольник.
        var probe = CFRange(location: range.location, length: max(1, range.length))
        guard let probeValue = AXValueCreate(.cfRange, &probe) else { return nil }

        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString,
            probeValue, &boundsRef
        ) == .success, let rawBounds = boundsRef,
              CFGetTypeID(rawBounds) == AXValueGetTypeID() else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(rawBounds as! AXValue, .cgRect, &rect) else { return nil }
        guard rect.width.isFinite, rect.height.isFinite, rect.height > 0 else { return nil }

        return flipToScreenCoordinates(rect)
    }

    /// AX отдаёт координаты с началом в левом верхнем углу главного экрана,
    /// AppKit — в левом нижнем. Без пересчёта плашка уезжает за пределы экрана.
    private static func flipToScreenCoordinates(_ rect: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return rect }
        let maxY = primary.frame.maxY
        return CGRect(x: rect.origin.x,
                      y: maxY - rect.origin.y - rect.height,
                      width: rect.width, height: rect.height)
    }

    /// Точка, рядом с которой уместно показать плашку: под кареткой, а если её
    /// положение неизвестно — под курсором мыши.
    static func anchorPoint() -> CGPoint {
        if let caret = caretRect() {
            return CGPoint(x: caret.minX, y: caret.minY)
        }
        return NSEvent.mouseLocation
    }
}
