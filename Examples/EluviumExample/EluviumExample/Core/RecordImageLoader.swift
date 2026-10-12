import EluviumCore
import EluviumNet
import EluviumUI
import Foundation
import ImageIO
import UIKit

/// The app-side implementation behind `ELVRecordCardView.imageLoader`: the
/// framework renders records but never fetches image bytes, so thumbnails go
/// through the host's own network stack. An ephemeral, cookie-less session
/// under the same egress policy as the pipeline's fetcher (checked up front,
/// per redirect hop, and on the landing), a streaming byte cap, a bounded
/// in-memory cache, in-flight coalescing (a card and the Now Playing artwork
/// asking for one image share one fetch), and ImageIO downsampling so a
/// full-size product shot never decodes at native resolution for a 160pt
/// box.
enum RecordImageLoader {
    // MARK: - Properties

    /// NSCache is thread-safe and evicts under memory pressure on its own;
    /// the count limit bounds the steady state and the cost limit bounds the
    /// worst case (100 full-ceiling RGBA thumbnails would be ~370 MB).
    private nonisolated(unsafe) static let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 100
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    /// Never `URLSession.shared`: its cookie jar and persistent cache would
    /// carry state across sites that the pipeline's own fetcher refuses to
    /// keep. Ephemeral and cookie-less, like `ELVHTTPFetcher`.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    /// Decode ceiling (longest edge, pixels), derived from the card's
    /// rendered box: the 160pt side at the 3x maximum display scale with 2x
    /// headroom. Deriving it keeps the budget honest if the card resizes.
    /// MainActor because `thumbnailSide` lives on the MainActor-bound card;
    /// `image(for:)` reads it there and hands the value to the decoder.
    @MainActor
    private static let maxThumbnailPixels = Int(ELVRecordCardView.thumbnailSide) * 3 * 2

    /// Fetches in flight, by URL: a second request for the same image joins
    /// the first instead of fetching twice. Each entry leaves the table when
    /// its task completes (the cache answers after that).
    @MainActor
    private static var inFlight: [URL: Task<UIImage?, Never>] = [:]

    // MARK: - Constants

    /// Streaming byte cap for one thumbnail fetch. A card thumbnail is
    /// kilobytes to a few megabytes; anything past this is not one, and it
    /// must not sit in RAM waiting for ImageIO to reject it.
    private static let maxImageBytes = 8 * 1024 * 1024

    /// The body streams into this buffer and lands in the result a chunk at
    /// a time, not a byte at a time.
    private static let readChunkBytes = 64 * 1024

    /// Redirect hop cap, matching the pipeline fetcher's guard.
    private static let maxRedirectHops = 10

    // MARK: - Loading

    /// MainActor by design: every caller is a card's `imageLoader` closure,
    /// and the actual fetch + decode hops off through `fetchAndDecode`.
    /// Takes the whole media ref so a source-stamped `referer` rides the
    /// request (Douban's hotlink protection 418s a bare image fetch).
    /// The shared fetch outlives a caller that stops waiting (a card
    /// reconfigured mid-load): it finishes into the cache for the next ask.
    @MainActor
    static func image(for media: ELVMediaRef) async -> UIImage? {
        let url = media.url
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        if let pending = inFlight[url] { return await pending.value }
        let maxPixels = maxThumbnailPixels
        let task = Task<UIImage?, Never> {
            let image = await fetchAndDecode(url, referer: media.referer, maxPixels: maxPixels)
            if let image {
                cache.setObject(image, forKey: url as NSURL, cost: cost(of: image))
            }
            inFlight[url] = nil
            return image
        }
        inFlight[url] = task
        return await task.value
    }

    // MARK: - Helpers

    /// The decoded footprint in bytes, so the cache's cost limit tracks
    /// real memory, not image count.
    private static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }

    /// `@concurrent` so the fetch and decode never ride the main actor:
    /// under Approachable Concurrency a plain `nonisolated async` function
    /// runs on the caller's executor, and the card always calls from
    /// MainActor.
    @concurrent
    private static func fetchAndDecode(_ url: URL, referer: URL?, maxPixels: Int) async -> UIImage? {
        // The same policy the pipeline applies: a thumbnail is a device
        // egress too, and a pack can point an image ref anywhere.
        guard ELVEgressPolicy.violation(url) == nil else { return nil }
        var request = URLRequest(url: url)
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        let redirectGuard = ELVRedirectGuard(maxHops: maxRedirectHops)
        guard let (bytes, response) = try? await session.bytes(for: request, delegate: redirectGuard) else { return nil }
        // Landing checks: no refused hop, the final URL itself passes, and
        // the response is plausibly an image.
        guard redirectGuard.refusalReason == nil, let finalURL = response.url, ELVEgressPolicy.violation(finalURL) == nil, isImageResponse(response) else {
            bytes.task.cancel()
            return nil
        }
        guard let data = await collect(bytes, expectedLength: response.expectedContentLength) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: thumbnail)
    }

    /// Streams the body against the byte cap: nil when it overruns (a
    /// partial image is not worth decoding) or the transfer fails. Bytes
    /// gather in a fixed buffer that flushes into the result per chunk.
    private static func collect(_ bytes: URLSession.AsyncBytes, expectedLength: Int64) async -> Data? {
        var data = Data()
        // `expectedLength` is server-supplied: clamp before converting.
        data.reserveCapacity(Int(min(max(expectedLength, 0), Int64(maxImageBytes))))
        var chunk: [UInt8] = []
        chunk.reserveCapacity(readChunkBytes)
        func flush() -> Bool {
            guard data.count + chunk.count <= maxImageBytes else { return false }
            data.append(contentsOf: chunk)
            chunk.removeAll(keepingCapacity: true)
            return true
        }
        do {
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count == readChunkBytes, !flush() {
                    bytes.task.cancel()
                    return nil
                }
            }
        } catch {
            return nil
        }
        return flush() ? data : nil
    }

    /// Refuses what ImageIO would otherwise be handed and log about (an
    /// error status — Reddit's feed icon URL 404s as text/plain — or a text
    /// body). A missing or generic MIME type still decodes: some CDNs serve
    /// images as `application/octet-stream`, and ImageIO sniffs the bytes.
    private static func isImageResponse(_ response: URLResponse) -> Bool {
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) { return false }
        if let mime = response.mimeType?.lowercased(), mime.hasPrefix("text/") { return false }
        return true
    }
}
