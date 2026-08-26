import Testing
import Foundation
import ArcaVoiceKit

/// Covers the parts of the cloud identity that can be checked without a
/// network or a Keychain: the token shape the backend issues, and the two
/// response bodies the app decodes. The transport itself (mint, refresh) is
/// left to real-device verification — there is no URLProtocol harness in this
/// package and adding one to assert on `URLSession` would test URLSession.
@Suite struct ArcaCloudAccountTests {
    /// The exact shape `lib/arca/device.ts` mints: `d1.<base64url id>.<hmac>`.
    private static let token = "d1.aGVsbG93b3JsZDEy.rDLzB3kQ8xN2pV1wYtu4c9AeFgHiJkLmNoPqRsTuVwY"
    private static let deviceId = "aGVsbG93b3JsZDEy"

    @Test func readsTheDeviceIdOutOfAToken() {
        #expect(ArcaCloudAccount.deviceId(from: Self.token) == Self.deviceId)
        #expect(ArcaCloudAccount.isWellFormed(Self.token))
    }

    @Test func rejectsTokensThatArenTOurs() {
        // Truncated paste, wrong version, empty segments, and an HTML error
        // page — all of which must never reach the Keychain as an identity.
        #expect(ArcaCloudAccount.deviceId(from: "d1.\(Self.deviceId)") == nil)
        #expect(ArcaCloudAccount.deviceId(from: "d2.\(Self.deviceId).sig") == nil)
        #expect(ArcaCloudAccount.deviceId(from: "d1..sig") == nil)
        #expect(ArcaCloudAccount.deviceId(from: "d1.\(Self.deviceId).") == nil)
        #expect(ArcaCloudAccount.deviceId(from: "<!DOCTYPE html>") == nil)
        #expect(ArcaCloudAccount.deviceId(from: "") == nil)
    }

    @Test func decodesAMintedToken() throws {
        let json = #"{"deviceId":"\#(Self.deviceId)","token":"\#(Self.token)"}"#
        #expect(ArcaCloudAccount.decodeMintedToken(from: Data(json.utf8)) == Self.token)
    }

    @Test func refusesAMintWhoseIdDisagreesWithItsToken() {
        let json = #"{"deviceId":"someOtherId","token":"\#(Self.token)"}"#
        #expect(ArcaCloudAccount.decodeMintedToken(from: Data(json.utf8)) == nil)
    }

    @Test func refusesAMintThatIsnTATokenAtAll() {
        // The 503 body `POST /api/arca/device` returns when the deployment has
        // no ARCA_DEVICE_SECRET.
        let json = #"{"error":"ARCA Cloud is not configured on this deployment."}"#
        #expect(ArcaCloudAccount.decodeMintedToken(from: Data(json.utf8)) == nil)
    }

    @Test func decodesAnUnlinkedDevice() throws {
        let json = #"{"linked":false,"deviceId":"\#(Self.deviceId)"}"#
        let status = try #require(ArcaCloudAccount.decodeLinkStatus(from: Data(json.utf8)))
        #expect(status.linked == false)
        #expect(status.email == nil)
        #expect(status.sessionCount == nil)
    }

    @Test func decodesALinkedDeviceWithStats() throws {
        let json = """
        {
          "linked": true,
          "deviceId": "\(Self.deviceId)",
          "userId": "6f1b0f6e-0000-4000-8000-000000000001",
          "organizationId": "6f1b0f6e-0000-4000-8000-000000000002",
          "email": "me@thezonebio.com",
          "plan": "pro",
          "stats": { "sessionCount": 12, "audioHours": 3.4 }
        }
        """
        let status = try #require(ArcaCloudAccount.decodeLinkStatus(from: Data(json.utf8)))
        #expect(status.linked)
        #expect(status.email == "me@thezonebio.com")
        #expect(status.plan == "pro")
        #expect(status.sessionCount == 12)
        #expect(status.audioHours == 3.4)
    }

    /// A brand-new account has no usage yet, so `/me` omits `stats` entirely —
    /// that must read as "linked, nothing to show", not as a decode failure.
    @Test func decodesALinkedDeviceWithNoStatsYet() throws {
        let json = #"{"linked":true,"email":"me@thezonebio.com","plan":"free"}"#
        let status = try #require(ArcaCloudAccount.decodeLinkStatus(from: Data(json.utf8)))
        #expect(status.linked)
        #expect(status.sessionCount == nil)
        #expect(status.audioHours == nil)
    }

    @Test func returnsNilForABodyThatIsnTALinkStatus() {
        #expect(ArcaCloudAccount.decodeLinkStatus(from: Data(#"{"error":"Not signed in."}"#.utf8)) == nil)
        #expect(ArcaCloudAccount.decodeLinkStatus(from: Data("<html>".utf8)) == nil)
    }

    @Test func onboardingURLPointsAtTheWebFlow() {
        #expect(ArcaCloudAccount.onboardingURL.path.hasSuffix("/arca/onboarding"))
    }
}
