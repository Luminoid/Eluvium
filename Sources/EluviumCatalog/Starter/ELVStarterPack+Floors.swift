/// The generic-floor chunk of the starter pack: the feed floor
/// (RSS/Atom/JSON Feed via the envelope) and the OpenGraph card floor.
/// Floors are last by contract — recognition falls through to them in
/// declaration order. Composition contract in ELVStarterPack.swift.
///
/// generic.opengraph escalates to the crawler persona on STATUS only (403 /
/// 429 / 503), never on a thin record: as the catch-all, an empty record is
/// the honest answer for a page with no metadata, and re-fetching every
/// bare page would double the floor's cost for nothing. Its fields ride
/// `ogCore` (2026-09-10) with only the candidates that must outrank the
/// fragment's kept inline — the JSON-LD title candidates, and the whole
/// image ladder, because `og:image` must keep beating `twitter:image` and
/// `use` appends fragment candidates after the source's own (the
/// fragment's trailing `og:image` is an inert duplicate).
let starterGenericFloorsJSON = """
    {
      "id": "generic.feed",
      "title": "Web feeds",
      "kind": "feed",
      "fetch": { "mode": "feed", "ua": "mobileSafari", "maxBytes": 10000000 },
      "fields": [
        { "name": "title", "candidates": [{ "from": { "json": "$.title" } }] },
        { "name": "summary", "candidates": [{ "from": { "json": "$.description" } }] },
        { "name": "language", "candidates": [{ "from": { "json": "$.language" } }] },
        { "name": "link", "candidates": [{ "from": { "json": "$.link" }, "as": "url" }] },
        { "name": "image", "candidates": [{ "from": { "json": "$.image" }, "as": "image" }] },
        { "name": "author", "candidates": [{ "from": { "json": "$.author" } }] },
        { "name": "nextPage", "candidates": [{ "from": { "json": "$.nextURL" }, "as": "url" }] },
        { "name": "funding", "candidates": [{ "from": { "json": "$.fundingURL" }, "as": "url" }] },
        { "name": "fundingLabel", "candidates": [{ "from": { "json": "$.fundingLabel" } }] },
        { "name": "showType", "candidates": [{ "from": { "json": "$.itunesType" } }] }
      ],
      "collections": [
        {
          "name": "items",
          "from": { "json": "$.items[*]" },
          "kind": "article",
          "item": [
            { "name": "externalId", "candidates": [{ "from": { "json": "$.externalId" } }] },
            { "name": "title", "candidates": [{ "from": { "json": "$.title" } }] },
            { "name": "summary", "candidates": [{ "from": { "json": "$.summary" } }] },
            { "name": "content", "candidates": [{ "from": { "json": "$.contentHTML" }, "pipe": ["rewriteLazyImages"] }] },
            { "name": "link", "candidates": [{ "from": { "json": "$.link" }, "as": "url" }] },
            { "name": "published", "candidates": [{ "from": { "json": "$.published" }, "as": "date" }] },
            { "name": "image", "candidates": [{ "from": { "json": "$.image" }, "as": "image" }] },
            { "name": "audio", "candidates": [{ "from": { "json": "$.enclosureAudioURL" }, "as": "audio" }] },
            { "name": "duration", "candidates": [{ "from": { "json": "$.durationSeconds" }, "as": "duration" }] },
            { "name": "transcript", "candidates": [{ "from": { "json": "$.transcriptURL" }, "as": "url" }] },
            { "name": "chapters", "candidates": [{ "from": { "json": "$.chaptersURL" }, "as": "url" }] }
          ]
        }
      ],
      "identities": [
        { "ns": "podcast.guid", "from": { "json": "$.podcastGuid" } }
      ],
      "examples": [
        { "input": "https://daringfireball.net/feeds/main", "expect": { "kind": "feed", "nonEmpty": ["title"] } },
        { "input": "https://inessential.com/feed.json", "expect": { "kind": "feed", "nonEmpty": ["title"] } },
        { "input": "https://xkcd.com/rss.xml", "expect": { "kind": "feed", "nonEmpty": ["title"] } },
        { "input": "https://www.swift.org/atom.xml", "expect": { "kind": "feed", "nonEmpty": ["title"] } },
        { "input": "https://blog.luminoid.dev/atom.xml", "expect": { "kind": "feed", "nonEmpty": ["title"] } }
      ]
    },
    {
      "id": "generic.opengraph",
      "title": "Web pages",
      "kind": "link",
      "use": ["ogCore", "placeNode"],
      "fetch": { "mode": "composite", "steps": [
        { "mode": "http", "ua": "mobileSafari" },
        { "mode": "http", "ua": "crawler", "when": { "status": [403, 429, 503] } },
        { "mode": "dom", "ua": "desktopSafari", "settle": { "signals": ["jsonld", "og:title", "h1"] },
          "when": { "anyOf": [{ "status": [403, 429, 503] }, { "missingAny": ["title"] }] } }
      ]},
      "label": ["placeName", "title", "host"],
      "fields": [
        { "name": "host", "candidates": [{ "from": { "urlRegex": "^https?://(?:www[.])?([^/?#:@]+)" }, "pipe": ["lower"] }] },
        { "name": "title", "candidates": [
          { "from": { "jsonld": "Product.name" }, "pipe": ["decodeEntities", "trim"] },
          { "from": { "jsonld": "ProductGroup.name" }, "pipe": ["decodeEntities", "trim"] },
          { "from": { "jsonld": "*.name" } }
        ]},
        { "name": "brand", "candidates": [
          { "from": { "jsonld": "Product.brand.name" }, "pipe": ["decodeEntities", "trim"] },
          { "from": { "jsonld": "Product.brand" }, "pipe": ["decodeEntities", "trim"] },
          { "from": { "jsonld": "ProductGroup.brand.name" }, "pipe": ["decodeEntities", "trim"] },
          { "from": { "jsonld": "ProductGroup.brand" }, "pipe": ["decodeEntities", "trim"] }
        ]},
        { "name": "price", "candidates": [
          { "from": { "jsonld": "Product.offers.price" }, "as": "money", "currencyFrom": { "jsonld": "Product.offers.priceCurrency" } },
          { "from": { "jsonld": "Product.offers.lowPrice" }, "as": "money", "currencyFrom": { "jsonld": "Product.offers.priceCurrency" } },
          { "from": { "jsonld": "ProductGroup.offers.price" }, "as": "money", "currencyFrom": { "jsonld": "ProductGroup.offers.priceCurrency" } },
          { "from": { "jsonld": "ProductGroup.offers.lowPrice" }, "as": "money", "currencyFrom": { "jsonld": "ProductGroup.offers.priceCurrency" } },
          { "from": { "meta": "product:price:amount" }, "as": "money", "currencyFrom": { "meta": "product:price:currency" } },
          { "from": { "meta": "og:price:amount" }, "as": "money", "currencyFrom": { "meta": "og:price:currency" } }
        ]},
        { "name": "image", "candidates": [
          { "from": { "jsonld": "Product.image" }, "as": "image" },
          { "from": { "jsonld": "ProductGroup.image" }, "as": "image" },
          { "from": { "meta": "og:image" }, "pipe": ["resolveURL"], "as": "image" },
          { "from": { "meta": "twitter:image" }, "pipe": ["resolveURL"], "as": "image" }
        ]},
        { "name": "content", "candidates": [{ "from": { "native": "article.bodyFromPage@1" }, "select": "html", "pipe": ["rewriteLazyImages"] }] }
      ],
      "examples": [
        { "input": "https://www.apple.com/", "expect": { "kind": "link", "nonEmpty": ["title"] } },
        { "input": "https://www.mozilla.org/en-US/", "expect": { "kind": "link", "nonEmpty": ["title"] } },
        { "input": "https://swift.org/", "expect": { "kind": "link", "nonEmpty": ["title"] } },
        { "input": "https://www.themoviedb.org/", "expect": { "kind": "link", "nonEmpty": ["title"] } },
        { "input": "https://blog.luminoid.dev/", "expect": { "kind": "link", "nonEmpty": ["title"] } }
      ]
    }
"""
