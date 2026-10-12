import EluviumCore
import EluviumNet
import Foundation
import Testing

@Suite("Remote pack service")
struct ELVRemotePackServiceTests {
    private let caps = ELVCapabilities(fetchModes: ["http", "json", "archive", "feed", "dom"], binaryVersion: "0.1")
    private let url = URL(string: "https://packs.example.com/pack.json")!

    private func tempStore() -> ELVRemotePackStore {
        ELVRemotePackStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("elv-service-\(UUID().uuidString)"))
    }

    /// A service that serves `envelope` through a store, as a host wires it.
    private func service(serving envelope: Data, keys: ELVPackKeySet, store: ELVRemotePackStore, etag: String? = nil) -> ELVRemotePackService {
        ELVRemotePackService(fetcher: CannedFetcher { _, _ in RemotePackFixture.response(envelope, etag: etag) }, keys: keys, store: store)
    }

    @Test
    func `A valid signed envelope is verified, loaded, and returned`() async throws {
        let payload = try RemotePackFixture.payload(packVersion: "2026.10.10-remote.1")
        let (keys, envelopeData) = try RemotePackFixture.signed(payload: payload)
        let service = ELVRemotePackService(fetcher: CannedFetcher { _, _ in RemotePackFixture.response(envelopeData) }, keys: keys)

        let outcome = try await service.refresh(from: url, capabilities: caps)
        guard case let .updated(loaded) = outcome else {
            Issue.record("expected .updated, got \(outcome)")
            return
        }
        #expect(loaded.pack.packVersion == "2026.10.10-remote.1")
        #expect(loaded.genericFloors.contains { $0.id == "generic.opengraph" })
    }

    @Test
    func `A tampered payload fails verification`() async throws {
        let payload = try RemotePackFixture.payload()
        let (keys, envelopeData) = try RemotePackFixture.signed(payload: payload, tamper: true)
        let service = ELVRemotePackService(fetcher: CannedFetcher { _, _ in RemotePackFixture.response(envelopeData) }, keys: keys)

        await #expect(throws: ELVPackVerificationError.signatureMismatch) {
            _ = try await service.refresh(from: url, capabilities: caps)
        }
    }

    @Test
    func `An HTML response is rejected before verification`() async throws {
        let (keys, _) = try RemotePackFixture.signed(payload: RemotePackFixture.payload())
        let html = Data("<!doctype html><html><body>login</body></html>".utf8)
        let service = ELVRemotePackService(fetcher: CannedFetcher { _, _ in RemotePackFixture.response(html) }, keys: keys)

        await #expect(throws: ELVRemotePackError.htmlResponse) {
            _ = try await service.refresh(from: url, capabilities: caps)
        }
    }

    @Test
    func `HTML behind leading whitespace is still rejected`() async throws {
        let (keys, _) = try RemotePackFixture.signed(payload: RemotePackFixture.payload())
        let html = Data("\n\r\n  \t<html><body>portal</body></html>".utf8)
        let service = ELVRemotePackService(fetcher: CannedFetcher { _, _ in RemotePackFixture.response(html) }, keys: keys)

        await #expect(throws: ELVRemotePackError.htmlResponse) {
            _ = try await service.refresh(from: url, capabilities: caps)
        }
    }

    @Test
    func `A JSON body that is not an envelope names the decode failure`() async throws {
        let (keys, _) = try RemotePackFixture.signed(payload: RemotePackFixture.payload())
        let body = Data(#"{"hello": "world"}"#.utf8)
        let service = ELVRemotePackService(fetcher: CannedFetcher { _, _ in RemotePackFixture.response(body) }, keys: keys)

        do {
            _ = try await service.refresh(from: url, capabilities: caps)
            Issue.record("expected notAnEnvelope")
        } catch let ELVRemotePackError.notAnEnvelope(detail) {
            // The decoder's own account of the drift travels to the host.
            #expect(!detail.isEmpty)
        }
    }

    @Test
    func `A 304 yields notModified`() async throws {
        let (keys, _) = try RemotePackFixture.signed(payload: RemotePackFixture.payload())
        let service = ELVRemotePackService(fetcher: CannedFetcher { _, _ in ELVConditionalFetchResult(response: nil, etag: "v1") }, keys: keys)

        let outcome = try await service.refresh(from: url, capabilities: caps)
        guard case .notModified = outcome else {
            Issue.record("expected .notModified, got \(outcome)")
            return
        }
    }

    @Test
    func `Egress refuses a non-HTTPS pack URL`() async throws {
        let (keys, _) = try RemotePackFixture.signed(payload: RemotePackFixture.payload())
        let service = ELVRemotePackService(fetcher: ELVHTTPFetcher(), keys: keys)

        await #expect(throws: ELVFetchFailure.self) {
            _ = try await service.refresh(from: #require(URL(string: "http://packs.example.com/pack.json")), capabilities: caps)
        }
    }

    // MARK: - Rollback

    @Test
    func `A replayed older signed pack is refused as a rollback, and the accepted pack stays cached`() async throws {
        let signer = RemotePackSigner()
        let store = tempStore()
        defer { store.clear() }
        _ = try await service(serving: signer.envelope(packVersion: "2026.10.10-remote.2"), keys: signer.keys, store: store, etag: "v2")
            .refresh(from: url, capabilities: caps)
        #expect(store.packVersion == "2026.10.10-remote.2")

        // A stale CDN edge (or an attacker) serves an older, validly signed pack.
        let replay = try service(serving: signer.envelope(packVersion: "2026.10.10-remote.1"), keys: signer.keys, store: store, etag: "v1")
        await #expect(throws: ELVRemotePackError.versionRollback(offered: "2026.10.10-remote.1", accepted: "2026.10.10-remote.2")) {
            _ = try await replay.refresh(from: url, capabilities: caps)
        }
        // Nothing of the replay was persisted: floor, ETag, and cache are
        // still the accepted pack's.
        #expect(store.packVersion == "2026.10.10-remote.2")
        #expect(store.etag == "v2")
        #expect(try store.loadCached(keys: signer.keys, capabilities: caps)?.pack.packVersion == "2026.10.10-remote.2")
    }

    @Test
    func `A newer pack is accepted and raises the floor; the same version re-served still applies`() async throws {
        let signer = RemotePackSigner()
        let store = tempStore()
        defer { store.clear() }
        _ = try await service(serving: signer.envelope(packVersion: "2026.10.10-remote.1"), keys: signer.keys, store: store)
            .refresh(from: url, capabilities: caps)

        let newer = try await service(serving: signer.envelope(packVersion: "2026.10.12-remote.1"), keys: signer.keys, store: store)
            .refresh(from: url, capabilities: caps)
        guard case let .updated(loaded) = newer else {
            Issue.record("expected .updated, got \(newer)")
            return
        }
        #expect(loaded.pack.packVersion == "2026.10.12-remote.1")
        #expect(store.packVersion == "2026.10.12-remote.1")

        // Re-signed or re-hosted at the same version: not a rollback.
        let same = try await service(serving: signer.envelope(packVersion: "2026.10.12-remote.1"), keys: signer.keys, store: store)
            .refresh(from: url, capabilities: caps)
        guard case .updated = same else {
            Issue.record("expected .updated, got \(same)")
            return
        }
    }

    @Test
    func `A cache discarded as older than the bundled pack is never re-accepted by a refresh`() async throws {
        let signer = RemotePackSigner()
        let store = tempStore()
        defer { store.clear() }
        let stale = try signer.envelope(packVersion: "2026.10.10-remote.1")
        _ = try await service(serving: stale, keys: signer.keys, store: store).refresh(from: url, capabilities: caps)

        // An app update bundles a newer pack: the launch discards the cache.
        #expect(try store.loadCached(keys: signer.keys, capabilities: caps, bundledVersion: "2026.10.12-starter.1") == nil)

        // The server still serves the old pack (no ETag, so no 304): refused.
        await #expect(throws: ELVRemotePackError.versionRollback(offered: "2026.10.10-remote.1", accepted: "2026.10.12-starter.1")) {
            _ = try await service(serving: stale, keys: signer.keys, store: store).refresh(from: url, capabilities: caps)
        }
    }
}
