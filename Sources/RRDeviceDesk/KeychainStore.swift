import Foundation
import Security
import DeviceCore

enum KeychainStore {
    /// Opt-in only. No sync to iCloud. No password is written into UserDefaults, files or argv.
    static func save(password: String, deviceID: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "local.rrdevicedesk.backup-password",
                                    kSecAttrAccount as String: deviceID,
                                    kSecAttrSynchronizable as String: false]
        let attributes: [String: Any] = [kSecValueData as String: Data(password.utf8),
                                        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw DeskError.io("Шифрование включено, но пароль НЕ сохранён в Связке ключей (код \(status)). Сохраните его самостоятельно.")
        }
    }
}
