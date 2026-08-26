import Foundation

/// This install's identity with ARCA Cloud (`app/api/arca/*` in the Next.js
/// repo).
///
/// The backend's model, from `lib/arca/device.ts`: a fresh install POSTs to
/// `api/arca/device` and gets back `d1.<deviceId>.<hmac>` — a token the server
/// can verify without ever having stored it. That token *is* the device's
/// identity, and it is also, verbatim, the "device link code" the web
/// onboarding flow asks the user to paste. There is no shorter code: the link
/// endpoint requires the whole token precisely because the HMAC is the proof
/// that the pasting browser really has the device.
///
/// A device token is not a login. It says "this token was issued by us", not
/// "this is Minsung" — so it is displayed to its owner, never logged, and
/// exchanged for a real account by the web flow rather than trusted on its own.
///
/// Everything here degrades silently. `cloudBaseURL` may point at a deploy that
/// hasn't shipped these routes, the device may be offline, or the deployment
/// may have no `ARCA_DEVICE_SECRET` (503) — all three are ordinary, and all
/// three surface as `nil`, which the UI renders as "연결 안 됨". Nothing on this
/// path runs at launch: a token is only minted when the user actually opens the
/// ARCA Cloud section, so a cold start never waits on the network.
public enum ArcaCloudAccount {
    /// Whether this device is attached to an account, plus what the backend
    /// knows about that account. Absent fields simply weren't returned —
    /// `/api/arca/me` omits stats until there is usage to report.
    public struct LinkStatus: Sendable, Equatable {
        public let linked: Bool
        public let email: String?
        public let plan: String?
        public let sessionCount: Int?
        public let audioHours: Double?

        public init(linked: Bool, email: String? = nil, plan: String? = nil,
                    sessionCount: Int? = nil, audioHours: Double? = nil) {
            self.linked = linked
            self.email = email
            self.plan = plan
            self.sessionCount = sessionCount
            self.audioHours = audioHours
        }
    }

    private static let timeout: TimeInterval = 15

    // MARK: - Token shape

    /// The version prefix `lib/arca/device.ts` signs under. A token minted by
    /// a future `d2` scheme is not one this build knows how to hold.
    private static let version = "d1"

    /// `d1.<deviceId>.<signature>` — the shape the backend issues. Checked
    /// before anything is stored or sent so a truncated paste or a 404 page
    /// decoded as JSON can never be persisted as an identity.
    public static func isWellFormed(_ token: String) -> Bool {
        deviceId(from: token) != nil
    }

    /// The device id a token carries, or nil when it isn't one of ours. This
    /// only reads the token's shape — the signature can only be checked by the
    /// server, which holds the secret.
    public static func deviceId(from token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0] == version,
              !parts[1].isEmpty,
              !parts[2].isEmpty
        else { return nil }
        return String(parts[1])
    }

    // MARK: - Stored identity

    /// The token this install already holds, or nil if it has never minted one.
    /// Keychain-backed and account-scoped, so switching ARCA accounts switches
    /// cloud identity too rather than silently re-attributing usage.
    public static var storedToken: String? {
        guard let token = KeychainStore.get(.arcaDevice), isWellFormed(token) else { return nil }
        return token
    }

    /// The code the user pastes into web onboarding, minting one on first use.
    /// nil when the cloud is unreachable or doesn't serve these routes.
    public static func linkCode() async -> String? {
        if let existing = storedToken { return existing }
        return await mint()
    }

    /// Forgets this install's cloud identity. The next `linkCode()` mints a
    /// fresh one — which is a *different* device to the backend, so the account
    /// link is left behind with the old id.
    public static func forget() {
        KeychainStore.delete(.arcaDevice)
    }

    private static func mint() async -> String? {
        var request = URLRequest(url: ArcaConfig.cloudEndpoint("api/arca/device"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let token = decodeMintedToken(from: data)
        else { return nil }
        try? KeychainStore.set(token, for: .arcaDevice)
        return token
    }

    /// Parses `POST /api/arca/device`'s `{deviceId, token}`. Rejects a token
    /// whose embedded id disagrees with the one alongside it — that pairing is
    /// the only consistency check available client-side.
    public static func decodeMintedToken(from data: Data) -> String? {
        struct Minted: Decodable {
            let deviceId: String
            let token: String
        }
        guard let minted = try? JSONDecoder().decode(Minted.self, from: data),
              let embedded = deviceId(from: minted.token),
              embedded == minted.deviceId
        else { return nil }
        return minted.token
    }

    // MARK: - Link status

    /// Asks `/api/arca/me` who, if anyone, this device belongs to. Mints a
    /// token first if there isn't one, so a fresh install has a code to show
    /// the moment the section is opened.
    public static func refreshLinkStatus() async -> LinkStatus? {
        guard let token = await linkCode() else { return nil }
        var request = URLRequest(url: ArcaConfig.cloudEndpoint("api/arca/me"))
        request.setValue(token, forHTTPHeaderField: "x-arca-device")
        request.timeoutInterval = timeout
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return decodeLinkStatus(from: data)
    }

    /// Parses `GET /api/arca/me`. An unclaimed device gets `{linked: false}`;
    /// a claimed one carries the account's email, plan, and lifetime stats.
    public static func decodeLinkStatus(from data: Data) -> LinkStatus? {
        struct Payload: Decodable {
            struct Stats: Decodable {
                let sessionCount: Int
                let audioHours: Double
            }
            let linked: Bool
            let email: String?
            let plan: String?
            let stats: Stats?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        return LinkStatus(
            linked: payload.linked,
            email: payload.email,
            plan: payload.plan,
            sessionCount: payload.stats?.sessionCount,
            audioHours: payload.stats?.audioHours
        )
    }

    // MARK: - Web onboarding

    /// The page that consumes the link code.
    public static var onboardingURL: URL {
        ArcaConfig.cloudEndpoint("arca/onboarding")
    }
}
