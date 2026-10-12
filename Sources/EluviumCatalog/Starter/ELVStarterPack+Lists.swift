/// The `lists.*` chunk of the starter pack: the config-as-list mechanism.
/// Wikidata SPARQL seeds (Oscars, TGA, Liu Cixin, Van Gogh), `regexRows`
/// over server-rendered markup (Apple Music 100 Best, Michelin LA), and
/// inline `entries` where no API exists (IGN's 10/10 canon). Long SPARQL
/// seed URLs use backslash line continuation inside the literal. Michelin
/// entries are restaurants, so they carry the `food` kind the Yelp and
/// Tripadvisor restaurant records use (2026-09-10; `place` was a
/// too-generic label that grouped them with map pins).
///
/// Entry identities (2026-10-10): every entry that points at a resolvable
/// record declares that record's namespace, so the list row and the pasted
/// page land in one entity: Oscars `imdb`, TGA `igdb.game`, IGN `ign.game`
/// (the slug of its member URL), 100 Best `applemusic.album`, and Van Gogh
/// and Liu Cixin `wikidata`. Those two were keyed on a Commons image
/// filename and an English Wikipedia title, neither the work's id: the
/// Liu Cixin query now also selects `?book`, and both key on the QID. A
/// list whose `title` falls back to a `const` pins `nonEmptyCollections`
/// in its examples, since the const alone would pass a dead fetch.
/// Composition contract in ELVStarterPack.swift (declaration order is
/// behavior; chunks carry no trailing comma).
let starterListsJSON = """
    {
      "id": "lists.oscars.bestpicture",
      "title": "Oscars Best Picture",
      "kind": "list",
      "seed": "https://query.wikidata.org/sparql?format=json&query=SELECT%20%3FfilmLabel%20%3Fyear%20%3Fimdb%20WHERE%20%7B%20%3Ffilm%20p%3AP166%20%3Fst%20.%20%3Fst%20ps%3AP166%20wd%3AQ102427%20.%20\
%3Ffilm%20wdt%3AP31%20wd%3AQ11424%20.%20OPTIONAL%20%7B%20%3Fst%20pq%3AP585%20%3Ftime%20%7D%20OPTIONAL%20%7B%20%3Ffilm%20wdt%3AP345%20%3Fimdb%20%7D%20SERVICE%20wikibase%3Alabel%20%7B%20\
bd%3AserviceParam%20wikibase%3Alanguage%20%22en%22%20%7D%20BIND%28YEAR%28%3Ftime%29%20AS%20%3Fyear%29%20%7D%20ORDER%20BY%20DESC%28%3Fyear%29",
      "fetch": { "mode": "json", "ua": "mobileSafari" },
      "fields": [
        { "name": "title", "candidates": [{ "from": { "const": "Academy Award for Best Picture" } }] }
      ],
      "collections": [
        {
          "name": "entries",
          "from": { "json": "$.results.bindings[*]" },
          "kind": "movie",
          "item": [
            { "name": "externalId", "candidates": [{ "from": { "json": "$.imdb.value" } }] },
            { "name": "title", "candidates": [{ "from": { "json": "$.filmLabel.value" } }] },
            { "name": "year", "candidates": [{ "from": { "json": "$.year.value" }, "as": "int" }] },
            { "name": "url", "candidates": [{ "from": { "json": "$.imdb.value" }, "pipe": [{ "regexReplace": ["^", "https://www.imdb.com/title/"] }, { "regexReplace": ["$", "/"] }], "as": "url" }] }
          ],
          "identities": [{ "ns": "imdb", "from": { "json": "$.imdb.value" } }]
        }
      ]
    },
    {
      "id": "lists.tga.goty",
      "title": "The Game Awards: Game of the Year",
      "kind": "list",
      "seed": "https://query.wikidata.org/sparql?format=json&query=SELECT%20%3FgameLabel%20%3Fyear%20%3Figdb%20WHERE%20%7B%20%3Fgame%20p%3AP166%20%3Fst%20.%20%3Fst%20ps%3AP166%20wd%3AQ78762377%20\
.%20OPTIONAL%20%7B%20%3Fst%20pq%3AP585%20%3Ftime%20%7D%20OPTIONAL%20%7B%20%3Fgame%20wdt%3AP5794%20%3Figdb%20%7D%20SERVICE%20wikibase%3Alabel%20%7B%20bd%3AserviceParam%20wikibase%3Alanguage%20\
%22en%22%20%7D%20BIND%28YEAR%28%3Ftime%29%20AS%20%3Fyear%29%20%7D%20ORDER%20BY%20DESC%28%3Fyear%29",
      "fetch": { "mode": "json", "ua": "mobileSafari" },
      "fields": [
        { "name": "title", "candidates": [{ "from": { "const": "The Game Awards: Game of the Year" } }] }
      ],
      "collections": [
        {
          "name": "entries",
          "from": { "json": "$.results.bindings[*]" },
          "kind": "game",
          "item": [
            { "name": "externalId", "candidates": [{ "from": { "json": "$.igdb.value" } }] },
            { "name": "title", "candidates": [
              { "from": { "json": "$.gameLabel.value" }, "pipe": [{ "regexReplace": ["^Q[0-9]+$", ""] }] },
              { "from": { "json": "$.igdb.value" }, "pipe": ["slugToTitle"] }
            ]},
            { "name": "year", "candidates": [{ "from": { "json": "$.year.value" }, "as": "int" }] },
            { "name": "url", "candidates": [{ "from": { "json": "$.igdb.value" }, "pipe": [{ "regexReplace": ["^", "https://www.igdb.com/games/"] }], "as": "url" }] }
          ],
          "identities": [{ "ns": "igdb.game", "from": { "json": "$.igdb.value" } }]
        }
      ]
    },
    {
      "id": "lists.ign.tens",
      "title": "IGN 10/10 Games",
      "kind": "list",
      "seed": "https://www.ign.com/reviews/games",
      "fetch": { "mode": "none" },
      "fields": [
        { "name": "title", "candidates": [{ "from": { "const": "IGN 10/10 Games" } }] }
      ],
      "collections": [
        {
          "name": "entries",
          "kind": "game",
          "entries": [
            { "year": 1999, "title": "SoulCalibur", "url": "https://www.ign.com/games/soulcalibur" },
            { "year": 2008, "title": "Grand Theft Auto IV", "url": "https://www.ign.com/games/grand-theft-auto-iv" },
            { "year": 2008, "title": "Metal Gear Solid 4: Guns of the Patriots", "url": "https://www.ign.com/games/metal-gear-solid-4-guns-of-the-patriots" },
            { "year": 2010, "title": "Super Mario Galaxy 2", "url": "https://www.ign.com/games/super-mario-galaxy-2" },
            { "year": 2013, "title": "Grand Theft Auto V", "url": "https://www.ign.com/games/grand-theft-auto-v" },
            { "year": 2013, "title": "The Last of Us", "url": "https://www.ign.com/games/the-last-of-us" },
            { "year": 2017, "title": "The Legend of Zelda: Breath of the Wild", "url": "https://www.ign.com/games/the-legend-of-zelda-breath-of-the-wild" },
            { "year": 2017, "title": "Super Mario Odyssey", "url": "https://www.ign.com/games/super-mario-odyssey" },
            { "year": 2018, "title": "God of War", "url": "https://www.ign.com/games/god-of-war" },
            { "year": 2018, "title": "Red Dead Redemption 2", "url": "https://www.ign.com/games/red-dead-redemption-2" },
            { "year": 2020, "title": "The Last of Us Part II", "url": "https://www.ign.com/games/the-last-of-us-part-ii" },
            { "year": 2020, "title": "Half-Life: Alyx", "url": "https://www.ign.com/games/half-life-alyx" },
            { "year": 2020, "title": "Microsoft Flight Simulator", "url": "https://www.ign.com/games/microsoft-flight-simulator" },
            { "year": 2022, "title": "Elden Ring", "url": "https://www.ign.com/games/elden-ring" },
            { "year": 2022, "title": "God of War Ragnarök", "url": "https://www.ign.com/games/god-of-war-ragnarok" },
            { "year": 2023, "title": "Baldur's Gate 3", "url": "https://www.ign.com/games/baldurs-gate-iii" }
          ],
          "item": [
            { "name": "externalId", "candidates": [{ "from": { "json": "$.url" }, "pipe": [{ "regexReplace": ["^.*/", ""] }] }] },
            { "name": "title", "candidates": [{ "from": { "json": "$.title" } }] },
            { "name": "year", "candidates": [{ "from": { "json": "$.year" }, "as": "int" }] },
            { "name": "url", "candidates": [{ "from": { "json": "$.url" }, "as": "url" }] }
          ],
          "identities": [{ "ns": "ign.game", "from": { "field": "externalId" } }]
        }
      ]
    },
    {
      "id": "lists.applemusic.100best",
      "title": "Apple Music 100 Best Albums",
      "kind": "list",
      "match": { "host": ["100best.music.apple.com"], "path": "/:storefront", "priority": 100 },
      "seed": "https://100best.music.apple.com/us",
      "fetch": { "mode": "http", "ua": "mobileSafari" },
      "fields": [
        { "name": "title", "candidates": [
          { "from": { "meta": "og:title" } },
          { "from": { "const": "Apple Music 100 Best Albums" } }
        ]}
      ],
      "collections": [
        {
          "name": "entries",
          "from": { "regexRows": "(?s)position:\\"(\\\\d+)\\".*?url:\\"(https://music\\\\.apple\\\\.com/[a-z]{2}/album/[^\\"]+)\\",name:\\"([^\\"]*)\\",artistName:\\"([^\\"]*)\\"",
            "after": "{position:\\"" },
          "kind": "album",
          "item": [
            { "name": "externalId", "candidates": [{ "from": { "json": "$.g2" }, "pipe": [{ "regexReplace": ["^.*/", ""] }] }] },
            { "name": "rank", "candidates": [{ "from": { "json": "$.g1" }, "as": "int" }] },
            { "name": "title", "candidates": [{ "from": { "json": "$.g3" }, "pipe": ["decodeEntities", "trim"] }] },
            { "name": "artist", "candidates": [{ "from": { "json": "$.g4" }, "pipe": ["decodeEntities", "trim"] }] },
            { "name": "url", "candidates": [{ "from": { "json": "$.g2" }, "as": "url" }] }
          ],
          "identities": [{ "ns": "applemusic.album", "from": { "field": "externalId" } }]
        }
      ],
      "examples": [
        { "input": "https://100best.music.apple.com/us", "expect": { "kind": "list", "nonEmpty": ["title"], "nonEmptyCollections": ["entries"] } },
        { "input": "https://100best.music.apple.com/jp", "expect": { "kind": "list", "nonEmpty": ["title"], "nonEmptyCollections": ["entries"] } }
      ]
    },
    {
      "id": "lists.michelin.la",
      "title": "Michelin Guide Los Angeles",
      "kind": "list",
      "match": { "host": ["guide.michelin.com"], "priority": 100, "path": [
        "/us/en/california/us-los-angeles/restaurants", "/us/en/california/us-los-angeles/restaurants/**",
        "/us/en/california/los-angeles/restaurants", "/us/en/california/los-angeles/restaurants/**"
      ] },
      "seed": "https://guide.michelin.com/us/en/california/us-los-angeles/restaurants",
      "fetch": { "mode": "http", "ua": "mobileSafari" },
      "fields": [
        { "name": "title", "candidates": [
          { "from": { "meta": "og:title" }, "pipe": ["decodeEntities", "trim"] },
          { "from": { "const": "Michelin Guide Los Angeles" } }
        ]}
      ],
      "collections": [
        {
          "name": "entries",
          "from": { "regexRows": "card__menu selection(?s:.*?)data-restaurant-name=\\"([^\\"{}]+)\\"\\\\s+data-restaurant-selection=\\"[^\\"]*\\"\\\\s+data-distinction=\\"([^\\"{}]*)\\"(?s:.*?)\
href=\\"(/us/en/california/us-los-angeles/restaurant/[^\\"]+)\\"" },
          "kind": "food",
          "item": [
            { "name": "externalId", "candidates": [{ "from": { "json": "$.g3" }, "pipe": [{ "regexReplace": ["^.*/", ""] }] }] },
            { "name": "title", "candidates": [{ "from": { "json": "$.g1" }, "pipe": ["decodeEntities", "trim"] }] },
            { "name": "distinction", "candidates": [{ "from": { "json": "$.g2" }, "pipe": [{ "regexReplace": ["_", " "] }] }] },
            { "name": "url", "candidates": [{ "from": { "json": "$.g3" }, "pipe": [{ "regexReplace": ["^", "https://guide.michelin.com"] }], "as": "url" }] }
          ]
        }
      ],
      "examples": [
        { "input": "https://guide.michelin.com/us/en/california/us-los-angeles/restaurants",
          "expect": { "kind": "list", "nonEmpty": ["title"], "nonEmptyCollections": ["entries"] } },
        { "input": "https://guide.michelin.com/us/en/california/los-angeles/restaurants",
          "expect": { "kind": "list", "nonEmpty": ["title"], "nonEmptyCollections": ["entries"] } }
      ]
    },
    {
      "id": "lists.liucixin.books",
      "title": "Liu Cixin: Notable Books",
      "kind": "list",
      "seed": "https://query.wikidata.org/sparql?format=json&query=SELECT%20%3Fbook%20%3FbookLabel%20%3Fyear%20%3Farticle%20WHERE%20%7B%20wd%3AQ607588%20wdt%3AP800%20%3Fbook%20.%20\
OPTIONAL%20%7B%20%3Fbook%20wdt%3AP577%20%3Fdate%20%7D%20\
OPTIONAL%20%7B%20%3Farticle%20schema%3Aabout%20%3Fbook%20.%20%3Farticle%20schema%3AisPartOf%20%3Chttps%3A%2F%2Fen.wikipedia.org%2F%3E%20%7D%20SERVICE%20\
wikibase%3Alabel%20%7B%20bd%3AserviceParam%20wikibase%3Alanguage%20%22en%22%20%7D%20BIND%28YEAR%28%3Fdate%29%20AS%20%3Fyear%29%20%7D%20ORDER%20BY%20%3Fyear",
      "fetch": { "mode": "json", "ua": "mobileSafari" },
      "fields": [
        { "name": "title", "candidates": [{ "from": { "const": "Liu Cixin: Notable Books" } }] }
      ],
      "collections": [
        {
          "name": "entries",
          "from": { "json": "$.results.bindings[*]" },
          "kind": "book",
          "item": [
            { "name": "externalId", "candidates": [{ "from": { "json": "$.book.value" }, "pipe": [{ "regexReplace": ["^.*/", ""] }] }] },
            { "name": "title", "candidates": [{ "from": { "json": "$.bookLabel.value" }, "pipe": [{ "regexReplace": ["^Q[0-9]+$", ""] }] }] },
            { "name": "year", "candidates": [{ "from": { "json": "$.year.value" }, "as": "int" }] },
            { "name": "url", "candidates": [{ "from": { "json": "$.article.value" }, "as": "url" }] }
          ],
          "identities": [{ "ns": "wikidata", "from": { "field": "externalId" } }]
        }
      ]
    },
    {
      "id": "lists.vangogh.paintings",
      "title": "Van Gogh: Paintings",
      "kind": "list",
      "seed": "https://query.wikidata.org/sparql?format=json&query=SELECT%20%3Fpainting%20%3FpaintingLabel%20%3Fyear%20%3Fimg%20WHERE%20%7B%20%3Fpainting%20wdt%3AP170%20wd%3AQ5582%\
20.%20%3Fpainting%20\
wdt%3AP31%20wd%3AQ3305213%20.%20%3Fpainting%20wdt%3AP18%20%3Fimg%20.%20OPTIONAL%20%7B%20%3Fpainting%20wdt%3AP571%20%3Fdate%20%7D%20SERVICE%20wikibase%3Alabel%20%7B%20bd%3AserviceParam%20\
wikibase%3Alanguage%20%22en%22%20%7D%20BIND%28YEAR%28%3Fdate%29%20AS%20%3Fyear%29%20%7D%20ORDER%20BY%20%3Fyear%20LIMIT%20150",
      "fetch": { "mode": "json", "ua": "mobileSafari" },
      "fields": [
        { "name": "title", "candidates": [{ "from": { "const": "Van Gogh: Paintings" } }] }
      ],
      "collections": [
        {
          "name": "entries",
          "from": { "json": "$.results.bindings[*]" },
          "kind": "artwork",
          "item": [
            { "name": "externalId", "candidates": [{ "from": { "json": "$.painting.value" }, "pipe": [{ "regexReplace": ["^.*/", ""] }] }] },
            { "name": "title", "candidates": [{ "from": { "json": "$.paintingLabel.value" }, "pipe": [{ "regexReplace": ["^Q[0-9]+$", ""] }] }] },
            { "name": "year", "candidates": [{ "from": { "json": "$.year.value" }, "as": "int" }] },
            { "name": "image", "candidates": [{ "from": { "json": "$.img.value" }, "pipe": [{ "regexReplace": ["^http://", "https://"] }], "as": "image" }] },
            { "name": "url", "candidates": [{ "from": { "json": "$.painting.value" }, "as": "url" }] }
          ],
          "identities": [{ "ns": "wikidata", "from": { "field": "externalId" } }]
        }
      ]
    }
"""
