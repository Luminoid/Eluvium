import EluviumCore
import Foundation

/// A windowed view over an already-materialized item list: feeds and lists
/// arrive whole (a feed document, a SPARQL result, inline entries), so
/// "load more" reveals in pages instead of refetching. Pure and Equatable
/// so paging is testable without a table view.
struct RecordWindow: Equatable {
    let pageSize: Int
    private(set) var revealed: Int
    var total: Int

    init(total: Int, pageSize: Int = 20) {
        self.pageSize = pageSize
        self.total = total
        revealed = min(pageSize, total)
    }

    var hasMore: Bool { revealed < total }

    /// One more page, clamped to the total.
    mutating func revealMore() {
        revealed = min(revealed + pageSize, total)
    }

    /// A grown list (a fetched next page appended) keeps the reveal point
    /// and extends the total, so the new items sit behind one more tap.
    mutating func extend(total newTotal: Int) {
        total = max(total, newTotal)
    }

    /// The revealed prefix as an O(1) slice (zero-based indices): a copy
    /// per data-source callback turned every table pass quadratic.
    func visible<Element>(of items: [Element]) -> ArraySlice<Element> {
        items.prefix(revealed)
    }
}

/// The affordance decisions a record card or item row needs: what can be
/// browsed, drilled into, played, or fetched next. Pure functions over the
/// record shape so both screens and tests share one reading.
enum RecordBrowsing {
    /// Non-empty collections in stable name order.
    static func browsableCollections(of record: ELVRecord) -> [(name: String, children: [ELVRecord])] {
        record.collections
            .filter { !$0.value.isEmpty }
            .sorted { $0.key < $1.key }
            .map { (name: $0.key, children: $0.value) }
    }

    /// The podcast-show chain: a record carrying `feedUrl` resolves it
    /// as a fresh feed input for the full episode list.
    static func feedURL(of record: ELVRecord) -> URL? {
        url(of: record, field: "feedUrl")
    }

    /// A feed's continuation pointer (`nextPage`), chased as a fresh resolve
    /// once the embedded items run out.
    static func nextPage(of record: ELVRecord) -> URL? {
        url(of: record, field: "nextPage")
    }

    /// An item's member link, the drill-through for list entries and feed
    /// posts alike: `url` (list entries) before `link` (feed items).
    static func memberURL(of item: ELVRecord) -> URL? {
        url(of: item, field: "url") ?? url(of: item, field: "link")
    }

    /// A playable audio URL: the typed `.media` audio ref, tolerating the
    /// plain-url form older pack revisions produced.
    static func audioURL(of item: ELVRecord) -> URL? {
        switch item.fields["audio"] {
        case let .media(media) where media.kind == ELVMediaRef.audio: media.url
        case let .media(media) where media.kind == ELVMediaRef.image: nil
        case let .url(url): url
        default: nil
        }
    }

    /// The record's image ref, for artwork surfaces (the player's Now
    /// Playing) — full ref, not URL, so a source-stamped referer rides along.
    static func imageRef(of record: ELVRecord) -> ELVMediaRef? {
        guard case let .media(media)? = record.fields["image"], media.kind == ELVMediaRef.image else { return nil }
        return media
    }

    /// The strongest stable handle a row offers, for append-time dedup when
    /// a chased page re-ships items the list already has.
    static func dedupKey(_ item: ELVRecord) -> String? {
        if let id = item.externalId { return "id:\(id)" }
        if let audio = audioURL(of: item) { return "audio:\(audio.absoluteString)" }
        if let member = memberURL(of: item) { return "url:\(member.absoluteString)" }
        if case let .text(title)? = item.fields["title"] { return "title:\(title)" }
        return nil
    }

    /// Whether the item carries its own readable body (a feed post's
    /// content or summary); entries without one drill into their member URL.
    static func hasDetailBody(_ item: ELVRecord) -> Bool {
        if case .text = item.fields["content"] { return true }
        if case .text = item.fields["summary"] { return true }
        return false
    }

    /// The body to render as HTML: full `content` when the feed ships one,
    /// else a markup-bearing `summary` — plenty of RSS feeds put the whole
    /// post (images included; xkcd is one big `<img>`) in `description`,
    /// which the envelope surfaces as the summary. Plain-text summaries
    /// return nil so they stay on the native label.
    static func detailHTML(of item: ELVRecord) -> String? {
        if case let .text(content)? = item.fields["content"] { return content }
        if case let .text(summary)? = item.fields["summary"], looksLikeHTML(summary) { return summary }
        return nil
    }

    // Fixed patterns compile once (the static-pattern rule): these run per
    // cell configure on every table pass.
    // swiftlint:disable:next force_try
    private static let tagOpenRegex = try! NSRegularExpression(pattern: "<[a-zA-Z!/]")
    // swiftlint:disable:next force_try
    private static let tagStripRegex = try! NSRegularExpression(pattern: "<[^>]+>")
    // swiftlint:disable:next force_try
    private static let whitespaceRunRegex = try! NSRegularExpression(pattern: "\\s+")

    /// A tag open (`<p`, `</a`, `<!--`) anywhere; loose comparisons like
    /// "5 < 10" don't qualify.
    private static func looksLikeHTML(_ text: String) -> Bool {
        tagOpenRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The row's secondary line: list-entry metadata (rank, year, artist,
    /// distinction) when present, else date · duration for playable items,
    /// else a summary snippet.
    static func rowSecondary(for item: ELVRecord) -> String? {
        var parts: [String] = []
        if case let .number(rank)? = item.fields["rank"], let rank = displayInteger(rank) { parts.append("No. \(rank)") }
        if case let .number(year)? = item.fields["year"], let year = displayInteger(year) { parts.append(String(year)) }
        if case let .text(artist)? = item.fields["artist"] { parts.append(artist) }
        if case let .text(distinction)? = item.fields["distinction"] { parts.append(distinction) }
        if !parts.isEmpty { return parts.joined(separator: Separator.dot) }

        if case let .date(date, _)? = item.fields["published"] {
            parts.append(Self.dayFormatter.string(from: date))
        }
        if case let .duration(seconds)? = item.fields["duration"] {
            parts.append(ELVValueDisplay.duration(seconds))
        }
        if !parts.isEmpty { return parts.joined(separator: Separator.dot) }

        if case let .text(summary)? = item.fields["summary"] { return snippet(summary, limit: 120) }
        return nil
    }

    /// A feed or page number as a display integer, nil when it can't be one:
    /// `Int(_:)` traps on NaN, infinity, and anything past `Int`'s range, and
    /// `1e300` is ordinary JSON. Below 9e15 every whole double is exact.
    /// Callers skip the part on nil.
    static func displayInteger(_ value: Double) -> Int? {
        guard value.isFinite, abs(value) < maxDisplayInteger else { return nil }
        return Int(value.rounded(.towardZero))
    }

    private static let maxDisplayInteger: Double = 9e15

    /// Strips markup, decodes the common entities, and collapses whitespace
    /// so an HTML-bearing feed summary reads as one plain secondary line.
    static func snippet(_ text: String, limit: Int) -> String {
        var stripped = tagStripRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        for (entity, character) in htmlEntities {
            stripped = stripped.replacingOccurrences(of: entity, with: character)
        }
        stripped = whitespaceRunRegex.stringByReplacingMatches(in: stripped, range: NSRange(stripped.startIndex..., in: stripped), withTemplate: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard stripped.count > limit else { return stripped }
        return String(stripped.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The handful of entities feed text actually ships. `&amp;` decodes
    /// last so double-escaped text decodes exactly once.
    private static let htmlEntities: [(String, String)] = [
        ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&"),
    ]

    private static func url(of record: ELVRecord, field: String) -> URL? {
        if case let .url(url)? = record.fields[field] { return url }
        return nil
    }

    /// Static: a per-call `DateFormatter` costs ~1 ms each.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
