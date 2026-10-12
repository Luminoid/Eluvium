import Foundation
import Testing
@testable import EluviumCore

@Suite("Record assembly")
struct ELVAssemblerTests {
    @Test
    func `A podcast-shaped source assembles fields, identities, and an episode collection from a JSON envelope`() throws {
        let envelope = """
        {
          "title": "Under the Radar",
          "podcastGuid": "8e2f0c6a-guid",
          "items": [
            {"guid": "e300", "title": "Episode 300", "enclosure": {"url": "https://cdn.example.com/300.mp3"}, "durationSeconds": 1800},
            {"guid": "e299", "title": "Episode 299", "enclosure": {"url": "https://cdn.example.com/299.mp3"}, "durationSeconds": 1740}
          ]
        }
        """
        let source = ELVSource(
            id: "podcast.show",
            kind: "podcast",
            fields: [
                ELVFieldSpec(name: "title", candidates: [ELVCandidate(from: .json("$.title"))]),
            ],
            collections: [
                ELVCollectionSpec(name: "episodes", from: .json("$.items[*]"), item: [
                    ELVFieldSpec(name: "externalId", candidates: [ELVCandidate(from: .json("$.guid"))]),
                    ELVFieldSpec(name: "title", candidates: [ELVCandidate(from: .json("$.title"))]),
                    ELVFieldSpec(name: "audio", candidates: [ELVCandidate(from: .json("$.enclosure.url"), coercion: ELVCoercion(kind: "url"))]),
                    ELVFieldSpec(name: "duration", candidates: [ELVCandidate(from: .json("$.durationSeconds"), coercion: ELVCoercion(kind: "duration"))]),
                ], kind: "episode"),
            ],
            identities: [
                ELVIdentitySpec(namespace: "podcast.guid", from: .json("$.podcastGuid")),
            ]
        )
        let json = try #require(ELVRawJSON.parse(Data(envelope.utf8)))
        let context = ELVExtractionContext(document: ELVDocument(json: json))
        let record = ELVAssembler.assemble(source: source, context: context)

        #expect(record.kind == "podcast")
        #expect(record.fields["title"] == .text("Under the Radar"))
        #expect(record.identities == [ELVIdentity(namespace: "podcast.guid", value: "8e2f0c6a-guid", origin: .declared)])

        let episodes = try #require(record.collections["episodes"])
        #expect(episodes.count == 2)
        #expect(episodes.first?.externalId == "e300")
        #expect(episodes.first?.kind == "episode")
        #expect(episodes.first?.fields["externalId"] == nil)
        #expect(episodes.first?.fields["duration"] == .duration(1800))
    }

    @Test
    func `externalId extracted as a field is promoted to record metadata and removed from fields`() {
        let source = ELVSource(
            id: "imdb.title",
            kind: "movie",
            fields: [
                ELVFieldSpec(name: "externalId", candidates: [ELVCandidate(from: .urlParam("id"))]),
                ELVFieldSpec(name: "title", candidates: [ELVCandidate(from: .meta("og:title"))]),
            ],
            identities: [
                ELVIdentitySpec(namespace: "imdb", from: .urlParam("id")),
            ]
        )
        let context = ELVExtractionContext(
            url: URL(string: "https://www.imdb.com/title/tt0076759/"),
            params: ["id": "tt0076759"],
            document: ELVDocument(metas: ["og:title": "Star Wars (1977)"])
        )
        let record = ELVAssembler.assemble(source: source, context: context)
        #expect(record.externalId == "tt0076759")
        #expect(record.fields["externalId"] == nil)
        #expect(record.provenance["externalId"] == nil)
        #expect(record.identities == [ELVIdentity(namespace: "imdb", value: "tt0076759", origin: .declared)])
        #expect(record.sourceURL?.absoluteString == "https://www.imdb.com/title/tt0076759/")
    }

    @Test
    func `A record with no externalId spec falls back to a stable URL-derived key`() throws {
        let source = ELVSource(
            id: "generic.opengraph",
            kind: "link",
            fields: [ELVFieldSpec(name: "title", candidates: [ELVCandidate(from: .meta("og:title"))])]
        )
        let url = try #require(URL(string: "https://example.com/post"))
        let context = ELVExtractionContext(url: url, document: ELVDocument(metas: ["og:title": "A Blog Post"]))
        let record = ELVAssembler.assemble(source: source, context: context)
        // Deterministic across launches: this is what lets floor records
        // dedup on re-import and join the entity graph.
        #expect(record.externalId == "url:" + ELVStableHash.fnv1a(url.absoluteString))
        #expect(ELVAssembler.assemble(source: source, context: context).externalId == record.externalId)
        // No URL, no stable handle: a pasted blurb keys on nothing.
        let urlless = ELVAssembler.assemble(source: source, context: ELVExtractionContext(document: ELVDocument(metas: ["og:title": "A"])))
        #expect(urlless.externalId == nil)
    }

    @Test
    func `assemble reuses a pre-extracted field result instead of extracting twice`() {
        let source = ELVSource(
            id: "reuse.example",
            kind: "thing",
            fields: [ELVFieldSpec(name: "title", candidates: [ELVCandidate(from: .meta("og:title"))])]
        )
        let context = ELVExtractionContext(document: ELVDocument(metas: ["og:title": "Fresh"]))
        let preExtracted = ELVExtractor.FieldResult(
            values: ["title": .text("Cached")],
            provenance: ["title": ELVProvenance(origin: "meta:og:title", candidateIndex: 0)]
        )
        // The handed-over result is authoritative; no second extraction runs.
        let record = ELVAssembler.assemble(source: source, context: context, preExtracted: preExtracted)
        #expect(record.fields["title"] == .text("Cached"))
        #expect(ELVAssembler.assemble(source: source, context: context).fields["title"] == .text("Fresh"))
    }

    @Test
    func `All four assembly entry points trim, drop-empty, and dedup identities identically`() throws {
        let source = ELVSource(
            id: "consistent.source",
            kind: "thing",
            fields: [ELVFieldSpec(name: "title", candidates: [ELVCandidate(from: .json("$.title"))])],
            rows: [ELVFieldSpec(name: "title", candidates: [ELVCandidate(from: .json("$.title"))])],
            collections: [
                ELVCollectionSpec(name: "children", from: .json("$.items[*]"), item: [
                    ELVFieldSpec(name: "title", candidates: [ELVCandidate(from: .json("$.title"))]),
                ]),
            ],
            identities: [
                ELVIdentitySpec(namespace: "test.ns", from: .json("$.id")),
                ELVIdentitySpec(namespace: "test.ns", from: .json("$.idAgain")),
                ELVIdentitySpec(namespace: "blank.ns", from: .json("$.blank")),
            ]
        )
        let item = #"{"title": "C", "id": " x7 ", "idAgain": "x7", "blank": " "}"#
        let body = #"{"title": "T", "id": " x7 ", "idAgain": "x7", "blank": "  ", "items": [\#(item)]}"#
        let json = try #require(ELVRawJSON.parse(Data(body.utf8)))
        let itemJSON = try #require(ELVRawJSON.parse(Data(item.utf8)))
        let url = try #require(URL(string: "https://consistent.example/x"))
        let context = ELVExtractionContext(url: url, document: ELVDocument(json: json))
        let expected = [ELVIdentity(namespace: "test.ns", value: "x7", origin: .declared)]

        let page = ELVAssembler.assemble(source: source, context: context)
        #expect(page.identities == expected)
        // Children do NOT inherit the parent's identity specs: a
        // track is not its album, so parent ids never leak into items. A
        // collection that wants item identities declares its own (below).
        #expect(page.collections["children"]?.first?.identities == [])

        let listItem = try #require(ELVAssembler.assembleItem(source: source, itemJSON: itemJSON, url: url))
        #expect(listItem.identities == expected)
        #expect(listItem.sourceURL == url)

        let row = try #require(ELVAssembler.assembleRow(source: source, row: ["title": "R"], context: context))
        #expect(row.identities == expected)
        #expect(row.sourceURL == url)
    }

    @Test
    func `regexRows collections turn markup matches into ranked rows`() throws {
        let source = ELVSource(
            id: "list.test",
            kind: "list",
            collections: [
                ELVCollectionSpec(name: "entries", from: .regexRows("entry:\"([a-z]+)\""), item: [
                    ELVFieldSpec(name: "title", candidates: [ELVCandidate(from: .json("$.g1"))]),
                    ELVFieldSpec(name: "rank", candidates: [ELVCandidate(from: .json("$.rank"))]),
                ], kind: "entry"),
            ]
        )
        var document = ELVDocument(html: "entry:\"alpha\" filler entry:\"beta\"")
        document.text = document.html
        let url = try #require(URL(string: "https://example.com/list"))
        let record = ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: url, document: document))
        let entries = try #require(record.collections["entries"])
        #expect(entries.count == 2)
        #expect(entries.map { $0.fields["title"] } == [.text("alpha"), .text("beta")])
        // Document order keys the synthesized rank, 1-based.
        #expect(entries.map { $0.fields["rank"] } == [.number(1), .number(2)])
        #expect(entries.allSatisfy { $0.kind == "entry" })
    }

    @Test
    func `A regexRows after anchor starts the capped window at a blob deep in a large page`() {
        /// The Apple Music 100 Best page outgrew the input cap: its data blob
        /// starts past it, so the unanchored scan saw no rows at all.
        func rows(after: String?) -> [ELVRecord] {
            let source = ELVSource(
                id: "list.anchor",
                kind: "list",
                collections: [
                    ELVCollectionSpec(name: "entries", from: .regexRows("entry:\"([a-z]+)\"", after: after), item: [
                        ELVFieldSpec(name: "title", candidates: [ELVCandidate(from: .json("$.g1"))]),
                    ]),
                ]
            )
            let padding = String(repeating: "x", count: ELVRegexCache.inputCap + 10)
            let document = ELVDocument(html: padding + "{blob:[entry:\"alpha\", entry:\"beta\"]}")
            return ELVAssembler.assemble(source: source, context: ELVExtractionContext(document: document)).collections["entries"] ?? []
        }
        #expect(rows(after: nil).isEmpty)
        #expect(rows(after: "{blob:").map { $0.fields["title"] } == [.text("alpha"), .text("beta")])
        // An anchor that never appears yields no rows rather than a full scan.
        #expect(rows(after: "{nowhere:").isEmpty)
    }

    @Test
    func `The after key decodes beside regexRows and an empty anchor is a diagnostic`() throws {
        let anchored = try JSONDecoder().decode(ELVSelector.self, from: Data(#"{"regexRows": "a(b)", "after": "{x:"}"#.utf8))
        #expect(anchored == .regexRows("a(b)", after: "{x:"))
        let plain = try JSONDecoder().decode(ELVSelector.self, from: Data(#"{"regexRows": "a(b)"}"#.utf8))
        #expect(plain == .regexRows("a(b)", after: nil))
        // textRegex takes the same key (schemaMinor 4); without it the
        // selector is the unanchored one every earlier pack wrote.
        let anchoredText = try JSONDecoder().decode(ELVSelector.self, from: Data(#"{"textRegex": "a(b)", "after": "{x:"}"#.utf8))
        #expect(anchoredText == .textRegex("a(b)", after: "{x:"))
        #expect(try JSONDecoder().decode(ELVSelector.self, from: Data(#"{"textRegex": "a(b)"}"#.utf8)) == .textRegex("a(b)", after: nil))
        let pack = #"""
        {"schemaVersion": 1, "packVersion": "t", "sources": [{"id": "s", "kind": "list", "match": {"host": ["a.example"]},
          "fetch": {"mode": "http"}, "collections": [{"name": "e", "from": {"regexRows": "a(b)", "after": ""}, "item": []}]}]}
        """#
        let notes = try ELVPackLoader.load(embedded: Data(pack.utf8)).diagnostics.map(\.message)
        #expect(notes.contains { $0.contains("regexRows `after` is empty") })
    }

    @Test
    func `Inline entries win over from and assemble as item documents`() throws {
        let source = ELVSource(
            id: "list.inline",
            kind: "list",
            collections: [
                ELVCollectionSpec(
                    name: "entries",
                    from: .json("$.never[*]"),
                    item: [ELVFieldSpec(name: "title", candidates: [ELVCandidate(from: .json("$.title"))])],
                    kind: "book",
                    entries: [.object(["title": .string("Ball Lightning")]), .object(["title": .string("Death's End")])]
                ),
            ]
        )
        let url = try #require(URL(string: "https://example.com/inline"))
        let record = ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: url, document: ELVDocument()))
        #expect(record.collections["entries"]?.map { $0.fields["title"] } == [.text("Ball Lightning"), .text("Death's End")])
    }

    @Test
    func `Per-collection identity specs evaluate against each item's own document`() throws {
        let source = ELVSource(
            id: "album.test",
            kind: "album",
            collections: [
                ELVCollectionSpec(
                    name: "tracks",
                    from: .json("$.tracks[*]"),
                    item: [
                        ELVFieldSpec(name: "title", candidates: [ELVCandidate(from: .json("$.name"))]),
                    ],
                    kind: "song",
                    identities: [ELVIdentitySpec(namespace: "isrc", from: .json("$.isrc"))]
                ),
            ],
            // A URL-derived parent identity: must NOT leak into the tracks.
            identities: [ELVIdentitySpec(namespace: "album.ns", from: .urlRegex("/album/([a-z0-9]+)"))]
        )
        let body = #"{"tracks": [{"name": "One", "isrc": "USX1"}, {"name": "Two"}]}"#
        let json = try #require(ELVRawJSON.parse(Data(body.utf8)))
        let url = try #require(URL(string: "https://music.example/album/abc123"))
        let record = ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: url, document: ELVDocument(json: json)))

        #expect(record.identities == [ELVIdentity(namespace: "album.ns", value: "abc123", origin: .declared)])
        let tracks = try #require(record.collections["tracks"])
        #expect(tracks.first?.identities == [ELVIdentity(namespace: "isrc", value: "USX1", origin: .declared)])
        // No isrc on the second item, and no parent leak either.
        #expect(tracks.last?.identities == [])
    }

    @Test
    func `The URL fallback key ignores tracking params, never the page's own query`() throws {
        let source = ELVSource(id: "generic.opengraph", kind: "link", fields: [ELVFieldSpec(name: "title", candidates: [ELVCandidate(from: .meta("og:title"))])])
        func fallbackId(_ string: String) throws -> String? {
            let url = try #require(URL(string: string))
            return ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: url, document: ELVDocument(metas: ["og:title": "Post"]))).externalId
        }
        let clean = try fallbackId("https://example.com/post?id=7")
        #expect(clean == "url:" + ELVStableHash.fnv1a("https://example.com/post?id=7"))
        for tracked in [
            "https://example.com/post?id=7&utm_source=x&utm_medium=social",
            "https://example.com/post?fbclid=IwAR0&id=7",
            "https://example.com/post?id=7&gclid=1&dclid=2&mc_cid=3&mc_eid=4&igshid=5&_hsenc=6&_hsmi=7&yclid=8&msclkid=9",
        ] {
            #expect(try fallbackId(tracked) == clean, "\(tracked)")
        }
        #expect(try fallbackId("https://example.com/post?id=8") != clean)
        #expect(try fallbackId("https://example.com/post?utm_source=x") == "url:" + ELVStableHash.fnv1a("https://example.com/post"))
        #expect(ELVCanonicalizeRule.trackingParams.contains("utm_*"))
    }
}
