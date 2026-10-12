import Foundation

/// The feed engine: one normalizer for RSS 2.0 (tolerating the 0.9x
/// fossils), Atom (RFC 4287), and JSON Feed 1.1 into the canonical envelope.
/// Pure over captured bytes — the conditional-GET transport lives in
/// EluviumNet. Hardened for twenty years of tolerated malformation: XXE
/// defense, BOM tolerance, RFC 822 and ISO 8601 dates in the same feed,
/// CDATA-vs-escaped HTML.
public enum ELVFeedNormalizer {
    /// Normalizes `data`. Returns `nil` only when the bytes are neither
    /// recognizable XML nor JSON.
    public static func normalize(_ data: Data) -> ELVFeedEnvelope? {
        guard let first = firstContentByte(of: data) else { return nil }
        if first == UInt8(ascii: "{") {
            return normalizeJSONFeed(data)
        }
        if first == UInt8(ascii: "<") {
            return ELVXMLFeedParser.parse(data)
        }
        return nil
    }

    /// The first byte past any UTF-8 BOM (EF BB BF) and ASCII whitespace —
    /// sniffed on the raw bytes so dispatch never round-trips the payload
    /// through a `String` (which tripled peak memory just to inspect one
    /// character).
    private static func firstContentByte(of data: Data) -> UInt8? {
        var index = data.startIndex
        while index < data.endIndex {
            let byte = data[index]
            if byte == 0xEF, data.distance(from: index, to: data.endIndex) >= 3,
               data[data.index(index, offsetBy: 1)] == 0xBB, data[data.index(index, offsetBy: 2)] == 0xBF {
                index = data.index(index, offsetBy: 3)
                continue
            }
            if byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x20 {
                index = data.index(after: index)
                continue
            }
            return byte
        }
        return nil
    }

    // MARK: - JSON Feed

    private static func normalizeJSONFeed(_ data: Data) -> ELVFeedEnvelope? {
        guard let root = ELVRawJSON.parse(data), root["version"]?.stringValue?.contains("jsonfeed") == true || root["items"] != nil else {
            return nil
        }
        // JSON Feed 1.1 top-level `authors`, falling back to 1.0's singular `author`.
        let feedAuthor = root["authors"]?.arrayValue?.first?["name"]?.stringValue ?? root["author"]?["name"]?.stringValue
        var envelope = ELVFeedEnvelope(
            title: root["title"]?.stringValue.map(ELVEntityDecoder.decode),
            feedDescription: root["description"]?.stringValue.map(ELVEntityDecoder.decode),
            link: root["home_page_url"]?.stringValue ?? root["feed_url"]?.stringValue,
            image: root["icon"]?.stringValue ?? root["favicon"]?.stringValue,
            language: root["language"]?.stringValue,
            author: feedAuthor.map(ELVEntityDecoder.decode),
            nextURL: root["next_url"]?.stringValue
        )
        envelope.items = (root["items"]?.arrayValue ?? []).enumerated().map { ordinal, node in
            let guid = node["id"]?.stringValue
            let link = node["url"]?.stringValue ?? node["external_url"]?.stringValue
            let title = node["title"]?.stringValue.map(ELVEntityDecoder.decode)
            let published = normalizeDate(node["date_published"]?.stringValue)
            var enclosure: ELVFeedEnvelope.Enclosure?
            if let attachment = node["attachments"]?.arrayValue?.first, let url = attachment["url"]?.stringValue {
                enclosure = ELVFeedEnvelope.Enclosure(
                    url: url,
                    type: attachment["mime_type"]?.stringValue,
                    // Clamp before Int conversion: hostile feeds publish 1e300, and Int(1e300) traps.
                    lengthBytes: attachment["size_in_bytes"]?.numberValue.flatMap { ELVBounds.isSafeNumber($0) ? Int($0) : nil }
                )
            }
            // JSON Feed 1.1 `authors`, falling back to 1.0's singular `author` object.
            var authors = (node["authors"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
            if authors.isEmpty, let author = node["author"]?["name"]?.stringValue {
                authors = [author]
            }
            return ELVFeedEnvelope.Item(
                externalId: itemIdentity(guid: guid, atomId: nil, jsonId: node["id"]?.stringValue, enclosureURL: enclosure?.url, link: link, title: title, published: published, ordinal: ordinal),
                guid: guid,
                title: title,
                summary: node["summary"]?.stringValue.map(ELVEntityDecoder.decode),
                contentHTML: node["content_html"]?.stringValue ?? node["content_text"]?.stringValue,
                link: link,
                published: published,
                updated: normalizeDate(node["date_modified"]?.stringValue),
                authors: authors,
                image: node["image"]?.stringValue,
                enclosure: enclosure,
                durationSeconds: attachmentDuration(node),
                tags: node["tags"]?.arrayValue?.compactMap(\.stringValue) ?? []
            )
        }
        return envelope
    }

    /// JSON Feed `duration_in_seconds`, bounded like every duration leaf
    /// (`ELVBounds.centurySeconds`): a hostile feed publishes 1e300 here as
    /// readily as in `size_in_bytes`.
    private static func attachmentDuration(_ node: ELVRawJSON) -> Double? {
        guard let seconds = node["attachments"]?.arrayValue?.first?["duration_in_seconds"]?.numberValue,
              seconds >= 0, seconds.isFinite, seconds < ELVBounds.centurySeconds else { return nil }
        return seconds
    }

    // MARK: - Shared helpers

    /// The item-identity ladder: first non-empty of guid → atom id →
    /// json id → enclosure url → link → hash(title+published). Real feeds
    /// lie, so a stable fallback always exists. When every rung is empty the
    /// item's position keys it (`ordinal`) — otherwise all such degenerate
    /// items would hash the bare "|" basis and collapse into one identity —
    /// while well-formed items ignore the ordinal and stay stable across
    /// refreshes.
    static func itemIdentity(guid: String?, atomId: String?, jsonId: String?, enclosureURL: String?, link: String?, title: String?, published: String?, ordinal: Int) -> String {
        for candidate in [guid, atomId, jsonId, enclosureURL, link] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        var basis = "\(title ?? "")|\(published ?? "")"
        if basis == "|" { basis = "|\(ordinal)" }
        return "hash:\(ELVStableHash.fnv1a(basis))"
    }

    /// Seconds from `itunes:duration` in any tolerated form — ISO 8601
    /// (`PT45M`), clock (`HH:MM:SS` / `MM:SS`), bare seconds — via the shared
    /// coercion ladder, bounded against overflow-inducing values.
    static func durationSeconds(_ string: String?) -> Double? {
        guard let string = string?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else { return nil }
        return ELVCoercionEngine.durationSeconds(from: string)
    }

    /// Normalizes any parseable date (RFC 822 or ISO 8601 alike) to one
    /// canonical ISO 8601 form via the shared `ELVDateParser` ladder,
    /// leaving an unparseable string as-is (better than dropping it).
    static func normalizeDate(_ string: String?) -> String? {
        guard let string = string?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else { return nil }
        return ELVDateParser.iso8601String(string) ?? string
    }
}
