# Eluvium

[![Swift](https://img.shields.io/badge/Swift-6.2-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-iOS%2018%2B%20%7C%20macOS%2015%2B%20%7C%20Mac%20Catalyst%2018%2B-blue.svg)](Package.swift)
[![Release](https://img.shields.io/github/v/release/Luminoid/Eluvium)](https://github.com/Luminoid/Eluvium/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

> Declarative source-to-structured-record ingestion for Swift: a URL, feed, or archive goes in; signed on-device JSON packs describe how to recognize, fetch, extract, and assemble it; a typed `ELVRecord` comes out.
>
> *Eluvium*: in geology, the residue that remains in place after wind and water carry the finer material away.

Eluvium is built to replace per-app scraping code (the link autofill in apps like TripDays and Petfolio) with one pipeline driven by data, not code: **recognize** (host/brand/path registry) → **fetch** (`http` / `json` / `feed` / `dom` / `none` / `archive`, with escalation triggers, per-step byte budgets, and step-scoped fields/collections for multi-endpoint sources) → **extract** (selectors + pipes + coercions over metas, JSON-LD, JSON paths, CSS) → **assemble** (records, collections with their own identity specs, cross-source identities). Packs share config through named `fragments` and `triggers`; every decoded key is executed, validated, and tested (unknown keys degrade, never error). ## Installation

```swift
dependencies: [
    .package(url: "https://github.com/Luminoid/Eluvium.git", from: "0.1.0"),
]
```

## Libraries — import only what you need

Each concern is its own library product; a consumer links exactly the layers it uses and nothing more (a Core-only consumer pulls no networking, no WebKit, no MapKit, no UIKit).

| Target | Dependencies | Default isolation | What it adds |
|--------|--------------|-------------------|--------------|
| EluviumCore | — | — | Pack schema + loader + verifier, extraction engine, record model, feed normalizer, archive readers, entity identity graph, egress/URL policies, value display formatting |
| EluviumCatalog | EluviumCore | — | The bundled source catalog: `ELVStarterPack` composed from the family chunks in `Starter/`, plus the opt-in JSON packs in `OptIn/` behind `ELVOptInPacks`, and the curation helpers (`ELVPackSubset`, `ELVCatalogFamilies`). Link it to load the full roster; omit it and compile in a curated subset instead (see Selecting sources) |
| EluviumNet | EluviumCore | — | `ELVPipeline` (URL → record), `ELVIngestSession` (session result cache + in-flight coalescing), streaming HTTP fetcher with SSRF guard + per-hop redirect policy, short-link chase, list enumerator, remote-pack download/verify/cache |
| EluviumDOM | EluviumCore, WebKit | MainActor | Headless `WKWebView` renderer for JS-walled pages (settle policy, canonical-URL capture) |
| EluviumPlaces | EluviumCore, MapKit | — | `place.mapKitLookup` / `geo.anchorLadder` native ops, place resolution scoring |
| EluviumUI | EluviumCore, LumiKitUI (LumiKit 1.x), SnapKit | MainActor | `ELVRecordCardView` record preview |

Typical footprints: link-autofill app → Core + Net (+ DOM for pages that build their content in script); travel app → Core + Net + DOM + Places; archive importer → Core only. The `eluvium` executable (EluviumCLI) is author tooling for curating and signing packs; apps never link it.

## Startup contract

Native ops register per module, **before** the first pack load; a binary that skips a registration skips every source requiring that op (capability gating):

```swift
ELVNetOps.register()      // shortlink.expand: required for redirector sources
ELVPlacesOps.register()   // place.mapKitLookup, geo.anchorLadder (pass geocoder: for the address anchor)
let pack = try ELVStarterPack.load(capabilities: .init(fetchModes: ["http", "json", "feed", "dom", "archive"], binaryVersion: ELVBinary.version))
let pipeline = ELVPipeline(pack: pack, domRenderer: ELVWebViewRenderer())  // renderer optional
```

An identity graph built over that pack's records takes the pack's strong namespaces too, so records from different sources that share a stable id (an eBird species code, an IMDb id, an iNaturalist taxon) link: `var index = ELVEntityIndex(); index.addStrongNamespaces(pack.strongNamespaces)`.

`ELVStarterPack` lives in `EluviumCatalog`; loading the full roster means linking that product. To ship only a subset, curate one instead (below) and load your generated pack in its place.

## Pasted links

A paste flow reads the text in two halves. `ELVPastedInput.parse` decides whether a title box's text is a link at all (ordinary titles like "Dinner at 7" or "Dinner.at" never are) and lifts the link out of a share blurb. The pack's offline `preview` then answers at once, with no network; `run` (or an `ELVIngestSession`'s `ingest`) does the rest when `needsFullRun` says there is more:

```swift
guard let input = ELVPastedInput.parse(text, policy: pack.pastePolicy) else { return }   // not a link
let preview = pack.preview(input)            // synchronous: label, kind, URL-borne pin
show(preview.record.fields["label"])
if preview.needsFullRun {
    let run = await session.ingest(input: input)   // the blurb rides along to every step
}
```

Sources with a `label` ladder put one display label on each record, page-derived names ahead of a share blurb's name, ahead of the URL slug, ahead of the brand; a label your user typed (`userLabel:`) outranks them all.

## Selecting sources

The catalog is separate from the engine, so an app compiles in only the sources it needs. Curate a subset at build time with the `eluvium` tool:

```bash
swift run eluvium curate --families travel,floors --enum-name TripDaysSources -o TripDaysSources.swift
# or by id; --format json emits a bundle resource instead of a Swift file
swift run eluvium curate --ids alltrails.trail,booking.lodging,generic.opengraph -o AppSources.swift
```

The generated Swift file is a compiled-in pack holding only the chosen sources plus their fragment/trigger closure. Add it to your target and call `TripDaysSources.load(capabilities:)`. Your app then links `EluviumCore` (and the transports it uses) plus this one file, not `EluviumCatalog`, so unused sources never reach the binary. `curate` warns when a selected source needs a module you may not have linked, naming it: EluviumDOM for a `dom` step, EluviumPlaces for the MapKit and anchor-ladder ops, EluviumNet for the shortlink chase.

## Pack trust

`ELVPackLoader` accepts only `ELVVerifiedPackBytes`: compiled-in bytes claim trust explicitly (`ELVPackLoader.load(embedded:)`), remote bytes must pass `ELVPackVerifier.verify(_:keys:)` (detached Ed25519 signature over the exact payload, binary-pinned key set with `keyId` rotation). There is no raw-`Data` entry point: a pack drives fetch URLs, personas, and regexes, so unauthenticated bytes are unrepresentable at the API level.

## Remote packs

An app can extend its built-in sources from a signed pack fetched at runtime. Sign a pack once, author side:

```bash
swift run eluvium keygen --key-id 2026-a   # key to ~/.config/eluvium/keys/2026-a.private.key (0600); prints the public key to pin
swift run eluvium sign --key ~/.config/eluvium/keys/2026-a.private.key --key-id 2026-a --pack pack.json -o pack.envelope.json
```

`keygen` refuses to write a key inside a git work tree. `sign` loads the pack first: it refuses one that does not decode or carries authoring diagnostics (`--force` overrides the latter) and lists the version and sources it is about to sign.

At runtime, download, verify, and merge over the built-in subset:

```swift
let service = ELVRemotePackService(
    keys: ELVPackKeySet(keys: ["2026-a": pinnedPublicKey]),
    store: ELVRemotePackStore(directory: appSupportDirectory)
)
switch try await service.refresh(from: packURL, capabilities: caps) {
case .updated(let downloaded): pack = builtin.merging(downloaded)  // overlay wins per source id, unless it is older
case .notModified: break                                           // keep the cached/built-in pack
}
```

The service reuses the egress-checked fetcher (HTTPS-only, SSRF guard, per-hop redirect policy, byte cap) and a conditional GET (`ETag` / 304). The store persists the verified envelope and re-verifies it on load, so a cached pack survives an offline launch without weakening the trust boundary. Schedule `refresh` from your foreground and `BGAppRefreshTask` hooks; observe `.elvRemotePackUpdated` to re-merge.

Versions only move forward. The store records the `packVersion` it last accepted, and `refresh` throws `ELVRemotePackError.versionRollback` for a validly signed pack older than that (a stale CDN, a replayed envelope). At launch, pass the built-in pack's version so a cache older than the binary is discarded instead of loaded: `store.loadCached(keys:capabilities:bundledVersion: builtin.pack.packVersion)`. `merging` itself keeps the built-in pack when the overlay is older (`ELVPackVersion.compare`).

## Diagnostics: the run trace and the log

Diagnostics are data first. Every pipeline run returns an `ELVPipelineRun`: the `result` (`.record`, `.unrecognized`, or `.failed(_, sourceId:)`) plus an `ELVRunTrace` that says what ran to get there.

```swift
let run = await pipeline.run(url: pastedURL)
switch run.result { /* ... */ }
for step in run.trace.steps {
    // step.mode, step.host, step.status, step.bytes, step.truncated,
    // step.settled (dom), step.extracted, step.duration, step.outcome
}
run.trace.fieldMisses        // declared fields the record lacks, with the candidates tried
run.trace.nativeOpFailures   // async ops (MapKit, short links) that threw instead of answering
```

The trace lists every step, including ones a `when` condition declined, ones skipped because the binary lacks the mode (a `dom` step with no renderer), and a later step that failed after an earlier one produced. A redirector chase or a canonical capture shows as its own step before the source it led to, and `trace.sourceIds` lists both. `ELVIngestSession.ingest(url:)` returns the same type; a cache hit carries the original trace with `servedFromCache` set. `ELVEnumerator` results carry `pages` (one `ELVStepTrace` per page), `notes` (empty item paths, items that assembled to nothing, an unparseable seed), and `skippedPages` with each page's failure. `ELVExample.unmetExpectations(for:)` is the corpus check, so a health run, a host's corpus screen, and its log all report the same verdict.

The trace also backs a few failure rules that used to pass silently as empty records:

- A recognized source that answers but yields no field and no child fails as `.formatDrift("no fields extracted")`. A partially filled record stays a record, with its gaps in `fieldMisses`. The generic floors still return an empty link card when every floor misses.
- A `json` step whose body does not parse as JSON, and a `feed` step that ends with no feed (none served, none advertised, or an advertised link that is not a feed), fail as `formatDrift` with the reason.
- A `dom` render that never settled and extracted nothing fails with its WebKit load error or final-evaluate error instead of returning an empty record. `ELVDOMResult` carries both as `loadError` and `extractionError`.
- An unexpected error type is folded into `formatDrift` as its type and case, or its domain and code, so every failure reason is free of user data.

The framework logs to the unified log under the subsystem `dev.luminoid.eluvium`, in the categories `Pack`, `Remote`, `Fetch`, `Extract`, `Render`, `Enumerate`, and `Import`. Each run writes one outcome line rendered from its trace: info for a record (missed fields are listed on that line: optional fields and drift sentinels miss on healthy runs), warning for a degraded record (a step failed or was truncated, a render did not settle, a native op threw, a canonical capture timed out) or a drift, error for any other failure, debug for a cancellation. Walks, imports, and pack loads write a notice summary; pack diagnostics, signature failures, and remote refresh failures are logged too, once, at the outermost call (a remote refresh's failed verification is the refresh's error line, with the verifier's own line at debug). Per-step and per-page detail goes to debug.

Public log text holds source ids, hosts, statuses, byte counts, durations, and field and selector names. Full URLs go only into the private part of a line, because share tokens live in paths and query strings (a Komoot `share_token`, a Swarm `?s=`, a shared-list path). Field values appear only in private debug lines. Errors are attached with their type, domain, and code rather than a localized description.

```swift
#if DEBUG
    ELVLog.minimumLevel = .debug    // default .info; error and fault always come through
#endif
ELVLog.handler = { entry in /* forward to a crash reporter or an in-app log store */ }
```

Watch it live: `log stream --level debug --predicate 'subsystem == "dev.luminoid.eluvium"'`.

## Using the sources responsibly

The framework targets no site; the pack a host loads and the URLs it resolves decide what gets fetched. The example corpus is illustrative, not an endorsement to scrape any site. Some sources whose targets restrict automated access ship as opt-in packs (`ELVOptInPacks`) that nothing loads by default. See [LEGAL.md](LEGAL.md) before building on the framework: terms of service, personal data, copyright, and access controls are the caller's responsibility.

## Example app

[Examples/EluviumExample](Examples/EluviumExample) (separate Xcode project, scheme `EluviumExample`): five tabs: Paste (URL → record, with feed/episode browsing and audio playback), Sources (pack inspection), Catalogs (the pack's seeded lists + paged enumeration), Imports (archive files: the demo formats plus the catalog's export sources, 微信读书 notes, iNaturalist and eBird CSVs), Identity (cross-source entity graph).

## Development

```bash
brew bundle             # install swiftlint + swiftformat
make setup-hooks        # wire pre-commit lint + format
make build              # xcodebuild, iOS Simulator (EluviumUI needs it)
make test               # all six test targets: Core, Catalog, Net, DOM, Places, UI
make check              # strict lint + format check (CI gate), then the example app's own
```

Bare `swift build` / `swift test` fail on a macOS host, and only because of EluviumUI (LumiKitUI is UIKit). Every other target builds standalone there: `swift build --target EluviumCore` (likewise EluviumCatalog, EluviumNet, EluviumDOM, and EluviumPlaces) and `swift build --product eluvium`. Xcode builds the whole package through the `Eluvium-Package` scheme: no target is named `Eluvium`, so Xcode generates no scheme by that name.

### Dependency policy

EluviumCore and every non-UI target (EluviumCatalog, EluviumNet, EluviumDOM, EluviumPlaces, EluviumCLI) have zero third-party dependencies; CryptoKit, WebKit, and MapKit are platform frameworks. LumiKit (1.x) and SnapKit (both MIT) exist only for EluviumUI, but because every product shares one manifest, every adopter resolves them at package-resolution time even when linking Core alone (resolution, not linking: nothing from them reaches a non-UI binary). LumiKit's manifest also brings in `lottie-spm` (Apache-2.0) at resolution; no Eluvium product links it. Moving EluviumUI into a sibling package would remove that cost, and may happen in a later minor release.

## License

MIT. © Luminoid. See [LICENSE](LICENSE) and [CHANGELOG](CHANGELOG.md).

## Related projects

- [LumiKit](https://github.com/Luminoid/LumiKit): design tokens and UIKit components (EluviumUI and the example app are built on it)
- [Monolith](https://github.com/Luminoid/Monolith): CLI that scaffolds iOS apps, Swift Packages, and Swift CLIs (Eluvium was scaffolded with it)
- Everything else at [luminoid.dev](https://luminoid.dev)
