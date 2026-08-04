import Foundation
import Security

/// Ключ от стороннего API лежал в UserDefaults открытым текстом — то есть в plist,
/// доступном любому процессу пользователя, и уезжал в бэкапы.
enum KeychainStore {
    private static let service = "com.granin.keyswitcher"

    /// Отличаем «ключа нет» от «прочитать не удалось»: во втором случае затирать
    /// хранилище нельзя — там может лежать рабочий ключ.
    static func readStatus(_ account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil)
    }

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        guard !value.isEmpty else {
            // Пустое значение удаляет запись только если мы уверены, что читали её
            // успешно. Иначе сбой чтения приводил бы к потере рабочего ключа.
            let status = readStatus(account)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                Log.clipboard.error("Keychain недоступен (\(status, privacy: .public)) — ключ не трогаю")
                return false
            }
            return delete(account)
        }
        guard let data = value.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { current, _ in current }
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
