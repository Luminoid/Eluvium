# Legal notes

This is engineering documentation, not legal advice. If any of this matters to
your use, get your own counsel.

## What Eluvium is

Eluvium is a general-purpose ingestion framework: it turns a source URL into a
structured record by following a declarative pack (recognize → fetch → extract →
assemble). The framework itself targets no site. What it fetches is entirely
determined by the pack a host application loads and the URLs that host resolves.

## The example corpus

The starter pack and the example app exist to demonstrate the framework. Their
source list is illustrative, not an endorsement to scrape any particular site.
A host application ships its own pack and is responsible for its own targets.

The corpus carries no share tokens, sharer ids, or private individuals' details.
Sources whose only loadable inputs are personal share links (Komoot tours,
Xiaohongshu notes, short links that resolve to their minter's account) ship
without examples, and test fixtures captured from real pages have names and
client keys redacted. The sources themselves still handle such links fully when a
user pastes one.

If you build on Eluvium, you are responsible for ensuring that what your app
fetches is permitted:

- **Respect each target's terms of service and `robots.txt`.** Some sites in the
  example corpus restrict automated access in their terms. Fetching them anyway
  may breach a contract even where no other law is implicated.
- **Personal data.** Several example sources return user-generated content that
  includes third parties' names, handles, and photos (social posts, reviews,
  profiles). Handling that data can bring GDPR, CCPA, and platform-specific
  obligations. Curate the URLs you resolve, and do not resolve links to private
  individuals without a basis to.
- **Copyright.** Extracting and storing titles, summaries, images, article text,
  or curated lists can implicate copyright and (in the EU) database rights. Store
  and display only what your use permits.
- **Access controls.** Do not use the framework to defeat a technical access
  control you are not authorized to bypass. Circumvention can carry liability
  well beyond a terms breach.

## How the starter pack fetches

The starter pack fetches a URL the user chose, the way a link preview does. When a
site refuses a plain request, some sources retry with another built-in user agent
(one of them a link-preview crawler's) or a headless WebKit render. The framework
checks no `robots.txt` and has no rate limiter of its own; it fetches one URL per
user action. If any of that conflicts with what your app may do, curate those
sources out (`eluvium curate`) or ship your own pack.

## The opt-in packs

Some retailer sources are kept out of the default pack because their targets'
terms restrict automated access. They ship as separate, opt-in packs (`ELVOptInPacks`, e.g. the commerce pack
covering Amazon and Chewy) that nothing loads by default. Load one only for
targets you have decided you may fetch. In this repository they exist to keep the
Petfolio parity tests runnable, not as a recommendation to fetch those sites.

## Built-in safeguards

The framework enforces a shared egress policy on every fetch path (HTTP fetcher,
redirect hops, short-link chase, DOM renderer): loopback, private, link-local,
CGNAT, and benchmark address ranges are blocked in every spelling, so a pack
cannot be steered into someone's internal network. This is an anti-SSRF control,
not a substitute for the caller's own diligence about which public sites they may
fetch.

## Where data goes

Eluvium has no server and no telemetry. Records are returned to the host app,
which decides where they are stored. The framework's own network traffic is the
requests a pack's fetch plan makes to the target sites, Apple's MapKit when a host
registers the EluviumPlaces ops, and the remote-pack URL a host configures. Log
lines keep full URLs and field values in the private part of the unified log.

## Trademarks

Brand and product names in the packs and records are used nominatively, to
identify the thing a record describes. All trademarks belong to their respective
owners, and no affiliation or endorsement is implied. The repository includes no
third-party logos or artwork.

## Acknowledgments

The article-body extraction (`article.bodyFromPage`) follows the scoring
heuristics of Arc90's Readability and Mozilla's Readability.js (Apache License
2.0). The Swift implementation is independent.
