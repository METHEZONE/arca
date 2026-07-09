import CryptoKit
import Foundation

/// Access to the shared ARCA runtime config in ~/.arca (real home, not the
/// sandbox container — reads require the macOS home-relative read entitlement).
public enum ArcaConfig {
    /// The user's real home directory, bypassing the sandbox container path.
    /// (On iOS there is no shared ~/.arca; loaders simply return nil.)
    public static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    public static var arcaDirectory: URL {
        realHome.appendingPathComponent(".arca", isDirectory: true)
    }

    /// ~/.arca/voice-keys.json — BYOK keys staged for first-launch import.
    public struct VoiceKeys: Decodable {
        public let openAI: String?
        public let anthropic: String?
    }

    public static func loadVoiceKeys() -> VoiceKeys? {
        let url = arcaDirectory.appendingPathComponent("voice-keys.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(VoiceKeys.self, from: data)
    }

    /// ~/.arca/connections.json — Composio credentials + connected accounts,
    /// shared with the main ARCA app for the default account.
    public struct Connections: Decodable {
        public let userId: String
        public let composioApiKey: String?
        public let connectedAccounts: [String: String]?
    }

    public static func connectionsURL(accountId: String) -> URL {
        connectionsURL(accountId: accountId, arcaDirectory: arcaDirectory)
    }

    static func connectionsURL(accountId: String, arcaDirectory: URL) -> URL {
        if AccountStore.isDefault(accountId) {
            return arcaDirectory.appendingPathComponent("connections.json")
        }
        return arcaDirectory
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(accountId, isDirectory: true)
            .appendingPathComponent("connections.json")
    }

    public static func prepareConnectionsDirectoryForWrite(accountId: String) throws {
        let directory = connectionsURL(accountId: accountId).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static func loadConnections() -> Connections? {
        let url = connectionsURL(accountId: AccountStore.currentAccountId())
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Connections.self, from: data)
    }

    /// Keys shipped inside the app bundle (personal build) — imported into the
    /// Keychain whenever the bundled file changes. iOS has no ~/.arca, so this
    /// is how the iPhone/Watch builds get their keys. Works on macOS too as a
    /// fallback; the ~/.arca staging file still wins there (imported after).
    public static func importBundledKeysIfNeeded() {
        guard let url = Bundle.main.url(forResource: "BundledKeys", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(
                  from: data, format: nil) as? [String: String]
        else { return }
        let defaults = UserDefaults.standard
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let hashKey = AccountDefaults.key("importedBundledKeysHash")
        let changed = defaults.string(forKey: hashKey) != digest

        func store(_ value: String?, as kind: ApiKeyKind) {
            guard let value, !value.isEmpty,
                  changed || KeychainStore.get(kind) == nil else { return }
            try? KeychainStore.set(value, for: kind)
        }
        store(dict["anthropic"], as: .anthropic)
        store(dict["openAI"], as: .openAI)
        store(dict["githubToken"], as: .github)
        store(dict["composioApiKey"], as: .composio)
        if let repo = dict["githubRepo"], !repo.isEmpty {
            defaults.set(repo, forKey: "relayRepo")
        }
        if let userId = dict["composioUserId"], !userId.isEmpty {
            AccountDefaults.set(userId, for: "composioUserId")
        }
        defaults.set(digest, forKey: hashKey)
    }

    /// Imports staged keys into the Keychain whenever voice-keys.json changes
    /// since the last import (so rotating a dead key in the file takes effect
    /// on next launch). Between file changes the Keychain stays the source of
    /// truth — keys overwritten in 설정 are not clobbered.
    public static func importVoiceKeysIntoKeychainIfNeeded() {
        let url = arcaDirectory.appendingPathComponent("voice-keys.json")
        guard let data = try? Data(contentsOf: url),
              let keys = try? JSONDecoder().decode(VoiceKeys.self, from: data)
        else {
            NSLog("[ArcaVoice] key import: voice-keys.json unreadable at %@", url.path)
            return
        }
        let defaults = UserDefaults.standard
        let hashKey = AccountDefaults.key("importedVoiceKeysHash")
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let fileChanged = defaults.string(forKey: hashKey) != digest
        if let key = keys.openAI, !key.isEmpty,
           fileChanged || KeychainStore.get(.openAI) == nil {
            do {
                try KeychainStore.set(key, for: .openAI)
                NSLog("[ArcaVoice] key import: openAI stored")
            } catch {
                NSLog("[ArcaVoice] key import: openAI failed: %@", "\(error)")
            }
        }
        if let key = keys.anthropic, !key.isEmpty,
           fileChanged || KeychainStore.get(.anthropic) == nil {
            do {
                try KeychainStore.set(key, for: .anthropic)
                NSLog("[ArcaVoice] key import: anthropic stored")
            } catch {
                NSLog("[ArcaVoice] key import: anthropic failed: %@", "\(error)")
            }
        }
        defaults.set(digest, forKey: hashKey)
    }
}
