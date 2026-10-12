import Foundation

/// The canonical feed envelope: RSS 2.0, Atom, and JSON Feed all
/// normalize into this one shape, so everything downstream is ordinary
/// `json`-selector machinery. Binary-owned and versioned like a native op
/// (`feed.normalize@1`); grows append-only.
public struct ELVFeedEnvelope: Sendable, Equatable {
    public var title: String?
    public var feedDescription: String?
    public var link: String?
    public var image: String?
    public var language: String?
    /// The show-level author (`itunes:author`, JSON Feed top-level authors).
    public var author: String?
    /// The show's strong identity (Podcasting 2.0 `podcast:guid`).
    public var podcastGuid: String?
    /// The next page's URL when the feed paginates (RFC 5005 `rel="next"`,
    /// JSON Feed `next_url`). Continuation is host-driven: the engine never
    /// follows it.
    public var nextURL: String?
    /// Podcasting 2.0 `podcast:funding`: the support URL and its label text.
    public var fundingURL: String?
    public var fundingLabel: String?
    /// `itunes:type` at the channel level, validated to `episodic`/`serial`.
    public var itunesType: String?
    public var items: [Item]

    public init(
        title: String? = nil,
        feedDescription: String? = nil,
        link: String? = nil,
        image: String? = nil,
        language: String? = nil,
        author: String? = nil,
        podcastGuid: String? = nil,
        nextURL: String? = nil,
        fundingURL: String? = nil,
        fundingLabel: String? = nil,
        itunesType: String? = nil,
        items: [Item] = []
    ) {
        self.title = title
        self.feedDescription = feedDescription
        self.link = link
        self.image = image
        self.language = language
        self.author = author
        self.podcastGuid = podcastGuid
        self.nextURL = nextURL
        self.fundingURL = fundingURL
        self.fundingLabel = fundingLabel
        self.itunesType = itunesType
        self.items = items
    }

    public struct Enclosure: Sendable, Equatable {
        public var url: String
        public var type: String?
        public var lengthBytes: Int?

        public init(url: String, type: String? = nil, lengthBytes: Int? = nil) {
            self.url = url
            self.type = type
            self.lengthBytes = lengthBytes
        }
    }

    /// Podcasting 2.0 `podcast:transcript`: one alternative transcript
    /// rendition (VTT / SRT / JSON in the wild).
    public struct Transcript: Sendable, Equatable {
        public var url: String
        public var type: String?
        public var language: String?

        public init(url: String, type: String? = nil, language: String? = nil) {
            self.url = url
            self.type = type
            self.language = language
        }
    }

    public struct Item: Sendable, Equatable {
        /// The item-identity ladder result: guid → atom id → json id →
        /// enclosure url → link → hash(title+published), position-keyed when
        /// every rung is empty.
        public var externalId: String
        public var guid: String?
        public var title: String?
        public var summary: String?
        public var contentHTML: String?
        public var link: String?
        /// ISO 8601 form of the item's publish date (normalized from RFC 822
        /// or ISO 8601 in the source).
        public var published: String?
        public var updated: String?
        public var authors: [String]
        public var image: String?
        public var enclosure: Enclosure?
        public var durationSeconds: Double?
        public var episode: Int?
        public var season: Int?
        public var episodeType: String?
        public var explicit: Bool?
        public var tags: [String]
        /// Podcasting 2.0 `podcast:transcript` renditions, document order.
        public var transcripts: [Transcript]
        /// Podcasting 2.0 `podcast:chapters` URL (JSON chapters file).
        public var chaptersURL: String?

        public init(
            externalId: String,
            guid: String? = nil,
            title: String? = nil,
            summary: String? = nil,
            contentHTML: String? = nil,
            link: String? = nil,
            published: String? = nil,
            updated: String? = nil,
            authors: [String] = [],
            image: String? = nil,
            enclosure: Enclosure? = nil,
            durationSeconds: Double? = nil,
            episode: Int? = nil,
            season: Int? = nil,
            episodeType: String? = nil,
            explicit: Bool? = nil,
            tags: [String] = [],
            transcripts: [Transcript] = [],
            chaptersURL: String? = nil
        ) {
            self.externalId = externalId
            self.guid = guid
            self.title = title
            self.summary = summary
            self.contentHTML = contentHTML
            self.link = link
            self.published = published
            self.updated = updated
            self.authors = authors
            self.image = image
            self.enclosure = enclosure
            self.durationSeconds = durationSeconds
            self.episode = episode
            self.season = season
            self.episodeType = episodeType
            self.explicit = explicit
            self.tags = tags
            self.transcripts = transcripts
            self.chaptersURL = chaptersURL
        }

        /// The rendition a reader should reach for first: VTT, then SRT,
        /// then JSON, then whatever the feed offered. Typeless renditions
        /// only win when nothing typed exists.
        public var preferredTranscript: Transcript? {
            for marker in ["vtt", "srt", "subrip", "json"] {
                if let match = transcripts.first(where: { $0.type?.lowercased().contains(marker) == true }) {
                    return match
                }
            }
            return transcripts.first
        }
    }

    /// The envelope as an `ELVRawJSON` tree, so packs select from it with
    /// ordinary `json` candidates. This is the seam between the feed
    /// engine and the rest of the pipeline.
    public func asRawJSON() -> ELVRawJSON {
        var root: [String: ELVRawJSON] = [:]
        root["title"] = title.map(ELVRawJSON.string)
        root["description"] = feedDescription.map(ELVRawJSON.string)
        root["link"] = link.map(ELVRawJSON.string)
        root["image"] = image.map(ELVRawJSON.string)
        root["language"] = language.map(ELVRawJSON.string)
        root["author"] = author.map(ELVRawJSON.string)
        root["podcastGuid"] = podcastGuid.map(ELVRawJSON.string)
        root["nextURL"] = nextURL.map(ELVRawJSON.string)
        root["fundingURL"] = fundingURL.map(ELVRawJSON.string)
        root["fundingLabel"] = fundingLabel.map(ELVRawJSON.string)
        root["itunesType"] = itunesType.map(ELVRawJSON.string)
        root["items"] = .array(items.map { $0.asRawJSON() })
        return .object(root.compactMapValues { $0 })
    }
}

extension ELVFeedEnvelope.Item {
    func asRawJSON() -> ELVRawJSON {
        var object: [String: ELVRawJSON] = [:]
        object["externalId"] = .string(externalId)
        object["guid"] = guid.map(ELVRawJSON.string)
        object["title"] = title.map(ELVRawJSON.string)
        object["summary"] = summary.map(ELVRawJSON.string)
        object["contentHTML"] = contentHTML.map(ELVRawJSON.string)
        object["link"] = link.map(ELVRawJSON.string)
        object["published"] = published.map(ELVRawJSON.string)
        object["updated"] = updated.map(ELVRawJSON.string)
        if !authors.isEmpty { object["authors"] = .array(authors.map { .object(["name": .string($0)]) }) }
        object["image"] = image.map(ELVRawJSON.string)
        if let enclosure {
            var enclosureObject: [String: ELVRawJSON] = ["url": .string(enclosure.url)]
            enclosureObject["type"] = enclosure.type.map(ELVRawJSON.string)
            enclosureObject["lengthBytes"] = enclosure.lengthBytes.map { .number(Double($0)) }
            object["enclosure"] = .object(enclosureObject.compactMapValues { $0 })
            // Typed convenience for packs: only audio enclosures (or
            // typeless ones — many podcast feeds omit the MIME) qualify, so
            // an image/PDF enclosure never grows a Play button.
            if enclosure.type.map({ $0.lowercased().hasPrefix("audio/") }) ?? true {
                object["enclosureAudioURL"] = .string(enclosure.url)
            }
        }
        object["chaptersURL"] = chaptersURL.map(ELVRawJSON.string)
        if !transcripts.isEmpty {
            object["transcripts"] = .array(transcripts.map { transcript in
                var node: [String: ELVRawJSON] = ["url": .string(transcript.url)]
                node["type"] = transcript.type.map(ELVRawJSON.string)
                node["language"] = transcript.language.map(ELVRawJSON.string)
                return .object(node.compactMapValues { $0 })
            })
            // Typed convenience like `enclosureAudioURL`: the preferred
            // rendition, so packs need no per-type ladder.
            object["transcriptURL"] = preferredTranscript.map { .string($0.url) }
        }
        object["durationSeconds"] = durationSeconds.map(ELVRawJSON.number)
        object["episode"] = episode.map { .number(Double($0)) }
        object["season"] = season.map { .number(Double($0)) }
        object["episodeType"] = episodeType.map(ELVRawJSON.string)
        object["explicit"] = explicit.map(ELVRawJSON.bool)
        if !tags.isEmpty { object["tags"] = .array(tags.map(ELVRawJSON.string)) }
        return .object(object.compactMapValues { $0 })
    }
}
