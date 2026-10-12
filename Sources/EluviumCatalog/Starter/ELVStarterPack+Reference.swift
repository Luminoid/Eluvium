/// The reference chunk of the starter pack: PokéAPI (one Pokémon, and the
/// dex as a walkable list), themeparks.wiki entities, Wikipedia articles,
/// and Six Flags attractions. Composition contract in ELVStarterPack.swift
/// (declaration order is behavior; chunks carry no trailing comma). The
/// chunk sits second in the table, between the Maps and trail chunks,
/// because that is where history put it; it moved out of +Media into its
/// own file on 2026-10-10 without changing its table position; the 2026-10-11
/// sources append at its end.
///
/// wikipedia.article (2026-10-11) reads the page-summary REST endpoint
/// (`/api/rest_v1/page/summary/{title}`): plain title, short description,
/// lead extract, page image, coordinates, language, page type (`standard`,
/// `disambiguation`, `no-extract`), and the Wikidata QID. Every language
/// edition and every `xx.m.` mobile host serves the same endpoint, so the
/// step URL takes the pasted host through `{host}` (schemaMinor 4) instead
/// of a per-language host table. `/wiki/:title` is one segment on purpose:
/// a title with a slash (`AC/DC`) falls to the OpenGraph floor rather than
/// fetching the summary of its first segment. The QID rides the built-in
/// `wikidata` namespace, so an article and the Liu Cixin / Van Gogh list
/// entries keyed on the same item land in one entity. The image URLs carry
/// `?utm_…` tracking the API appends; the pipe strips it.
///
/// sixflags.attraction (2026-10-11) covers every park on sixflags.com
/// (`/:park/attractions/:slug`), the legacy Cedar Fair parks included. The
/// page is a Next.js RSC render: the head carries OpenGraph (summary and
/// image ride `ogCore`), the hero `<h1>` the ride name, and the ride's own
/// data object sits in the flight payload ~640 KB in, past the regex input
/// cap, so every blob candidate anchors `after: "RidePage"` (the route
/// marker that opens the object, once per page). Inside the payload every
/// quote is JSON-escaped (`\"thrillLevel\":4`), so the patterns match the
/// key names and walk the punctuation with `\W+` instead of spelling the
/// escapes; `\u0026` is the one escape that reaches a value (`B \u0026 M`),
/// and the string-value idiom keeps it for a `regexReplace` to turn back
/// into `&`. Thrill level is the 1–5 gauge the page draws (the own block
/// is numeric on every park checked); `topSpeed`, `trackLength`,
/// `height` (the blob's `elevation`), and `yearIntroduced` read the first
/// non-zero value, which on most pages is the "For the Geeks" statistics
/// block that precedes the metadata. The `relatedRides` collection reads
/// the cards below the ride: slug, name, the card's thrill tier (a word,
/// `high` / `aggressive`, not the gauge) and height minimum, with the
/// detail URL joined from the park param. The `fimsId` the page prints is
/// Six Flags' own ride key (`RIDE-<park>-<number>`, one scheme across the
/// merged parks: Cedar Point rides are `RIDE-001-…`, Magic Mountain's
/// `RIDE-906-…`), so `sixflags.attraction` is a strong namespace. A park's
/// `/attractions` grid server-renders only its first ten cards (the rest
/// load client-side), so there is no list source: a browse of a park
/// needs a dom render first.
///
/// The dex rows declare `pokeapi.pokemon` (a built-in strong namespace)
/// through `{ "field": "externalId" }`, so a dex row and the Pokémon's own
/// record land in one entity. The page-level dex record extracts no
/// `externalId` field, so the spec stays silent there. A Pokémon's `types`
/// and `abilities` children carry their own kinds (`pokemon.type`,
/// `pokemon.ability`); without one they inherited the parent's `pokemon`.
let starterReferenceJSON = """
    {
      "id": "pokeapi.pokemon",
      "title": "PokéAPI Pokémon",
      "kind": "pokemon",
      "match": { "host": ["pokeapi.co"], "path": "/api/v2/pokemon/:id", "priority": 100 },
      "fetch": { "mode": "json" },
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "json": "$.id" } }] },
        { "name": "title", "candidates": [{ "from": { "json": "$.name" }, "pipe": ["slugToTitle"] }] },
        { "name": "height", "candidates": [{ "from": { "json": "$.height" }, "as": "int" }] },
        { "name": "weight", "candidates": [{ "from": { "json": "$.weight" }, "as": "int" }] },
        { "name": "image", "candidates": [
          { "from": { "json": "$.sprites.other.official-artwork.front_default" }, "as": "image" },
          { "from": { "json": "$.sprites.front_default" }, "as": "image" }
        ]}
      ],
      "collections": [
        {
          "name": "types",
          "from": { "json": "$.types[*]" },
          "kind": "pokemon.type",
          "item": [
            { "name": "externalId", "candidates": [{ "from": { "json": "$.type.name" } }] },
            { "name": "title", "candidates": [{ "from": { "json": "$.type.name" }, "pipe": ["capitalizeFirst"] }] }
          ]
        },
        {
          "name": "abilities",
          "from": { "json": "$.abilities[*]" },
          "kind": "pokemon.ability",
          "item": [
            { "name": "externalId", "candidates": [{ "from": { "json": "$.ability.name" } }] },
            { "name": "title", "candidates": [{ "from": { "json": "$.ability.name" }, "pipe": ["slugToTitle"] }] }
          ]
        }
      ],
      "identities": [{ "ns": "pokeapi.pokemon", "from": { "json": "$.id" } }],
      "examples": [
        { "input": "https://pokeapi.co/api/v2/pokemon/1", "expect": { "kind": "pokemon", "nonEmpty": ["title", "image"] } },
        { "input": "https://pokeapi.co/api/v2/pokemon/25", "expect": { "kind": "pokemon", "nonEmpty": ["title", "image"] } },
        { "input": "https://pokeapi.co/api/v2/pokemon/150", "expect": { "kind": "pokemon", "nonEmpty": ["title"] } }
      ]
    },
    {
      "id": "pokeapi.dex",
      "title": "PokéAPI Pokédex",
      "kind": "pokemon",
      "match": { "host": ["pokeapi.co"], "path": "/api/v2/pokemon", "priority": 90 },
      "fetch": { "mode": "json" },
      "rows": [
        { "name": "externalId", "candidates": [{ "from": { "json": "$.url" }, "pipe": [{ "regexReplace": [".*/pokemon/(\\\\d+)/?$", "$1"] }] }] },
        { "name": "title", "candidates": [{ "from": { "json": "$.name" }, "pipe": ["slugToTitle"] }] },
        { "name": "detail", "candidates": [{ "from": { "json": "$.url" }, "as": "url" }] }
      ],
      "list": {
        "seed": "https://pokeapi.co/api/v2/pokemon?limit=60",
        "items": { "json": "$.results[*]" },
        "next": { "json": "$.next" },
        "total": { "json": "$.count" },
        "maxPages": 30
      },
      "identities": [{ "ns": "pokeapi.pokemon", "from": { "field": "externalId" } }],
      "examples": [
        { "input": "https://pokeapi.co/api/v2/pokemon?limit=60", "expect": { "kind": "pokemon", "nonEmptyCollections": ["items"] } },
        { "input": "https://pokeapi.co/api/v2/pokemon?limit=20", "expect": { "kind": "pokemon", "nonEmptyCollections": ["items"] } },
        { "input": "https://pokeapi.co/api/v2/pokemon?limit=60&offset=60", "expect": { "kind": "pokemon", "nonEmptyCollections": ["items"] } }
      ]
    },
    {
      "id": "themeparks.entity",
      "title": "ThemeParks.wiki",
      "kind": "themepark",
      "match": { "host": ["api.themeparks.wiki"], "path": "/v1/entity/:entityId", "priority": 100 },
      "fetch": { "mode": "json" },
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "json": "$.id" } }] },
        { "name": "title", "candidates": [{ "from": { "json": "$.name" } }] },
        { "name": "entityType", "candidates": [{ "from": { "json": "$.entityType" } }] },
        { "name": "geo", "candidates": [{ "from": { "json": "$.location" }, "as": "geo" }] },
        { "name": "timezone", "candidates": [{ "from": { "json": "$.timezone" } }] }
      ],
      "identities": [{ "ns": "themeparks.entity", "from": { "json": "$.id" } }],
      "examples": [
        { "input": "https://api.themeparks.wiki/v1/entity/waltdisneyworldresort", "expect": { "kind": "themepark", "nonEmpty": ["title"] } },
        { "input": "https://api.themeparks.wiki/v1/entity/e957da41-3552-4cf6-b636-5babc5cbc4e5", "expect": { "kind": "themepark", "nonEmpty": ["title"] } },
        { "input": "https://api.themeparks.wiki/v1/entity/universalresort_orlando", "expect": { "kind": "themepark", "nonEmpty": ["title"] } },
        { "input": "https://api.themeparks.wiki/v1/entity/tdr", "expect": { "kind": "themepark", "nonEmpty": ["title"] } }
      ]
    },
    {
      "id": "wikipedia.article",
      "title": "Wikipedia",
      "kind": "article",
      "match": { "host": ["wikipedia.org"], "path": "/wiki/:title", "priority": 100 },
      "fetch": { "mode": "json", "url": "https://{host}/api/rest_v1/page/summary/{param.title}" },
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "json": "$.pageid" }, "as": "text" }] },
        { "name": "title", "candidates": [{ "from": { "json": "$.title" } }] },
        { "name": "description", "candidates": [{ "from": { "json": "$.description" } }] },
        { "name": "summary", "candidates": [{ "from": { "json": "$.extract" } }] },
        { "name": "image", "candidates": [
          { "from": { "json": "$.originalimage.source" }, "pipe": [{ "regexReplace": ["\\\\?utm_.*$", ""] }], "as": "image" },
          { "from": { "json": "$.thumbnail.source" }, "pipe": [{ "regexReplace": ["\\\\?utm_.*$", ""] }], "as": "image" }
        ]},
        { "name": "geo", "candidates": [{ "from": { "json": "$.coordinates" }, "as": "geo" }] },
        { "name": "language", "candidates": [{ "from": { "json": "$.lang" } }] },
        { "name": "pageType", "candidates": [{ "from": { "json": "$.type" } }] },
        { "name": "wikidata", "candidates": [{ "from": { "json": "$.wikibase_item" } }] },
        { "name": "modified", "candidates": [{ "from": { "json": "$.timestamp" }, "as": "date" }] },
        { "name": "link", "candidates": [{ "from": { "json": "$.content_urls.desktop.page" }, "as": "url" }] }
      ],
      "identities": [{ "ns": "wikidata", "from": { "json": "$.wikibase_item" } }],
      "examples": [
        { "input": "https://en.wikipedia.org/wiki/Jenny_Lake", "expect": { "kind": "article", "nonEmpty": ["title", "summary", "geo"] } },
        { "input": "https://zh.wikipedia.org/wiki/%E4%B8%8A%E6%B5%B7%E5%B8%82", "expect": { "kind": "article", "nonEmpty": ["title", "summary", "wikidata"] } },
        { "input": "https://en.m.wikipedia.org/wiki/Eluvium", "expect": { "kind": "article", "nonEmpty": ["title", "summary"] } },
        { "input": "https://ja.wikipedia.org/wiki/%E6%9D%B1%E4%BA%AC%E3%82%BF%E3%83%AF%E3%83%BC", "expect": { "kind": "article", "nonEmpty": ["title", "geo"] } }
      ]
    },
    {
      "id": "sixflags.attraction",
      "title": "Six Flags",
      "kind": "attraction",
      "match": { "host": ["sixflags.com"], "path": "/:park/attractions/:slug", "priority": 100 },
      "fetch": { "mode": "http", "ua": "mobileSafari" },
      "use": ["ogCore"],
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "textRegex": "fimsId\\\\W+([A-Z]+-[0-9]+-[0-9]+)", "after": "RidePage" } }] },
        { "name": "title", "candidates": [
          { "from": { "textRegex": "<h1[^>]*>\\\\s*<span[^>]*>([^<]+)</span>" }, "pipe": ["decodeEntities", "collapseWhitespace", "trim"] },
          { "from": { "textRegex": "parkSlug\\\\W+[a-z0-9-]+\\\\W+plainTextTitle\\\\W+([\\\\p{L}\\\\p{N}](?:[^\\\\\\\\\\"]|\\\\\\\\u0026)*)", "after": "RidePage" },
            "pipe": [{ "regexReplace": ["\\\\\\\\u0026", "&"] }] },
          { "from": { "meta": "og:title" }, "pipe": [{ "regexReplace": ["^.*?\\\\s[-|]\\\\s", ""] }, { "regexReplace": ["\\\\s\\\\|.*$", ""] }, "trim"] }
        ]},
        { "name": "park", "candidates": [{ "from": { "urlParam": "park" } }] },
        { "name": "parkName", "candidates": [{ "from": { "meta": "og:title" }, "pipe": [{ "regexReplace": ["\\\\s[-|]\\\\s.*$", ""] }, "trim"] }] },
        { "name": "area", "candidates": [
          { "from": { "textRegex": "neighborhood\\\\W+label\\\\W+([\\\\p{L}\\\\p{N}](?:[^\\\\\\\\\\"]|\\\\\\\\u0026)*)", "after": "RidePage" },
            "pipe": [{ "regexReplace": ["\\\\\\\\u0026", "&"] }] }
        ]},
        { "name": "thrillLevel", "candidates": [{ "from": { "textRegex": "thrillLevel\\\\W+([1-5])\\\\W+topSpeed", "after": "RidePage" }, "as": "int" }] },
        { "name": "minimumHeight", "candidates": [{ "from": { "textRegex": "minimumHeight\\\\W+([0-9]+)\\\\W+minimumHeightAccompanied", "after": "RidePage" }, "as": "int" }] },
        { "name": "minimumHeightAccompanied", "candidates": [{ "from": { "textRegex": "minimumHeightAccompanied\\\\W+([1-9][0-9]*)\\\\W+specialFeatures", "after": "RidePage" }, "as": "int" }] },
        { "name": "heightUnits", "candidates": [{ "from": { "textRegex": "metricOrImperial\\\\W+(imperial|metric)", "after": "RidePage" } }] },
        { "name": "height", "candidates": [{ "from": { "textRegex": "elevation\\\\W+([1-9][0-9]*)\\\\W+goesUpsideDown", "after": "RidePage" }, "as": "int" }] },
        { "name": "topSpeed", "candidates": [{ "from": { "textRegex": "topSpeed\\\\W+([1-9][0-9]*)\\\\W+trackLength", "after": "RidePage" }, "as": "int" }] },
        { "name": "trackLength", "candidates": [{ "from": { "textRegex": "trackLength\\\\W+([1-9][0-9]*)\\\\W+yearIntroduced", "after": "RidePage" }, "as": "int" }] },
        { "name": "yearIntroduced", "candidates": [{ "from": { "textRegex": "yearIntroduced\\\\W+([1-9][0-9]{3})", "after": "RidePage" }, "as": "int" }] },
        { "name": "manufacturer", "candidates": [
          { "from": { "textRegex": "manufacturer\\\\W+([\\\\p{L}\\\\p{N}](?:[^\\\\\\\\\\"]|\\\\\\\\u0026)*)\\\\W+(?:maxHeightAccompanied|metricOrImperial)", "after": "RidePage" },
            "pipe": [{ "regexReplace": ["\\\\\\\\u0026", "&"] }] }
        ]},
        { "name": "specialFeatures", "candidates": [
          { "from": { "textRegex": "specialFeatures\\\\W+([\\\\p{L}\\\\p{N}](?:[^\\\\\\\\\\"]|\\\\\\\\u0026)*)\\\\W+(?:thrillLevel|topSpeed)", "after": "RidePage" },
            "pipe": [{ "regexReplace": ["\\\\\\\\u0026", "&"] }] }
        ]}
      ],
      "collections": [
        {
          "name": "relatedRides",
          "from": { "regexRows": "link\\\\W+([a-z0-9-]+)\\\\W+metadata\\\\W+[^}]*?minimumHeight\\\\W+([0-9]+)[^}]*?thrillLevel\\\\W+([a-z0-9]+)\\\\W+plainTextTitle\\\\W+\
([\\\\p{L}\\\\p{N}](?:[^\\\\\\\\\\"]|\\\\\\\\u0026)*)", "after": "preSelectedRelatedRidesCount" },
          "kind": "attraction",
          "item": [
            { "name": "externalId", "candidates": [{ "from": { "json": "$.g1" } }] },
            { "name": "title", "candidates": [{ "from": { "json": "$.g4" }, "pipe": [{ "regexReplace": ["\\\\\\\\u0026", "&"] }] }] },
            { "name": "thrillTier", "candidates": [{ "from": { "json": "$.g3" } }] },
            { "name": "minimumHeight", "candidates": [{ "from": { "json": "$.g2" }, "as": "int" }] },
            { "name": "url", "candidates": [{ "from": { "native": "text.join@1",
              "input": { "part1": "https://www.sixflags.com", "part2": "$param.park", "part3": "attractions", "part4": "$field.externalId", "separator": "/" } },
              "select": "text", "as": "url" }] }
          ]
        }
      ],
      "identities": [{ "ns": "sixflags.attraction", "from": { "textRegex": "fimsId\\\\W+([A-Z]+-[0-9]+-[0-9]+)", "after": "RidePage" } }],
      "requires": ["native:text.join@1"],
      "examples": [
        { "input": "https://www.sixflags.com/magicmountain/attractions/wonder-woman-flight-of-courage", "expect": { "kind": "attraction", "nonEmpty": ["title", "thrillLevel"] } },
        { "input": "https://www.sixflags.com/cedarpoint/attractions/millennium-force",
          "expect": { "kind": "attraction", "nonEmpty": ["title", "thrillLevel", "topSpeed"], "nonEmptyCollections": ["relatedRides"] } },
        { "input": "https://www.sixflags.com/greatadventure/attractions/nitro", "expect": { "kind": "attraction", "nonEmpty": ["title", "thrillLevel", "manufacturer"] } },
        { "input": "https://www.sixflags.com/magicmountain/attractions/bonzai-pipelines", "expect": { "kind": "attraction", "nonEmpty": ["title", "thrillLevel", "minimumHeight"] } }
      ]
    }
"""
