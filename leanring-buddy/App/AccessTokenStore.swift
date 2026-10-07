import Foundation
import Security

/// Individual credentials never come from the distributed app bundle.
enum AccessTokenStore {
    private static let service = "com.kesideonyeocha.sage.access"
    private static let account = "beta-access-token"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static var token: String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ rawToken: String) throws {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.hasPrefix("sage_"), token.count == 69,
              token.dropFirst(5).allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw TokenError(message: "Use the full sage_ access token provided for your account.")
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insertion = query.merging(attributes) { _, newValue in newValue }
            insertion[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let status = SecItemAdd(insertion as CFDictionary, nil)
            guard status == errSecSuccess else { throw TokenError(message: "Keychain error (\(status)).") }
        } else if updateStatus != errSecSuccess {
            throw TokenError(message: "Keychain error (\(updateStatus)).")
        }
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenError(message: "Keychain error (\(status)).")
        }
    }

    private struct TokenError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
