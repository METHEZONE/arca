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

    // MARK: - ARCA Cloud

    /// Where the ARCA web backend lives (`app/api/arca/*` in the Next.js repo).
    /// Overridable per install via the `arcaCloudBaseURL` default or a
    /// `BundledKeys.plist` entry, so a staging deploy or a laptop can be used
    /// without a rebuild.
    ///
    /// This is the real production URL for the `arca` Vercel project (confirmed via
    /// `vercel project ls`; package.json name is also `arca`). As of this writing
    /// `app/api/arca/*` hasn't been redeployed since these routes were added, so a
    /// fresh deploy is required before the crash pipeline actually responds — every
    /// caller must still treat an unreachable/404 host as a non-event. That matters
    /// most for the crash pipeline, whose two halves both go through here —
    /// `CrashDiagnosticsReporter` POSTs to `api/arca/crash` from the phone, and the
    /// Mac's `CrashNoteSync` GETs from it to write the report into Obsidian — and
    /// both silently no-op when this host isn't serving those routes yet.
    public static var cloudBaseURL: URL {
        let configured = UserDefaults.standard.string(forKey: "arcaCloudBaseURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let configured, !configured.isEmpty, let url = URL(string: configured) {
            return url
        }
        return URL(string: "https://arca-nine.vercel.app")!
    }

    /// `cloudBaseURL` + a route path, e.g. `cloudEndpoint("api/arca/crash")`.
    public static func cloudEndpoint(_ path: String) -> URL {
        cloudBaseURL.appendingPathComponent(path)
    }

    /// A stable random id for this install, generated on first use.
    ///
    /// Not an identity and deliberately not derived from the hardware: it only
    /// exists so several reports from one device can be recognised as one
    /// device. Resetting the app resets it, which is the correct privacy
    /// behaviour for something that only groups diagnostics.
    public static var installId: String {
        let key = "arcaInstallId"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: key)
        return generated
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
        /// A Notion internal-integration token (`ntn_…`). Notion DB sync talks to
        /// the Notion REST API directly rather than through Composio, so it needs
        /// its own token — see `NotionDBClient` for why. Absent = sync disabled.
        public let notionToken: String?
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

    /// The Composio `user_id` this account transacts under, generating and
    /// persisting one on first use.
    ///
    /// Composio scopes connected accounts by `user_id` against a single project
    /// key, so this id — not the key — is what separates one person's Gmail and
    /// Slack from another's. It used to arrive only from `BundledKeys.plist`,
    /// which meant any build shipped to someone else inherited the developer's
    /// id and read the developer's mailbox. A build handed to another person
    /// must omit `composioUserId` from that plist and let this generate a fresh
    /// one per install.
    public static func composioUserId() -> String {
        if let existing = AccountDefaults.string("composioUserId"), !existing.isEmpty {
            return existing
        }
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).uppercased()
        let generated = "arca-\(suffix)"
        AccountDefaults.set(generated, for: "composioUserId")
        return generated
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
        if let base = dict["arcaCloudBaseURL"], !base.isEmpty {
            defaults.set(base, forKey: "arcaCloudBaseURL")
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
        // Composio는 connections.json이 원본 — Keychain에 없으면 같이 채워서
        // 커넥터 허브가 어느 빌드(본편/테스트)에서든 바로 살아나게 한다.
        if let composio = loadConnections()?.composioApiKey, !composio.isEmpty,
           KeychainStore.get(.composio) == nil {
            do {
                try KeychainStore.set(composio, for: .composio)
                NSLog("[ArcaVoice] key import: composio stored")
            } catch {
                NSLog("[ArcaVoice] key import: composio failed: %@", "\(error)")
            }
        }
        defaults.set(digest, forKey: hashKey)
    }
}
