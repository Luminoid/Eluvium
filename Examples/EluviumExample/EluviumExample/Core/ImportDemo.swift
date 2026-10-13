import EluviumCore

/// The three bundled sample imports and their mirror wiring, plus the
/// merge arithmetic the Imports screen reports. Kept out of the view
/// controller so the numbers it shows are testable without a table view.
enum ImportDemo: CaseIterable {
    case flighty
    case twitter
    case opml

    /// What one import did to a demo's account mirror.
    struct MergeOutcome {
        var mirror: ELVRecord
        var countBefore: Int
        var countAfter: Int
        /// Whether the first row's user-edited `note` survived the merge.
        var noteKept: Bool
    }

    /// Every file source recognition considers, in demo order.
    static var recognizableSources: [ELVSource] { allCases.map(\.source) }

    var source: ELVSource {
        switch self {
        case .flighty: FlightySource.source
        case .twitter: TwitterArchiveSource.source
        case .opml: OPMLSource.source
        }
    }

    /// The mirror collection imported rows accumulate into.
    var collection: String {
        switch self {
        case .flighty: "flights"
        case .twitter: "tweets"
        case .opml: "feeds"
        }
    }

    var rowNoun: String {
        switch self {
        case .flighty: "flights"
        case .twitter: "tweets"
        case .opml: "subscriptions"
        }
    }

    var dedupKey: String {
        switch self {
        case .flighty: "ID"
        case .twitter: "id_str"
        case .opml: "xmlUrl"
        }
    }

    var headerTitle: String {
        switch self {
        case .flighty: "Flights (Flighty CSV)"
        case .twitter: "Tweets (Twitter archive jsJson)"
        case .opml: "Subscriptions (OPML)"
        }
    }

    var files: [(fileName: String, text: String)] {
        switch self {
        case .flighty: [("FlightyExport-sample.csv", FlightySource.sampleCSV)]
        case .twitter: TwitterArchiveSource.sampleShards
        case .opml: [("Subscriptions.opml", OPMLSource.sampleOPML)]
        }
    }

    /// A fresh account mirror for this demo.
    var emptyMirror: ELVRecord {
        ELVRecord(sourceId: source.id, kind: "account")
    }

    /// The demo whose source recognized a picked file. Unrecognized picks
    /// stay on the Flighty source so a mismatch keeps its typed failure copy.
    static func demo(for recognized: ELVSource?) -> Self {
        allCases.first { $0.source.id == recognized?.id } ?? .flighty
    }

    /// Merges imported rows into `mirror` under `policy`, reporting the
    /// before/after counts and whether an edited note survived.
    func merge(_ records: [ELVRecord], into mirror: ELVRecord?, policy: ELVMergePolicy) -> MergeOutcome {
        let incoming = ELVRecord(sourceId: source.id, kind: "account", collections: [collection: records])
        let base = mirror ?? emptyMirror
        let merged = base.merging(incoming, policy: policy)
        return MergeOutcome(
            mirror: merged,
            countBefore: base.collections[collection]?.count ?? 0,
            countAfter: merged.collections[collection]?.count ?? 0,
            noteKept: merged.collections[collection]?.first?.fields["note"] != nil
        )
    }

    /// The one-line import summary the status line shows.
    func summary(imported count: Int, fileCount: Int, policy: ELVMergePolicy, outcome: MergeOutcome) -> String {
        let policyLabel = policy == .fillEmptyOnly ? "fill-empty" : "prefer-incoming"
        let origin = fileCount > 1 ? "\(fileCount) shards, concatenated in part order" : "1 file"
        var summary = "Imported \(count) rows from \(origin) (\(policyLabel)). Mirror \(outcome.countBefore) → \(outcome.countAfter) \(rowNoun), deduped on \(dedupKey)."
        if outcome.noteKept { summary += " Edited note preserved." }
        return summary
    }
}

/// A file the catalog's own archive sources recognized: the starter
/// pack's `fileSources` (the iNaturalist and eBird CSVs, the 微信读书 notes
/// export). Unlike the demos, these sources are pack data, so the screen
/// renders them in one generic section per source: a title, and a secondary
/// line from whatever the row carries (chapter, observed date, summary).
enum CatalogImport {
    /// The mirror collection imported rows accumulate into.
    static let collection = "records"

    /// Merges imported rows into `source`'s mirror, deduped on `externalId`
    /// like every demo mirror.
    static func merge(_ records: [ELVRecord], into mirror: ELVRecord?, source: ELVSource, policy: ELVMergePolicy) -> ImportDemo.MergeOutcome {
        let incoming = ELVRecord(sourceId: source.id, kind: "account", collections: [collection: records])
        let base = mirror ?? ELVRecord(sourceId: source.id, kind: "account")
        let merged = base.merging(incoming, policy: policy)
        return ImportDemo.MergeOutcome(
            mirror: merged,
            countBefore: base.collections[collection]?.count ?? 0,
            countAfter: merged.collections[collection]?.count ?? 0,
            noteKept: false
        )
    }

    /// The one-line import summary the status line shows.
    static func summary(source: ELVSource, imported count: Int, outcome: ImportDemo.MergeOutcome) -> String {
        "Imported \(count) rows through \(source.id). \(headerTitle(for: source)): \(outcome.countBefore) → \(outcome.countAfter) records, deduped on externalId."
    }

    static func headerTitle(for source: ELVSource) -> String {
        source.displayName
    }

    /// A row's primary line: its title, else its id.
    static func rowTitle(_ record: ELVRecord) -> String {
        record.displayTitle ?? record.externalId ?? record.kind
    }

    /// A row's secondary line: chapter (a WeRead note), observed date (an
    /// iNaturalist or eBird sighting), and a summary snippet, as present.
    static func rowSecondary(_ record: ELVRecord) -> String? {
        var parts: [String] = []
        if case let .text(chapter)? = record.fields["chapter"] { parts.append(chapter) }
        if let observed = record.fields["observed"] ?? record.fields["date"] { parts.append(ELVValueDisplay.string(observed)) }
        if case let .text(summary)? = record.fields["summary"] { parts.append(RecordBrowsing.snippet(summary, limit: 80)) }
        return parts.isEmpty ? nil : parts.joined(separator: Separator.dot)
    }
}
