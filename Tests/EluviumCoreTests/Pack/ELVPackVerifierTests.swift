import CryptoKit
import Foundation
import Testing
@testable import EluviumCore

/// The Ed25519 trust boundary, exercised end to end: sign in-test, verify,
/// and load the exact signed bytes. Until this suite existed the verify
/// path had zero call sites anywhere in the repo.
@Suite("Pack verifier")
struct ELVPackVerifierTests {
    private let payload = Data(#"{"schemaVersion": 1, "packVersion": "signed", "sources": []}"#.utf8)

    @Test
    func `A validly signed envelope verifies and the loader decodes the exact signed bytes`() throws {
        let key = Curve25519.Signing.PrivateKey()
        let envelope = try ELVPackEnvelope(keyId: "k1", signature: key.signature(for: payload), payload: payload)
        let keys = ELVPackKeySet(keys: ["k1": key.publicKey.rawRepresentation])
        let verified = try ELVPackVerifier.verify(envelope, keys: keys)
        #expect(verified.data == payload)
        let pack = try ELVPackLoader.load(verified)
        #expect(pack.pack.packVersion == "signed")
    }

    @Test
    func `A tampered payload fails with signatureMismatch`() throws {
        let key = Curve25519.Signing.PrivateKey()
        var tampered = payload
        tampered[tampered.count - 3] ^= 0x01
        let envelope = try ELVPackEnvelope(keyId: "k1", signature: key.signature(for: payload), payload: tampered)
        let keys = ELVPackKeySet(keys: ["k1": key.publicKey.rawRepresentation])
        #expect(throws: ELVPackVerificationError.signatureMismatch) {
            _ = try ELVPackVerifier.verify(envelope, keys: keys)
        }
    }

    @Test
    func `A signature from the wrong signer fails even under the pinned key`() throws {
        let pinned = Curve25519.Signing.PrivateKey()
        let impostor = Curve25519.Signing.PrivateKey()
        let envelope = try ELVPackEnvelope(keyId: "k1", signature: impostor.signature(for: payload), payload: payload)
        let keys = ELVPackKeySet(keys: ["k1": pinned.publicKey.rawRepresentation])
        #expect(throws: ELVPackVerificationError.signatureMismatch) {
            _ = try ELVPackVerifier.verify(envelope, keys: keys)
        }
    }

    @Test
    func `An unknown key id and junk key bytes fail typed, never verify`() throws {
        let key = Curve25519.Signing.PrivateKey()
        let envelope = try ELVPackEnvelope(keyId: "retired", signature: key.signature(for: payload), payload: payload)
        #expect(throws: ELVPackVerificationError.unknownKey("retired")) {
            _ = try ELVPackVerifier.verify(envelope, keys: ELVPackKeySet(keys: ["k1": key.publicKey.rawRepresentation]))
        }
        let junkKeys = ELVPackKeySet(keys: ["retired": Data([0x01, 0x02, 0x03])])
        #expect(throws: ELVPackVerificationError.invalidKey) {
            _ = try ELVPackVerifier.verify(envelope, keys: junkKeys)
        }
    }
}
