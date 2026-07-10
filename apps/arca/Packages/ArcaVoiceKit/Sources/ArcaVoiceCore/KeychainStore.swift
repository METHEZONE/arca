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
    /// Shared service identifier for every ARCA Voice key item. Keyed to the
    /// running app's bundle id so a test build (com.thezone.arca.voice.test)
    /// keeps fully separate keys with zero keychain-ACL crossings; the main
    /// app resolves to the same literal as before, so nothing migrates.
    public static let service = Bundle.main.bundleIdentifier ?? "com.thezone.arca.voice"

    /// Store (or replace) the key for `kind`. An empty string is treated as a delete.
    /// Update-in-place first: delete+add silently fails on macOS when the item
    /// was created by an earlier binary of the app (ACL mismatch after a
    /// product rename), which left rotated keys stale.
    public static func set(_ value: String, for key: ApiKeyKind) throws {
        try set(value, for: key, accountId: AccountStore.currentAccountId())
    }

    public static func set(_ value: String, for key: ApiKeyKind, accountId: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(baseQuery(for: key, accountId: accountId) as CFDictionary,
                                   update as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery(for: key, accountId: accountId)
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
        get(key, accountId: AccountStore.currentAccountId())
    }

    public static func get(_ key: ApiKeyKind, accountId: String) -> String? {
        var query = baseQuery(for: key, accountId: accountId)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            // 진단용 파일 트레이스: 앱이 실제로 받는 OSStatus를 남긴다
            // (-25300 = not found, -25293 = authFailed — 파일 키체인 ACL이
            // 바이너리 해시에 고정되어 재빌드마다 깨지는 케이스)
            diagnose("get \(key.rawValue) status=\(status)")
            // 폴백: 키의 원본인 ~/.arca 스테이징 파일에서 직접 읽는다.
            // 키체인 ACL/서명 변경/재설치 그 무엇에도 핵심 기능이 죽지 않게.
            return fileFallback(for: key, accountId: accountId)
        }
        return value
    }

    /// macOS 기본 계정 한정 — Keychain이 거부해도 스테이징 파일이 진실의 원천.
    private static func fileFallback(for key: ApiKeyKind, accountId: String) -> String? {
        #if os(macOS)
        guard AccountStore.isDefault(accountId) else { return nil }
        switch key {
        case .openAI:
            return nonEmpty(ArcaConfig.loadVoiceKeys()?.openAI)
        case .anthropic:
            return nonEmpty(ArcaConfig.loadVoiceKeys()?.anthropic)
        case .composio:
            return nonEmpty(ArcaConfig.loadConnections()?.composioApiKey)
        case .github:
            return nil
        }
        #else
        return nil
        #endif
    }

    private static func nonEmpty(_ value: String?) -> String? {
        (value?.isEmpty ?? true) ? nil : value
    }

    /// ~/Library/Application Support/<앱폴더>/keychain-trace.log 에 한 줄 append.
    /// unified log가 읽히지 않는 환경 진단용 — 값은 절대 기록하지 않는다.
    private static func diagnose(_ message: String) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let dir = base?.appendingPathComponent("ArcaVoice", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("keychain-trace.log")
        let line = "\(Date().timeIntervalSince1970) [\(service)] \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// Remove the key for `kind`. A missing item is not an error.
    public static func delete(_ key: ApiKeyKind) {
        delete(key, accountId: AccountStore.currentAccountId())
    }

    public static func delete(_ key: ApiKeyKind, accountId: String) {
        SecItemDelete(baseQuery(for: key, accountId: accountId) as CFDictionary)
    }

    static func keychainAccount(for key: ApiKeyKind, accountId: String) -> String {
        AccountStore.isDefault(accountId) ? key.rawValue : "\(accountId).\(key.rawValue)"
    }

    private static func baseQuery(for key: ApiKeyKind, accountId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainAccount(for: key, accountId: accountId),
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
