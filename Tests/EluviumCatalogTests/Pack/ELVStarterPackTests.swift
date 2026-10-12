import EluviumCatalog
import Foundation
import Testing
@testable import EluviumCore

@Suite("Starter pack")
struct ELVStarterPackTests {
    private func loaded() throws -> ELVLoadedPack {
        try ELVStarterPack.load(capabilities: ELVCapabilities(fetchModes: ["http", "json", "archive", "feed"], binaryVersion: "0.1"))
    }

    @Test
    func `The bundled pack is valid JSON and every source carries at least two examples`() throws {
        // Two is the validator-enforced floor (curated down from five
        // in the 2026-08-29 corpus prune: dead and placeholder links out, real
        // minted shares in). Share-link corpora (shortlinks, Flighty) carry
        // tokens real shares minted; entries a fixture capture must replace
        // assert kind only, never fields.
        let pack = try loaded()
        #expect(!pack.pack.sources.isEmpty)
        // Seeded list sources are browse-first: their runnable entry is the
        // seed itself, so the paste-corpus floor doesn't apply (most have no
        // recognizable input URL at all). komoot.route is exempt by owner
        // ruling (2026-08-29): its only real inputs are share-token URLs,
        // and the tokens on hand unlocked third parties' private tours, so
        // the corpus ships empty until owner-minted shares exist. The
        // Xiaohongshu redirector (shortlinks.media) is exempt the same way
        // (2026-10-11): an xhslink short link resolves to its minter's
        // account on the platform's side. xiaohongshu.post ships none either
        // (2026-10-12): a note loads only with a share-minted xsec_token.
        // flighty.flight keeps one share; its others name their traveler
        // (2026-10-12). File sources take files, not links: their corpus is
        // the fixture files their EluviumCatalogTests suites import.
        let exempt: Set = ["komoot.route", "shortlinks.media", "xiaohongshu.post", "flighty.flight"]
        for source in pack.pack.sources where source.seed == nil && !exempt.contains(source.id) && source.match?.file == nil {
            #expect(source.examples.count >= 2, "\(source.id) has \(source.examples.count) examples, needs 2")
        }
        // Host UI sections and rows lead with the title; a raw id in a
        // header is a pack-authoring miss, so the starter corpus pins it.
        for source in pack.pack.sources {
            #expect(source.title?.isEmpty == false, "\(source.id) has no display title")
        }
    }

    @Test
    func `Every fetched example pins evidence a dead fetch cannot fake`() throws {
        // A login wall or 404 shell is a real page: a kind-only pin, or a pin
        // on a field a `const` candidate fills, passes it vacuously. Every
        // example of a source that fetches (any step mode but `none`) pins
        // a field with no const candidate, or a collection that is not the
        // pack's own inline entries; every pinned field is one the source
        // declares (a renamed field must not leave a dead pin behind). A
        // redirector's examples pin the record its expansion lands on, so
        // only those skip the declared-field check.
        let capabilities = ELVCapabilities(fetchModes: ["http", "json", "archive", "feed", "dom"], binaryVersion: "0.1")
        for pack in try [ELVStarterPack.load(capabilities: capabilities), ELVOptInPacks.commerce(capabilities: capabilities)] {
            let report = Self.examplePinReport(pack)
            #expect(report.vacuous.isEmpty, "\(pack.pack.packVersion): \(report.vacuous)")
            #expect(report.undeclared.isEmpty, "\(pack.pack.packVersion): \(report.undeclared)")
        }
    }

    /// Examples whose pins a dead fetch could satisfy, and pins naming no
    /// declared field, as `source example` lines.
    static func examplePinReport(_ pack: ELVLoadedPack) -> (vacuous: [String], undeclared: [String]) {
        var vacuous: [String] = []
        var undeclared: [String] = []
        for source in pack.pack.sources {
            let steps = source.fetch?.resolvedSteps ?? []
            let specs = source.fields + steps.flatMap { $0.fields ?? [] }
            let inlineCollections = Set((source.collections + steps.flatMap { $0.collections ?? [] }).filter { $0.entries != nil }.map(\.name))
            let fetches = !(source.fetch?.requiredModes.isEmpty ?? true)
            for example in source.examples {
                var evidence = false
                for name in example.expectedNonEmpty {
                    let candidates = specs.filter { $0.name == name }.flatMap(\.candidates)
                    if candidates.isEmpty, source.resolvesVia == nil { undeclared.append("\(source.id) \(name)") }
                    let constFillable = candidates.contains { if case .const = $0.from { true } else { false } }
                    if !candidates.isEmpty, !constFillable { evidence = true }
                }
                if example.expectedNonEmptyCollections.contains(where: { !inlineCollections.contains($0) }) { evidence = true }
                if fetches, !evidence { vacuous.append("\(source.id) \(example.input)") }
            }
        }
        return (vacuous, undeclared)
    }

    @Test
    func `Every declared identity namespace is strong except the three that can merge different things`() throws {
        // A strong namespace auto-links, so it must be a platform's own
        // stable unique id. booking.hotel drops the country segment from
        // its slug, vrbo.property strips the suffix naming the legacy id
        // system, and yelp.business is an alias Yelp reassigns; those three
        // stay weak. The pack lists only what the binary's built-ins lack.
        let pack = try loaded()
        var declared = Set<String>()
        for source in pack.pack.sources {
            let collections = source.collections + (source.fetch?.resolvedSteps.flatMap { $0.collections ?? [] } ?? [])
            declared.formUnion(source.identities.map(\.namespace))
            declared.formUnion(collections.flatMap(\.identities).map(\.namespace))
        }
        let strong = Set(pack.strongNamespaces)
        #expect(strong.isSubset(of: declared), "strong but never declared: \(strong.subtracting(declared))")
        #expect(strong.isDisjoint(with: ELVIdentityNamespaces.builtinStrong))
        let weak = declared.filter { !ELVIdentityNamespaces.isStrong($0, extra: strong) }
        #expect(weak == ["booking.hotel", "vrbo.property", "yelp.business"])
        // The renamed and newly built-in namespaces.
        #expect(declared.isSuperset(of: ["itunes.podcast", "douban.film", "wikidata", "pokeapi.pokemon"]))
        #expect(!declared.contains("applepodcasts.show"))
    }

    @Test
    func `The bundled pack is diagnostic-free`() throws {
        // The validator's canary: any hit here means a starter source
        // declares something this binary cannot run.
        let diagnostics = try loaded().diagnostics
        #expect(diagnostics.isEmpty, "\(diagnostics)")
    }

    @Test
    func `Sources whose capabilities this binary lacks are skipped; the rest stay active`() throws {
        // A Core-only load has neither the DOM engine, EluviumNet's
        // shortlink op, nor EluviumPlaces' MapKit ops, so the dom-escalating,
        // redirector, and MapKit-enriched sources skip. gmaps.share is
        // dom-only by design (its whole job is the canonical-URL
        // capture); gmaps.place.mapkit is the priority-110 shadow that only
        // a Places-registered binary runs — plain gmaps.place serves here;
        // Komoot, Goodreads (past AWS WAF's challenge), Fragrantica, and
        // Xiaohongshu escalate to dom like AllTrails. (camera.lens is plain
        // http, so it stays active here;
        // Amazon/Chewy are no longer here at all: they live in the opt-in
        // commerce pack, tested separately.)
        let pack = try loaded()
        #expect(pack.skipped.map(\.id) == [
            "shortlinks.travel", "gmaps.place.mapkit", "gmaps.share", "alltrails.trail", "komoot.route",
            "goodreads.book", "fragrantica.perfume", "xiaohongshu.post", "shortlinks.media",
        ])
        #expect(pack.sources.map(\.id).contains("pokeapi.pokemon"))
        #expect(pack.sources.map(\.id).contains("imdb.title"))
        // The flight op is a builtin, so Flighty needs only Core capabilities.
        #expect(pack.sources.map(\.id).contains("flighty.flight"))
        // The syndication-token op is a builtin too, so x.post runs without
        // EluviumNet: its fetch is plain json/http through templates.
        #expect(pack.sources.map(\.id).contains("x.post"))
    }

    @Test
    func `Generic floors are catch-alls, feed-shaped first then the OG floor`() throws {
        let pack = try loaded()
        #expect(pack.genericFloors.map(\.id) == ["generic.feed", "generic.opengraph"])
    }

    @Test
    func `Exact host sources recognize their URLs; the floor is not consulted for them`() throws {
        let pack = try loaded()
        let poke = try #require(URL(string: "https://pokeapi.co/api/v2/pokemon/25"))
        #expect(pack.registry.recognize(poke)?.sourceId == "pokeapi.pokemon")
        #expect(pack.registry.recognize(poke)?.params["id"] == "25")

        let imdb = try #require(URL(string: "https://www.imdb.com/title/tt0076759/reference"))
        #expect(pack.registry.recognize(imdb)?.sourceId == "imdb.title")
        #expect(pack.registry.recognize(imdb)?.params["id"] == "tt0076759")

        let arbitrary = try #require(URL(string: "https://example.com/whatever"))
        #expect(pack.registry.recognize(arbitrary) == nil)
    }

    @Test
    func `Flight sources recognize their URL shapes, the marketing site excluded`() throws {
        let pack = try ELVStarterPack.load(capabilities: ELVCapabilities(fetchModes: ["http", "json", "archive", "feed", "dom"], binaryVersion: "0.1"))

        let flighty = try #require(URL(string: "https://live.flighty.app/00000000f-0000-4000-8000-000000000000"))
        #expect(pack.registry.recognize(flighty)?.sourceId == "flighty.flight")
        // The marketing site is not a share page.
        let marketing = try #require(URL(string: "https://www.flighty.app/press"))
        #expect(pack.registry.recognize(marketing) == nil)
    }

    @Test
    func `The Flighty source surfaces format drift as a typed field, never a silent nil`() throws {
        let pack = try loaded()
        let source = try #require(pack.source(withId: "flighty.flight"))
        // A share page whose island lost its required keys (the
        // drift exposure): the sentinel names what vanished.
        let html = """
        <html><head><meta property="og:title" content="Track AS 6208 to Palm Springs" /></head>
        <body><script>{"flight":{"airline":{"iata":"AS"},"flight_number":"6208"}}</script></body></html>
        """
        let url = try #require(URL(string: "https://live.flighty.app/00000000f-0000-4000-8000-000000000000"))
        let params = ["shareId": "00000000f-0000-4000-8000-000000000000"]
        let record = ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: url, params: params, document: ELVDocument(html: html)))

        #expect(record.fields["title"] == .text("Track AS 6208 to Palm Springs"))
        guard case let .text(drift)? = record.fields["formatDrift"] else {
            Issue.record("Expected the drift sentinel to produce")
            return
        }
        #expect(drift.contains("departure.airport.iata"))
        // No parsed flight, so the share id is the external id.
        #expect(record.externalId == "00000000f-0000-4000-8000-000000000000")
    }

    @Test
    func `The PokeAPI source extracts a full record from a captured body, hyphenated JSON keys included`() throws {
        let pack = try loaded()
        let source = try #require(pack.source(withId: "pokeapi.pokemon"))
        let body = """
        {
          "id": 25, "name": "pikachu", "height": 4, "weight": 60,
          "sprites": {
            "front_default": "https://img.example/25.png",
            "other": { "official-artwork": { "front_default": "https://img.example/art/25.png" } }
          },
          "types": [{"slot": 1, "type": {"name": "electric"}}],
          "abilities": [{"ability": {"name": "static"}}, {"ability": {"name": "lightning-rod"}}]
        }
        """
        let json = try #require(ELVRawJSON.parse(Data(body.utf8)))
        let context = ELVExtractionContext(url: URL(string: "https://pokeapi.co/api/v2/pokemon/25"), document: ELVDocument(json: json))
        let record = ELVAssembler.assemble(source: source, context: context)

        let expectedArt = try #require(URL(string: "https://img.example/art/25.png"))
        #expect(record.externalId == "25")
        #expect(record.fields["title"] == .text("Pikachu"))
        #expect(record.fields["height"] == .number(4))
        #expect(record.fields["image"] == .media(ELVMediaRef(url: expectedArt, kind: ELVMediaRef.image)))
        #expect(record.identities == [ELVIdentity(namespace: "pokeapi.pokemon", value: "25", origin: .declared)])
        #expect(record.collections["types"]?.first?.fields["title"] == .text("Electric"))
        #expect(record.collections["abilities"]?.count == 2)
        #expect(record.collections["abilities"]?.last?.fields["title"] == .text("Lightning Rod"))
    }

    @Test
    func `The AllTrails source derives trail stats through the native op's document fallback`() throws {
        let pack = try ELVStarterPack.load(capabilities: ELVCapabilities(fetchModes: ["http", "json", "archive", "feed", "dom"], binaryVersion: "0.1"))
        let source = try #require(pack.source(withId: "alltrails.trail"))
        #expect(source.requires.contains("native:trail.statsFromText@2"))
        let document = ELVDocument(metas: [
            "og:title": "Hidden Falls Trail - Wyoming | AllTrails",
            "og:description": "Try this 1.1-mile out-and-back trail. Generally considered an easy route, it takes an average of 32 min to complete.",
        ])
        let url = try #require(URL(string: "https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail"))
        let params = ["country": "us", "region": "wyoming", "slug": "hidden-falls-trail"]
        let record = ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: url, params: params, document: document))
        #expect(record.fields["distance"] == .text("1.1 mi"))
        #expect(record.fields["difficulty"] == .text("Easy"))
        #expect(record.fields["duration"] == .text("32 min"))
    }

    @Test
    func `The gmaps share source claims the root ?q= form and leaves gmaps.place its URLs`() throws {
        let pack = try ELVStarterPack.load(capabilities: ELVCapabilities(fetchModes: ["http", "json", "archive", "feed", "dom"], binaryVersion: "0.1"))
        // The iOS share expansion (maps.google.com root + `?q=`) is the form
        // gmaps.place's `/maps/**` path can never match — the rescue target.
        let share = try #require(URL(string: "https://maps.google.com/?q=Grand+Prismatic"))
        #expect(pack.registry.recognize(share)?.sourceId == "gmaps.share")
        // The `/maps?q=` form stays with gmaps.place (priority 100 over 95):
        // `/maps/**` matches the bare `/maps` path, and its example corpus
        // pins the URL-only extraction of exactly this shape.
        let legacy = try #require(URL(string: "https://maps.google.com/maps?q=Grand+Prismatic+Spring+Overlook,+Yellowstone+NP&ftid=0x5351eb:0"))
        #expect(pack.registry.recognize(legacy)?.sourceId == "gmaps.place")
        // The captured canonical desktop form recognizes to gmaps.place, so
        // capture re-entry terminates there (never back on gmaps.share).
        let canonical = try #require(URL(string: "https://www.google.com/maps/place/Grand+Prismatic+Spring/@44.52,-110.83,17z/data=!8m2!3d44.5251!4d-110.8382"))
        #expect(pack.registry.recognize(canonical)?.sourceId == "gmaps.place")

        // The dom step declares the capture: the share URL lacks the target
        // data (the gate), the canonical form matches it.
        let source = try #require(pack.source(withId: "gmaps.share"))
        let step = try #require(source.fetch?.resolvedSteps.first)
        #expect(step.mode == "dom")
        let capture = try #require(step.captureCanonical)
        #expect(capture.maxPolls == 20)
        #expect(!ELVRegexCache.matches(capture.untilURLRegex, in: share.absoluteString))
        #expect(ELVRegexCache.matches(capture.untilURLRegex, in: canonical.absoluteString))
    }

    @Test
    func `The gmaps share source extracts its ?q= fallback from the URL alone (the capture-timeout shape)`() throws {
        let pack = try ELVStarterPack.load(capabilities: ELVCapabilities(fetchModes: ["http", "json", "archive", "feed", "dom"], binaryVersion: "0.1"))
        let source = try #require(pack.source(withId: "gmaps.share"))
        // When the render never rewrites, the step falls through to the URL
        // extraction: name + locality from `q`, ftid as the external id, and
        // NO pin — skip beats wrong.
        let url = try #require(URL(string: "https://maps.google.com/?q=Grand+Prismatic+Spring+Overlook,+Yellowstone+National+Park,+WY&ftid=0x5351eb:0"))
        let record = ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: url, document: ELVDocument(html: "")))
        #expect(record.kind == "place")
        #expect(record.fields["title"] == .text("Grand Prismatic Spring Overlook"))
        #expect(record.fields["locality"] == .text("Yellowstone National Park, WY"))
        #expect(record.fields["geo"] == nil)
        #expect(record.externalId == "0x5351eb:0")

        // A dropped-pin share IS its coordinate: the coordinate-shaped `q`
        // pins offline without any capture.
        let pinned = try #require(URL(string: "https://maps.google.com/?q=48.858,2.294"))
        let pinnedRecord = ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: pinned, document: ELVDocument(html: "")))
        #expect(pinnedRecord.fields["geo"] == .geo(latitude: 48.858, longitude: 2.294))
    }

    @Test
    func `The OpenGraph floor extracts a record from a plain page's metas`() throws {
        let pack = try loaded()
        let source = try #require(pack.source(withId: "generic.opengraph"))
        let html = """
        <html><head>
          <meta property="og:title" content="A Blog Post" />
          <meta property="og:description" content="Something interesting" />
          <meta property="og:image" content="/cover.png" />
          <meta property="og:site_name" content="Example Blog" />
        </head></html>
        """
        let context = ELVExtractionContext(url: URL(string: "https://example.com/post"), document: ELVDocument(html: html))
        let record = ELVAssembler.assemble(source: source, context: context)
        let expectedCover = try #require(URL(string: "https://example.com/cover.png"))
        #expect(record.kind == "link")
        #expect(record.fields["title"] == .text("A Blog Post"))
        #expect(record.fields["siteName"] == .text("Example Blog"))
        #expect(record.fields["image"] == .media(ELVMediaRef(url: expectedCover, kind: ELVMediaRef.image)))
        // The floor declares no externalId spec, so the URL-derived fallback
        // is the record's dedup handle.
        #expect(record.externalId == "url:" + ELVStableHash.fnv1a("https://example.com/post"))
    }

    @Test
    func `The x post source recognizes every status URL form as one source, lookalikes excluded`() throws {
        let pack = try loaded()
        // Family assertion: x.com, twitter.com, and /i/status/ all land
        // on x.post with the id captured.
        for url in [
            "https://x.com/jack/status/20",
            "https://twitter.com/naval/status/1002103360646823936",
            "https://x.com/i/status/1585341984679469056",
        ] {
            let target = try #require(URL(string: url))
            let recognition = try #require(pack.registry.recognize(target), "\(url)")
            #expect(recognition.sourceId == "x.post", "\(url)")
            #expect(recognition.params["id"]?.isEmpty == false, "\(url)")
        }
        // Anchored hosts: suffix and infix lookalikes never match.
        for url in [
            "https://x.com.evil.io/jack/status/20",
            "https://evil-x.com/jack/status/20",
            "https://twitter.com.attacker.net/naval/status/1002103360646823936",
            "https://x.com@evil.com/jack/status/20",
        ] {
            let target = try #require(URL(string: url))
            #expect(pack.registry.recognize(target) == nil, "\(url)")
        }
        // A non-status path is not a post.
        let profile = try #require(URL(string: "https://x.com/jack"))
        #expect(pack.registry.recognize(profile) == nil)
    }

    @Test
    func `The x post source declares the computed-token template, oEmbed and OG fallbacks, and share-param stripping`() throws {
        let pack = try loaded()
        let source = try #require(pack.source(withId: "x.post"))
        let steps = try #require(source.fetch?.resolvedSteps)
        #expect(steps.map(\.mode) == ["json", "json", "http"])
        // The syndication step's URL is a computed-param template:
        // the token op rides the template, never a computed host.
        #expect(steps[0].url?.contains("cdn.syndication.twimg.com") == true)
        #expect(steps[0].url?.contains("{native:x.syndicationToken@1(param.id)}") == true)
        #expect(steps[1].url?.contains("publish.x.com/oembed") == true)
        // The `{}` churn case: an empty syndication answer must fire the
        // oEmbed step (typed fallback, not silence).
        let trigger = try #require(steps[1].when)
        #expect(trigger.fires(status: 200, extractedFields: [:]))
        // Both fallback rungs name one trigger in the prologue table instead
        // of spelling it out twice.
        #expect(steps[2].when == trigger)
        #expect(ELVStarterPack.json.components(separatedBy: "\"when\": \"noTweetText\"").count == 3)
        // Share tracking params are stripped; the status id params survive
        // as path segments untouched.
        let canonicalize = try #require(source.canonicalize)
        let shared = try #require(URL(string: "https://x.com/jack/status/20?s=46&t=AbCdEf"))
        #expect(canonicalize.apply(to: shared).query == nil)
    }

    @Test
    func `The x post source extracts the syndication JSON offline, like count clamped through int coercion`() throws {
        let pack = try loaded()
        let source = try #require(pack.source(withId: "x.post"))
        // The x.post syndication shape, trimmed from the live 2026-08-11
        // capture: text + user + counts + photos.
        let body = """
        {
          "__typename": "Tweet", "id_str": "20",
          "text": "just setting up my twttr",
          "created_at": "2006-03-21T20:50:14.000Z",
          "user": { "id_str": "12", "name": "jack", "screen_name": "jack" },
          "favorite_count": 176089,
          "photos": [{ "url": "https://pbs.twimg.com/media/abc.jpg", "width": 1200, "height": 800 }]
        }
        """
        let json = try #require(ELVRawJSON.parse(Data(body.utf8)))
        let url = try #require(URL(string: "https://x.com/jack/status/20"))
        let context = ELVExtractionContext(url: url, params: ["user": "jack", "id": "20"], document: ELVDocument(json: json))
        let record = ELVAssembler.assemble(source: source, context: context)

        let expectedPhoto = try #require(URL(string: "https://pbs.twimg.com/media/abc.jpg"))
        #expect(record.kind == "post")
        #expect(record.externalId == "20")
        #expect(record.fields["text"] == .text("just setting up my twttr"))
        #expect(record.fields["title"] == .text("just setting up my twttr"))
        // generic.feed's field names: `author`, `handle` (threads.post's
        // key), `image` (what a host thumbnail reads), `published`.
        #expect(record.fields["author"] == .text("jack"))
        #expect(record.fields["handle"] == .text("jack"))
        #expect(record.fields["likeCount"] == .number(176_089))
        #expect(record.fields["image"] == .media(ELVMediaRef(url: expectedPhoto, kind: ELVMediaRef.image)))
        for drifted in ["authorName", "authorHandle", "photo", "date"] {
            #expect(record.fields[drifted] == nil, "\(drifted)")
        }
        #expect(record.identities == [ELVIdentity(namespace: "x.tweet", value: "20", origin: .declared)])
        // The date coercion parsed the ISO form.
        guard case .date? = record.fields["published"] else {
            Issue.record("Expected the created_at date to coerce")
            return
        }
    }

    @Test
    func `The oEmbed fallback shape extracts through the same x post fields, html stripped to text`() throws {
        let pack = try loaded()
        let source = try #require(pack.source(withId: "x.post"))
        let body = """
        {
          "author_name": "jack",
          "author_url": "https://twitter.com/jack",
          "html": "<blockquote class=\\"twitter-tweet\\"><p lang=\\"en\\">just setting up my twttr</p>&mdash; jack (@jack)</blockquote>"
        }
        """
        let json = try #require(ELVRawJSON.parse(Data(body.utf8)))
        let url = try #require(URL(string: "https://x.com/jack/status/20"))
        let record = ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: url, params: ["user": "jack", "id": "20"], document: ELVDocument(json: json)))
        guard case let .text(text)? = record.fields["text"] else {
            Issue.record("Expected the oEmbed html to strip into text")
            return
        }
        #expect(text.contains("just setting up my twttr"))
        #expect(!text.contains("<"))
        #expect(record.fields["author"] == .text("jack"))
        #expect(record.fields["handle"] == .text("jack"))
    }

    @Test
    func `The Fragrantica source extracts the note pyramid through the prose op, offline`() throws {
        let pack = try ELVStarterPack.load(capabilities: ELVCapabilities(fetchModes: ["http", "json", "archive", "feed", "dom"], binaryVersion: "0.1"))
        let source = try #require(pack.source(withId: "fragrantica.perfume"))
        #expect(source.requires == ["native:notePyramid.fromProse@1"])
        #expect(source.fetch?.resolvedSteps.map(\.mode) == ["http", "dom"])

        let html = """
        <html><head>
          <meta property="og:title" content="Aventus Creed cologne" />
          <meta property="og:description" content="Top notes are Pineapple, Bergamot and Black Currant; middle notes are Birch and Jasmine; base notes are Musk and Oakmoss." />
          <meta property="og:image" content="https://fimgs.net/mdimg/perfume/375x500.9828.jpg" />
          <script type="application/ld+json">
          {"@type": "Product", "name": "Aventus", "brand": {"@type": "Brand", "name": "Creed"},
           "aggregateRating": {"ratingValue": 4.35, "reviewCount": 21053}}
          </script>
        </head></html>
        """
        let url = try #require(URL(string: "https://www.fragrantica.com/perfume/Creed/Aventus-9828.html"))
        let params = ["brand": "Creed", "slug": "Aventus-9828.html"]
        let record = ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: url, params: params, document: ELVDocument(html: html)))

        #expect(record.kind == "perfume")
        #expect(record.externalId == "9828")
        #expect(record.fields["title"] == .text("Aventus"))
        #expect(record.fields["brand"] == .text("Creed"))
        #expect(record.fields["topNotes"] == .tags(["Pineapple", "Bergamot", "Black Currant"]))
        #expect(record.fields["heartNotes"] == .tags(["Birch", "Jasmine"]))
        #expect(record.fields["baseNotes"] == .tags(["Musk", "Oakmoss"]))
        #expect(record.fields["rating"] == .rating(value: 4.35, scale: 0 ... 5))
        #expect(record.fields["summary"] == .text("Top notes are Pineapple, Bergamot and Black Currant; middle notes are Birch and Jasmine; base notes are Musk and Oakmoss."))
        #expect(record.identities == [ELVIdentity(namespace: "fragrantica.perfume", value: "9828", origin: .declared)])
        // No tiered pyramid → nothing invented: the flat form only fills
        // `notes` when the tiers are genuinely absent.
        #expect(record.fields["notes"] == nil)

        // The URL alone still yields a titled record (the http step's
        // pre-escalation floor).
        let bare = ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: url, params: params, document: ELVDocument()))
        #expect(bare.fields["title"] == .text("Aventus"))
        #expect(bare.fields["brand"] == .text("Creed"))
    }

    @Test
    func `The gmaps place page metas classify into name, type, rating, and address through the wired ops`() throws {
        let pack = try loaded()
        let source = try #require(pack.source(withId: "gmaps.place"))
        // The composite: URL-only first, http(crawler) only when the URL
        // yielded no name — the pin corpus stays fetch-free.
        let steps = try #require(source.fetch?.resolvedSteps)
        #expect(steps.map(\.mode) == ["none", "http"])
        let trigger = try #require(steps.last?.when)
        #expect(trigger.fires(status: 200, extractedFields: [:]))
        #expect(!trigger.fires(status: 200, extractedFields: ["title": .text("Jenny Lake")]))

        // A label-less URL whose page metas carry the " · " segments: the
        // classifier routes them by shape into the wired fields.
        let document = ELVDocument(metas: [
            "og:title": "Benu · 4.6★(3,067) · Fine dining restaurant",
            "og:description": "★★★★☆ · Restaurant · 22 Hawthorne St, San Francisco",
        ])
        let url = try #require(URL(string: "https://maps.google.com/maps?ftid=0x808f7fc5d3d0f0f9:0x3a0e2"))
        let record = ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: url, document: document))
        #expect(record.fields["title"] == .text("Benu"))
        // A typed 0-5 rating, the key every other source's aggregate uses.
        #expect(record.fields["rating"] == .rating(value: 4.6, scale: 0 ... 5))
        #expect(record.fields["onlineRating"] == nil)
        #expect(record.fields["placeType"] == .text("Fine dining restaurant"))
        #expect(record.fields["category"] == .text("food"))
        #expect(record.fields["address"] == .text("22 Hawthorne St, San Francisco"))
        #expect(record.externalId == "0x808f7fc5d3d0f0f9:0x3a0e2")

        // A big-endian share label in the metas folds through
        // place.littleEndianLabel before the name is taken.
        let bigEndian = ELVDocument(metas: [
            "og:title": "United States, California, Los Angeles, S Western Ave, COIN DE RUE bakery and cafe",
        ])
        let folded = ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: url, document: bigEndian))
        #expect(folded.fields["title"] == .text("COIN DE RUE bakery and cafe"))
    }
}
