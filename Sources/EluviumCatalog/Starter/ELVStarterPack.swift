import EluviumCore
import Foundation

/// The bundled starter pack: ships in the binary so a fresh offline
/// install works; a downloaded pack layers over it through the remote
/// channel (`ELVRemotePackService` downloads, verifies, and merges it via
/// `ELVLoadedPack.merging`, the overlay winning per source id). Deliberately
/// small and public-web only — no auth anywhere — but the roster spans the
/// real fetch modes: `http`/`json` API sources, `composite` plans that
/// escalate to `dom` (AllTrails, Komoot, Goodreads, Fragrantica,
/// Xiaohongshu), the `feed`
/// and OpenGraph generic floors, a `none`-mode URL-only parser (Google
/// Maps), a `captureCanonical` dom rescue for the coordinate-less Maps
/// `?q=` share (gmaps.share, whose captured canonical re-enters recognition
/// at gmaps.place), and a shortlink redirector. A binary missing a
/// capability skips those sources through the gate and runs the rest.
///
/// The 2026-08-23 corpus pass replaces every dead example token with a
/// live-verified one (curl, iPhone Safari UA) and records the hosts whose
/// tokens cannot be pinned: `goo.gl/maps` tokens are gone with the goo.gl
/// sunset; `g.co/kgs` shares expand to a google.com/**search** page (a
/// knowledge-panel result, not a Maps URL), so even a live token lands on
/// the OG floor — the host stays recognized as a redirector but carries no
/// example; `yelp.to` / `gyg.me` / `abnb.me` are per-share Branch links
/// that expire in weeks, and Expedia's `expe.onelink.me` app shares carry
/// the sharer's attribution ids, so the corpus carries none of them either.
/// Share-token examples are gone entirely (owner rulings 2026-08-29 through
/// 2026-10-12): a token identifies its sharer or unlocks someone's private
/// content, so `komoot.route`, `shortlinks.media`, and `xiaohongshu.post`
/// ship no corpus. Bare Xiaohongshu explore/discovery URLs 404 without a
/// share token (the app serves "你访问的页面不见了", a page whose og:title is
/// real text, so no schema gate can reject it); only tokened shares yield
/// content, and those stay with whoever pastes them.
///
/// Second lesson from the same pass: a dead token on a fetch-based source
/// can "pass" a kind-only expectation vacuously — Komoot's login page and
/// XHS's 404 page are real pages, so the pipeline hands back a thin record
/// and the corpus run reads green. Every fetch-based example therefore
/// pins `nonEmpty: ["title"]` when the provider serves one, so token rot
/// surfaces as an unmet expectation instead of a silent junk record.
/// `flighty.flight` keeps one real share (AS866, live-verified 2026-10-12).
/// Its two other real shares (AS6208, FR9756) were dropped the same day by
/// owner ruling: a share page names its traveler, and the corpus carries no
/// traveler names (flight, dates, and cities are fine), so the source is
/// exempt from the two-example floor. The example pins `designator`, which only
/// the page parse fills: `externalId` falls back to the share id, so it
/// stays non-empty on a dead share and could never be the canary.
///
/// The 2026-08-23 feed/audio/lists pass: `generic.feed` maps each item's
/// summary AND full content plus the show author, artwork, and the RFC
/// 5005 / JSON Feed `nextPage` pointer (continuation is host-driven; the
/// engine never follows it). Playable audio rides typed `as: audio` media
/// refs: podcast feeds via enclosures, Apple Podcasts resolves its RSS
/// feedUrl through the iTunes lookup API (the `text.digits` computed param
/// strips the path id's `id` prefix), Apple Music albums pull per-track
/// previews from `lookup?entity=song`, and Xiaoyuzhou and Spotify read
/// their `__NEXT_DATA__` islands via `jsonIsland` steps — Spotify previews
/// exist only on the /embed pages, so pathRegex-gated steps template them
/// per shape. The `lists.*` sources are the config-as-list mechanism:
/// Wikidata SPARQL seeds for award/author/painter lists (Oscars carry IMDb
/// ids, TGA carries IGDB slugs, Liu Cixin's books carry Wikipedia
/// sitelinks, Van Gogh's paintings carry Commons images), `regexRows` over
/// server-rendered markup (Apple Music 100 Best's data blob, rank 100→1
/// with rank 1 = The Miseducation of Lauryn Hill; Michelin LA's card grid
/// with distinctions), and inline `entries` where no API exists (IGN's
/// 10/10 canon, 16 entries each score-verified against the live page).
/// Every entry's member URL chains into an existing source (imdb.title,
/// igdb.game, ign.game, applemusic.album) or lands on the OG floor.
///
/// Declaration order IS behavior: recognition breaks priority ties by
/// declaration order (`maps.apple` stays with the shortlink redirector),
/// and `ELVLoadedPack.skipped` is test-asserted in this order. The source
/// chunks live in per-family sibling files (`ELVStarterPack+*.swift`) and
/// are composed below in the original interleaved order — passes appended
/// where history put them, so reordering is a behavior change, never a
/// cleanup. Chunks carry no trailing comma; the join supplies it.
///
/// The 2026-08-23 step-scope migration (schemaMinor 1): the three
/// enrichment composites (spotify.media, applemusic.album,
/// applepodcasts.show) moved their lookup/embed fields and track
/// collections onto scoped steps, so an enrichment document can no longer
/// clobber page fields it never declared; generic.feed opts into a 10 MB
/// budget (giant podcast feeds) and types audio off the envelope's
/// MIME-gated `enclosureAudioURL`; the lodging sources share one
/// `lodgingDates` fragment (five then, all seven since 2026-09-10); the
/// award lists gain entry identities (imdb,
/// igdb.game) and Van Gogh entries a member URL; pokeapi's types/abilities
/// children got externalIds so merges key per child.
///
/// The two composite shapes, as of the 2026-10-10 audit. Fallback
/// composites keep the flat source ladder: their steps fetch the SAME
/// logical document through escalating transports, where cross-context
/// candidate fallback is the correct shape. They are the `httpEscalate`
/// users (imdb.title, youtube.video, ign.game, threads.post), douban.subject,
/// x.post, xiaoyuzhou.podcast, goodreads.book, fragrantica.perfume,
/// xiaohongshu.post, gmaps.place and gmaps.place.mapkit, alltrails.trail,
/// and komoot.route (the opt-in pack's chewy.product and amazon.product
/// too). Enrichment composites scope the fields and collections of the
/// step that fetches a DIFFERENT document to that step: spotify.media,
/// applemusic.album, applepodcasts.show, inat.user, and youtube.channel
/// (its channel-page step, see below).
/// The 2026-08-29 reader additions (schemaMinor 2): generic.feed maps the
/// Podcasting 2.0 envelope fields (funding, itunes:type at the show level;
/// preferred transcript + chapters per item) and rewrites lazy-loaded
/// images in item content; generic.opengraph gains a readability `content`
/// field via `article.bodyFromPage@1`; douban.subject declares
/// `imageReferer: "page"` (hotlink protection 418s bare image fetches).
/// Pack vocabulary this minor adds the `rewriteLazyImages` pipe, the
/// file-rule `contains` probe, and source `imageReferer`; `htmlStrip` is
/// existing pipe vocabulary the reader pass leans on, not a new key.
///
/// The 2026-09-10 audit pass (packVersion `.2`, no schema change): the
/// shared fragments do more of the lifting. `ogCore` now also backs
/// generic.opengraph, camera.lens.sigma, and xiaohongshu.post — each keeps
/// inline only the candidates that must outrank the fragment's, because
/// `use` appends fragment candidates AFTER a source's own (first present
/// wins), so every ladder's order was checked before it moved; camera.lens
/// deliberately stays off it (its chunk header says why). Two fragments are
/// new: `gmapsMetas` (the Google Maps meta-classifier block the three gmaps
/// sources had copied verbatim) and `trailStats` (the
/// `trail.statsFromText@2` trio AllTrails and Komoot share). `lodgingDates`
/// gains Hotels.com's `chkin`/`chkout` and now rides every lodging source;
/// the lodging, tour, and review sources with a stable external id declare
/// a matching identity namespace. Kind cleanup: komoot.route authors
/// `trail` (not `hike`), Xiaoyuzhou episodes are `episode` (not
/// `podcastEpisode`), Michelin entries are `food` (not `place`), and
/// Airbnb's lodgingType is `rental` (a type, like Vrbo's; the brand already
/// rides the source id). Smaller fixes: imdb.title resolves its og:image,
/// fragrantica.perfume maps a summary, and the feed-backed trio (reddit,
/// youtube.channel, mastodon) maps the envelope's `nextPage` pointer the
/// way generic.feed does.
///
/// The 2026-10-10 pass (schemaMinor 3): a live run of the whole corpus
/// re-verified every source and fixed the five that had drifted.
/// goodreads.book gains a `dom` rung: AWS WAF answers a burst with an empty
/// `202` challenge, which the fetcher now reads as `blocked`, and a WebKit
/// render clears it. lists.applemusic.100best anchors its rows regex
/// (`after`) at the data blob, which the page's growth had pushed past the
/// regex input cap, and reads any storefront's album URLs, not only /us/.
/// themeparks.entity's `geo` fills again (the `geo` coercion reads a
/// `{latitude, longitude}` object). xiaohongshu.post and
/// fragrantica.perfume moved to the data their pages still serve (chunk
/// header in +Media says how). New sources: the nature chunk
/// (iNaturalist, Merlin, All About Birds, the iNaturalist and eBird export
/// files) and the 微信读书 trio. Vocabulary this minor adds: the
/// `regexRows` `after` anchor, `{query.x}` in step URL templates, the
/// `wereadNotes` archive format, and the `text.join@1` op. The catalog
/// now carries file sources (`match.file`, no URL examples: their corpus
/// is fixture files, tested in EluviumCatalogTests).
///
/// The 2026-10-10 audit (packVersion `.2`, same schemaMinor). Identity:
/// the prologue's `strongNamespaces` names every declared namespace that is
/// a platform's own stable unique id, so records sharing one auto-link
/// (append-only, binary built-ins not repeated). Three stay weak on
/// purpose: `booking.hotel` (a slug with its country segment cut, so two
/// countries' "hotel-central" would merge), `vrbo.property` (the regex
/// strips the `ha`/`vb` suffix that names the legacy id system), and
/// `yelp.business` (an alias Yelp reassigns on merges and renames).
/// Apple Podcasts declares the built-in `itunes.podcast`; Douban adds the
/// built-in `douban.film` on movie shapes. Stable ids that declared
/// nothing now do: Komoot tours, Xiaohongshu notes, Google feature ids
/// (gmaps.place reads the `!1s0x…:0x…` data token ahead of `ftid`, so a
/// place no longer re-keys at every zoom), Apple's `place-id`, the feed
/// trio, and the collection children that point at a resolvable entity
/// (Spotify and Apple Music tracks, Xiaoyuzhou episodes, the IGN and 100
/// Best entries, the dex rows, Van Gogh and Liu Cixin entries re-keyed on
/// their Wikidata QIDs). Xiaoyuzhou infers `podcast` vs `episode` from the
/// path, and episodes get their own namespace. Field keys align on
/// generic.feed's: x.post maps `image`, `handle`, `author`, `published`;
/// aggregate ratings are a typed `rating` everywhere (the Maps metas and
/// chewy included). camera.lens gates its kind (chunk header in
/// +Commerce). `requires` lists only what a step's mode does not already
/// imply, every native op versioned. youtube.channel is an enrichment
/// composite now: a channel-page step (scoped fields) supplies the avatar
/// and description the channel feed lacks, at one extra page fetch.
///
/// The 2026-10-11 pass (schemaMinor 4): two reference sources and the two
/// vocabulary additions they needed. wikipedia.article reads the REST
/// summary of any language or mobile host through the new `{host}` URL
/// template placeholder (the input's host; a fetch-step filler like
/// `{query.x}`, never a seed's), and declares the built-in `wikidata`
/// namespace, so an article links to the list entries keyed on the same
/// QID. sixflags.attraction reads a ride's server-rendered data blob,
/// which sits ~640 KB into the page: `textRegex` takes the `after` anchor
/// `regexRows` gained on 2026-10-10, so the capped window starts at the
/// blob. The generic.opengraph corpus swaps its Wikipedia example for
/// mozilla.org, since that URL now recognizes to its own source. Same
/// pass: the xhslink hosts left the travel redirector for
/// `shortlinks.media` in the Xiaohongshu chunk (a family's expander lives
/// in its family, so `--families media` keeps it); xiaohongshu.post gained
/// a keep-list canonicalize that drops the sharer's ids from expanded
/// shares, and its corpus became direct note URLs; the AllTrails examples
/// dropped their per-user share token.
///
/// Embedded as a string rather than a resource so it is testable in the
/// pure package and needs no per-app bundling. The chunks are authored as
/// JSON here; a YAML source repo that compiles to this same JSON is
/// planned, not built.
public enum ELVStarterPack {
    /// The one stored copy of the pack for the process lifetime: the
    /// composed text is built, encoded, and dropped in this initializer.
    public static let data = Data(composedStarterPackJSON().utf8)

    /// Loads the starter pack against the given capabilities.
    public static func load(capabilities: ELVCapabilities) throws -> ELVLoadedPack {
        try ELVPackLoader.load(embedded: data, capabilities: capabilities)
    }

    /// The pack as text, decoded from `data` on each access (tests and
    /// tooling read it; nothing on a hot path does). The bytes were encoded
    /// from a Swift string, so the decode cannot fail.
    public static var json: String {
        String(bytes: data, encoding: .utf8) ?? ""
    }
}

/// File scope, not a member: the pack body is data, and SwiftLint's
/// type-body budget should meter code. A function, not a stored global, so
/// the joined text never outlives `ELVStarterPack.data`'s initializer.
private func composedStarterPackJSON() -> String {
    starterPackPrologueJSON + "\n"
        + starterPackChunks.map(\.json).joined(separator: ",\n")
        + "\n" + starterPackEpilogueJSON
}

/// One row of the chunk table: the `eluvium curate --families` name the
/// chunk's sources answer to, the chunk's Swift name (so a test can name
/// the file a syntax slip lives in), and the chunk JSON itself.
struct ELVStarterChunk {
    let family: String
    let name: String
    let json: String
}

/// THE ordered chunk table. Both consumers derive from it — the composition
/// join above and `ELVCatalogFamilies.families` — so a chunk added here is
/// in the pack and in `--families` by construction; it can no longer land
/// in one and vanish from the other. See the declaration-order paragraph
/// above: this table IS the pack's sources array, and families interleave
/// by design (a family's ids are its chunks' ids in table order).
let starterPackChunks: [ELVStarterChunk] = [
    ELVStarterChunk(family: "travel", name: "starterTravelMapsJSON", json: starterTravelMapsJSON), // +Travel: shortlinks.travel … applemaps.place
    ELVStarterChunk(family: "reference", name: "starterReferenceJSON", json: starterReferenceJSON), // +Reference: pokeapi ×2, themeparks.entity, wikipedia.article, sixflags.attraction
    ELVStarterChunk(family: "travel", name: "starterTrailsAndFlightsJSON", json: starterTrailsAndFlightsJSON), // +Travel: alltrails … flighttracker.flight
    ELVStarterChunk(family: "media", name: "starterMediaJSON", json: starterMediaJSON), // +Media: x.post … mastodon.profile
    ELVStarterChunk(family: "commerce", name: "starterCommerceJSON", json: starterCommerceJSON), // +Commerce: camera.lens, camera.lens.sigma
    ELVStarterChunk(family: "travel", name: "starterLodgingToursJSON", json: starterLodgingToursJSON), // +Travel: booking.lodging … carrental.brands
    ELVStarterChunk(family: "media", name: "starterXiaohongshuJSON", json: starterXiaohongshuJSON), // +Media: xiaohongshu.post
    ELVStarterChunk(family: "nature", name: "starterNatureJSON", json: starterNatureJSON), // +Nature: inat.* ×4, merlin.species, allaboutbirds.guide, ebird.mydata
    ELVStarterChunk(family: "media", name: "starterWeReadJSON", json: starterWeReadJSON), // +Media: weread.book, weread.review, weread.notes
    ELVStarterChunk(family: "lists", name: "starterListsJSON", json: starterListsJSON), // +Lists: lists.* ×7
    ELVStarterChunk(family: "floors", name: "starterGenericFloorsJSON", json: starterGenericFloorsJSON), // +Floors: generic.feed, generic.opengraph
]

/// Everything above the sources array: schema/pack versions and the
/// shared `fragments` block. Ends exactly at `"sources": [`.
private let starterPackPrologueJSON = """
{
  "schemaVersion": 1,
  "schemaMinor": 5,
  "packVersion": "2026.10.13-starter.1",
  "strongNamespaces": [
    "gmaps.feature", "applemaps.place", "komoot.tour",
    "x.tweet", "spotify", "applemusic.album", "applemusic.song", "xiaoyuzhou.podcast", "xiaoyuzhou.episode",
    "youtube.video", "douban.subject", "goodreads.book", "igdb.game", "ign.game", "threads.post", "fragrantica.perfume",
    "reddit.subreddit", "youtube.channel", "mastodon.account",
    "airbnb.listing", "expedia.hotel", "hostelworld.property", "hotels.hotel", "tripadvisor.location",
    "gyg.tour", "viator.product", "klook.activity",
    "xiaohongshu.note", "inat.user", "weread.book", "weread.review", "sixflags.attraction"
  ],
  "fragments": {
    "lodgingDates": {
      "fields": [
        { "name": "checkIn", "candidates": [
          { "from": { "urlQuery": "checkin" }, "as": "date", "format": "yyyy-MM-dd" },
          { "from": { "urlQuery": "checkIn" }, "as": "date", "format": "yyyy-MM-dd" },
          { "from": { "urlQuery": "checkindate" }, "as": "date", "format": "yyyy-MM-dd" },
          { "from": { "urlQuery": "checkin_date" }, "as": "date", "format": "yyyy-MM-dd" },
          { "from": { "urlQuery": "chkin" }, "as": "date", "format": "yyyy-MM-dd" },
          { "from": { "urlQuery": "ci" }, "as": "date", "format": "yyyy-MM-dd" },
          { "from": { "urlQuery": "startDate" }, "as": "date", "format": "yyyy-MM-dd" }
        ]},
        { "name": "checkOut", "candidates": [
          { "from": { "urlQuery": "checkout" }, "as": "date", "format": "yyyy-MM-dd" },
          { "from": { "urlQuery": "checkOut" }, "as": "date", "format": "yyyy-MM-dd" },
          { "from": { "urlQuery": "checkoutdate" }, "as": "date", "format": "yyyy-MM-dd" },
          { "from": { "urlQuery": "checkout_date" }, "as": "date", "format": "yyyy-MM-dd" },
          { "from": { "urlQuery": "chkout" }, "as": "date", "format": "yyyy-MM-dd" },
          { "from": { "urlQuery": "co" }, "as": "date", "format": "yyyy-MM-dd" },
          { "from": { "urlQuery": "endDate" }, "as": "date", "format": "yyyy-MM-dd" }
        ]}
      ]
    },
    "gmapsMetas": {
      "fields": [
        { "name": "metaName", "candidates": [{ "from": { "native": "maps.classifyMetaSegments@1" }, "select": "name" }] },
        { "name": "title", "candidates": [
          { "from": { "native": "maps.splitPlaceLabel@1" }, "select": "name" },
          { "from": { "native": "place.littleEndianLabel@1", "input": { "label": "$field.metaName" } }, "select": "label",
            "pipe": [{ "split": "," }, "first", "trim"] }
        ]},
        { "name": "locality", "candidates": [
          { "from": { "native": "maps.splitPlaceLabel@1" }, "select": "locality" },
          { "from": { "native": "maps.classifyMetaSegments@1" }, "select": "locality" }
        ]},
        { "name": "address", "candidates": [{ "from": { "native": "maps.classifyMetaSegments@1" }, "select": "address" }] },
        { "name": "placeType", "candidates": [{ "from": { "native": "maps.classifyMetaSegments@1" }, "select": "type" }] },
        { "name": "category", "candidates": [{ "from": { "native": "maps.classifyMetaSegments@1" }, "select": "category" }] },
        { "name": "rating", "candidates": [{ "from": { "native": "maps.classifyMetaSegments@1" }, "select": "rating" }] }
      ]
    },
    "trailStats": {
      "fields": [
        { "name": "distance", "candidates": [
          { "from": { "native": "trail.statsFromText@3", "input": { "text": "$paste.text?" } }, "select": "distance" }
        ]},
        { "name": "difficulty", "candidates": [
          { "from": { "native": "trail.statsFromText@3", "input": { "text": "$paste.text?" } }, "select": "difficulty" }
        ]},
        { "name": "duration", "candidates": [
          { "from": { "native": "trail.statsFromText@3", "input": { "text": "$paste.text?" } }, "select": "duration" }
        ]},
        { "name": "trailStatSources", "candidates": [
          { "from": { "native": "trail.statsFromText@3", "input": { "text": "$paste.text?" } }, "select": "sources" }
        ]}
      ]
    },
    "placeNode": {
      "fields": [
        { "name": "placeName", "candidates": [{ "from": { "native": "jsonld.bestPlaceNode@1" }, "select": "name" }] },
        { "name": "address", "candidates": [{ "from": { "native": "jsonld.bestPlaceNode@1" }, "select": "address" }] },
        { "name": "phone", "candidates": [{ "from": { "native": "jsonld.bestPlaceNode@1" }, "select": "phone" }] },
        { "name": "geo", "candidates": [{ "from": { "native": "jsonld.bestPlaceNode@1" }, "select": "geo" }] },
        { "name": "cuisine", "candidates": [{ "from": { "native": "jsonld.bestPlaceNode@1" }, "select": "cuisine" }] },
        { "name": "rating", "candidates": [{ "from": { "native": "jsonld.bestPlaceNode@1" }, "select": "rating" }] },
        { "name": "hotelStars", "candidates": [{ "from": { "native": "jsonld.bestPlaceNode@1" }, "select": "hotelStars" }] },
        { "name": "price", "candidates": [{ "from": { "native": "jsonld.bestPlaceNode@1" }, "select": "price" }] },
        { "name": "duration", "candidates": [{ "from": { "native": "jsonld.bestPlaceNode@1" }, "select": "duration" }] },
        { "name": "placeCategory", "candidates": [{ "from": { "native": "jsonld.bestPlaceNode@1" }, "select": "category" }] },
        { "name": "placeDescription", "candidates": [{ "from": { "native": "jsonld.bestPlaceNode@1" }, "select": "description" }] }
      ]
    },
    "placePage": {
      "fetch": { "mode": "composite", "steps": [
        { "mode": "none" },
        { "mode": "http", "ua": "desktopSafari" },
        { "mode": "dom", "ua": "desktopSafari", "settle": { "signals": ["jsonld", "og:title", "h1"] }, "when": "placeThin" }
      ]}
    },
    "httpEscalate": {
      "fetch": { "mode": "composite", "steps": [
        { "mode": "http", "ua": "mobileSafari" },
        { "mode": "http", "ua": "crawler", "when": "blockedOrThin" }
      ]}
    },
    "ogCore": {
      "fields": [
        { "name": "title", "candidates": [
          { "from": { "meta": "og:title" } },
          { "from": { "meta": "twitter:title" } },
          { "from": { "textRegex": "<title[^>]*>([\\\\s\\\\S]*?)</title>" }, "pipe": ["decodeEntities", "collapseWhitespace", "trim",
            { "regexReplace": ["^(?:Access Denied|Just a moment\\\\.\\\\.\\\\.|Attention Required! \\\\| Cloudflare|Pardon Our Interruption|Bot or Not\\\\?)$", ""] }] }
        ]},
        { "name": "summary", "candidates": [
          { "from": { "meta": "og:description" } },
          { "from": { "meta": "description" } }
        ]},
        { "name": "image", "candidates": [
          { "from": { "meta": "og:image" }, "pipe": ["resolveURL"], "as": "image" }
        ]},
        { "name": "siteName", "candidates": [{ "from": { "meta": "og:site_name" } }] }
      ]
    }
  },
  "triggers": {
    "blockedOrThin": { "anyOf": [{ "status": [403, 429, 503] }, { "emptyRecord": true }, { "missingAny": ["title"] }] },
    "noTweetText": { "anyOf": [{ "status": [403, 404, 429] }, { "emptyRecord": true }, { "missingAny": ["text"] }] },
    "placeThin": { "anyOf": [{ "status": [403, 429, 503] }, { "missingAny": ["placeName"] }] },
    "trailThin": { "anyOf": [{ "status": [403, 429, 503] }, { "emptyRecord": true }, { "missingAny": ["distance", "difficulty", "duration"] }] }
  },
  "sources": [
"""

private let starterPackEpilogueJSON = """
  ]
}
"""
