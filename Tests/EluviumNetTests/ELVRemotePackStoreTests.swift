import EluviumCore
import EluviumNet
import Foundation
import Testing

@Suite("Remote pack store")
struct ELVRemotePackStoreTests {
    private func tempStore() -> ELVRemotePackStore {
        ELVRemotePackStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("elv-store-\(UUID().uuidString)"))
    }

    @Test
    func `Save then loadCached re-verifies and round-trips`() throws {
        let payload = try RemotePackFixture.payload(packVersion: "2026.10.10-cached.2")
        let (keys, envelopeData) = try RemotePackFixture.signed(payload: payload)
        let store = tempStore()

        try store.save(envelope: envelopeData, etag: "etag-2", packVersion: "2026.10.10-cached.2")
        #expect(store.etag == "etag-2")
        #expect(store.packVersion == "2026.10.10-cached.2")
        let loaded = try store.loadCached(keys: keys)
        #expect(loaded?.pack.packVersion == "2026.10.10-cached.2")
    }

    @Test
    func `A tampered cache file is rejected on load`() throws {
        let (keys, envelopeData) = try RemotePackFixture.signed(payload: RemotePackFixture.payload(), tamper: true)
        let store = tempStore()

        try store.save(envelope: envelopeData, etag: nil, packVersion: "2026.10.10-remote.1")
        #expect(throws: ELVPackVerificationError.signatureMismatch) {
            _ = try store.loadCached(keys: keys)
        }
    }

    @Test
    func `An empty store loads nothing`() throws {
        let (keys, _) = try RemotePackFixture.signed(payload: RemotePackFixture.payload())
        let store = tempStore()
        #expect(try store.loadCached(keys: keys) == nil)
        #expect(store.etag == nil)
        #expect(store.packVersion == nil)
    }

    @Test
    func `A save without an ETag clears the previously stored one`() throws {
        let (_, envelopeData) = try RemotePackFixture.signed(payload: RemotePackFixture.payload())
        let store = tempStore()

        try store.save(envelope: envelopeData, etag: "e1", packVersion: "2026.10.10-remote.1")
        #expect(store.etag == "e1")
        // A stale tag would ride the next conditional GET against an
        // envelope the server never described with it.
        try store.save(envelope: envelopeData, etag: nil, packVersion: "2026.10.10-remote.1")
        #expect(store.etag == nil)
    }

    @Test
    func `A present but undecodable cache file throws instead of reading as no cache`() throws {
        let (keys, _) = try RemotePackFixture.signed(payload: RemotePackFixture.payload())
        let store = tempStore()

        try store.save(envelope: Data("not an envelope".utf8), etag: nil, packVersion: "2026.10.10-remote.1")
        #expect(throws: (any Error).self) {
            _ = try store.loadCached(keys: keys)
        }
    }

    @Test
    func `clear removes the cached envelope, etag, and recorded version`() throws {
        let (keys, envelopeData) = try RemotePackFixture.signed(payload: RemotePackFixture.payload())
        let store = tempStore()

        try store.save(envelope: envelopeData, etag: "e", packVersion: "2026.10.10-remote.1")
        store.clear()
        #expect(store.etag == nil)
        #expect(store.packVersion == nil)
        #expect(try store.loadCached(keys: keys) == nil)
    }

    // MARK: - Bundled-version discard

    @Test
    func `A cache older than the bundled pack is discarded, keeping the ETag and raising the floor`() throws {
        let signer = RemotePackSigner()
        let store = tempStore()
        defer { store.clear() }
        try store.save(envelope: signer.envelope(packVersion: "2026.10.10-remote.1"), etag: "e1", packVersion: "2026.10.10-remote.1")

        #expect(try store.loadCached(keys: signer.keys, bundledVersion: "2026.10.12-starter.1") == nil)
        // Gone for good, not just skipped this launch.
        #expect(try store.loadCached(keys: signer.keys) == nil)
        // The ETag still names the stale server resource, so the next
        // conditional GET for it answers 304 instead of re-downloading it.
        #expect(store.etag == "e1")
        #expect(store.packVersion == "2026.10.12-starter.1")
    }

    @Test
    func `A cache at or past the bundled version loads`() throws {
        let signer = RemotePackSigner()
        let store = tempStore()
        defer { store.clear() }
        try store.save(envelope: signer.envelope(packVersion: "2026.10.11-remote.1"), etag: nil, packVersion: "2026.10.11-remote.1")

        #expect(try store.loadCached(keys: signer.keys, bundledVersion: "2026.10.10-starter.3")?.pack.packVersion == "2026.10.11-remote.1")
        #expect(try store.loadCached(keys: signer.keys, bundledVersion: "2026.10.11-remote.1")?.pack.packVersion == "2026.10.11-remote.1")
        #expect(store.packVersion == "2026.10.11-remote.1")
    }

    @Test
    func `Discarding never lowers a floor already above the bundled version`() throws {
        let signer = RemotePackSigner()
        let store = tempStore()
        defer { store.clear() }
        // The floor already sits above the bundled version while the cached
        // envelope is older than both (an envelope file restored from a
        // backup, say): the discard must not pull the floor down.
        try store.save(envelope: signer.envelope(packVersion: "2026.10.10-remote.1"), etag: nil, packVersion: "2026.10.12-remote.1")

        #expect(try store.loadCached(keys: signer.keys, bundledVersion: "2026.10.12-starter.1") == nil)
        #expect(store.packVersion == "2026.10.12-remote.1")
    }
}
