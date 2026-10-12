import CryptoKit
import Foundation

/// The signed-pack envelope: a detached Ed25519 signature over the pack
/// JSON exactly as authored — no canonicalization step, so there is no
/// canonicalization to attack. `keyId` selects the pinned key, which is how
/// rotation works: ship new binaries with both keys, re-sign packs with the
/// new one, retire the old id a release later.
public struct ELVPackEnvelope: Codable, Sendable, Equatable {
    public var keyId: String
    /// Raw 64-byte Ed25519 signature over `payload`, verbatim.
    public var signature: Data
    /// The pack JSON, byte-for-byte as signed.
    public var payload: Data

    public init(keyId: String, signature: Data, payload: Data) {
        self.keyId = keyId
        self.signature = signature
        self.payload = payload
    }
}

/// The binary-pinned verifying keys: `keyId` → raw Ed25519 public key bytes.
/// Compiled into the host; never loaded from the network or a pack.
public struct ELVPackKeySet: Sendable {
    private let keys: [String: Data]

    public init(keys: [String: Data]) {
        self.keys = keys
    }

    public func key(for id: String) -> Data? {
        keys[id]
    }
}

public enum ELVPackVerificationError: Error, Sendable, Equatable {
    case unknownKey(String)
    case invalidKey
    case signatureMismatch
}

/// Proof of verification: the only way to hand bytes to `ELVPackLoader`.
/// Constructible solely by `ELVPackVerifier.verify` or the public
/// `embedded(_:)` claim. The type system gates the remote path: bytes that
/// crossed the network can only become verified through a signature check.
/// `embedded(_:)` is the one caller-discipline seam, kept for bundled JSON
/// packs (a curated subset shipped as an app resource, the opt-in packs);
/// its argument label is the trust claim, and nothing network-facing may
/// call it.
public struct ELVVerifiedPackBytes: Sendable {
    public let data: Data

    fileprivate init(data: Data) {
        self.data = data
    }

    /// Compiled-in trust: bytes embedded in the binary (the starter pack, a
    /// test fixture) are as trusted as the code around them, so they skip
    /// signature verification by construction. Never use this for bytes that
    /// crossed the network — those go through `ELVPackVerifier.verify`.
    public static func embedded(_ data: Data) -> Self {
        Self(data: data)
    }
}

/// Verifies a pack envelope against the pinned key set. Verification and the
/// verified bytes share one `Data` value — callers must decode exactly what
/// was checked, never re-derive the bytes.
public enum ELVPackVerifier {
    /// Checks `envelope` against the pinned keys. A rejection is logged at
    /// error level (the key id stays in private detail: it arrived from
    /// the network) before it rethrows.
    public static func verify(_ envelope: ELVPackEnvelope, keys: ELVPackKeySet) throws -> ELVVerifiedPackBytes {
        try verify(envelope, keys: keys, failureLevel: .error)
    }

    /// `verify` for a caller that logs a rejection itself at its own
    /// boundary (a remote refresh, the cached-pack store): the verifier's
    /// failure line drops to `failureLevel`, so one failure is one error
    /// line.
    package static func verify(_ envelope: ELVPackEnvelope, keys: ELVPackKeySet, failureLevel: ELVLogLevel) throws -> ELVVerifiedPackBytes {
        do {
            let verified = try check(envelope, keys: keys)
            ELVLog.debug(.remote, "Pack signature verified payloadBytes=\(envelope.payload.count)")
            return verified
        } catch {
            ELVLog.log(failureLevel, .remote, "Pack signature verification failed payloadBytes=\(envelope.payload.count)", private: "keyId=\(envelope.keyId)", error: error)
            throw error
        }
    }

    private static func check(_ envelope: ELVPackEnvelope, keys: ELVPackKeySet) throws -> ELVVerifiedPackBytes {
        guard let keyBytes = keys.key(for: envelope.keyId) else {
            throw ELVPackVerificationError.unknownKey(envelope.keyId)
        }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes) else {
            throw ELVPackVerificationError.invalidKey
        }
        guard key.isValidSignature(envelope.signature, for: envelope.payload) else {
            throw ELVPackVerificationError.signatureMismatch
        }
        return ELVVerifiedPackBytes(data: envelope.payload)
    }
}
