import CryptoKit
import EluviumCatalog
import EluviumCore
import Foundation
@testable import EluviumNet

/// A canned `ELVFetching` for pack-download tests: returns whatever the closure
/// produces (including a 304/notModified), so the service runs fully offline.
/// Named to avoid the pipeline suite's own `StubFetcher`.
struct CannedFetcher: ELVFetching {
    let conditional: @Sendable (URL, String?) throws -> ELVConditionalFetchResult

    func fetch(_ url: URL, persona _: ELVUAPersona, referer _: URL?, accept _: String?, budget _: ELVFetchBudget) async throws -> ELVFetchResponse {
        guard let response = try conditional(url, nil).response else { throw ELVFetchFailure.offline }
        return response
    }

    func fetchConditional(_ url: URL, ifNoneMatch: String?, budget _: ELVFetchBudget) async throws -> ELVConditionalFetchResult {
        try conditional(url, ifNoneMatch)
    }
}

enum RemotePackFixture {
    /// A tiny, real, loadable pack payload (one catch-all floor).
    static func payload(packVersion: String = "2026.10.10-remote.1") throws -> Data {
        try ELVPackSubset.subset(fromPackJSON: ELVStarterPack.data, ids: ["generic.opengraph"], packVersion: packVersion)
    }

    /// A keyset plus a signed-envelope JSON over `payload`. When `tamper` is
    /// true the signature covers different bytes, so verification must fail
    /// while the envelope still decodes.
    static func signed(payload: Data, keyId: String = "test", tamper: Bool = false) throws -> (keys: ELVPackKeySet, envelopeData: Data) {
        let privateKey = Curve25519.Signing.PrivateKey()
        let keys = ELVPackKeySet(keys: [keyId: privateKey.publicKey.rawRepresentation])
        let signedBytes = tamper ? payload + Data([0x20]) : payload
        let signature = try privateKey.signature(for: signedBytes)
        let envelope = ELVPackEnvelope(keyId: keyId, signature: signature, payload: payload)
        return try (keys, JSONEncoder().encode(envelope))
    }

    static func response(_ data: Data, etag: String? = "v1") -> ELVConditionalFetchResult {
        let response = ELVFetchResponse(
            finalURL: URL(string: "https://packs.example.com/pack.json")!,
            status: 200,
            data: data,
            bodyText: String(bytes: data, encoding: .utf8) ?? "",
            truncated: false
        )
        return ELVConditionalFetchResult(response: response, etag: etag)
    }
}

/// One signing key for a sequence of envelopes, so a test can serve several
/// pack versions that the same pinned keyset verifies (a replayed older
/// pack is validly signed; that is the point).
struct RemotePackSigner {
    let keyId = "test"
    private let privateKey = Curve25519.Signing.PrivateKey()

    var keys: ELVPackKeySet {
        ELVPackKeySet(keys: [keyId: privateKey.publicKey.rawRepresentation])
    }

    /// A signed-envelope JSON over a loadable pack at `packVersion`.
    func envelope(packVersion: String) throws -> Data {
        let payload = try RemotePackFixture.payload(packVersion: packVersion)
        let envelope = try ELVPackEnvelope(keyId: keyId, signature: privateKey.signature(for: payload), payload: payload)
        return try JSONEncoder().encode(envelope)
    }
}
