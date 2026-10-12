import EluviumCore
import Foundation

/// Downloads a signed pack, verifies it, and loads it — the client half of the
/// remote channel. Reuses `ELVHTTPFetcher`, so every egress checkpoint
/// (HTTPS-only, SSRF guard, per-hop redirect check, final-URL recheck) and the
/// streaming byte cap come for free. The caller merges the result over its
/// built-in subset: `builtin.merging(downloaded)`.
///
/// The trust boundary is unchanged: bytes reach the loader only through
/// `ELVPackVerifier.verify`, keyed by the binary-pinned `ELVPackKeySet`. An
/// unsigned or tampered pack is rejected outright. A valid signature is not
/// enough on its own: with a store, a verified pack older than the last one
/// accepted (`ELVRemotePackStore.packVersion`, ordered by
/// `ELVPackVersion.compare`) is refused as a rollback, so a stale CDN edge
/// or a replayed older signed pack cannot downgrade sources.
public struct ELVRemotePackService: Sendable {
    public enum Outcome: Sendable {
        /// A new, verified pack (also persisted if a store was given).
        case updated(ELVLoadedPack)
        /// The server answered 304; keep using the cached/built-in pack.
        case notModified
    }

    private let fetcher: any ELVFetching
    private let keys: ELVPackKeySet
    private let store: ELVRemotePackStore?
    private let budget: ELVFetchBudget

    public init(
        fetcher: any ELVFetching = ELVHTTPFetcher(),
        keys: ELVPackKeySet,
        store: ELVRemotePackStore? = nil,
        budget: ELVFetchBudget = ELVFetchBudget(maxBytes: 5_000_000)
    ) {
        self.fetcher = fetcher
        self.keys = keys
        self.store = store
        self.budget = budget
    }

    /// Fetches (conditionally, if a store holds an ETag), verifies, loads,
    /// refuses a pack older than the store's last accepted version
    /// (`ELVRemotePackError.versionRollback`), and on success persists the
    /// envelope with its version and posts `.elvRemotePackUpdated`. Logs one
    /// outcome line: a notice for an update (with the new pack's version and
    /// source count), info for a 304, an error for any failure, the rollback
    /// naming both versions. The pack URL's host is public; the full URL
    /// stays private.
    public func refresh(from url: URL, capabilities: ELVCapabilities = .core) async throws -> Outcome {
        let started = ContinuousClock.now
        let host = ELVLogFormat.host(url)
        do {
            let outcome = try await refreshBody(from: url, capabilities: capabilities)
            let elapsed = ELVLogFormat.milliseconds(ContinuousClock.now - started)
            switch outcome {
            case let .updated(loaded):
                ELVLog.notice(
                    .remote,
                    "Remote pack updated host=\(host) version=\(loaded.pack.packVersion) sources=\(loaded.sources.count) skipped=\(loaded.skipped.count) in \(elapsed)ms",
                    private: "url=\(url.absoluteString)"
                )
            case .notModified:
                ELVLog.info(.remote, "Remote pack not modified host=\(host) in \(elapsed)ms", private: "url=\(url.absoluteString)")
            }
            return outcome
        } catch is CancellationError {
            ELVLog.debug(.remote, "Remote pack refresh cancelled host=\(host)")
            throw CancellationError()
        } catch {
            let elapsed = ELVLogFormat.milliseconds(ContinuousClock.now - started)
            if case let .versionRollback(offered, accepted)? = error as? ELVRemotePackError {
                // Both versions are signed pack text, so the line is public.
                ELVLog.error(
                    .remote,
                    "Remote pack refused host=\(host) version=\(offered) is older than accepted=\(accepted) in \(elapsed)ms",
                    private: "url=\(url.absoluteString)"
                )
            } else {
                ELVLog.error(.remote, "Remote pack refresh failed host=\(host) in \(elapsed)ms", private: "url=\(url.absoluteString)", error: error)
            }
            throw error
        }
    }

    private func refreshBody(from url: URL, capabilities: ELVCapabilities) async throws -> Outcome {
        let result = try await fetcher.fetchConditional(url, ifNoneMatch: store?.etag, budget: budget)
        guard let response = result.response else {
            return .notModified
        }

        // HTML-response detection: a captive portal or error shell can
        // answer 200 with markup; it must never be parsed as a pack. Scans
        // the bytes for the first non-whitespace one instead of trimming a
        // copy of a multi-MB body text.
        if response.data.first(where: { !Self.isASCIIWhitespace($0) }) == UInt8(ascii: "<") {
            throw ELVRemotePackError.htmlResponse
        }

        let envelope: ELVPackEnvelope
        do {
            envelope = try JSONDecoder().decode(ELVPackEnvelope.self, from: response.data)
        } catch {
            throw ELVRemotePackError.notAnEnvelope(String(describing: error))
        }

        let verified = try ELVPackVerifier.verify(envelope, keys: keys, failureLevel: .debug)
        let loaded = try ELVPackLoader.load(verified, capabilities: capabilities, failureLevel: .debug)

        // Rollback guard: a signature proves who made a pack, not that it is
        // current. Same-version re-serves pass (a re-signed or re-hosted
        // pack); only strictly older ones are refused.
        let offered = loaded.pack.packVersion
        if let accepted = store?.packVersion, ELVPackVersion.compare(offered, accepted) == .orderedAscending {
            throw ELVRemotePackError.versionRollback(offered: offered, accepted: accepted)
        }

        if let store {
            try store.save(envelope: response.data, etag: result.etag, packVersion: offered)
        }
        // Posted on the main actor: the observers are UI (re-merge, reload
        // a list), and a background-queue post would hand every one of them
        // a thread hop.
        await MainActor.run {
            NotificationCenter.default.post(name: .elvRemotePackUpdated, object: nil)
        }
        return .updated(loaded)
    }

    /// Space, tab, CR, LF: the whitespace JSON and HTML may both lead with.
    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}

public enum ELVRemotePackError: Error, Equatable, Sendable {
    /// The response body is HTML, not a pack envelope.
    case htmlResponse
    /// The body is not a decodable `ELVPackEnvelope`; the payload is the
    /// decoder's description of what was wrong (a missing key, a type
    /// mismatch), so a health run names the server-side drift.
    case notAnEnvelope(String)
    /// The pack verified but is older than the last one the store accepted:
    /// a stale CDN edge or a replayed signed pack. Nothing is persisted and
    /// the accepted pack stays in effect.
    case versionRollback(offered: String, accepted: String)
}

public extension Notification.Name {
    /// Posted on the main actor after a downloaded pack is verified and
    /// applied, so the host can re-merge and clear caches.
    static let elvRemotePackUpdated = Notification.Name("ELVRemotePackUpdated")
}
