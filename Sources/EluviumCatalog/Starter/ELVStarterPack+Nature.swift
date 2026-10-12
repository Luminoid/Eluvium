/// The nature chunk of the starter pack (2026-10-10): iNaturalist,
/// Merlin Bird ID, and All About Birds, plus the two export files that
/// carry a user's own sightings. Composition contract in
/// ELVStarterPack.swift (declaration order is behavior; chunks carry no
/// trailing comma).
///
/// iNaturalist pages sit behind a Cloudflare managed challenge for every
/// persona, so all three iNat sources read `api.inaturalist.org` instead:
/// v2 with an explicit `fields=` list (a v1 observation is ~1.2 MB, the v2
/// field set ~2 KB). The same numeric ids serve every network host
/// (inaturalist.ca, mexico.inaturalist.org, biodiversity4all.org, …), so
/// one host list covers them. An observation path also takes a UUID; the
/// two shapes route to their endpoints through `pathRegex`-gated steps (a
/// login under /observations/ is a list page and runs neither). A taxon
/// slug (`48662-Danaus-plexippus`) reaches the API through `text.digits`.
/// inat.user is an enrichment composite: the profile lookup runs the
/// source ladder and the latest-observations call is step-scoped, so its
/// rows can never clobber the profile's fields. Full history is the
/// user's own export (inat.export), the sanctioned backfill; the API asks
/// for ≤60 requests a minute and no bulk paging, so the pack never walks
/// a user's whole list.
///
/// Merlin shares a species as `merlinbirds.org/species/{eBird code}`;
/// sightings and Sound ID recordings have no link and no export of their
/// own (saved birds land in the user's eBird account, whose Download My
/// Data CSV is ebird.mydata). eBird species links carry the same code but
/// ebird.org sits behind an Anubis proof-of-work wall with
/// `Disallow: /`, so merlin.species claims both hosts and fetches the
/// Merlin page; its first song is a Macaulay Library asset served from the
/// open media CDN. All About Birds answers URLSession (curl's TLS
/// fingerprint is refused) and prints the eBird code through its Birds of
/// the World link, so both bird sources declare `ebird.species` and link.
/// Only its overview tab carries the species block (scientific name,
/// family, the code), so every tab URL fetches /overview.
let starterNatureJSON = """
    {
      "id": "inat.observation",
      "title": "iNaturalist",
      "kind": "observation",
      "match": { "host": [
          "inaturalist.org", "inaturalist.ca", "inaturalist.nz", "inaturalist.se", "inaturalist.lu", "inaturalist.ala.org.au",
          "inaturalist.mma.gob.cl", "inaturalist.laji.fi", "biodiversity4all.org", "argentinat.org", "naturalista.mx", "naturalista.uy"
        ],
        "path": "/observations/:id", "priority": 100 },
      "fetch": { "mode": "composite", "steps": [
        { "mode": "json", "when": { "pathRegex": "^/observations/[0-9]+/?$" },
          "url": "https://api.inaturalist.org/v2/observations?id={param.id}&fields=id,uri,observed_on,time_observed_at,place_guess,location,geoprivacy,\
public_positional_accuracy,quality_grade,license_code,description,species_guess,user.login,user.name,taxon.id,taxon.name,taxon.rank,\
taxon.preferred_common_name,taxon.iconic_taxon_name,photos.id,photos.url,photos.attribution,photos.license_code" },
        { "mode": "json", "when": { "pathRegex": "^/observations/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-" },
          "url": "https://api.inaturalist.org/v2/observations/{param.id}?fields=id,uri,observed_on,time_observed_at,place_guess,location,geoprivacy,\
public_positional_accuracy,quality_grade,license_code,description,species_guess,user.login,user.name,taxon.id,taxon.name,taxon.rank,\
taxon.preferred_common_name,taxon.iconic_taxon_name,photos.id,photos.url,photos.attribution,photos.license_code" }
      ]},
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "json": "$.results[0].id" }, "as": "text" }] },
        { "name": "title", "candidates": [
          { "from": { "json": "$.results[0].taxon.preferred_common_name" } },
          { "from": { "json": "$.results[0].species_guess" } },
          { "from": { "json": "$.results[0].taxon.name" } }
        ]},
        { "name": "scientificName", "candidates": [{ "from": { "json": "$.results[0].taxon.name" } }] },
        { "name": "rank", "candidates": [{ "from": { "json": "$.results[0].taxon.rank" } }] },
        { "name": "iconicTaxon", "candidates": [{ "from": { "json": "$.results[0].taxon.iconic_taxon_name" } }] },
        { "name": "taxonId", "candidates": [{ "from": { "json": "$.results[0].taxon.id" }, "as": "text" }] },
        { "name": "observed", "candidates": [
          { "from": { "json": "$.results[0].time_observed_at" }, "as": "date" },
          { "from": { "json": "$.results[0].observed_on" }, "as": "date", "format": "yyyy-MM-dd" }
        ]},
        { "name": "geo", "candidates": [{ "from": { "json": "$.results[0].location" }, "as": "geo" }] },
        { "name": "positionalAccuracy", "candidates": [{ "from": { "json": "$.results[0].public_positional_accuracy" }, "as": "int" }] },
        { "name": "geoprivacy", "candidates": [{ "from": { "json": "$.results[0].geoprivacy" } }] },
        { "name": "place", "candidates": [{ "from": { "json": "$.results[0].place_guess" } }] },
        { "name": "observer", "candidates": [{ "from": { "json": "$.results[0].user.login" } }] },
        { "name": "observerName", "candidates": [{ "from": { "json": "$.results[0].user.name" } }] },
        { "name": "qualityGrade", "candidates": [{ "from": { "json": "$.results[0].quality_grade" } }] },
        { "name": "license", "candidates": [{ "from": { "json": "$.results[0].license_code" } }] },
        { "name": "summary", "candidates": [{ "from": { "json": "$.results[0].description" }, "pipe": ["trim"] }] },
        { "name": "image", "candidates": [{ "from": { "json": "$.results[0].photos[0].url" }, "pipe": [{ "regexReplace": ["/square\\\\.", "/large."] }], "as": "image" }] },
        { "name": "link", "candidates": [{ "from": { "json": "$.results[0].uri" }, "as": "url" }] }
      ],
      "collections": [
        {
          "name": "photos",
          "from": { "json": "$.results[0].photos[*]" },
          "kind": "photo",
          "item": [
            { "name": "externalId", "candidates": [{ "from": { "json": "$.id" }, "as": "text" }] },
            { "name": "image", "candidates": [{ "from": { "json": "$.url" }, "pipe": [{ "regexReplace": ["/square\\\\.", "/large."] }], "as": "image" }] },
            { "name": "attribution", "candidates": [{ "from": { "json": "$.attribution" } }] },
            { "name": "license", "candidates": [{ "from": { "json": "$.license_code" } }] }
          ]
        }
      ],
      "identities": [{ "ns": "inat.observation", "from": { "json": "$.results[0].id" } }],
      "examples": [
        { "input": "https://www.inaturalist.org/observations/13169483", "expect": { "kind": "observation", "nonEmpty": ["title", "geo", "image"] } },
        { "input": "https://www.inaturalist.org/observations/4b9a0338-12e3-4224-8b7c-f9c1b1a798f7", "expect": { "kind": "observation", "nonEmpty": ["title", "externalId"] } },
        { "input": "https://www.inaturalist.org/observations/5890862", "expect": { "kind": "observation", "nonEmpty": ["title", "image"] } },
        { "input": "https://www.inaturalist.ca/observations/141610425", "expect": { "kind": "observation", "nonEmpty": ["title"] } }
      ]
    },
    {
      "id": "inat.taxon",
      "title": "iNaturalist taxa",
      "kind": "taxon",
      "match": { "host": [
          "inaturalist.org", "inaturalist.ca", "inaturalist.nz", "inaturalist.se", "inaturalist.lu", "inaturalist.ala.org.au",
          "inaturalist.mma.gob.cl", "inaturalist.laji.fi", "biodiversity4all.org", "argentinat.org", "naturalista.mx", "naturalista.uy"
        ],
        "path": "/taxa/:slug", "priority": 100 },
      "fetch": { "mode": "json",
        "url": "https://api.inaturalist.org/v2/taxa/{native:text.digits@1(param.slug)}?fields=id,name,rank,preferred_common_name,iconic_taxon_name,\
observations_count,wikipedia_summary,wikipedia_url,default_photo.medium_url,default_photo.attribution,conservation_status.status,\
ancestors.id,ancestors.name,ancestors.rank,ancestors.preferred_common_name" },
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "json": "$.results[0].id" }, "as": "text" }] },
        { "name": "title", "candidates": [
          { "from": { "json": "$.results[0].preferred_common_name" } },
          { "from": { "json": "$.results[0].name" } }
        ]},
        { "name": "scientificName", "candidates": [{ "from": { "json": "$.results[0].name" } }] },
        { "name": "rank", "candidates": [{ "from": { "json": "$.results[0].rank" } }] },
        { "name": "iconicTaxon", "candidates": [{ "from": { "json": "$.results[0].iconic_taxon_name" } }] },
        { "name": "observationsCount", "candidates": [{ "from": { "json": "$.results[0].observations_count" }, "as": "int" }] },
        { "name": "conservationStatus", "candidates": [{ "from": { "json": "$.results[0].conservation_status.status" } }] },
        { "name": "summary", "candidates": [{ "from": { "json": "$.results[0].wikipedia_summary" },
          "pipe": [{ "regexReplace": ["<[^>]+>", ""] }, "decodeEntities", "collapseWhitespace", "trim"] }] },
        { "name": "image", "candidates": [{ "from": { "json": "$.results[0].default_photo.medium_url" }, "pipe": [{ "regexReplace": ["/medium\\\\.", "/large."] }], "as": "image" }] },
        { "name": "imageAttribution", "candidates": [{ "from": { "json": "$.results[0].default_photo.attribution" } }] },
        { "name": "wikipedia", "candidates": [{ "from": { "json": "$.results[0].wikipedia_url" }, "pipe": [{ "regexReplace": [" ", "_"] }], "as": "url" }] }
      ],
      "collections": [
        {
          "name": "ancestors",
          "from": { "json": "$.results[0].ancestors[*]" },
          "kind": "taxon",
          "item": [
            { "name": "externalId", "candidates": [{ "from": { "json": "$.id" }, "as": "text" }] },
            { "name": "title", "candidates": [
              { "from": { "json": "$.preferred_common_name" } },
              { "from": { "json": "$.name" } }
            ]},
            { "name": "scientificName", "candidates": [{ "from": { "json": "$.name" } }] },
            { "name": "rank", "candidates": [{ "from": { "json": "$.rank" } }] }
          ],
          "identities": [{ "ns": "inat.taxon", "from": { "json": "$.id" } }]
        }
      ],
      "identities": [{ "ns": "inat.taxon", "from": { "json": "$.results[0].id" } }],
      "examples": [
        { "input": "https://www.inaturalist.org/taxa/48662-Danaus-plexippus",
          "expect": { "kind": "taxon", "nonEmpty": ["title", "scientificName", "image"], "nonEmptyCollections": ["ancestors"] } },
        { "input": "https://www.inaturalist.org/taxa/47219-Apis-mellifera", "expect": { "kind": "taxon", "nonEmpty": ["title", "summary"], "nonEmptyCollections": ["ancestors"] } },
        { "input": "https://www.inaturalist.org/taxa/3017", "expect": { "kind": "taxon", "nonEmpty": ["title"] } },
        { "input": "https://mexico.inaturalist.org/taxa/41641-Ursus-arctos", "expect": { "kind": "taxon", "nonEmpty": ["title"] } }
      ]
    },
    {
      "id": "inat.user",
      "title": "iNaturalist people",
      "kind": "profile",
      "match": { "host": [
          "inaturalist.org", "inaturalist.ca", "inaturalist.nz", "inaturalist.se", "inaturalist.lu", "inaturalist.ala.org.au",
          "inaturalist.mma.gob.cl", "inaturalist.laji.fi", "biodiversity4all.org", "argentinat.org", "naturalista.mx", "naturalista.uy"
        ],
        "path": ["/people/:login", "/users/:login"], "priority": 100 },
      "fetch": { "mode": "composite", "steps": [
        { "mode": "json", "url": "https://api.inaturalist.org/v2/users/{param.login}?fields=id,login,name,icon_url,observations_count,species_count,identifications_count,created_at" },
        { "mode": "json",
          "url": "https://api.inaturalist.org/v2/observations?user_id={param.login}&per_page=30&order_by=id&order=desc&fields=id,uri,observed_on,place_guess,\
location,species_guess,quality_grade,taxon.id,taxon.name,taxon.preferred_common_name,photos.url",
          "fields": [],
          "collections": [
            {
              "name": "observations",
              "from": { "json": "$.results[*]" },
              "kind": "observation",
              "item": [
                { "name": "externalId", "candidates": [{ "from": { "json": "$.id" }, "as": "text" }] },
                { "name": "title", "candidates": [
                  { "from": { "json": "$.taxon.preferred_common_name" } },
                  { "from": { "json": "$.species_guess" } },
                  { "from": { "json": "$.taxon.name" } }
                ]},
                { "name": "scientificName", "candidates": [{ "from": { "json": "$.taxon.name" } }] },
                { "name": "observed", "candidates": [{ "from": { "json": "$.observed_on" }, "as": "date", "format": "yyyy-MM-dd" }] },
                { "name": "place", "candidates": [{ "from": { "json": "$.place_guess" } }] },
                { "name": "geo", "candidates": [{ "from": { "json": "$.location" }, "as": "geo" }] },
                { "name": "qualityGrade", "candidates": [{ "from": { "json": "$.quality_grade" } }] },
                { "name": "image", "candidates": [{ "from": { "json": "$.photos[0].url" }, "pipe": [{ "regexReplace": ["/square\\\\.", "/medium."] }], "as": "image" }] },
                { "name": "link", "candidates": [{ "from": { "json": "$.uri" }, "as": "url" }] }
              ],
              "identities": [{ "ns": "inat.observation", "from": { "json": "$.id" } }]
            }
          ]}
      ]},
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "json": "$.results[0].id" }, "as": "text" }] },
        { "name": "title", "candidates": [
          { "from": { "json": "$.results[0].name" } },
          { "from": { "json": "$.results[0].login" } }
        ]},
        { "name": "handle", "candidates": [{ "from": { "json": "$.results[0].login" } }] },
        { "name": "image", "candidates": [{ "from": { "json": "$.results[0].icon_url" }, "as": "image" }] },
        { "name": "observationsCount", "candidates": [{ "from": { "json": "$.results[0].observations_count" }, "as": "int" }] },
        { "name": "speciesCount", "candidates": [{ "from": { "json": "$.results[0].species_count" }, "as": "int" }] },
        { "name": "identificationsCount", "candidates": [{ "from": { "json": "$.results[0].identifications_count" }, "as": "int" }] },
        { "name": "joined", "candidates": [{ "from": { "json": "$.results[0].created_at" }, "as": "date" }] }
      ],
      "identities": [{ "ns": "inat.user", "from": { "json": "$.results[0].id" } }],
      "examples": [
        { "input": "https://www.inaturalist.org/people/kueda", "expect": { "kind": "profile", "nonEmpty": ["title", "observationsCount"], "nonEmptyCollections": ["observations"] } },
        { "input": "https://www.inaturalist.org/people/loarie", "expect": { "kind": "profile", "nonEmpty": ["title"], "nonEmptyCollections": ["observations"] } }
      ]
    },
    {
      "id": "inat.export",
      "title": "iNaturalist export",
      "kind": "observation",
      "match": { "file": { "name": "*.csv", "probe": { "csvHeader": ["id", "observed_on", "quality_grade"] } } },
      "fetch": { "mode": "archive", "format": "csv" },
      "rows": [
        { "name": "externalId", "candidates": [{ "from": { "column": "id" } }] },
        { "name": "title", "candidates": [
          { "from": { "column": "common_name" } },
          { "from": { "column": "species_guess" } },
          { "from": { "column": "scientific_name" } }
        ]},
        { "name": "scientificName", "candidates": [{ "from": { "column": "scientific_name" } }] },
        { "name": "iconicTaxon", "candidates": [{ "from": { "column": "iconic_taxon_name" } }] },
        { "name": "taxonId", "candidates": [{ "from": { "column": "taxon_id" } }] },
        { "name": "observed", "candidates": [
          { "from": { "column": "time_observed_at" }, "as": "date" },
          { "from": { "column": "observed_on" }, "as": "date", "format": "yyyy-MM-dd" }
        ]},
        { "name": "latitude", "candidates": [{ "from": { "column": "latitude" }, "as": "double" }] },
        { "name": "longitude", "candidates": [{ "from": { "column": "longitude" }, "as": "double" }] },
        { "name": "place", "candidates": [{ "from": { "column": "place_guess" } }] },
        { "name": "observer", "candidates": [{ "from": { "column": "user_login" } }] },
        { "name": "qualityGrade", "candidates": [{ "from": { "column": "quality_grade" } }] },
        { "name": "license", "candidates": [{ "from": { "column": "license" } }] },
        { "name": "summary", "candidates": [{ "from": { "column": "description" } }] },
        { "name": "image", "candidates": [{ "from": { "column": "image_url" }, "as": "image" }] },
        { "name": "link", "candidates": [{ "from": { "column": "url" }, "as": "url" }] }
      ],
      "identities": [{ "ns": "inat.observation", "from": { "column": "id" } }]
    },
    {
      "id": "merlin.species",
      "title": "Merlin Bird ID",
      "kind": "species",
      "match": { "host": ["merlinbirds.org", "ebird.org"], "path": ["/species/:code", "/species/:code/:region"], "priority": 100 },
      "fetch": { "mode": "http", "ua": "mobileSafari", "url": "https://merlinbirds.org/species/{param.code}" },
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlParam": "code" }, "pipe": ["lower"] }] },
        { "name": "title", "candidates": [{ "from": { "meta": "og:title" }, "pipe": [{ "stripPrefix": "Check out this bird - " }, "decodeEntities", "trim"] }] },
        { "name": "scientificName", "candidates": [{ "from": { "textRegex": "<div class=\\"sciName\\"[^>]*>([^<]+)<" }, "pipe": ["decodeEntities", "trim"] }] },
        { "name": "image", "candidates": [{ "from": { "meta": "og:image" }, "pipe": ["resolveURL"], "as": "image" }] },
        { "name": "audio", "candidates": [{ "from": { "textRegex": "\\"audio\\",([0-9]+)," },
          "pipe": [{ "regexReplace": ["^([0-9]+)$", "https://cdn.download.ams.birds.cornell.edu/api/v1/asset/$1/mp3"] }], "as": "audio" }] }
      ],
      "identities": [{ "ns": "ebird.species", "from": { "urlParam": "code" } }],
      "examples": [
        { "input": "https://merlinbirds.org/species/norcar", "expect": { "kind": "species", "nonEmpty": ["title", "scientificName", "audio"] } },
        { "input": "https://merlinbirds.org/species/amerob", "expect": { "kind": "species", "nonEmpty": ["title", "image"] } },
        { "input": "https://ebird.org/species/comrav", "expect": { "kind": "species", "nonEmpty": ["title", "scientificName"] } },
        { "input": "https://ebird.org/species/sonspa/US-NY", "expect": { "kind": "species", "nonEmpty": ["title"] } }
      ]
    },
    {
      "id": "allaboutbirds.guide",
      "title": "All About Birds",
      "kind": "species",
      "match": { "host": ["allaboutbirds.org"], "path": ["/guide/:name", "/guide/:name/:tab"], "priority": 100 },
      "fetch": { "mode": "http", "ua": "mobileSafari", "url": "https://www.allaboutbirds.org/guide/{param.name}/overview" },
      "fields": [
        { "name": "externalId", "candidates": [
          { "from": { "textRegex": "<link rel=\\"canonical\\" href=\\"https://www\\\\.allaboutbirds\\\\.org/guide/([^/\\"?#]+)" } },
          { "from": { "urlParam": "name" } }
        ]},
        { "name": "title", "candidates": [
          { "from": { "textRegex": "<div class=\\"species-info\\"><span class=\\"species-name\\">([^<]+)</span>" }, "pipe": ["decodeEntities", "trim"] },
          { "from": { "meta": "og:title" },
            "pipe": [{ "regexReplace": ["^(.*?) (?:Overview|Identification|Sounds|Life History|Range Map|Species Compare), All About Birds.*$", "$1"] }, "decodeEntities", "trim"] }
        ]},
        { "name": "scientificName", "candidates": [
          { "from": { "textRegex": "<div class=\\"species-info\\"><span class=\\"species-name\\">[^<]*</span><em>([^<]+)</em>" }, "pipe": ["decodeEntities", "trim"] }
        ]},
        { "name": "family", "candidates": [{ "from": { "textRegex": "FAMILY:</span>\\\\s*([^<]+)</li>" }, "pipe": ["decodeEntities", "trim"] }] },
        { "name": "order", "candidates": [{ "from": { "textRegex": "ORDER:</span>\\\\s*([^<]+)</li>" }, "pipe": ["decodeEntities", "trim"] }] },
        { "name": "summary", "candidates": [
          { "from": { "meta": "og:description" }, "pipe": ["decodeEntities", "trim"] },
          { "from": { "meta": "description" }, "pipe": ["decodeEntities", "trim"] }
        ]},
        { "name": "image", "candidates": [{ "from": { "meta": "og:image" }, "pipe": ["resolveURL"], "as": "image" }] },
        { "name": "audio", "candidates": [
          { "from": { "textRegex": "class=\\"jp-jplayer[^\\"]*\\"[^>]*\\\\sname=\\"([^\\"]+\\\\.mp3)\\"" }, "pipe": ["resolveURL"], "as": "audio" }
        ]},
        { "name": "ebirdCode", "candidates": [{ "from": { "textRegex": "birdsoftheworld\\\\.org/bow/species/([a-z0-9]+)/" } }] }
      ],
      "identities": [
        { "ns": "ebird.species", "from": { "textRegex": "birdsoftheworld\\\\.org/bow/species/([a-z0-9]+)/" } }
      ],
      "examples": [
        { "input": "https://www.allaboutbirds.org/guide/Northern_Cardinal/overview", "expect": { "kind": "species", "nonEmpty": ["title", "scientificName", "audio"] } },
        { "input": "https://www.allaboutbirds.org/guide/American_Robin/sounds", "expect": { "kind": "species", "nonEmpty": ["title", "ebirdCode"] } },
        { "input": "https://www.allaboutbirds.org/guide/Common_Raven", "expect": { "kind": "species", "nonEmpty": ["title", "image"] } },
        { "input": "https://www.allaboutbirds.org/guide/Black-capped_Chickadee/id", "expect": { "kind": "species", "nonEmpty": ["title"] } }
      ]
    },
    {
      "id": "ebird.mydata",
      "title": "eBird data download",
      "kind": "observation",
      "match": { "file": { "name": "*.csv", "probe": { "csvHeader": ["Submission ID", "Common Name", "Scientific Name"] } } },
      "fetch": { "mode": "archive", "format": "csv" },
      "rows": [
        { "name": "checklist", "candidates": [{ "from": { "column": "Submission ID" } }] },
        { "name": "scientificName", "candidates": [{ "from": { "column": "Scientific Name" } }] },
        { "name": "externalId", "candidates": [{ "from": { "native": "text.join@1", "input": { "part1": "$field.checklist", "part2": "$field.scientificName" } } }] },
        { "name": "title", "candidates": [{ "from": { "column": "Common Name" } }] },
        { "name": "count", "candidates": [{ "from": { "column": "Count" } }] },
        { "name": "observed", "candidates": [{ "from": { "column": "Date" }, "as": "date", "format": "yyyy-MM-dd" }] },
        { "name": "time", "candidates": [{ "from": { "column": "Time" } }] },
        { "name": "location", "candidates": [{ "from": { "column": "Location" } }] },
        { "name": "region", "candidates": [{ "from": { "column": "State/Province" } }] },
        { "name": "latitude", "candidates": [{ "from": { "column": "Latitude" }, "as": "double" }] },
        { "name": "longitude", "candidates": [{ "from": { "column": "Longitude" }, "as": "double" }] },
        { "name": "protocol", "candidates": [{ "from": { "column": "Protocol" } }] },
        { "name": "notes", "candidates": [{ "from": { "column": "Observation Details" } }] },
        { "name": "mediaIds", "candidates": [{ "from": { "column": "ML Catalog Numbers" } }] }
      ]
    }
"""
