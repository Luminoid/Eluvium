import Foundation

/// Frozen historical packs for the compatibility matrix. Each entry is
/// the bundled starter pack exactly as its date's binary shipped it —
/// NEVER edited afterward, because its whole value is being what that
/// author actually wrote. When the live starter pack changes, freeze the
/// outgoing copy here.
enum ELVFrozenPacks {
    /// The 2026-08-11 starter pack: 9 sources, 2 generic floors.
    static let starter20260811 = """
    {
      "schemaVersion": 1,
      "schemaMinor": 0,
      "packVersion": "2026.08.11-starter",
      "sources": [
        {
          "id": "shortlinks.travel",
          "kind": "link",
          "match": { "host": ["maps.app.goo.gl", "goo.gl", "g.co", "maps.apple", "yelp.to", "abnb.me", "gyg.me"], "path": "/**", "priority": 90 },
          "resolvesVia": "shortlink.expand",
          "requires": ["native:shortlink.expand"],
          "examples": [
            { "input": "https://maps.app.goo.gl/372N2pn6HcSTEA4w6", "expect": { "kind": "link" } },
            { "input": "https://maps.app.goo.gl/aMm2UNBDn4XEEAfT9", "expect": { "kind": "link" } },
            { "input": "https://maps.apple/p/4yzVtPGTAYBHbCf", "expect": { "kind": "link" } },
            { "input": "https://yelp.to/R8jV3sQ", "expect": { "kind": "link" } },
            { "input": "https://abnb.me/e/AbCdEf123", "expect": { "kind": "link" } }
          ]
        },
        {
          "id": "gmaps.place",
          "kind": "place",
          "match": { "host": ["google.com", "maps.google.com"], "path": "/maps/**", "priority": 100 },
          "fetch": { "mode": "none" },
          "fields": [
            { "name": "externalId", "candidates": [{ "from": { "urlQuery": "ftid" } }] },
            { "name": "title", "candidates": [{ "from": { "native": "gmaps.splitPlaceLabel@1" }, "select": "name" }] },
            { "name": "locality", "candidates": [{ "from": { "native": "gmaps.splitPlaceLabel@1" }, "select": "locality" }] },
            { "name": "geo", "candidates": [{ "from": { "native": "gmaps.pinCoordinate@1" }, "select": "geo" }] },
            { "name": "viewport", "candidates": [{ "from": { "native": "gmaps.pinCoordinate@1" }, "select": "viewportGeo" }] }
          ],
          "requires": ["native:gmaps.pinCoordinate", "native:gmaps.splitPlaceLabel"],
          "examples": [
            { "input": "https://www.google.com/maps/place/Jenny+Lake/@43.7904,-110.7624,15z/data=!8m2!3d43.7904!4d-110.7624", "expect": { "kind": "place", "nonEmpty": ["title", "geo"] } },
            { "input": "https://www.google.com/maps/place/Jenny+Lake,+Wyoming+83424,+USA/@43.75,-110.72,14z", "expect": { "kind": "place", "nonEmpty": ["title"] } },
            { "input": "https://maps.google.com/maps?q=Grand+Prismatic+Spring+Overlook,+Yellowstone+NP&ftid=0x5351eb9454af1c5d:0",
              "expect": { "kind": "place", "nonEmpty": ["title", "locality"] } },
            { "input": "https://www.google.com/maps/place/Dornan's+Pizza+Pasta+Company/@43.6572,-110.7147,17z", "expect": { "kind": "place", "nonEmpty": ["title"] } },
            { "input": "https://www.google.com/maps/place/Church+of+La+Merced/@-12.0445,-77.0339,17z/data=!8m2!3d-12.0466!4d-77.0328",
              "expect": { "kind": "place", "nonEmpty": ["title", "geo"] } }
          ]
        },
        {
          "id": "pokeapi.pokemon",
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
              "item": [{ "name": "title", "candidates": [{ "from": { "json": "$.type.name" }, "pipe": ["capitalizeFirst"] }] }]
            },
            {
              "name": "abilities",
              "from": { "json": "$.abilities[*]" },
              "item": [{ "name": "title", "candidates": [{ "from": { "json": "$.ability.name" }, "pipe": ["slugToTitle"] }] }]
            }
          ],
          "identities": [{ "ns": "pokeapi.pokemon", "from": { "json": "$.id" } }],
          "examples": [
            { "input": "https://pokeapi.co/api/v2/pokemon/1", "expect": { "kind": "pokemon", "nonEmpty": ["title", "image"] } },
            { "input": "https://pokeapi.co/api/v2/pokemon/25", "expect": { "kind": "pokemon", "nonEmpty": ["title", "image"] } },
            { "input": "https://pokeapi.co/api/v2/pokemon/150", "expect": { "kind": "pokemon", "nonEmpty": ["title"] } },
            { "input": "https://pokeapi.co/api/v2/pokemon/6", "expect": { "kind": "pokemon", "nonEmpty": ["title"] } },
            { "input": "https://pokeapi.co/api/v2/pokemon/94", "expect": { "kind": "pokemon", "nonEmpty": ["title"] } }
          ]
        },
        {
          "id": "pokeapi.dex",
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
            "ref": { "source": "pokeapi.pokemon", "id": { "json": "$.url" } },
            "maxPages": 30,
            "cache": { "ttlHours": 168 }
          },
          "examples": [
            { "input": "https://pokeapi.co/api/v2/pokemon?limit=60", "expect": { "kind": "pokemon", "nonEmpty": ["title"] } },
            { "input": "https://pokeapi.co/api/v2/pokemon?limit=20", "expect": { "kind": "pokemon", "nonEmpty": ["title"] } },
            { "input": "https://pokeapi.co/api/v2/pokemon?limit=60&offset=60", "expect": { "kind": "pokemon", "nonEmpty": ["title"] } },
            { "input": "https://pokeapi.co/api/v2/pokemon?limit=100", "expect": { "kind": "pokemon", "nonEmpty": ["title"] } },
            { "input": "https://pokeapi.co/api/v2/pokemon?limit=10", "expect": { "kind": "pokemon", "nonEmpty": ["title"] } }
          ]
        },
        {
          "id": "themeparks.entity",
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
            { "input": "https://api.themeparks.wiki/v1/entity/disneylandresort", "expect": { "kind": "themepark", "nonEmpty": ["title"] } },
            { "input": "https://api.themeparks.wiki/v1/entity/universalorlando", "expect": { "kind": "themepark", "nonEmpty": ["title"] } },
            { "input": "https://api.themeparks.wiki/v1/entity/tokyodisneyresort", "expect": { "kind": "themepark", "nonEmpty": ["title"] } }
          ]
        },
        {
          "id": "alltrails.trail",
          "kind": "trail",
          "match": { "host": ["alltrails.com"], "path": "/trail/:country/:region/:slug", "priority": 100 },
          "canonicalize": { "strip": ["utm_*", "sh", "ref"] },
          "fetch": { "mode": "composite", "steps": [
            { "mode": "http", "ua": "crawler" },
            { "mode": "dom", "ua": "desktopSafari", "settle": { "signals": ["h1", "jsonld", "og:title"] }, "when": { "anyOf": [
              { "status": [403, 429, 503] },
              { "emptyRecord": true },
              { "missingAny": ["title"] }
            ]}}
          ]},
          "fields": [
            { "name": "externalId", "candidates": [{ "from": { "urlParam": "slug" } }] },
            { "name": "title", "candidates": [
              { "from": { "jsonld": "TouristAttraction.name" } },
              { "from": { "meta": "og:title" }, "pipe": [{ "stripSuffix": " | AllTrails" }] },
              { "from": { "urlParam": "slug" }, "pipe": ["slugToTitle"] }
            ]},
            { "name": "summary", "candidates": [{ "from": { "meta": "og:description" } }] },
            { "name": "rating", "candidates": [{ "from": { "jsonld": "TouristAttraction.aggregateRating.ratingValue" }, "as": "rating" }] },
            { "name": "image", "candidates": [{ "from": { "meta": "og:image" }, "pipe": ["resolveURL"], "as": "image" }] },
            { "name": "distance", "candidates": [{ "from": { "native": "trail.statsFromText@2" }, "select": "distance" }] },
            { "name": "difficulty", "candidates": [{ "from": { "native": "trail.statsFromText@2" }, "select": "difficulty" }] },
            { "name": "duration", "candidates": [{ "from": { "native": "trail.statsFromText@2" }, "select": "duration" }] }
          ],
          "identities": [{ "ns": "alltrails.trail", "from": { "urlParam": "slug" } }],
          "requires": ["fetch:dom", "native:trail.statsFromText@2"],
          "examples": [
            { "input": "https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail", "expect": { "kind": "trail", "nonEmpty": ["title"] } },
            { "input": "https://www.alltrails.com/trail/us/california/mist-trail", "expect": { "kind": "trail", "nonEmpty": ["title"] } },
            { "input": "https://www.alltrails.com/trail/us/wyoming/schwabachers-landing", "expect": { "kind": "trail", "nonEmpty": ["title"] } },
            { "input": "https://www.alltrails.com/trail/us/wyoming/grand-prismatic-hot-spring", "expect": { "kind": "trail", "nonEmpty": ["title"] } },
            { "input": "https://www.alltrails.com/trail/us/california/fairy-falls", "expect": { "kind": "trail", "nonEmpty": ["title"] } }
          ]
        },
        {
          "id": "imdb.title",
          "kind": "movie",
          "match": { "host": ["imdb.com"], "path": "/title/:id/**", "priority": 100 },
          "canonicalize": { "strip": ["ref_", "ref"] },
          "fetch": { "mode": "composite", "steps": [
            { "mode": "http", "ua": "mobileSafari" },
            { "mode": "http", "ua": "crawler", "when": { "status": [403, 429, 503] } }
          ]},
          "fields": [
            { "name": "externalId", "candidates": [{ "from": { "urlParam": "id" } }] },
            { "name": "title", "candidates": [
              { "from": { "jsonld": "Movie.name" } },
              { "from": { "meta": "og:title" } }
            ]},
            { "name": "summary", "candidates": [{ "from": { "jsonld": "Movie.description" } }, { "from": { "meta": "og:description" } }] },
            { "name": "image", "candidates": [{ "from": { "meta": "og:image" }, "as": "image" }] },
            { "name": "rating", "candidates": [{ "from": { "jsonld": "Movie.aggregateRating.ratingValue" }, "as": "rating", "scale": { "min": 0, "max": 10 } }] }
          ],
          "identities": [{ "ns": "imdb", "from": { "urlParam": "id" } }],
          "examples": [
            { "input": "https://www.imdb.com/title/tt0076759/", "expect": { "kind": "movie", "nonEmpty": ["title"] } },
            { "input": "https://www.imdb.com/title/tt0080684/", "expect": { "kind": "movie", "nonEmpty": ["title"] } },
            { "input": "https://www.imdb.com/title/tt0086190/", "expect": { "kind": "movie", "nonEmpty": ["title"] } },
            { "input": "https://www.imdb.com/title/tt0120915/", "expect": { "kind": "movie", "nonEmpty": ["title"] } },
            { "input": "https://www.imdb.com/title/tt2488496/", "expect": { "kind": "movie", "nonEmpty": ["title"] } }
          ]
        },
        {
          "id": "generic.feed",
          "kind": "feed",
          "fetch": { "mode": "feed", "ua": "mobileSafari" },
          "requires": ["fetch:feed"],
          "fields": [
            { "name": "title", "candidates": [{ "from": { "json": "$.title" } }] },
            { "name": "summary", "candidates": [{ "from": { "json": "$.description" } }] },
            { "name": "language", "candidates": [{ "from": { "json": "$.language" } }] },
            { "name": "link", "candidates": [{ "from": { "json": "$.link" }, "as": "url" }] }
          ],
          "collections": [
            {
              "name": "items",
              "from": { "json": "$.items[*]" },
              "kind": "article",
              "item": [
                { "name": "externalId", "candidates": [{ "from": { "json": "$.externalId" } }] },
                { "name": "title", "candidates": [{ "from": { "json": "$.title" } }] },
                { "name": "link", "candidates": [{ "from": { "json": "$.link" }, "as": "url" }] },
                { "name": "published", "candidates": [{ "from": { "json": "$.published" }, "as": "date" }] },
                { "name": "audio", "candidates": [{ "from": { "json": "$.enclosure.url" }, "as": "url" }] },
                { "name": "duration", "candidates": [{ "from": { "json": "$.durationSeconds" }, "as": "duration" }] }
              ]
            }
          ],
          "identities": [
            { "ns": "podcast.guid", "from": { "json": "$.podcastGuid" } },
            { "ns": "itunes.podcast", "from": { "json": "$.itunesId" } }
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
          "kind": "link",
          "fetch": { "mode": "composite", "steps": [
            { "mode": "http", "ua": "mobileSafari" },
            { "mode": "http", "ua": "crawler", "when": { "status": [403, 429, 503] } }
          ]},
          "fields": [
            { "name": "title", "candidates": [
              { "from": { "jsonld": "*.name" } },
              { "from": { "meta": "og:title" } },
              { "from": { "meta": "twitter:title" } }
            ]},
            { "name": "summary", "candidates": [
              { "from": { "meta": "og:description" } },
              { "from": { "meta": "description" } }
            ]},
            { "name": "image", "candidates": [
              { "from": { "meta": "og:image" }, "pipe": ["resolveURL"], "as": "image" },
              { "from": { "meta": "twitter:image" }, "pipe": ["resolveURL"], "as": "image" }
            ]},
            { "name": "siteName", "candidates": [{ "from": { "meta": "og:site_name" } }] }
          ],
          "examples": [
            { "input": "https://www.apple.com/", "expect": { "kind": "link", "nonEmpty": ["title"] } },
            { "input": "https://en.wikipedia.org/wiki/Eluvium", "expect": { "kind": "link", "nonEmpty": ["title"] } },
            { "input": "https://swift.org/", "expect": { "kind": "link", "nonEmpty": ["title"] } },
            { "input": "https://www.themoviedb.org/", "expect": { "kind": "link", "nonEmpty": ["title"] } },
            { "input": "https://blog.luminoid.dev/", "expect": { "kind": "link", "nonEmpty": ["title"] } }
          ]
        }
      ]
    }
    """
}
