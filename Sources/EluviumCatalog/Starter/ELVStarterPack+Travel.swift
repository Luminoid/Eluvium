/// The travel + maps chunks of the starter pack: short-link redirector,
/// Google/Apple Maps, trails, flights, the lodging family, reviews, and
/// tours. Composition contract in ELVStarterPack.swift (declaration order
/// is behavior; chunks carry no trailing comma).
///
/// The 2026-08-21 revision folds in the TripDays `siteProviders` table:
/// URL-only `none` sources for Apple Maps
/// (the bare `maps.apple` short host stays with the redirector, which wins
/// the priority-90 tie by declaration order), the lodging family (Booking /
/// Airbnb / Vrbo / Agoda / Expedia / Hostelworld / Hotels.com — stay dates
/// from the query where TripDays reads them, per-brand `lodgingType`;
/// 2026-08-30: Airbnb and Hostelworld upgraded to `http(desktopSafari)` +
/// `ogCore` — both serve full server-rendered OG to that persona, so
/// title/image/summary land without a browser; Vrbo stays URL-only because
/// its wall 429s every curl persona and three of its four corpus ids are
/// delisted properties redirecting to walled region landings),
/// Tripadvisor (authors NO kind: the path marker rides a `category` field
/// into the inference tables, host prior = attraction), Yelp, the
/// three tour marketplaces, one 16-host car-rental source (per-host labels
/// via host-anchored urlRegex candidates), and the flight trackers (URL
/// designator, never fetched). Komoot and Xiaohongshu fetch http(crawler)
/// with a dom escalation like AllTrails. The xhslink.com / xhslink.cn
/// short hosts rode this redirector until 2026-10-11; they are
/// `shortlinks.media` in the Xiaohongshu chunk now, so a media-only
/// curation keeps its own expander (a family's expander lives in its
/// family). Booking's `/Share-…` short link is deliberately NOT a redirector row:
/// match paths are segment-literal (no in-segment prefix), so a `/Share-`
/// scope is inexpressible and a broader claim would swallow real booking
/// pages — those links fall to the OpenGraph floor.
///
/// The second 2026-08-21 pass wires the remaining native ops end to end:
/// `gmaps.place` becomes a `none` → http(crawler) composite (escalating
/// only when the URL yields no name) whose page metas run through
/// `maps.classifyMetaSegments@1` and `place.littleEndianLabel@1` into
/// name / locality / address / placeType / category / rating —
/// `gmaps.share`'s dom fallback gets the same block. `gmaps.place.mapkit`
/// shadows `gmaps.place` at priority 110 behind
/// `requires: [native:place.mapKitLookup@1, native:geo.anchorLadder@1]`,
/// adding MapKit-served address / phone / category / refined geo through
/// the pipeline's awaited field extraction — a binary without EluviumPlaces
/// skips the shadow and lands on plain `gmaps.place`, so the pack loads
/// everywhere and never half-works. The classify `category` output stays a
/// plain field here (no `inference` block): these sources author their
/// kind, and a table that can never run is dead weight the validator would
/// flag.
///
/// The 2026-09-10 audit pass. The Maps trio shares the `gmapsMetas`
/// fragment (metaName / title / locality / address / placeType / category /
/// rating, copied verbatim three times before). `gmaps.place.mapkit`
/// uses it too but keeps two groups inline, because `use` appends fragment
/// fields after the source's own and fields evaluate in declaration order:
/// `metaName` + `title` must stay declared ahead of the MapKit-input fields
/// that read `$field.title`, and `locality` / `address` / `category` must
/// keep their meta candidates ahead of the MapKit ones (in the fragment
/// they would land after). The fragment's copies of those five merge in as
/// duplicate trailing candidates — inert, since a candidate that already
/// failed fails again. AllTrails and Komoot share `trailStats` for the
/// `trail.statsFromText@2` trio. Komoot authors `trail` now: a Komoot tour
/// is a route like an AllTrails trail, and `hike` was a TripDays-era label
/// no other source used. Lodging: `lodgingDates` rides all seven sources
/// (Hotels.com's `chkin`/`chkout` joined the fragment; Hostelworld's
/// `from`/`to` stay inline on that source alone — generic names that mean
/// other things on other hosts, so they never enter the shared ladder even
/// though the yyyy-MM-dd coercion would reject most non-dates), Airbnb's
/// lodgingType is `rental` (a type, like Vrbo's; the brand is the source
/// id), and every lodging / tour / review source with a stable id declares
/// an identity in its own namespace (booking.hotel, airbnb.listing,
/// vrbo.property, expedia.hotel, hostelworld.property, hotels.hotel,
/// gyg.tour, viator.product, klook.activity, tripadvisor.location,
/// yelp.business) mirroring its externalId selector. Booking's identity is
/// the pipe-free urlRegex equivalent of its slug-strip, since identity
/// specs carry no pipe; Hostelworld declares one spec per URL shape (the
/// assembler drops the one that misses). agoda.lodging has no externalId
/// and so no identity: its `/<slug>/hotel/<city>.html` paths carry no id,
/// and the slug is a locale-variant label, not a key. yelp.review authors
/// a fixed `food` kind: `/biz/:slug` URLs carry no category to infer from,
/// and restaurants are the overwhelming Yelp paste (TripDays parity).
///
/// The 2026-10-10 audit. The URL ops are `maps.splitPlaceLabel@1` and
/// `maps.pinCoordinate@1` (they parse Apple Maps URLs too, so the `gmaps.`
/// prefix went), and the metas fragment's aggregate rating is a typed
/// `rating` like every other source's. A `/maps/place/` URL rarely carries
/// `ftid`, so gmaps.place read its id from the URL hash, which includes
/// `@lat,lng,zoom` and re-keyed the same place at every zoom: the external
/// id now reads the `!1s0x…:0x…` feature id from the `data=` blob first,
/// and the Google trio declares it as `gmaps.feature` (Apple Maps declares
/// its `place-id`, Komoot its tour id). Airbnb's identity reads `/rooms/`
/// ids only: a `/properties/` id is a different id space (the property
/// page 302s to a different `/rooms/` id, which the fetched record's final
/// URL then carries), so mixing the two would merge unrelated listings.
/// Expedia matches by `brand` like the other lodging marketplaces instead
/// of four hand-listed TLDs. AllTrails rides `ogCore` for its summary and
/// image; its title ladder stays inline (the og:title strip and the slug
/// fallback, after which the fragment's raw og:title is inert). Komoot
/// stays off `ogCore` entirely: the fragment would append `twitter:title`
/// and `<title>` after the JSON-LD name, and a shell page's generic
/// `<title>` would then satisfy `blockedOrThin` and stop the dom
/// escalation its `missingAny: [title]` exists for.
let starterTravelMapsJSON = """
    {
      "id": "shortlinks.travel",
      "title": "Travel short links",
      "kind": "link",
      "match": { "host": ["maps.app.goo.gl", "goo.gl", "g.co", "maps.apple", "yelp.to", "abnb.me", "gyg.me"], "path": "/**", "priority": 90 },
      "resolvesVia": "shortlink.expand",
      "requires": ["native:shortlink.expand@1"],
      "examples": [
        { "input": "https://maps.app.goo.gl/372N2pn6HcSTEA4w6", "expect": { "kind": "place", "nonEmpty": ["title"] } },
        { "input": "https://maps.app.goo.gl/Q2YzQehRD1hTZJRA6?g_st=ic", "expect": { "kind": "place", "nonEmpty": ["title"] } },
        { "input": "https://maps.app.goo.gl/n4iYsKAYcxnpNxjG8", "expect": { "kind": "place", "nonEmpty": ["title"] } }
      ]
    },
    {
      "id": "gmaps.place",
      "title": "Google Maps",
      "kind": "place",
      "match": { "host": ["google.com", "maps.google.com"], "path": "/maps/**", "priority": 100 },
      "use": ["gmapsMetas"],
      "fetch": { "mode": "composite", "steps": [
        { "mode": "none" },
        { "mode": "http", "ua": "crawler", "when": { "missingAny": ["title"] } }
      ]},
      "fields": [
        { "name": "externalId", "candidates": [
          { "from": { "urlRegex": "!1s(0x[0-9a-f]+:0x[0-9a-f]+)" } },
          { "from": { "urlQuery": "ftid" } }
        ]},
        { "name": "geo", "candidates": [{ "from": { "native": "maps.pinCoordinate@1" }, "select": "geo" }] },
        { "name": "viewport", "candidates": [{ "from": { "native": "maps.pinCoordinate@1" }, "select": "viewportGeo" }] }
      ],
      "identities": [
        { "ns": "gmaps.feature", "from": { "urlRegex": "!1s(0x[0-9a-f]+:0x[0-9a-f]+)" } },
        { "ns": "gmaps.feature", "from": { "urlQuery": "ftid" } }
      ],
      "requires": ["native:maps.pinCoordinate@1", "native:maps.splitPlaceLabel@1", "native:maps.classifyMetaSegments@1", "native:place.littleEndianLabel@1"],
      "examples": [
        { "input": "https://www.google.com/maps/place/Jenny+Lake/@43.7904,-110.7624,15z/data=!8m2!3d43.7904!4d-110.7624", "expect": { "kind": "place", "nonEmpty": ["title", "geo"] } },
        { "input": "https://www.google.com/maps/place/Golden+Gate+Bridge/@37.8199286,-122.4782551,17z/data=!8m2!3d37.8199286!4d-122.4782551",
          "expect": { "kind": "place", "nonEmpty": ["title", "geo"] } }
      ]
    },
    {
      "id": "gmaps.place.mapkit",
      "title": "Google Maps",
      "kind": "place",
      "match": { "host": ["google.com", "maps.google.com"], "path": "/maps/**", "priority": 110 },
      "use": ["gmapsMetas"],
      "fetch": { "mode": "composite", "steps": [
        { "mode": "none" },
        { "mode": "http", "ua": "crawler", "when": { "missingAny": ["title"] } }
      ]},
      "fields": [
        { "name": "externalId", "candidates": [
          { "from": { "urlRegex": "!1s(0x[0-9a-f]+:0x[0-9a-f]+)" } },
          { "from": { "urlQuery": "ftid" } }
        ]},
        { "name": "metaName", "candidates": [{ "from": { "native": "maps.classifyMetaSegments@1" }, "select": "name" }] },
        { "name": "title", "candidates": [
          { "from": { "native": "maps.splitPlaceLabel@1" }, "select": "name" },
          { "from": { "native": "place.littleEndianLabel@1", "input": { "label": "$field.metaName" } }, "select": "label",
            "pipe": [{ "split": "," }, "first", "trim"] }
        ]},
        { "name": "pinLat", "candidates": [{ "from": { "native": "maps.pinCoordinate@1" }, "select": "lat" }] },
        { "name": "pinLng", "candidates": [{ "from": { "native": "maps.pinCoordinate@1" }, "select": "lng" }] },
        { "name": "viewportLat", "candidates": [{ "from": { "native": "maps.pinCoordinate@1" }, "select": "viewportLat" }] },
        { "name": "viewportLng", "candidates": [{ "from": { "native": "maps.pinCoordinate@1" }, "select": "viewportLng" }] },
        { "name": "locality", "candidates": [
          { "from": { "native": "maps.splitPlaceLabel@1" }, "select": "locality" },
          { "from": { "native": "maps.classifyMetaSegments@1" }, "select": "locality" },
          { "from": { "native": "place.mapKitLookup@1", "input": { "name": "$field.title", "urlLat": "$field.pinLat", "urlLng": "$field.pinLng" } },
            "select": "locality" },
          { "from": { "native": "place.mapKitLookup@1", "input": { "name": "$field.title", "viewportLat": "$field.viewportLat", "viewportLng": "$field.viewportLng" } },
            "select": "locality" }
        ]},
        { "name": "address", "candidates": [
          { "from": { "native": "maps.classifyMetaSegments@1" }, "select": "address" },
          { "from": { "native": "place.mapKitLookup@1", "input": { "name": "$field.title", "urlLat": "$field.pinLat", "urlLng": "$field.pinLng" } },
            "select": "address" },
          { "from": { "native": "place.mapKitLookup@1", "input": { "name": "$field.title", "viewportLat": "$field.viewportLat", "viewportLng": "$field.viewportLng" } },
            "select": "address" }
        ]},
        { "name": "phone", "candidates": [
          { "from": { "native": "place.mapKitLookup@1", "input": { "name": "$field.title", "urlLat": "$field.pinLat", "urlLng": "$field.pinLng" } },
            "select": "phone" },
          { "from": { "native": "place.mapKitLookup@1", "input": { "name": "$field.title", "viewportLat": "$field.viewportLat", "viewportLng": "$field.viewportLng" } },
            "select": "phone" }
        ]},
        { "name": "category", "candidates": [
          { "from": { "native": "maps.classifyMetaSegments@1" }, "select": "category" },
          { "from": { "native": "place.mapKitLookup@1", "input": { "name": "$field.title", "urlLat": "$field.pinLat", "urlLng": "$field.pinLng" } },
            "select": "category" }
        ]},
        { "name": "geo", "candidates": [
          { "from": { "native": "place.mapKitLookup@1", "input": { "name": "$field.title", "urlLat": "$field.pinLat", "urlLng": "$field.pinLng" } },
            "select": "geo" },
          { "from": { "native": "geo.anchorLadder@1", "input": { "urlLat": "$field.pinLat", "urlLng": "$field.pinLng" } }, "select": "geo" }
        ]},
        { "name": "viewport", "candidates": [{ "from": { "native": "maps.pinCoordinate@1" }, "select": "viewportGeo" }] }
      ],
      "identities": [
        { "ns": "gmaps.feature", "from": { "urlRegex": "!1s(0x[0-9a-f]+:0x[0-9a-f]+)" } },
        { "ns": "gmaps.feature", "from": { "urlQuery": "ftid" } }
      ],
      "requires": [
        "native:maps.pinCoordinate@1", "native:maps.splitPlaceLabel@1", "native:maps.classifyMetaSegments@1",
        "native:place.littleEndianLabel@1", "native:place.mapKitLookup@1", "native:geo.anchorLadder@1"
      ],
      "examples": [
        { "input": "https://www.google.com/maps/place/Jenny+Lake/@43.7904,-110.7624,15z/data=!8m2!3d43.7904!4d-110.7624", "expect": { "kind": "place", "nonEmpty": ["title", "geo"] } },
        { "input": "https://www.google.com/maps/place/Golden+Gate+Bridge/@37.8199286,-122.4782551,17z/data=!8m2!3d37.8199286!4d-122.4782551",
          "expect": { "kind": "place", "nonEmpty": ["title", "geo"] } }
      ]
    },
    {
      "id": "gmaps.share",
      "title": "Google Maps",
      "kind": "place",
      "match": { "host": ["maps.google.com"], "path": "/**", "priority": 95 },
      "use": ["gmapsMetas"],
      "fetch": { "mode": "dom", "ua": "desktopSafari",
        "settle": { "signals": ["h1", "og:title"], "pollSeconds": 1, "maxPolls": 20 },
        "captureCanonical": { "until": { "urlRegex": "/maps/place/.*!3d-?[0-9.]+!4d-?[0-9.]+" }, "maxPolls": 20 } },
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlQuery": "ftid" } }] },
        { "name": "geo", "candidates": [{ "from": { "native": "maps.pinCoordinate@1" }, "select": "geo" }] }
      ],
      "identities": [{ "ns": "gmaps.feature", "from": { "urlQuery": "ftid" } }],
      "requires": ["native:maps.pinCoordinate@1", "native:maps.splitPlaceLabel@1", "native:maps.classifyMetaSegments@1", "native:place.littleEndianLabel@1"],
      "examples": [
        { "input": "https://maps.google.com/?q=Grand+Prismatic", "expect": { "kind": "place", "nonEmpty": ["title"] } },
        { "input": "https://maps.google.com/?q=Grand+Prismatic+Spring+Overlook,+Yellowstone+National+Park,+WY",
          "expect": { "kind": "place", "nonEmpty": ["title", "locality"] } },
        { "input": "https://maps.google.com/?q=48.858,2.294", "expect": { "kind": "place", "nonEmpty": ["geo"] } }
      ]
    },
    {
      "id": "applemaps.place",
      "title": "Apple Maps",
      "kind": "place",
      "match": { "host": ["maps.apple.com", "maps.apple"], "path": "/**", "priority": 90 },
      "fetch": { "mode": "none" },
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlQuery": "place-id" } }] },
        { "name": "title", "candidates": [{ "from": { "native": "maps.splitPlaceLabel@1" }, "select": "name" }] },
        { "name": "locality", "candidates": [{ "from": { "native": "maps.splitPlaceLabel@1" }, "select": "locality" }] },
        { "name": "geo", "candidates": [
          { "from": { "native": "maps.pinCoordinate@1" }, "select": "geo" },
          { "from": { "native": "maps.pinCoordinate@1" }, "select": "viewportGeo" }
        ]}
      ],
      "identities": [{ "ns": "applemaps.place", "from": { "urlQuery": "place-id" } }],
      "requires": ["native:maps.pinCoordinate@1", "native:maps.splitPlaceLabel@1"],
      "examples": [
        { "input": "https://maps.apple.com/?q=Tokyo+Tower&ll=35.6586,139.7454", "expect": { "kind": "place", "nonEmpty": ["title", "geo"] } },
        { "input": "https://maps.apple.com/?q=Jenny+Lake,+Wyoming&sll=43.75,-110.72", "expect": { "kind": "place", "nonEmpty": ["title", "locality"] } },
        { "input": "https://maps.apple.com/?q=48.8584,2.2945", "expect": { "kind": "place", "nonEmpty": ["geo"] } },
        { "input": "https://maps.apple.com/?q=Golden+Gate+Bridge", "expect": { "kind": "place", "nonEmpty": ["title"] } }
      ]
    }
"""

let starterTrailsAndFlightsJSON = """
    {
      "id": "alltrails.trail",
      "title": "AllTrails",
      "kind": "trail",
      "match": { "host": ["alltrails.com"], "path": "/trail/:country/:region/:slug", "priority": 100 },
      "canonicalize": { "strip": ["utm_*", "sh", "ref"] },
      "use": ["trailStats", "ogCore"],
      "fetch": { "mode": "composite", "steps": [
        { "mode": "http", "ua": "crawler" },
        { "mode": "dom", "ua": "desktopSafari", "settle": { "signals": ["h1", "jsonld", "og:title"] }, "when": "blockedOrThin"}
      ]},
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlParam": "slug" } }] },
        { "name": "title", "candidates": [
          { "from": { "jsonld": "TouristAttraction.name" } },
          { "from": { "meta": "og:title" }, "pipe": [{ "stripSuffix": " | AllTrails" }] },
          { "from": { "urlParam": "slug" }, "pipe": ["slugToTitle"] }
        ]},
        { "name": "rating", "candidates": [{ "from": { "jsonld": "TouristAttraction.aggregateRating.ratingValue" }, "as": "rating" }] }
      ],
      "identities": [{ "ns": "alltrails.trail", "from": { "urlParam": "slug" } }],
      "requires": ["native:trail.statsFromText@2"],
      "examples": [
        { "input": "https://www.alltrails.com/trail/us/california/half-dome-via-the-john-muir-trail-jmt", "expect": { "kind": "trail", "nonEmpty": ["title"] } },
        { "input": "https://www.alltrails.com/trail/us/california/la-jolla-beach-trail?p=-1&utm_medium=trail_share&utm_source=alltrails_virality",
          "expect": { "kind": "trail", "nonEmpty": ["title"] } },
        { "input": "https://www.alltrails.com/trail/portugal/lisboa--6/praia-da-ursa-cabo-da-roca?p=-1&u=i&utm_medium=trail_share&utm_source=alltrails_virality",
          "expect": { "kind": "trail", "nonEmpty": ["title"] } }
      ]
    },
    {
      "id": "komoot.route",
      "title": "Komoot",
      "kind": "trail",
      "match": { "host": ["komoot.com", "komoot.de"], "path": "/**", "priority": 100 },
      "canonicalize": { "keep": ["share_token"] },
      "use": ["trailStats"],
      "fetch": { "mode": "composite", "steps": [
        { "mode": "http", "ua": "crawler" },
        { "mode": "dom", "ua": "desktopSafari", "settle": { "signals": ["h1", "og:title"] }, "when": "blockedOrThin"}
      ]},
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlRegex": "/tour/([0-9]+)" } }] },
        { "name": "title", "candidates": [
          { "from": { "meta": "og:title" }, "pipe": [{ "stripSuffix": " | Komoot" }] },
          { "from": { "jsonld": "*.name" } }
        ]},
        { "name": "summary", "candidates": [{ "from": { "meta": "og:description" } }] },
        { "name": "image", "candidates": [{ "from": { "meta": "og:image" }, "pipe": ["resolveURL"], "as": "image" }] }
      ],
      "identities": [{ "ns": "komoot.tour", "from": { "urlRegex": "/tour/([0-9]+)" } }],
      "requires": ["native:trail.statsFromText@2"],
      "examples": []
    },
    {
      "id": "flighty.flight",
      "title": "Flighty",
      "kind": "flight",
      "match": { "host": ["live.flighty.app"], "path": "/:shareId", "priority": 100 },
      "fetch": { "mode": "http", "ua": "crawler" },
      "fields": [
        { "name": "externalId", "candidates": [
          { "from": { "native": "flighty.flightFromPage@2" }, "select": "designator" },
          { "from": { "native": "flight.designatorFromURL@1" }, "select": "designator" },
          { "from": { "urlParam": "shareId" } }
        ]},
        { "name": "title", "candidates": [
          { "from": { "meta": "og:title" } },
          { "from": { "native": "flighty.flightFromPage@2" }, "select": "designator" }
        ]},
        { "name": "designator", "candidates": [{ "from": { "native": "flighty.flightFromPage@2" }, "select": "designator" }] },
        { "name": "departureIata", "candidates": [{ "from": { "native": "flighty.flightFromPage@2" }, "select": "departureIata" }] },
        { "name": "arrivalIata", "candidates": [{ "from": { "native": "flighty.flightFromPage@2" }, "select": "arrivalIata" }] },
        { "name": "departureAirport", "candidates": [{ "from": { "native": "flighty.flightFromPage@2" }, "select": "departureAirport" }] },
        { "name": "arrivalAirport", "candidates": [{ "from": { "native": "flighty.flightFromPage@2" }, "select": "arrivalAirport" }] },
        { "name": "departureTime", "candidates": [{ "from": { "native": "flighty.flightFromPage@2" }, "select": "departureTime" }] },
        { "name": "arrivalTime", "candidates": [{ "from": { "native": "flighty.flightFromPage@2" }, "select": "arrivalTime" }] },
        { "name": "gate", "candidates": [{ "from": { "native": "flighty.flightFromPage@2" }, "select": "gate" }] },
        { "name": "terminal", "candidates": [{ "from": { "native": "flighty.flightFromPage@2" }, "select": "terminal" }] },
        { "name": "airline", "candidates": [{ "from": { "native": "flighty.flightFromPage@2" }, "select": "airlineName" }] },
        { "name": "arrivalGeo", "candidates": [{ "from": { "native": "flighty.flightFromPage@2" }, "select": "arrivalGeo" }] },
        { "name": "formatDrift", "candidates": [{ "from": { "native": "flighty.flightFromPage@2" }, "select": "formatDrift" }] }
      ],
      "requires": ["native:flighty.flightFromPage@2"],
      "examples": [
        { "input": "https://live.flighty.app/522c14cd-5c6e-4858-b201-b9c117d8477a", "expect": { "kind": "flight", "nonEmpty": ["title", "designator"] } }
      ]
    },
    {
      "id": "flighttracker.flight",
      "title": "Flight tracker",
      "kind": "flight",
      "match": { "host": ["flightaware.com", "flightradar24.com", "fr24.com"], "path": "/**", "priority": 100 },
      "fetch": { "mode": "none" },
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "native": "flight.designatorFromURL@1" }, "select": "designator" }] },
        { "name": "title", "candidates": [{ "from": { "native": "flight.designatorFromURL@1" }, "select": "designator" }] },
        { "name": "designator", "candidates": [{ "from": { "native": "flight.designatorFromURL@1" }, "select": "designator" }] }
      ],
      "requires": ["native:flight.designatorFromURL@1"],
      "examples": [
        { "input": "https://www.flightaware.com/live/flight/UAL123", "expect": { "kind": "flight", "nonEmpty": ["title"] } },
        { "input": "https://www.flightradar24.com/data/flights/ua123", "expect": { "kind": "flight", "nonEmpty": ["title"] } },
        { "input": "https://fr24.com/UA123", "expect": { "kind": "flight", "nonEmpty": ["title"] } },
        { "input": "https://www.flightaware.com/live/flight/DAL2362", "expect": { "kind": "flight", "nonEmpty": ["title"] } },
        { "input": "https://www.flightradar24.com/data/flights/ba284", "expect": { "kind": "flight", "nonEmpty": ["title"] } }
      ]
    }
"""

let starterLodgingToursJSON = """
    {
      "id": "booking.lodging",
      "title": "Booking.com",
      "kind": "lodging",
      "match": { "host": ["booking.com"], "path": "/hotel/:country/:slug", "priority": 100 },
      "use": ["lodgingDates"],
      "fetch": { "mode": "none" },
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlParam": "slug" }, "pipe": [{ "regexReplace": ["\\\\..*$", ""] }] }] },
        { "name": "title", "candidates": [{ "from": { "urlParam": "slug" }, "pipe": [{ "regexReplace": ["\\\\..*$", ""] }, "slugToTitle"] }] },
        { "name": "lodgingType", "candidates": [{ "from": { "const": "hotel" } }] }
      ],
      "identities": [{ "ns": "booking.hotel", "from": { "urlRegex": "/hotel/[^/]+/([^/.?#]+)" } }],
      "examples": [
        { "input": "https://www.booking.com/hotel/jp/the-peninsula-tokyo.zh-cn.html", "expect": { "kind": "lodging", "nonEmpty": ["title"] } },
        { "input": "https://www.booking.com/hotel/sg/marina-bay-sands.html?checkin=2026-09-12&checkout=2026-09-15&group_adults=2",
          "expect": { "kind": "lodging", "nonEmpty": ["title", "checkIn"] } }
      ]
    },
    {
      "id": "airbnb.lodging",
      "title": "Airbnb",
      "kind": "lodging",
      "match": { "brand": ["airbnb"], "path": "/**", "priority": 100 },
      "use": ["lodgingDates", "ogCore"],
      "fetch": { "mode": "http", "ua": "desktopSafari" },
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlRegex": "/(?:rooms|properties)/([0-9]+)" } }] },
        { "name": "lodgingType", "candidates": [{ "from": { "const": "rental" } }] }
      ],
      "identities": [{ "ns": "airbnb.listing", "from": { "urlRegex": "/rooms/([0-9]+)" } }],
      "examples": [
        { "input": "https://www.airbnb.com/properties/1608222261053394311", "expect": { "kind": "lodging", "nonEmpty": ["lodgingType", "externalId", "title"] } },
        { "input": "https://www.airbnb.com/properties/1643493051103467076", "expect": { "kind": "lodging", "nonEmpty": ["lodgingType", "title"] } }
      ]
    },
    {
      "id": "vrbo.lodging",
      "title": "Vrbo",
      "kind": "lodging",
      "match": { "brand": ["vrbo"], "path": "/**", "priority": 100 },
      "use": ["lodgingDates"],
      "fetch": { "mode": "none" },
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlRegex": "/p?([0-9]{6,})" } }] },
        { "name": "lodgingType", "candidates": [{ "from": { "const": "rental" } }] }
      ],
      "identities": [{ "ns": "vrbo.property", "from": { "urlRegex": "/p?([0-9]{6,})" } }],
      "examples": [
        { "input": "https://www.vrbo.com/2716034", "expect": { "kind": "lodging", "nonEmpty": ["lodgingType"] } },
        { "input": "https://www.vrbo.com/en-ca/p3081098vb", "expect": { "kind": "lodging" } },
        { "input": "https://www.vrbo.com/8360330ha", "expect": { "kind": "lodging" } },
        { "input": "https://www.vrbo.com/705146", "expect": { "kind": "lodging" } }
      ]
    },
    {
      "id": "agoda.lodging",
      "title": "Agoda",
      "kind": "lodging",
      "match": { "brand": ["agoda"], "path": "/**", "priority": 100 },
      "use": ["lodgingDates"],
      "fetch": { "mode": "none" },
      "fields": [
        { "name": "title", "candidates": [
          { "from": { "urlRegex": "^[^?#]*/((?![a-z]{2}(?:-[a-z]{2})?/)[^/?#]+)/hotel(?:/|$)" }, "pipe": ["slugToTitle"] }
        ]},
        { "name": "lodgingType", "candidates": [{ "from": { "const": "hotel" } }] }
      ],
      "examples": [
        { "input": "https://www.agoda.com/hotel-zephyr/hotel/san-francisco-ca-us.html", "expect": { "kind": "lodging", "nonEmpty": ["title"] } },
        { "input": "https://www.agoda.com/the-okura-tokyo/hotel/tokyo-jp.html?checkIn=2026-09-12&los=2",
          "expect": { "kind": "lodging", "nonEmpty": ["title", "checkIn"] } }
      ]
    },
    {
      "id": "expedia.lodging",
      "title": "Expedia",
      "kind": "lodging",
      "match": { "brand": ["expedia"], "path": "/**", "priority": 100 },
      "use": ["lodgingDates"],
      "fetch": { "mode": "none" },
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlRegex": "^[^?#]*\\\\.h([0-9]+)" } }] },
        { "name": "title", "candidates": [
          { "from": { "urlRegex": "^[^?#]*/(?:[^/?#]*-[Hh]otels-)?([^/?#.]+)\\\\.h[0-9]+" }, "pipe": ["slugToTitle"] }
        ]},
        { "name": "lodgingType", "candidates": [{ "from": { "const": "hotel" } }] }
      ],
      "identities": [{ "ns": "expedia.hotel", "from": { "urlRegex": "^[^?#]*\\\\.h([0-9]+)" } }],
      "examples": [
        { "input": "https://www.expedia.com/Jackson-Hole-Hotels-Cowboy-Village-Resort.h894154.Hotel-Information",
          "expect": { "kind": "lodging", "nonEmpty": ["title"] } },
        { "input": "https://www.expedia.co.uk/London-Hotels-The-Savoy.h11689.Hotel-Information", "expect": { "kind": "lodging", "nonEmpty": ["title"] } }
      ]
    },
    {
      "id": "hostelworld.lodging",
      "title": "Hostelworld",
      "kind": "lodging",
      "match": { "brand": ["hostelworld"], "path": "/**", "priority": 100 },
      "use": ["lodgingDates", "ogCore"],
      "fetch": { "mode": "http", "ua": "desktopSafari" },
      "fields": [
        { "name": "externalId", "candidates": [
          { "from": { "urlRegex": "/hostels/p/([0-9]+)/" } },
          { "from": { "urlRegex": "/hosteldetails\\\\.php/[^/]+/[^/]+/([0-9]+)" } }
        ]},
        { "name": "checkIn", "candidates": [{ "from": { "urlQuery": "from" }, "as": "date", "format": "yyyy-MM-dd" }] },
        { "name": "checkOut", "candidates": [{ "from": { "urlQuery": "to" }, "as": "date", "format": "yyyy-MM-dd" }] },
        { "name": "lodgingType", "candidates": [{ "from": { "const": "hostel" } }] }
      ],
      "identities": [
        { "ns": "hostelworld.property", "from": { "urlRegex": "/hostels/p/([0-9]+)/" } },
        { "ns": "hostelworld.property", "from": { "urlRegex": "/hosteldetails\\\\.php/[^/]+/[^/]+/([0-9]+)" } }
      ],
      "examples": [
        { "input": "https://www.hostelworld.com/hostels/p/265063/generator-amsterdam/",
          "expect": { "kind": "lodging", "nonEmpty": ["lodgingType", "externalId", "title"] } },
        { "input": "https://www.hostelworld.com/hostels/p/48034/generator-copenhagen/",
          "expect": { "kind": "lodging", "nonEmpty": ["lodgingType", "externalId", "title"] } },
        { "input": "https://www.hostelworld.com/pwa/hosteldetails.php/Colonnato-di-San-Pietro-B-B/Rome/3552",
          "expect": { "kind": "lodging", "nonEmpty": ["lodgingType", "externalId", "title"] } },
        { "input": "https://www.hostelworld.com/hostels/europe/italy/rome/", "expect": { "kind": "lodging", "nonEmpty": ["lodgingType", "title"] } }
      ]
    },
    {
      "id": "hotels.lodging",
      "title": "Hotels.com",
      "kind": "lodging",
      "match": { "host": ["hotels.com"], "path": "/**", "priority": 100 },
      "use": ["lodgingDates"],
      "fetch": { "mode": "none" },
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlRegex": "^[^?#]*/ho([0-9]+)(?:[/?#]|$)" } }] },
        { "name": "title", "candidates": [{ "from": { "urlRegex": "^[^?#]*/ho[0-9]+/([^/?#]+)(?:[/?#]|$)" }, "pipe": ["slugToTitle"] }] },
        { "name": "lodgingType", "candidates": [{ "from": { "const": "hotel" } }] }
      ],
      "identities": [{ "ns": "hotels.hotel", "from": { "urlRegex": "^[^?#]*/ho([0-9]+)(?:[/?#]|$)" } }],
      "examples": [
        { "input": "https://www.hotels.com/ho276485/hotel-zephyr-san-francisco-san-francisco-united-states-of-america/",
          "expect": { "kind": "lodging", "nonEmpty": ["externalId", "title", "lodgingType"] } },
        { "input": "https://www.hotels.com/ho343799/the-savoy-london-united-kingdom/",
          "expect": { "kind": "lodging", "nonEmpty": ["externalId", "title", "lodgingType"] } }
      ]
    },
    {
      "id": "tripadvisor.review",
      "title": "Tripadvisor",
      "match": { "host": ["tripadvisor.com"], "path": "/**", "priority": 100 },
      "fetch": { "mode": "none" },
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlRegex": "^[^?#]*_Review-g[0-9]+-d([0-9]+)" } }] },
        { "name": "title", "candidates": [
          { "from": { "urlRegex": "^[^?#]*_Review-[^?#]*-Reviews-(?:or[0-9]+-)*([^-./?#]+)" }, "pipe": ["slugToTitle"] }
        ]},
        { "name": "category", "candidates": [{ "from": { "urlRegex": "^[^?#]*/([A-Za-z]+)_Review-" }, "pipe": ["lower"] }] }
      ],
      "identities": [{ "ns": "tripadvisor.location", "from": { "urlRegex": "^[^?#]*_Review-g[0-9]+-d([0-9]+)" } }],
      "inference": {
        "categoryKeyword": { "hotel": "lodging", "restaurant": "food" },
        "hostBrand": { "tripadvisor": "attraction" }
      },
      "examples": [
        { "input": "https://www.tripadvisor.com/Attraction_Review-g60763-d104365-Reviews-Central_Park-New_York_City_New_York.html",
          "expect": { "kind": "attraction", "nonEmpty": ["title"] } },
        { "input": "https://www.tripadvisor.com/Attraction_Review-g60763-d104365-Reviews-or15-Central_Park-New_York_City_New_York.html",
          "expect": { "kind": "attraction", "nonEmpty": ["title"] } },
        { "input": "https://www.tripadvisor.com/Hotel_Review-g60713-d224953-Reviews-Hotel_Zephyr_San_Francisco-San_Francisco_California.html",
          "expect": { "kind": "lodging", "nonEmpty": ["title"] } },
        { "input": "https://www.tripadvisor.com/Restaurant_Review-g60713-d3539600-Reviews-Gary_Danko-San_Francisco.html",
          "expect": { "kind": "food", "nonEmpty": ["title"] } },
        { "input": "https://www.tripadvisor.com/Tourism-g60763-New_York_City-Vacations.html", "expect": { "kind": "attraction" } }
      ]
    },
    {
      "id": "yelp.review",
      "title": "Yelp",
      "kind": "food",
      "match": { "host": ["yelp.com"], "path": "/biz/:slug", "priority": 100 },
      "fetch": { "mode": "none" },
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlParam": "slug" } }] },
        { "name": "title", "candidates": [{ "from": { "urlParam": "slug" }, "pipe": [{ "regexReplace": ["-[0-9]+$", ""] }, "slugToTitle"] }] }
      ],
      "identities": [{ "ns": "yelp.business", "from": { "urlParam": "slug" } }],
      "examples": [
        { "input": "https://www.yelp.com/biz/gary-danko-san-francisco", "expect": { "kind": "food", "nonEmpty": ["title"] } },
        { "input": "https://www.yelp.com/biz/ippudo-ny-new-york-4", "expect": { "kind": "food", "nonEmpty": ["title"] } },
        { "input": "https://www.yelp.com/biz/tartine-bakery-san-francisco?osq=breakfast", "expect": { "kind": "food", "nonEmpty": ["title"] } },
        { "input": "https://www.yelp.com/biz/franklin-barbecue-austin", "expect": { "kind": "food", "nonEmpty": ["title"] } },
        { "input": "https://www.yelp.com/biz/katzs-delicatessen-new-york", "expect": { "kind": "food", "nonEmpty": ["title"] } }
      ]
    },
    {
      "id": "gyg.tour",
      "title": "GetYourGuide",
      "kind": "activity",
      "match": { "host": ["getyourguide.com"], "path": "/**", "priority": 100 },
      "fetch": { "mode": "none" },
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlRegex": "^[^?#]*-t([0-9]+)(?:[/?#]|$)" } }] },
        { "name": "title", "candidates": [{ "from": { "urlRegex": "^[^?#]*/([^/?#]+)-t[0-9]+(?:[/?#]|$)" }, "pipe": ["slugToTitle"] }] }
      ],
      "identities": [{ "ns": "gyg.tour", "from": { "urlRegex": "^[^?#]*-t([0-9]+)(?:[/?#]|$)" } }],
      "examples": [
        { "input": "https://www.getyourguide.com/paris-l16/eiffel-tower-summit-tour-t435659/", "expect": { "kind": "activity", "nonEmpty": ["title"] } },
        { "input": "https://www.getyourguide.com/rome-l33/colosseum-priority-access-t54476/", "expect": { "kind": "activity", "nonEmpty": ["title"] } },
        { "input": "https://www.getyourguide.com/kyoto-l96826/kyoto-full-day-tour-t394456/", "expect": { "kind": "activity", "nonEmpty": ["title"] } },
        { "input": "https://www.getyourguide.com/new-york-l59/statue-of-liberty-ellis-island-tour-t130725/",
          "expect": { "kind": "activity", "nonEmpty": ["title"] } },
        { "input": "https://www.getyourguide.com/barcelona-l45/", "expect": { "kind": "activity" } }
      ]
    },
    {
      "id": "viator.tour",
      "title": "Viator",
      "kind": "activity",
      "match": { "host": ["viator.com"], "path": "/**", "priority": 100 },
      "fetch": { "mode": "none" },
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlRegex": "^[^?#]*/d([0-9]+-[A-Za-z0-9]+)(?:[/?#]|$)" } }] },
        { "name": "title", "candidates": [{ "from": { "urlRegex": "^[^?#]*/tours/[^/?#]+/((?!d[0-9])[^/?#]+)" }, "pipe": ["slugToTitle"] }] }
      ],
      "identities": [{ "ns": "viator.product", "from": { "urlRegex": "^[^?#]*/d([0-9]+-[A-Za-z0-9]+)(?:[/?#]|$)" } }],
      "examples": [
        { "input": "https://www.viator.com/tours/Paris/Eiffel-Tower-Priority-Access/d479-3731EIFFEL", "expect": { "kind": "activity", "nonEmpty": ["title"] } },
        { "input": "https://www.viator.com/en-GB/tours/Rome/Colosseum-Tour/d511-1234ROME", "expect": { "kind": "activity", "nonEmpty": ["title"] } },
        { "input": "https://www.viator.com/tours/San-Francisco/Alcatraz-Tour/d651-2982ALCATRAZ", "expect": { "kind": "activity", "nonEmpty": ["title"] } },
        { "input": "https://www.viator.com/tours/Tokyo/Mount-Fuji-Day-Trip/d334-3050FUJI", "expect": { "kind": "activity", "nonEmpty": ["title"] } },
        { "input": "https://www.viator.com/tours/Paris", "expect": { "kind": "activity" } }
      ]
    },
    {
      "id": "klook.tour",
      "title": "Klook",
      "kind": "activity",
      "match": { "host": ["klook.com"], "path": "/**", "priority": 100 },
      "fetch": { "mode": "none" },
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlRegex": "^[^?#]*/activity/([0-9]+)-" } }] },
        { "name": "title", "candidates": [{ "from": { "urlRegex": "^[^?#]*/activity/(?:[0-9]+-)?([^/?#]+)" }, "pipe": ["slugToTitle"] }] }
      ],
      "identities": [{ "ns": "klook.activity", "from": { "urlRegex": "^[^?#]*/activity/([0-9]+)-" } }],
      "examples": [
        { "input": "https://www.klook.com/activity/2680-klook-pass-bangkok/", "expect": { "kind": "activity", "nonEmpty": ["title"] } },
        { "input": "https://www.klook.com/en-US/activity/71377-universal-studios-singapore/", "expect": { "kind": "activity", "nonEmpty": ["title"] } },
        { "input": "https://www.klook.com/activity/113-ngong-ping-360-cable-car-hong-kong/", "expect": { "kind": "activity", "nonEmpty": ["title"] } },
        { "input": "https://www.klook.com/activity/1734-tokyo-disneyland-ticket/", "expect": { "kind": "activity", "nonEmpty": ["title"] } },
        { "input": "https://www.klook.com/zh-CN/activity/2115-taipei-101-observatory/", "expect": { "kind": "activity", "nonEmpty": ["title"] } }
      ]
    },
    {
      "id": "carrental.brands",
      "title": "Car rental",
      "kind": "transport",
      "match": { "host": [
        "hertz.com", "avis.com", "budget.com", "enterprise.com", "enterprise.co.uk", "alamo.com", "nationalcar.com",
        "sixt.com", "sixt.de", "europcar.com", "dollar.com", "thrifty.com", "turo.com", "zipcar.com",
        "rentalcars.com", "discovercars.com"
      ], "path": "/**", "priority": 100 },
      "fetch": { "mode": "none" },
      "fields": [
        { "name": "title", "candidates": [
          { "from": { "urlRegex": "^https?://(?:[^/@?#]*@)?(?:[^/@?#.]*\\\\.)*?nationalcar\\\\." }, "pipe": [{ "regexReplace": ["^.*$", "National"] }] },
          { "from": { "urlRegex": "^https?://(?:[^/@?#]*@)?(?:[^/@?#.]*\\\\.)*?rentalcars\\\\." },
            "pipe": [{ "regexReplace": ["^.*$", "Rentalcars.com"] }] },
          { "from": { "urlRegex": "^https?://(?:[^/@?#]*@)?(?:[^/@?#.]*\\\\.)*?discovercars\\\\." },
            "pipe": [{ "regexReplace": ["^.*$", "Discover Cars"] }] },
          { "from": { "urlRegex": "^https?://(?:[^/@?#]*@)?(?:[^/@?#.]*\\\\.)*?(hertz|avis|budget|enterprise|alamo|sixt|europcar|dollar|thrifty|turo|zipcar)\\\\." },
            "pipe": ["lower", "capitalizeFirst"] }
        ]}
      ],
      "examples": [
        { "input": "https://www.hertz.com/rentacar/reservation/", "expect": { "kind": "transport", "nonEmpty": ["title"] } },
        { "input": "https://www.avis.com/en/locations/us/ca/los-angeles", "expect": { "kind": "transport", "nonEmpty": ["title"] } },
        { "input": "https://www.sixt.de/mietwagen/", "expect": { "kind": "transport", "nonEmpty": ["title"] } },
        { "input": "https://turo.com/us/en/car-rental/united-states/los-angeles-ca/123", "expect": { "kind": "transport", "nonEmpty": ["title"] } },
        { "input": "https://www.discovercars.com/united-states-los-angeles", "expect": { "kind": "transport", "nonEmpty": ["title"] } },
        { "input": "https://www.enterprise.co.uk/en/car-hire/locations/uk.html", "expect": { "kind": "transport", "nonEmpty": ["title"] } }
      ]
    }
"""
