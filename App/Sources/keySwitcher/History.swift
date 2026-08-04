import Foundation

/// Журнал последних замен — чтобы было видно, что и почему сработало.
/// Живёт только в памяти: на диск текст пользователя не пишем.
final class History: ObservableObject {
    static let shared = History()

    struct Entry: Identifiable {
        let id = UUID()
        let at: Date
        let original: String
        let converted: String
        let kind: Kind
        let appName: String

        enum Kind: String {
            case auto = "авто"
            case manual = "хоткей"
            case retro = "цепочка"
            case polish = "AI"
            case revert = "откат"
        }
    }

    @Published private(set) var entries: [Entry] = []
    private let capacity = 100

    private init() {}

    func add(original: String, converted: String, kind: Entry.Kind) {
        let entry = Entry(at: Date(), original: original, converted: converted,
                          kind: kind, appName: AppRules.shared.currentAppName)
        entries.insert(entry, at: 0)
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
    }

    func clear() { entries.removeAll() }
}
