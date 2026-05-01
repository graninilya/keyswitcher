import Foundation
import os.log

/// Унифицированный логгер. В Console.app или через
/// `log show --predicate 'subsystem == "com.granin.keyswitcher"' --info --last 5m`
enum Log {
    private static let subsystem = "com.granin.keyswitcher"

    static let buffer    = Logger(subsystem: subsystem, category: "Buffer")
    static let selection = Logger(subsystem: subsystem, category: "Selection")
    static let clipboard = Logger(subsystem: subsystem, category: "Clipboard")
    static let auto      = Logger(subsystem: subsystem, category: "Auto")
    static let hotkey    = Logger(subsystem: subsystem, category: "Hotkey")
    static let detector  = Logger(subsystem: subsystem, category: "Detector")
}
