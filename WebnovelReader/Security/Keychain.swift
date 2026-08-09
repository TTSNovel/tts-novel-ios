import Foundation
import Security

// Server login/password go in the Keychain, not UserDefaults — UserDefaults
// backs onto a plaintext plist inside the app sandbox, fine for the
// non-sensitive server URL but not for credentials.
enum Keychain {
    private static let service = "dev.yanglong.webnovelreader"
    private static let account = "server-credentials"

    struct Credentials: Codable {
        let username: String
        let password: String
    }

    static func saveCredentials(username: String, password: String) {
        guard let data = try? JSONEncoder().encode(Credentials(username: username, password: password)) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func loadCredentials() -> Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    static func deleteCredentials() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
