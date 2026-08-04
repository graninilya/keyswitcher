import AppKit

// Самопроверка детектора на реальных словарях — до поднятия UI.
if CommandLine.arguments.contains("--self-test") {
    SelfTest.run()
}
if CommandLine.arguments.contains("--test-injection") {
    SelfTest.testInjection()
}

// Второй экземпляр — это две копии перехватчика на одну клавиатуру: обе решают
// заменить слово, обе шлют свои нажатия и затирают работу друг друга. Внешне это
// выглядит как «иногда срабатывает, иногда портит текст».
let running = NSWorkspace.shared.runningApplications.filter {
    $0.bundleIdentifier == Bundle.main.bundleIdentifier
}
if running.count > 1 {
    // Уступаем дорогу тому, кто стартовал раньше, и показываем его окно настроек.
    let others = running.filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    others.first?.activate()
    NSLog("keySwitcher: экземпляр уже запущен — выхожу")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
