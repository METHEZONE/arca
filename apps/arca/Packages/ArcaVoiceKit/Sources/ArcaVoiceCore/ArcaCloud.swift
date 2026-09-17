import CryptoKit
import Foundation

/// ARCA without keys. A tester who has no Anthropic or Composio account
/// enters the invite code from their approval mail; from then on model calls
/// and connector calls go through ARCA Cloud (the Vercel app), which holds
/// THE ZONE's keys and checks the code's signature on every request. A user
/// who does have their own Anthropic key keeps talking to Anthropic directly —
/// the local key always wins.
///
/// Invite code shape: `email.exp.sig` — the same HMAC grant the download link
/// uses, so approving someone is one action.
public enum ArcaCloud {
    public static let baseURL = URL(string: "https://arca-the-zone-bio.vercel.app/api/arca/cloud")!
    static let inviteKey = "arcaInviteToken"

    public static var inviteToken: String? {
        let raw = AccountDefaults.string(inviteKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : raw
    }

    /// Stores a code after a shape check; returns the email it belongs to.
    @discardableResult
    public static func setInviteToken(_ raw: String) -> String? {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let email = email(fromInvite: code) else { return nil }
        AccountDefaults.set(code, for: inviteKey)
        // Connectors under this identity, on both sides of the proxy.
        AccountDefaults.set(composioEntity(for: email), for: "composioUserId")
        return email
    }

    public static func clearInvite() { AccountDefaults.set(nil, for: inviteKey) }

    public static func email(fromInvite code: String) -> String? {
        let parts = code.split(separator: ".")
        guard parts.count >= 3 else { return nil }
        let sig = parts[parts.count - 1], exp = parts[parts.count - 2]
        let email = parts[..<(parts.count - 2)].joined(separator: ".")
        guard email.contains("@"), Int(exp) != nil, sig.count >= 20 else { return nil }
        return email.lowercased()
    }

    public static var inviteEmail: String? { inviteToken.flatMap(email(fromInvite:)) }

    /// True when model/connector traffic is routed through ARCA Cloud.
    public static var isActive: Bool {
        KeychainStore.get(.anthropic) == nil && inviteToken != nil
    }

    // MARK: - Anthropic

    public static let anthropicDirectURL = URL(string: "https://api.anthropic.com/v1/messages")!

    /// The `x-api-key` value to send: the user's own key, else the invite code.
    public static var anthropicKey: String? {
        if let key = KeychainStore.get(.anthropic), !key.isEmpty { return key }
        return inviteToken
    }

    public static var anthropicMessagesURL: URL {
        if let key = KeychainStore.get(.anthropic), !key.isEmpty { return anthropicDirectURL }
        if inviteToken != nil { return baseURL.appendingPathComponent("messages") }
        return anthropicDirectURL
    }

    // MARK: - Composio

    public static let composioDirectBase = "https://backend.composio.dev/api/v3"

    public static var composioKey: String? {
        if let key = KeychainStore.get(.composio), !key.isEmpty { return key }
        return inviteToken
    }

    public static var composioBase: String {
        if let key = KeychainStore.get(.composio), !key.isEmpty { return composioDirectBase }
        if inviteToken != nil { return baseURL.appendingPathComponent("composio").absoluteString }
        return composioDirectBase
    }

    public static var composioBaseURL: URL { URL(string: composioBase)! }

    public static var composioUserId: String? {
        if let id = AccountDefaults.string("composioUserId"), !id.isEmpty { return id }
        if let email = inviteEmail { return composioEntity(for: email) }
        return nil
    }

    // MARK: - Free tier

    /// Anyone who installs ARCA can use it on THE ZONE's key without asking for
    /// a code: the app enrolls its device once and gets a signed grant back.
    /// Free-tier grants are per device, last a year, and the server pins them
    /// to Sonnet. A key of the user's own, or a personal invite, always wins.
    public static var isFreeTier: Bool { inviteEmail?.hasSuffix("@arca.device") == true }

    public static var deviceId: String {
        let key = "arcaDeviceId"
        if let id = UserDefaults.standard.string(forKey: key), !id.isEmpty { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    /// True when the app can reach a model afterwards (own key, invite, or a
    /// fresh free-tier grant). Safe to call on every launch — it's a no-op once
    /// anything is configured, and a failure just leaves things as they were.
    @discardableResult
    public static func enrollIfNeeded() async -> Bool {
        if KeychainStore.get(.anthropic)?.isEmpty == false { return true }
        if inviteToken != nil { return true }
        var request = URLRequest(url: baseURL.appendingPathComponent("enroll"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 15
        #if os(macOS)
        let platform = "mac"
        #elseif os(iOS)
        let platform = "ios"
        #else
        let platform = "other"
        #endif
        guard let payload = try? JSONSerialization.data(withJSONObject: ["deviceId": deviceId, "platform": platform]) else {
            return false
        }
        do {
            let (data, response) = try await uploadBody(URLSession.shared, for: request, body: payload)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let code = json["code"] as? String else { return false }
            return setInviteToken(code) != nil
        } catch {
            return false
        }
    }

    /// The same derivation the server uses: one connector identity per email.
    public static func composioEntity(for email: String) -> String {
        let digest = SHA256.hash(data: Data(email.lowercased().utf8))
        return "arca-b-" + digest.prefix(5).map { String(format: "%02x", $0) }.joined()
    }
}
