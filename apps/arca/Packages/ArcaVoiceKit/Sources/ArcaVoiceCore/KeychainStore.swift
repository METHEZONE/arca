import Foundation
import Security

/// Which BYOK provider key a value belongs to. Raw value is the Keychain account.
public enum ApiKeyKind: String, Sendable, CaseIterable {
    case openAI
    case anthropic
    /// GitHub token for the arca-brain relay (cross-device task sync).
    case github
    /// Composio API key — connector hub (Gmail/Slack/Drive/Calendar…).
    case composio
}

/// Minimal Keychain wrapper for user-owned API keys. There is no server: keys
/// live only on-device, under a generic-password item scoped to one service.
/// Works on the macOS app sandbox and on iOS.
public struct KeychainStore {
    /// Shared service identifier for every ARCA Voice key item.
    public static let service = "com.thezone.arca.voice"

    /// Store (or replace) the key for `kind`. An empty string is treated as a delete.
    /// Update-in-place first: delete+add silently fails on macOS when the item
    /// was created by an earlier binary of the app (ACL mismatch after a
    /// product rename), which left rotated keys stale.
    public static func set(_ value: String, for key: ApiKeyKind) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(baseQuery(for: key) as CFDictionary,
                                   update as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery(for: key)
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Fetch the key for `kind`, or `nil` if none is stored.
    public static func get(_ key: ApiKeyKind) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return value
    }

    /// Remove the key for `kind`. A missing item is not an error.
    public static func delete(_ key: ApiKeyKind) {
        SecItemDelete(baseQuery(for: key) as CFDictionary)
    }

    private static func baseQuery(for key: ApiKeyKind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }
}

public enum KeychainError: Error, CustomStringConvertible, LocalizedError {
    case encodingFailed
    case unexpectedStatus(OSStatus)

    public var description: String {
        switch self {
        case .encodingFailed:
            return "Could not encode the API key as UTF-8."
        case .unexpectedStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain operation failed: \(message)"
        }
    }

    public var errorDescription: String? { description }
}
