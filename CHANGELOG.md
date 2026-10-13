# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Pasted text as an input.** `ELVPastedInput.parse(_:)` reads text pasted into a title box strictly (a known scheme, or a bare host ending in a known TLD, so "Dinner.at" stays a title) and lifts the link out of a share blurb, keeping the text before it and the blurb without it; `ELVPastedInput.link(_:)` is the lenient reading for a link field. `ELVPastePolicy` sets the length cap, TLDs, schemes, and share-name separators; `ELVLoadedPack.pastePolicy` adds the app schemes the pack's sources claim. `ELVPipeline.run(input:userLabel:progress:)` and `ELVIngestSession.ingest(input:userLabel:progress:)` carry the blurb to every step (`run(url:)` and `ingest(url:)` forward to them).
- **Offline preview.** `ELVLoadedPack.preview(_:userLabel:)` (also on `ELVPipeline` and, nonisolated, on `ELVIngestSession`) recognizes the input and fills every field the URL and the paste can, synchronously and with no I/O, and reports what a full run would add (`ELVPreviewPending`: redirect, fetch, platform lookup, floor).
- **Labels.** A source's `label` ladder (pack grammar) names its label fields in precedence order; records then carry one `label` field resolved by `ELVLabelResolver`: a typed `userLabel` first, then the first strong value, then a country-shaped one, then the brand.
- **Pack grammar (schema minor 5).** The `paste` selector (`label`, `title`, `leading`, `text`) and `$paste.x` op inputs; optional op inputs (`$field.x?`, left out when they don't resolve); the `weakAny` trigger (a field missing, generic, or a bare country name); `match.scheme` for app links (`comgooglemaps://`; URL-only sources); dotted brands (`maps.google`); `previewAs` hints on redirectors; dom-step `regions` (`h1`, `header`, `body`), read as rendered text; the `{origin}` step URL (the link as recognized before a canonical capture); and `innerText` as a css attribute.
- **Native ops.** `trail.statsFromText@3` reads a dom step's rendered regions anchored at the page's own name, so a related trail's stats never land on this one, and reports which sources contributed; `trail.locality@1`; `place.mapKitLookup@2`, the address-anchored lookup (forward-geocodes a coordinate-free place's street address into an anchor, trusts a match only near it, and pins the anchor itself on a miss), with its radii as pack values.
- **Host seams.** `ELVGeocoding` (inject your geocoder through `ELVPlacesOps.register(searcher:geocoder:)`), `ELVHTTPFetcher(timeoutCap:)`, `ELVWebViewRenderer(watchdogSeconds:idleTeardownSeconds:)`, `ELVIngestSession(…, pinPolicy: .completeOnly)`, and `ELVCountry` for country lookups.
- **Catalog.** `booking.share`, `gmaps.directions`, `gmaps.applink`, `applemaps.place.mapkit`, `applemaps.applink`, `flighty.link`, `flighty.applink`, and `dining.reservations`.

### Changed

- A source whose later steps need a fetch mode the binary lacks now loads and degrades: only its first step and its unconditional steps gate it (`ELVFetchPlan.gatingModes`), so a binary without EluviumDOM keeps a source's http rung instead of losing the source.
- A generic floor's dom step now runs (when a renderer is injected and its `when` admits the shared fetch's outcome), so a refused or title-less page can still render.
- Travel sources: Google Maps sources match every Google ccTLD and read the place page's metas in their own step; lodging, tour, and review sources (Vrbo excepted, which stays URL-only) fetch their page and read its place node, so a page's name replaces the URL slug in their label; Flighty titles drop the og:title's "Track " lead and records carry both airport time zones; Booking `/Share-` links expand instead of falling to the OpenGraph floor.

### Fixed

- `ELVMapKitPlaceSearch` returns no results when MapKit finds nothing, instead of throwing; a place lookup with no match no longer reads as a failed op or degrades the run.
- `jsonld.bestPlaceNode` no longer repeats address pieces when a page puts the whole address in `streetAddress` and repeats its parts in the other PostalAddress keys.
- `maps.classifyMetaSegments` no longer reports a bare "Google Maps" page title as the place's name.
- Starter sources no longer take a bot wall's page title ("Access Denied", "Just a moment...") as the record's title.
- Lens titles drop the site suffix after " | " ("FUJINON XF8-16mmF2.8 R LM WR", not "… | Lenses | FUJIFILM X Series & GFX - USA").
- The GetYourGuide and Viator examples point at live tours; several were placeholders that never loaded.

## [0.1.0] - 2026-10-12

Initial release.

### Added

- **Pipeline.** `ELVPipeline` turns a URL into a typed `ELVRecord`: recognize (host, brand, and path rules; file rules for archives), fetch (`http`, `json`, `feed`, `dom`, `none`, `archive`, and `composite` plans that escalate step by step), extract, assemble. Every run returns an `ELVPipelineRun`: the result plus an `ELVRunTrace` (each step's host, status, bytes, truncation, settle state, duration, and outcome, the fields that missed with the candidates tried, and native-op failures). A recognized source that fetched and extracted nothing fails as `formatDrift` instead of returning an empty record. `ELVIngestSession` adds a bounded result cache; `runSeed(sourceId:)` runs a pack-authored seed.
- **Transport.** `ELVHTTPFetcher`: HTTPS only, one egress policy (`ELVEgressPolicy`) on the request, every redirect hop (`ELVRedirectGuard`, public for hosts fetching page-derived URLs), and the landing; a streaming byte cap and a wall-clock deadline; typed `ELVFetchFailure`s. A 2xx that is really a refusal (flagged by the server's challenge header) reads as `blocked`, so a source's fallback steps run.
- **Pack format** (schema 1, minor 4). Signed JSON packs (`ELVPackEnvelope`, Ed25519, `ELVPackVerifier` with binary-pinned keys); `ELVPackLoader` accepts compiled-in bytes or verified bytes only. The grammar: match rules, `canonicalize`, named `fragments` and `triggers`, fetch plans with URL templates (`{param.x}`, `{host}`, `{query.x}`, `{native:op(param.x)}`) and step-scoped fields and collections, selectors (`meta`, `jsonld`, `json`, `css`, `textRegex` and `regexRows` each with an optional `after` anchor, `urlParam`, `urlQuery`, `urlRegex`, `column`, `field`, `native`), pipes, coercions (text, numbers, ISO 4217 money in minor units, dates, durations, URLs, phones, geo from pairs, strings, or coordinate objects, image/video/audio media refs, ratings on a declared scale, tags), collections, identities, pack-level `strongNamespaces`, and per-source examples (`nonEmpty`, `nonEmptyCollections`). Unknown keys and values degrade with a diagnostic instead of failing; a pack declaring a newer minor still loads. Pack regexes read at most 256 K characters and run under a two-second budget, so a backtracking pattern over a hostile page is a miss, not a hang. The validator reports dead candidates, uncompilable patterns, dangling references, redundant `requires`, and off-vocabulary kinds.
- **Records and identity.** `ELVRecord` / `ELVValue` with merge policies (`fillEmptyOnly`, `preferIncoming`), values a newer binary wrote are preserved through a round trip. `ELVEntityIndex` links records that share a value in a strong namespace (built-in set plus a pack's `strongNamespaces`, append-only), surfaces heuristic suggestions (`entity.placeMatch`) for confirmation, and records vetoes.
- **Feeds and reading.** RSS, Atom, and JSON Feed with Podcasting 2.0 fields (transcripts, chapters, funding, `podcast:guid`), feed autodiscovery, OPML import, and a reader pass (`article.bodyFromPage@1`) for full-text extraction.
- **Archive import.** `ELVArchiveImporter` and `ELVFileRecognizer` over CSV, JSON and `jsJson` (with an optional `list.items` path), OPML, and the 微信读书 notes export (`wereadNotes`, `ELVWeReadNotesReader`), with byte, probe, and item ceilings (`ELVArchiveLimits`).
- **Enumeration.** `ELVEnumerator` walks list sources (next-URL, cursor-token, and offset cursors), resumable from persisted state; a walk that reaches its page cap completes with a note saying so.
- **DOM rendering.** `ELVWebViewRenderer` (EluviumDOM): headless WebKit with settle signals, canonical-URL capture, and the egress policy on every navigation; a page's hand-off to an app URL scheme is cancelled without failing the render.
- **Places.** EluviumPlaces registers the MapKit lookup and anchor-ladder ops.
- **UI.** EluviumUI's `ELVRecordCardView` renders any record (localized, one VoiceOver element per field, key beside value in regular width).
- **Remote packs.** `ELVRemotePackService` downloads, verifies, and loads a signed pack over a conditional GET; `ELVRemotePackStore` persists it and re-verifies on load; `ELVLoadedPack.merging` layers it over the built-in pack (overlay wins per source id, unless it is older). A replayed or stale pack older than the last one accepted is refused.
- **Catalog.** `EluviumCatalog` ships the starter pack (`ELVStarterPack`, `2026.10.12-starter.1`) across travel (maps, trails, flights, lodging, tours, reviews, car rental), media (X, IMDb, Spotify, Apple Music and Podcasts, 小宇宙, YouTube, Douban, Goodreads, IGDB, IGN, Threads, Fragrantica, Reddit, Mastodon, Xiaohongshu, 微信读书), reference (PokéAPI, ThemeParks.wiki, Wikipedia, Six Flags attractions), nature (iNaturalist, Merlin Bird ID, All About Birds, and the iNaturalist and eBird export files), commerce (camera lenses), seeded lists, and the generic feed and OpenGraph floors; `ELVOptInPacks.commerce` holds the retailer sources whose terms restrict automated access (see LEGAL.md). `ELVCatalogFamilies` and `ELVPackSubset` slice it.
- **CLI.** `eluvium curate --ids/--families` emits a compiled-in subset with its exact fragment and trigger closure; `eluvium keygen` (keys under `~/.config/eluvium/keys` at mode 0600, never inside a git work tree) and `eluvium sign` (loads and checks the pack before signing it) produce signed remote packs.
- **Logging.** `ELVLog` writes to the unified log under `dev.luminoid.eluvium` at six levels, rendered from the run trace; hosts, ids, codes, and counts are public, URLs and values private. `ELVLog.minimumLevel` and `ELVLog.handler` are the host controls.
- **Example app.** `Examples/EluviumExample` (iPhone, iPad, and Mac Catalyst) dogfoods the package: paste a link, browse sources and their example corpus, walk catalogs, import archive files (picked or dropped; the demo formats plus the catalog's iNaturalist, eBird, and 微信读书 exports), and review the identity graph.

[Unreleased]: https://github.com/Luminoid/Eluvium/compare/0.1.0...HEAD
[0.1.0]: https://github.com/Luminoid/Eluvium/releases/tag/0.1.0
