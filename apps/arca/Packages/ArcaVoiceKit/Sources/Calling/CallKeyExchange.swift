import Foundation
import CryptoKit

/// Curve25519 key agreement for the call key.
///
/// The alternative — one side generating a key and posting it through the
/// signaling server — would mean the signaling box could decrypt every call. That
/// is a bad property for a thing that carries supplier negotiations, so the two
/// ends derive the key themselves and the server only ever forwards public keys.
public struct CallKeyExchange: Sendable {
    private let privateKey: Curve25519.KeyAgreement.PrivateKey

    public init() {
        self.privateKey = Curve25519.KeyAgreement.PrivateKey()
    }

    public var publicKeyBase64: String {
        privateKey.publicKey.rawRepresentation.base64EncodedString()
    }

    /// Derives the shared media key. Both ends must pass the same `roomCode` so a
    /// captured public key cannot be replayed into a different call.
    public func deriveKeyBase64(peerPublicKeyBase64: String, roomCode: String) -> String? {
        guard let peerRaw = Data(base64Encoded: peerPublicKeyBase64),
              let peerKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerRaw),
              let shared = try? privateKey.sharedSecretFromKeyAgreement(with: peerKey) else {
            return nil
        }
        let derived = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("arca.call.v1".utf8),
            sharedInfo: Data(roomCode.utf8),
            outputByteCount: 32)
        return derived.withUnsafeBytes { Data($0).base64EncodedString() }
    }
}
