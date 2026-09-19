import Foundation
import Security

/// Minimal Keychain wrapper for API credentials. Generic passwords under the
/// service "com.pair.assistant"; never written to disk in plaintext.
enum KeychainStore {
    static let service = "com.pair.assistant"

    enum Key: String, CaseIterable {
        case xaiAPIKey = "xai_api_key"
        case typesafeAPIKey = "typesafe_api_key"
        case cursorAPIKey = "cursor_api_key"

        var title: String {
            switch self {
            case .xaiAPIKey: return "xAI (Grok Voice) API key"
            case .typesafeAPIKey: return "TypeSafe (Jev) API key"
            case .cursorAPIKey: return "Cursor API key (cloud agents, optional)"
            }
        }

        /// Environment variable that overrides the Keychain value (dev convenience).
        var environmentVariable: String {
            switch self {
            case .xaiAPIKey: return "XAI_API_KEY"
            case .typesafeAPIKey: return "TYPESAFE_API_KEY"
            case .cursorAPIKey: return "CURSOR_API_KEY"
            }
        }
    }

    static func read(_ key: Key) -> String? {
        if let env = ProcessInfo.processInfo.environment[key.environmentVariable], !env.isEmpty { return env }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ key: Key, value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return delete(key) }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        let data = Data(trimmed.utf8)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        if update == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    @discardableResult
    static func delete(_ key: Key) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
