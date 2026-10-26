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
        // Never logs the error's description — it could echo the credentials.
        guard let data = try? JSONEncoder().encode(Credentials(username: username, password: password)) else { // nolog: see above
            Log.error(.auth, "Can't encode credentials for the keychain")
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            Log.error(.auth, "Keychain save failed", ["status": "\(status)"])
        }
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
        guard let credentials = try? JSONDecoder().decode(Credentials.self, from: data) else { // nolog: logged below without the payload
            Log.error(.auth, "Stored keychain credentials are unreadable")
            return nil
        }
        return credentials
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
