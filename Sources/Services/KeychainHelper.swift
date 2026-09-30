import Foundation
import Security

public enum KeychainHelper {
    private static let serviceName = "com.gitxx.macos"
    private static let defaultGitHubAccount = "github_personal_access_token"

    // MARK: - Legacy / Default GitHub PAT

    public static func saveGitHubToken(_ token: String) -> Bool {
        return saveToken(token, forAccount: defaultGitHubAccount)
    }

    public static func getGitHubToken() -> String? {
        return getToken(forAccount: defaultGitHubAccount)
    }

    public static func deleteGitHubToken() {
        deleteToken(forAccount: defaultGitHubAccount)
    }

    // MARK: - Generic Secure Key Storage

    public static func saveToken(_ token: String, forAccount account: String) -> Bool {
        UserDefaults.standard.set(token, forKey: account)

        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]

        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    public static func getToken(forAccount account: String) -> String? {
        if let token = UserDefaults.standard.string(forKey: account), !token.isEmpty {
            return token
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Keychain only, never mirrored to UserDefaults.
    public static func saveSecret(_ secret: String, forAccount account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(secret.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public static func getSecret(forAccount account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func deleteToken(forAccount account: String) {
        UserDefaults.standard.removeObject(forKey: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
