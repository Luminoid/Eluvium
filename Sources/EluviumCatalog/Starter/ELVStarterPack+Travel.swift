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
/// family). Booking's `/Share-…` short link was left to the OpenGraph floor
/// here; the 2026-10-13 pass below gives it a redirector row.
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
/// (Hotels.com's `chkin`/`chkout` and the Expedia group's `startDate`/
/// `endDate` joined the fragment; Hostelworld's
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
/// image and `placeNode` for its pin, address, and rating (it types its
/// trails `LocalBusiness`, so its own `TouristAttraction` rating rung
/// misses); its title ladder stays inline (the og:title strip and the slug
/// fallback, after which the fragment's raw og:title is inert). Komoot
/// stays off `ogCore` entirely: the fragment would append `twitter:title`
/// and `<title>` after the JSON-LD name, and a shell page's generic
/// `<title>` would then satisfy `blockedOrThin` and stop the dom
/// escalation its `missingAny: [title]` exists for.
/// The 2026-10-13 pass (schemaMinor 5): the travel family as a paste
/// flow's engine. Every travel source declares a `label` ladder whose
/// order is the precedence (a page-derived name, then the share blurb's
/// `{"paste": "label"}` name, then the URL slug, then the brand), so a
/// host gets one display label per record and an offline preview of it.
/// Redirectors carry `previewAs` hints (the short host's landing source)
/// for that preview. New rows: `booking.share` (a glued-prefix
/// `/Share-:token` capture, which the path grammar has had since minor 2),
/// `gmaps.directions`, the app-scheme sources (`gmaps.applink`,
/// `applemaps.applink`, `flighty.applink`; URL-only, so an app link never
/// leaves the device), `applemaps.place.mapkit` (Apple Maps' MapKit
/// shadow, on maps.apple.com only so the bare maps.apple short host stays
/// the redirector's), `flighty.link` (flighty.app deep links, URL-only),
/// and `dining.reservations`. The Google place sources match any Google
/// ccTLD by brand, read the place page's metas in a step scoped to the
/// meta fields (fetched at `{origin}`, the share page a canonical capture
/// rewrote, which serves the rating and type), and the MapKit shadow uses
/// `place.mapKitLookup@2` (the address-anchored lookup) through ONE input
/// map of optional `$field.x?` references, so the walk runs one search.
/// `gmaps.share` claims the bare `/` and `/maps` paths on any
/// `maps.google.*` host and renders only while the URL carried no pin.
/// Trails move to `trail.statsFromText@3` over a dom step's rendered
/// regions (an unanchored body never contributes) with `trail.locality@1`;
/// the dom rung also fires while any stat is missing (`trailThin`). The
/// lodging, tour, and review sources fetch their page (`placePage`: URL
/// first, then http, then a render while no place node was found) and
/// read it through `placeNode` (`jsonld.bestPlaceNode@1`); a page's name
/// now outranks the URL slug. Vrbo stays URL-only: a corpus run fetched a
/// delisted id's redirect to a search page (wrong summary and image) and
/// a wall page titled "Bot or Not?". AllTrails, Booking.com, and Yelp claim
/// their whole site behind the detail path (a search or list page is still
/// that provider's link, labeled with the brand). Flighty strips the
/// og:title's "Track " lead
/// and exposes both airport time zones; Airbnb and Hostelworld join the
/// page flow. Kind-only examples on sources that now fetch were dropped
/// (they would pass on an empty page).
let starterTravelMapsJSON = """
    {
      "id": "shortlinks.travel",
      "title": "Travel short links",
      "kind": "link",
      "match": { "host": ["maps.app.goo.gl", "goo.gl", "g.co", "maps.apple", "yelp.to", "abnb.me", "gyg.me", "expe.onelink.me"], "path": "/**", "priority": 90 },
      "resolvesVia": "shortlink.expand",
      "previewAs": {
        "maps.app.goo.gl": "gmaps.place", "goo.gl": "gmaps.place", "g.co": "gmaps.place", "maps.apple": "applemaps.place",
        "yelp.to": "yelp.review", "abnb.me": "airbnb.lodging", "gyg.me": "gyg.tour", "expe.onelink.me": "expedia.lodging"
      },
      "requires": ["native:shortlink.expand@1"],
      "examples": [
        { "input": "https://maps.app.goo.gl/372N2pn6HcSTEA4w6", "expect": { "kind": "place", "nonEmpty": ["title"] } },
        { "input": "https://maps.app.goo.gl/Q2YzQehRD1hTZJRA6?g_st=ic", "expect": { "kind": "place", "nonEmpty": ["title"] } },
        { "input": "https://maps.app.goo.gl/n4iYsKAYcxnpNxjG8", "expect": { "kind": "place", "nonEmpty": ["title"] } }
      ]
    },
    {
      "id": "booking.share",
      "title": "Booking.com",
      "kind": "link",
      "match": { "host": ["booking.com"], "path": "/Share-:token", "priority": 110 },
      "resolvesVia": "shortlink.expand",
      "previewAs": { "booking.com": "booking.lodging" },
      "requires": ["native:shortlink.expand@1"],
      "examples": []
    },
    {
      "id": "gmaps.directions",
      "title": "Google Maps",
      "kind": "route",
      "match": { "brand": ["google"], "path": "/maps/dir/**", "priority": 120 },
      "fetch": { "mode": "none" },
      "fields": [
        { "name": "geo", "candidates": [{ "from": { "native": "maps.pinCoordinate@1" }, "select": "geo" }] },
        { "name": "viewport", "candidates": [{ "from": { "native": "maps.pinCoordinate@1" }, "select": "viewportGeo" }] },
        { "name": "stops", "candidates": [
          { "from": { "urlRegex": "/maps/dir/([^@?#]+?)/?(?:@|[?#]|$)" }, "pipe": [{ "regexReplace": ["[+]", " "] }, "decodePercent", { "regexReplace": ["/", " → "] }, "trim"] }
        ]}
      ],
      "requires": ["native:maps.pinCoordinate@1"],
      "examples": [
        { "input": "https://www.google.com/maps/dir/San+Francisco/Los+Angeles", "expect": { "kind": "route", "nonEmpty": ["stops"] } },
        { "input": "https://www.google.com/maps/dir/Jackson/Moose", "expect": { "kind": "route", "nonEmpty": ["stops"] } }
      ]
    },
    {
      "id": "gmaps.place",
      "title": "Google Maps",
      "kind": "place",
      "match": { "brand": ["google"], "path": "/maps/**", "priority": 100 },
      "fetch": { "mode": "composite", "steps": [
        { "mode": "none" },
        { "mode": "http", "ua": "crawler", "url": "{origin}", "fields": [
          { "name": "metaNameRaw", "candidates": [{ "from": { "native": "maps.classifyMetaSegments@1" }, "select": "name" }] },
          { "name": "metaName", "candidates": [
            { "from": { "native": "place.littleEndianLabel@1", "input": { "label": "$field.metaNameRaw" } }, "select": "label",
              "pipe": [{ "split": "," }, "first", "trim"] }
          ]},
          { "name": "address", "candidates": [{ "from": { "native": "maps.classifyMetaSegments@1" }, "select": "address" }] },
          { "name": "locality", "candidates": [{ "from": { "native": "maps.classifyMetaSegments@1" }, "select": "locality" }] },
          { "name": "placeType", "candidates": [{ "from": { "native": "maps.classifyMetaSegments@1" }, "select": "type" }] },
          { "name": "category", "candidates": [{ "from": { "native": "maps.classifyMetaSegments@1" }, "select": "category" }] },
          { "name": "rating", "candidates": [{ "from": { "native": "maps.classifyMetaSegments@1" }, "select": "rating" }] }
        ]}
      ]},
      "fields": [
        { "name": "externalId", "candidates": [
          { "from": { "urlRegex": "!1s(0x[0-9a-f]+:0x[0-9a-f]+)" } },
          { "from": { "urlQuery": "ftid" } }
        ]},
        { "name": "title", "candidates": [
          { "from": { "native": "maps.splitPlaceLabel@1" }, "select": "name" },
          { "from": { "paste": "label" } }
        ]},
        { "name": "locality", "candidates": [{ "from": { "native": "maps.splitPlaceLabel@1" }, "select": "locality" }] },
        { "name": "geo", "candidates": [{ "from": { "native": "maps.pinCoordinate@1" }, "select": "geo" }] },
        { "name": "viewport", "candidates": [{ "from": { "native": "maps.pinCoordinate@1" }, "select": "viewportGeo" }] }
      ],
      "label": ["title", "metaName"],
      "identities": [
        { "ns": "gmaps.feature", "from": { "urlRegex": "!1s(0x[0-9a-f]+:0x[0-9a-f]+)" } },
        { "ns": "gmaps.feature", "from": { "urlQuery": "ftid" } }
      ],
      "requires": ["native:maps.pinCoordinate@1", "native:maps.splitPlaceLabel@1", "native:maps.classifyMetaSegments@1", "native:place.littleEndianLabel@1"],
      "examples": [
        { "input": "https://www.google.com/maps/place/Jenny+Lake/@43.7904,-110.7624,15z/data=!8m2!3d43.7904!4d-110.7624", "expect": { "kind": "place", "nonEmpty": ["title", "geo"] } },
        { "input": "https://www.google.co.jp/maps/place/Tokyo+Tower/@35.6585805,139.7454329,17z/data=!8m2!3d35.6585805!4d139.7454329",
          "expect": { "kind": "place", "nonEmpty": ["title", "geo"] } },
        { "input": "https://www.google.com/maps/place/Golden+Gate+Bridge/@37.8199286,-122.4782551,17z/data=!8m2!3d37.8199286!4d-122.4782551",
          "expect": { "kind": "place", "nonEmpty": ["title", "geo"] } }
      ]
    },
    {
      "id": "gmaps.place.mapkit",
      "title": "Google Maps",
      "kind": "place",
      "match": { "brand": ["google"], "path": "/maps/**", "priority": 110 },
      "fetch": { "mode": "composite", "steps": [
        { "mode": "none" },
        { "mode": "http", "ua": "crawler", "url": "{origin}", "fields": [
          { "name": "metaNameRaw", "candidates": [{ "from": { "native": "maps.classifyMetaSegments@1" }, "select": "name" }] },
          { "name": "metaName", "candidates": [
            { "from": { "native": "place.littleEndianLabel@1", "input": { "label": "$field.metaNameRaw" } }, "select": "label",
              "pipe": [{ "split": "," }, "first", "trim"] }
          ]},
          { "name": "address", "candidates": [{ "from": { "native": "maps.classifyMetaSegments@1" }, "select": "address" }] },
          { "name": "locality", "candidates": [{ "from": { "native": "maps.classifyMetaSegments@1" }, "select": "locality" }] },
          { "name": "placeType", "candidates": [{ "from": { "native": "maps.classifyMetaSegments@1" }, "select": "type" }] },
          { "name": "category", "candidates": [{ "from": { "native": "maps.classifyMetaSegments@1" }, "select": "category" }] },
          { "name": "rating", "candidates": [{ "from": { "native": "maps.classifyMetaSegments@1" }, "select": "rating" }] }
        ]}
      ]},
      "fields": [
        { "name": "externalId", "candidates": [
          { "from": { "urlRegex": "!1s(0x[0-9a-f]+:0x[0-9a-f]+)" } },
          { "from": { "urlQuery": "ftid" } }
        ]},
        { "name": "title", "candidates": [
          { "from": { "native": "maps.splitPlaceLabel@1" }, "select": "name" },
          { "from": { "paste": "label" } }
        ]},
        { "name": "urlLocality", "candidates": [{ "from": { "native": "maps.splitPlaceLabel@1" }, "select": "locality" }] },
        { "name": "pinLat", "candidates": [{ "from": { "native": "maps.pinCoordinate@1" }, "select": "lat" }] },
        { "name": "pinLng", "candidates": [{ "from": { "native": "maps.pinCoordinate@1" }, "select": "lng" }] },
        { "name": "viewportLat", "candidates": [{ "from": { "native": "maps.pinCoordinate@1" }, "select": "viewportLat" }] },
        { "name": "viewportLng", "candidates": [{ "from": { "native": "maps.pinCoordinate@1" }, "select": "viewportLng" }] },
        { "name": "locality", "candidates": [
          { "from": { "field": "urlLocality" } },
          { "from": { "native": "place.mapKitLookup@2", "input": {
              "name": "$field.title", "locality": "$field.urlLocality?",
              "urlLat": "$field.pinLat?", "urlLng": "$field.pinLng?", "viewportLat": "$field.viewportLat?", "viewportLng": "$field.viewportLng?"
            } }, "select": "locality" }
        ]},
        { "name": "address", "candidates": [{ "from": { "native": "place.mapKitLookup@2", "input": {
            "name": "$field.title", "locality": "$field.urlLocality?",
            "urlLat": "$field.pinLat?", "urlLng": "$field.pinLng?", "viewportLat": "$field.viewportLat?", "viewportLng": "$field.viewportLng?"
          } }, "select": "address" }] },
        { "name": "phone", "candidates": [{ "from": { "native": "place.mapKitLookup@2", "input": {
            "name": "$field.title", "locality": "$field.urlLocality?",
            "urlLat": "$field.pinLat?", "urlLng": "$field.pinLng?", "viewportLat": "$field.viewportLat?", "viewportLng": "$field.viewportLng?"
          } }, "select": "phone" }] },
        { "name": "poiCategory", "candidates": [{ "from": { "native": "place.mapKitLookup@2", "input": {
            "name": "$field.title", "locality": "$field.urlLocality?",
            "urlLat": "$field.pinLat?", "urlLng": "$field.pinLng?", "viewportLat": "$field.viewportLat?", "viewportLng": "$field.viewportLng?"
          } }, "select": "category" }] },
        { "name": "geo", "candidates": [
          { "from": { "native": "maps.pinCoordinate@1" }, "select": "geo" },
          { "from": { "native": "place.mapKitLookup@2", "input": {
              "name": "$field.title", "locality": "$field.urlLocality?",
              "urlLat": "$field.pinLat?", "urlLng": "$field.pinLng?", "viewportLat": "$field.viewportLat?", "viewportLng": "$field.viewportLng?"
            } }, "select": "geo" }
        ]},
        { "name": "geoOrigin", "candidates": [{ "from": { "native": "place.mapKitLookup@2", "input": {
            "name": "$field.title", "locality": "$field.urlLocality?",
            "urlLat": "$field.pinLat?", "urlLng": "$field.pinLng?", "viewportLat": "$field.viewportLat?", "viewportLng": "$field.viewportLng?"
          } }, "select": "origin" }] },
        { "name": "viewport", "candidates": [{ "from": { "native": "maps.pinCoordinate@1" }, "select": "viewportGeo" }] }
      ],
      "label": ["title", "metaName"],
      "identities": [
        { "ns": "gmaps.feature", "from": { "urlRegex": "!1s(0x[0-9a-f]+:0x[0-9a-f]+)" } },
        { "ns": "gmaps.feature", "from": { "urlQuery": "ftid" } }
      ],
      "requires": [
        "native:maps.pinCoordinate@1", "native:maps.splitPlaceLabel@1", "native:maps.classifyMetaSegments@1",
        "native:place.littleEndianLabel@1", "native:place.mapKitLookup@2"
      ],
      "examples": [
        { "input": "https://www.google.com/maps/place/Jenny+Lake/@43.7904,-110.7624,15z/data=!8m2!3d43.7904!4d-110.7624", "expect": { "kind": "place", "nonEmpty": ["title", "geo"] } },
        { "input": "https://www.google.co.jp/maps/place/Tokyo+Tower/@35.6585805,139.7454329,17z/data=!8m2!3d35.6585805!4d139.7454329",
          "expect": { "kind": "place", "nonEmpty": ["title", "geo"] } },
        { "input": "https://www.google.com/maps/place/Golden+Gate+Bridge/@37.8199286,-122.4782551,17z/data=!8m2!3d37.8199286!4d-122.4782551",
          "expect": { "kind": "place", "nonEmpty": ["title", "geo"] } }
      ]
    },
    {
      "id": "gmaps.share",
      "title": "Google Maps",
      "kind": "place",
      "match": { "brand": ["maps.google"], "path": ["/", "/maps"], "priority": 120 },
      "use": ["gmapsMetas"],
      "fetch": { "mode": "composite", "steps": [
        { "mode": "none" },
        { "mode": "dom", "ua": "desktopSafari", "when": { "missingAny": ["geo"] },
          "settle": { "signals": ["h1", "og:title"], "pollSeconds": 1, "maxPolls": 20 },
          "captureCanonical": { "until": { "urlRegex": "/maps/place/.*!3d-?[0-9.]+!4d-?[0-9.]+" }, "maxPolls": 20 } }
      ]},
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlQuery": "ftid" } }] },
        { "name": "title", "candidates": [
          { "from": { "native": "maps.splitPlaceLabel@1" }, "select": "name" },
          { "from": { "paste": "label" } }
        ]},
        { "name": "geo", "candidates": [{ "from": { "native": "maps.pinCoordinate@1" }, "select": "geo" }] },
        { "name": "viewport", "candidates": [{ "from": { "native": "maps.pinCoordinate@1" }, "select": "viewportGeo" }] }
      ],
      "label": ["title", "metaName"],
      "identities": [{ "ns": "gmaps.feature", "from": { "urlQuery": "ftid" } }],
      "requires": ["native:maps.pinCoordinate@1", "native:maps.splitPlaceLabel@1", "native:maps.classifyMetaSegments@1", "native:place.littleEndianLabel@1"],
      "examples": [
        { "input": "https://maps.google.com/?q=Grand+Prismatic", "expect": { "kind": "place", "nonEmpty": ["title"] } },
        { "input": "https://maps.google.com/maps?q=Grand+Prismatic+Spring+Overlook,+Yellowstone+National+Park,+WY",
          "expect": { "kind": "place", "nonEmpty": ["title", "locality"] } },
        { "input": "https://maps.google.com/?q=48.858,2.294", "expect": { "kind": "place", "nonEmpty": ["geo"] } }
      ]
    },
    {
      "id": "gmaps.applink",
      "title": "Google Maps",
      "kind": "place",
      "match": { "scheme": ["comgooglemaps"], "priority": 100 },
      "fetch": { "mode": "none" },
      "fields": [
        { "name": "title", "candidates": [
          { "from": { "native": "maps.splitPlaceLabel@1" }, "select": "name" },
          { "from": { "paste": "label" } }
        ]},
        { "name": "locality", "candidates": [{ "from": { "native": "maps.splitPlaceLabel@1" }, "select": "locality" }] },
        { "name": "geo", "candidates": [{ "from": { "native": "maps.pinCoordinate@1" }, "select": "geo" }] },
        { "name": "viewport", "candidates": [{ "from": { "native": "maps.pinCoordinate@1" }, "select": "viewportGeo" }] }
      ],
      "label": ["title"],
      "requires": ["native:maps.pinCoordinate@1", "native:maps.splitPlaceLabel@1"],
      "examples": [
        { "input": "comgooglemaps://?q=Tokyo+Tower", "expect": { "kind": "place", "nonEmpty": ["title"] } },
        { "input": "comgooglemaps://?q=48.858,2.294", "expect": { "kind": "place", "nonEmpty": ["geo"] } }
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
        { "name": "title", "candidates": [
          { "from": { "native": "maps.splitPlaceLabel@1" }, "select": "name" },
          { "from": { "paste": "label" } }
        ]},
        { "name": "locality", "candidates": [{ "from": { "native": "maps.splitPlaceLabel@1" }, "select": "locality" }] },
        { "name": "geo", "candidates": [
          { "from": { "native": "maps.pinCoordinate@1" }, "select": "geo" },
          { "from": { "native": "maps.pinCoordinate@1" }, "select": "viewportGeo" }
        ]}
      ],
      "label": ["title"],
      "identities": [{ "ns": "applemaps.place", "from": { "urlQuery": "place-id" } }],
      "requires": ["native:maps.pinCoordinate@1", "native:maps.splitPlaceLabel@1"],
      "examples": [
        { "input": "https://maps.apple.com/?q=Tokyo+Tower&ll=35.6586,139.7454", "expect": { "kind": "place", "nonEmpty": ["title", "geo"] } },
        { "input": "https://maps.apple.com/?q=Jenny+Lake,+Wyoming&sll=43.75,-110.72", "expect": { "kind": "place", "nonEmpty": ["title", "locality"] } },
        { "input": "https://maps.apple.com/?q=48.8584,2.2945", "expect": { "kind": "place", "nonEmpty": ["geo"] } },
        { "input": "https://maps.apple.com/?q=Golden+Gate+Bridge", "expect": { "kind": "place", "nonEmpty": ["title"] } }
      ]
    },
    {
      "id": "applemaps.place.mapkit",
      "title": "Apple Maps",
      "kind": "place",
      "match": { "host": ["maps.apple.com"], "path": "/**", "priority": 100 },
      "fetch": { "mode": "none" },
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlQuery": "place-id" } }] },
        { "name": "title", "candidates": [
          { "from": { "native": "maps.splitPlaceLabel@1" }, "select": "name" },
          { "from": { "paste": "label" } }
        ]},
        { "name": "urlLocality", "candidates": [{ "from": { "native": "maps.splitPlaceLabel@1" }, "select": "locality" }] },
        { "name": "pinLat", "candidates": [
          { "from": { "native": "maps.pinCoordinate@1" }, "select": "lat" },
          { "from": { "native": "maps.pinCoordinate@1" }, "select": "viewportLat" }
        ]},
        { "name": "pinLng", "candidates": [
          { "from": { "native": "maps.pinCoordinate@1" }, "select": "lng" },
          { "from": { "native": "maps.pinCoordinate@1" }, "select": "viewportLng" }
        ]},
        { "name": "locality", "candidates": [
          { "from": { "field": "urlLocality" } },
          { "from": { "native": "place.mapKitLookup@2", "input": {
              "name": "$field.title", "locality": "$field.urlLocality?",
              "urlLat": "$field.pinLat?", "urlLng": "$field.pinLng?", "viewportLat": "$field.viewportLat?", "viewportLng": "$field.viewportLng?"
            } }, "select": "locality" }
        ]},
        { "name": "address", "candidates": [{ "from": { "native": "place.mapKitLookup@2", "input": {
            "name": "$field.title", "locality": "$field.urlLocality?",
            "urlLat": "$field.pinLat?", "urlLng": "$field.pinLng?", "viewportLat": "$field.viewportLat?", "viewportLng": "$field.viewportLng?"
          } }, "select": "address" }] },
        { "name": "phone", "candidates": [{ "from": { "native": "place.mapKitLookup@2", "input": {
            "name": "$field.title", "locality": "$field.urlLocality?",
            "urlLat": "$field.pinLat?", "urlLng": "$field.pinLng?", "viewportLat": "$field.viewportLat?", "viewportLng": "$field.viewportLng?"
          } }, "select": "phone" }] },
        { "name": "poiCategory", "candidates": [{ "from": { "native": "place.mapKitLookup@2", "input": {
            "name": "$field.title", "locality": "$field.urlLocality?",
            "urlLat": "$field.pinLat?", "urlLng": "$field.pinLng?", "viewportLat": "$field.viewportLat?", "viewportLng": "$field.viewportLng?"
          } }, "select": "category" }] },
        { "name": "geo", "candidates": [
          { "from": { "native": "maps.pinCoordinate@1" }, "select": "geo" },
          { "from": { "native": "maps.pinCoordinate@1" }, "select": "viewportGeo" },
          { "from": { "native": "place.mapKitLookup@2", "input": {
              "name": "$field.title", "locality": "$field.urlLocality?",
              "urlLat": "$field.pinLat?", "urlLng": "$field.pinLng?", "viewportLat": "$field.viewportLat?", "viewportLng": "$field.viewportLng?"
            } }, "select": "geo" }
        ]}
      ],
      "label": ["title"],
      "identities": [{ "ns": "applemaps.place", "from": { "urlQuery": "place-id" } }],
      "requires": ["native:maps.pinCoordinate@1", "native:maps.splitPlaceLabel@1", "native:place.mapKitLookup@2"],
      "examples": [
        { "input": "https://maps.apple.com/?q=Tokyo+Tower&ll=35.6586,139.7454", "expect": { "kind": "place", "nonEmpty": ["title", "geo"] } },
        { "input": "https://maps.apple.com/?q=Golden+Gate+Bridge&sll=37.8199,-122.4783", "expect": { "kind": "place", "nonEmpty": ["title", "geo"] } }
      ]
    },
    {
      "id": "applemaps.applink",
      "title": "Apple Maps",
      "kind": "place",
      "match": { "scheme": ["maps"], "priority": 100 },
      "fetch": { "mode": "none" },
      "fields": [
        { "name": "title", "candidates": [
          { "from": { "native": "maps.splitPlaceLabel@1" }, "select": "name" },
          { "from": { "paste": "label" } }
        ]},
        { "name": "locality", "candidates": [{ "from": { "native": "maps.splitPlaceLabel@1" }, "select": "locality" }] },
        { "name": "geo", "candidates": [
          { "from": { "native": "maps.pinCoordinate@1" }, "select": "geo" },
          { "from": { "native": "maps.pinCoordinate@1" }, "select": "viewportGeo" }
        ]}
      ],
      "label": ["title"],
      "requires": ["native:maps.pinCoordinate@1", "native:maps.splitPlaceLabel@1"],
      "examples": [
        { "input": "maps://?q=Tokyo+Tower&ll=35.6586,139.7454", "expect": { "kind": "place", "nonEmpty": ["title", "geo"] } },
        { "input": "maps://?q=Golden+Gate+Bridge", "expect": { "kind": "place", "nonEmpty": ["title"] } }
      ]
    }
"""

let starterTrailsAndFlightsJSON = """
    {
      "id": "alltrails.trail",
      "title": "AllTrails",
      "kind": "trail",
      "match": { "host": ["alltrails.com"], "path": ["/trail/:country/:region/:slug", "/**"], "priority": 100 },
      "canonicalize": { "strip": ["*"] },
      "use": ["trailStats", "ogCore", "placeNode"],
      "fetch": { "mode": "composite", "steps": [
        { "mode": "http", "ua": "crawler" },
        { "mode": "dom", "ua": "desktopSafari", "settle": { "signals": ["h1", "jsonld", "og:title"] }, "regions": ["h1", "header", "body"], "when": "trailThin" }
      ]},
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlParam": "slug" } }] },
        { "name": "title", "candidates": [
          { "from": { "jsonld": "TouristAttraction.name" } },
          { "from": { "meta": "og:title" }, "pipe": [{ "regexReplace": ["^(.*?)(?: [|] | - ).*$", "$1"] }, "trim"] },
          { "from": { "paste": "label" } },
          { "from": { "urlParam": "slug" }, "pipe": ["slugToTitle"] }
        ]},
        { "name": "rating", "candidates": [{ "from": { "jsonld": "TouristAttraction.aggregateRating.ratingValue" }, "as": "rating" }] },
        { "name": "locality", "candidates": [
          { "from": { "native": "trail.locality@1", "input": { "region": "$param.region", "country": "$param.country" } }, "select": "locality" }
        ]}
      ],
      "label": ["title"],
      "identities": [{ "ns": "alltrails.trail", "from": { "urlParam": "slug" } }],
      "requires": ["native:trail.statsFromText@3", "native:trail.locality@1", "native:jsonld.bestPlaceNode@1"],
      "examples": [
        { "input": "https://www.alltrails.com/trail/us/california/half-dome-via-the-john-muir-trail-jmt", "expect": { "kind": "trail", "nonEmpty": ["title", "locality"] } },
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
        { "mode": "dom", "ua": "desktopSafari", "settle": { "signals": ["h1", "og:title"] }, "regions": ["h1", "header", "body"], "when": "trailThin" }
      ]},
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlRegex": "/tour/([0-9]+)" } }] },
        { "name": "title", "candidates": [
          { "from": { "meta": "og:title" }, "pipe": [{ "stripSuffix": " | Komoot" }] },
          { "from": { "jsonld": "*.name" } },
          { "from": { "paste": "label" } }
        ]},
        { "name": "summary", "candidates": [{ "from": { "meta": "og:description" } }] },
        { "name": "image", "candidates": [{ "from": { "meta": "og:image" }, "pipe": ["resolveURL"], "as": "image" }] }
      ],
      "label": ["title"],
      "identities": [{ "ns": "komoot.tour", "from": { "urlRegex": "/tour/([0-9]+)" } }],
      "requires": ["native:trail.statsFromText@3"],
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
          { "from": { "meta": "og:title" }, "pipe": [{ "regexReplace": ["^Track +", ""] }, "trim"] }
        ]},
        { "name": "designator", "candidates": [{ "from": { "native": "flighty.flightFromPage@2" }, "select": "designator" }] },
        { "name": "departureIata", "candidates": [{ "from": { "native": "flighty.flightFromPage@2" }, "select": "departureIata" }] },
        { "name": "arrivalIata", "candidates": [{ "from": { "native": "flighty.flightFromPage@2" }, "select": "arrivalIata" }] },
        { "name": "departureAirport", "candidates": [{ "from": { "native": "flighty.flightFromPage@2" }, "select": "departureAirport" }] },
        { "name": "arrivalAirport", "candidates": [{ "from": { "native": "flighty.flightFromPage@2" }, "select": "arrivalAirport" }] },
        { "name": "departureTime", "candidates": [{ "from": { "native": "flighty.flightFromPage@2" }, "select": "departureTime" }] },
        { "name": "arrivalTime", "candidates": [{ "from": { "native": "flighty.flightFromPage@2" }, "select": "arrivalTime" }] },
        { "name": "departureTimeZone", "candidates": [{ "from": { "native": "flighty.flightFromPage@2" }, "select": "departureTimeZone" }] },
        { "name": "arrivalTimeZone", "candidates": [{ "from": { "native": "flighty.flightFromPage@2" }, "select": "arrivalTimeZone" }] },
        { "name": "gate", "candidates": [{ "from": { "native": "flighty.flightFromPage@2" }, "select": "gate" }] },
        { "name": "terminal", "candidates": [{ "from": { "native": "flighty.flightFromPage@2" }, "select": "terminal" }] },
        { "name": "airline", "candidates": [{ "from": { "native": "flighty.flightFromPage@2" }, "select": "airlineName" }] },
        { "name": "arrivalGeo", "candidates": [{ "from": { "native": "flighty.flightFromPage@2" }, "select": "arrivalGeo" }] },
        { "name": "formatDrift", "candidates": [{ "from": { "native": "flighty.flightFromPage@2" }, "select": "formatDrift" }] },
        { "name": "routeLabel", "candidates": [
          { "from": { "native": "text.join@1", "input": { "part1": "$field.designator", "part2": "$field.arrivalIata", "separator": " to " } }, "select": "text" }
        ]},
        { "name": "urlDesignator", "candidates": [{ "from": { "native": "flight.designatorFromURL@1" }, "select": "designator" }] }
      ],
      "label": ["title", "routeLabel", "urlDesignator"],
      "requires": ["native:flighty.flightFromPage@2", "native:flight.designatorFromURL@1"],
      "examples": [
        { "input": "https://live.flighty.app/522c14cd-5c6e-4858-b201-b9c117d8477a", "expect": { "kind": "flight", "nonEmpty": ["title", "designator"] } }
      ]
    },
    {
      "id": "flighty.link",
      "title": "Flighty",
      "kind": "flight",
      "match": { "host": ["flighty.app"], "path": ["/flight/**", "/share/**"], "priority": 100 },
      "fetch": { "mode": "none" },
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "native": "flight.designatorFromURL@1" }, "select": "designator" }] },
        { "name": "designator", "candidates": [{ "from": { "native": "flight.designatorFromURL@1" }, "select": "designator" }] },
        { "name": "title", "candidates": [{ "from": { "field": "designator" } }] }
      ],
      "label": ["title"],
      "requires": ["native:flight.designatorFromURL@1"],
      "examples": [
        { "input": "https://flighty.app/flight/AS1276", "expect": { "kind": "flight", "nonEmpty": ["designator"] } },
        { "input": "https://flighty.app/flight/UA123", "expect": { "kind": "flight", "nonEmpty": ["designator"] } }
      ]
    },
    {
      "id": "flighty.applink",
      "title": "Flighty",
      "kind": "flight",
      "match": { "scheme": ["flighty"], "priority": 100 },
      "fetch": { "mode": "none" },
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "native": "flight.designatorFromURL@1" }, "select": "designator" }] },
        { "name": "designator", "candidates": [{ "from": { "native": "flight.designatorFromURL@1" }, "select": "designator" }] },
        { "name": "title", "candidates": [{ "from": { "field": "designator" } }] }
      ],
      "label": ["title"],
      "requires": ["native:flight.designatorFromURL@1"],
      "examples": [
        { "input": "flighty://flight/UA123", "expect": { "kind": "flight", "nonEmpty": ["designator"] } },
        { "input": "flighty://flight/AS866", "expect": { "kind": "flight", "nonEmpty": ["designator"] } }
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
        { "name": "designator", "candidates": [{ "from": { "native": "flight.designatorFromURL@1" }, "select": "designator" }] },
        { "name": "brand", "candidates": [
          { "from": { "urlRegex": "^https?://(?:[^/@?#]*@)?(?:[^/@?#.]*[.])*?flightaware[.]" }, "pipe": [{ "regexReplace": ["^.*$", "FlightAware"] }] },
          { "from": { "urlRegex": "^https?://(?:[^/@?#]*@)?(?:[^/@?#.]*[.])*?(?:flightradar24|fr24)[.]" }, "pipe": [{ "regexReplace": ["^.*$", "Flightradar24"] }] }
        ]}
      ],
      "label": ["title"],
      "requires": ["native:flight.designatorFromURL@1"],
      "examples": [
        { "input": "https://www.flightaware.com/live/flight/UAL123", "expect": { "kind": "flight", "nonEmpty": ["title", "brand"] } },
        { "input": "https://www.flightradar24.com/data/flights/ua123", "expect": { "kind": "flight", "nonEmpty": ["title", "brand"] } },
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
      "match": { "host": ["booking.com"], "path": ["/hotel/:country/:slug", "/**"], "priority": 100 },
      "use": ["lodgingDates", "placePage", "placeNode"],
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlParam": "slug" }, "pipe": [{ "regexReplace": ["\\\\..*$", ""] }] }] },
        { "name": "title", "candidates": [
          { "from": { "native": "jsonld.bestPlaceNode@1" }, "select": "name" },
          { "from": { "paste": "label" } },
          { "from": { "urlParam": "slug" }, "pipe": [{ "regexReplace": ["\\\\..*$", ""] }, "slugToTitle"] }
        ]},
        { "name": "lodgingType", "candidates": [{ "from": { "const": "hotel" } }] }
      ],
      "label": ["title"],
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
      "use": ["lodgingDates", "placePage", "placeNode", "ogCore"],
      "fields": [
        { "name": "title", "candidates": [{ "from": { "native": "jsonld.bestPlaceNode@1" }, "select": "name" }, { "from": { "paste": "label" } }] },
        { "name": "externalId", "candidates": [{ "from": { "urlRegex": "/(?:rooms|properties)/([0-9]+)" } }] },
        { "name": "lodgingType", "candidates": [{ "from": { "const": "rental" } }] }
      ],
      "label": ["title"],
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
        { "name": "title", "candidates": [{ "from": { "paste": "label" } }] },
        { "name": "externalId", "candidates": [{ "from": { "urlRegex": "/p?([0-9]{6,})" } }] },
        { "name": "lodgingType", "candidates": [{ "from": { "const": "rental" } }] }
      ],
      "label": ["title"],
      "identities": [{ "ns": "vrbo.property", "from": { "urlRegex": "/p?([0-9]{6,})" } }],
      "examples": [
        { "input": "https://www.vrbo.com/2716034", "expect": { "kind": "lodging", "nonEmpty": ["externalId"] } },
        { "input": "https://www.vrbo.com/en-ca/p3081098vb", "expect": { "kind": "lodging", "nonEmpty": ["externalId"] } },
        { "input": "https://www.vrbo.com/8360330ha", "expect": { "kind": "lodging", "nonEmpty": ["externalId"] } },
        { "input": "https://www.vrbo.com/705146", "expect": { "kind": "lodging", "nonEmpty": ["externalId"] } }
      ]
    },
    {
      "id": "agoda.lodging",
      "title": "Agoda",
      "kind": "lodging",
      "match": { "brand": ["agoda"], "path": "/**", "priority": 100 },
      "use": ["lodgingDates", "placePage", "placeNode"],
      "fields": [
        { "name": "title", "candidates": [
          { "from": { "native": "jsonld.bestPlaceNode@1" }, "select": "name" },
          { "from": { "paste": "label" } },
          { "from": { "urlRegex": "^[^?#]*/((?![a-z]{2}(?:-[a-z]{2})?/)[^/?#]+)/hotel(?:/|$)" }, "pipe": ["slugToTitle"] }
        ]},
        { "name": "lodgingType", "candidates": [{ "from": { "const": "hotel" } }] }
      ],
      "label": ["title"],
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
      "use": ["lodgingDates", "placePage", "placeNode"],
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlRegex": "^[^?#]*\\\\.h([0-9]+)" } }] },
        { "name": "title", "candidates": [
          { "from": { "native": "jsonld.bestPlaceNode@1" }, "select": "name" },
          { "from": { "paste": "label" } },
          { "from": { "urlRegex": "^[^?#]*/(?:[^/?#]*-[Hh]otels-)?([^/?#.]+)\\\\.h[0-9]+" }, "pipe": ["slugToTitle"] }
        ]},
        { "name": "locality", "candidates": [
          { "from": { "urlQuery": "destination" }, "pipe": [{ "regexReplace": ["\\\\+", " "] }, "collapseWhitespace", "trim"] },
          { "from": { "urlRegex": "^[^?#]*/([^/?#]+)-[Hh]otels-[^/?#]*\\\\.h[0-9]+" }, "pipe": ["slugToTitle"] }
        ]},
        { "name": "lodgingType", "candidates": [{ "from": { "const": "hotel" } }] }
      ],
      "label": ["title"],
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
      "use": ["lodgingDates", "placePage", "placeNode", "ogCore"],
      "fields": [
        { "name": "title", "candidates": [{ "from": { "native": "jsonld.bestPlaceNode@1" }, "select": "name" }, { "from": { "paste": "label" } }] },
        { "name": "externalId", "candidates": [
          { "from": { "urlRegex": "/hostels/p/([0-9]+)/" } },
          { "from": { "urlRegex": "/hosteldetails\\\\.php/[^/]+/[^/]+/([0-9]+)" } }
        ]},
        { "name": "checkIn", "candidates": [{ "from": { "urlQuery": "from" }, "as": "date", "format": "yyyy-MM-dd" }] },
        { "name": "checkOut", "candidates": [{ "from": { "urlQuery": "to" }, "as": "date", "format": "yyyy-MM-dd" }] },
        { "name": "lodgingType", "candidates": [{ "from": { "const": "hostel" } }] }
      ],
      "label": ["title"],
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
      "use": ["lodgingDates", "placePage", "placeNode"],
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlRegex": "^[^?#]*/ho([0-9]+)(?:[/?#]|$)" } }] },
        { "name": "title", "candidates": [
          { "from": { "native": "jsonld.bestPlaceNode@1" }, "select": "name" },
          { "from": { "paste": "label" } },
          { "from": { "urlRegex": "^[^?#]*/ho[0-9]+/([^/?#]+)(?:[/?#]|$)" }, "pipe": ["slugToTitle"] }
        ]},
        { "name": "lodgingType", "candidates": [{ "from": { "const": "hotel" } }] }
      ],
      "label": ["title"],
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
      "use": ["placePage", "placeNode"],
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlRegex": "^[^?#]*_Review-g[0-9]+-d([0-9]+)" } }] },
        { "name": "title", "candidates": [
          { "from": { "native": "jsonld.bestPlaceNode@1" }, "select": "name" },
          { "from": { "paste": "label" } },
          { "from": { "urlRegex": "^[^?#]*_Review-[^?#]*-Reviews-(?:or[0-9]+-)*([^-./?#]+)" }, "pipe": ["slugToTitle"] }
        ]},
        { "name": "category", "candidates": [{ "from": { "urlRegex": "^[^?#]*/([A-Za-z]+)_Review-" }, "pipe": ["lower"] }] }
      ],
      "label": ["title"],
      "identities": [{ "ns": "tripadvisor.location", "from": { "urlRegex": "^[^?#]*_Review-g[0-9]+-d([0-9]+)" } }],
      "inference": {
        "categoryKeyword": { "hotel": "lodging", "restaurant": "food" },
        "hostBrand": { "tripadvisor": "attraction" }
      },
      "examples": [
        { "input": "https://www.tripadvisor.com/Attraction_Review-g60763-d104365-Reviews-Empire_State_Building-New_York_City_New_York.html",
          "expect": { "kind": "attraction", "nonEmpty": ["title"] } },
        { "input": "https://www.tripadvisor.com/Attraction_Review-g60763-d104365-Reviews-or10-Empire_State_Building-New_York_City_New_York.html",
          "expect": { "kind": "attraction", "nonEmpty": ["title"] } },
        { "input": "https://www.tripadvisor.com/Hotel_Review-g60713-d224953-Reviews-Four_Seasons_Hotel_San_Francisco-San_Francisco_California.html",
          "expect": { "kind": "lodging", "nonEmpty": ["title"] } },
        { "input": "https://www.tripadvisor.com/Restaurant_Review-g187791-d3539600-Reviews-Un_Posto_Per_Mangiare-Rome_Lazio.html",
          "expect": { "kind": "food", "nonEmpty": ["title"] } }
      ]
    },
    {
      "id": "yelp.review",
      "title": "Yelp",
      "kind": "food",
      "match": { "host": ["yelp.com"], "path": ["/biz/:slug", "/**"], "priority": 100 },
      "use": ["placePage", "placeNode"],
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlParam": "slug" } }] },
        { "name": "title", "candidates": [
          { "from": { "native": "jsonld.bestPlaceNode@1" }, "select": "name" },
          { "from": { "paste": "label" } },
          { "from": { "urlParam": "slug" }, "pipe": [{ "regexReplace": ["-[0-9]+$", ""] }, "slugToTitle"] }
        ]}
      ],
      "label": ["title"],
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
      "use": ["placePage", "placeNode"],
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlRegex": "^[^?#]*-t([0-9]+)(?:[/?#]|$)" } }] },
        { "name": "title", "candidates": [
          { "from": { "native": "jsonld.bestPlaceNode@1" }, "select": "name" },
          { "from": { "paste": "label" } },
          { "from": { "urlRegex": "^[^?#]*/([^/?#]+)-t[0-9]+(?:[/?#]|$)" }, "pipe": ["slugToTitle"] }
        ]}
      ],
      "label": ["title"],
      "identities": [{ "ns": "gyg.tour", "from": { "urlRegex": "^[^?#]*-t([0-9]+)(?:[/?#]|$)" } }],
      "examples": [
        { "input": "https://www.getyourguide.com/paris-l16/paris-guided-tour-eiffel-tower-ticket-t29942/", "expect": { "kind": "activity", "nonEmpty": ["title"] } },
        { "input": "https://www.getyourguide.com/rome-l33/rome-colosseum-roman-forum-and-palatine-hill-guided-tour-t84141/", "expect": { "kind": "activity", "nonEmpty": ["title"] } },
        { "input": "https://www.getyourguide.com/kyoto-l96826/kyoto-full-day-unesco-and-historical-sites-tour-t137921/", "expect": { "kind": "activity", "nonEmpty": ["title"] } },
        { "input": "https://www.getyourguide.com/new-york-l59/statue-of-liberty-and-ellis-island-4-hour-guided-tour-t53542/",
          "expect": { "kind": "activity", "nonEmpty": ["title"] } }
      ]
    },
    {
      "id": "viator.tour",
      "title": "Viator",
      "kind": "activity",
      "match": { "host": ["viator.com"], "path": "/**", "priority": 100 },
      "use": ["placePage", "placeNode"],
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlRegex": "^[^?#]*/d([0-9]+-[A-Za-z0-9]+)(?:[/?#]|$)" } }] },
        { "name": "title", "candidates": [
          { "from": { "native": "jsonld.bestPlaceNode@1" }, "select": "name" },
          { "from": { "paste": "label" } },
          { "from": { "urlRegex": "^[^?#]*/tours/[^/?#]+/((?!d[0-9])[^/?#]+)" }, "pipe": ["slugToTitle"] }
        ]}
      ],
      "label": ["title"],
      "identities": [{ "ns": "viator.product", "from": { "urlRegex": "^[^?#]*/d([0-9]+-[A-Za-z0-9]+)(?:[/?#]|$)" } }],
      "examples": [
        { "input": "https://www.viator.com/tours/Paris/Summit-Eiffel-Tower-Priority-Access-with-Host/d479-7845P10", "expect": { "kind": "activity", "nonEmpty": ["title"] } },
        { "input": "https://www.viator.com/en-GB/tours/Rome/Colosseum-and-Ancient-Rome-Tour-with-Roman-Forum-and-Palatine-Hill/d511-3731COLOSSEUM",
          "expect": { "kind": "activity", "nonEmpty": ["title"] } },
        { "input": "https://www.viator.com/tours/San-Francisco/Alcatraz-and-San-Francisco-City-Tour/d651-2660SFODLX3", "expect": { "kind": "activity", "nonEmpty": ["title"] } },
        { "input": "https://www.viator.com/tours/Tokyo/Mount-Fuji-Full-day-Tour-from-Tokyo-with-English-Speaking-Guide/d334-444978P1", "expect": { "kind": "activity", "nonEmpty": ["title"] } }
      ]
    },
    {
      "id": "klook.tour",
      "title": "Klook",
      "kind": "activity",
      "match": { "host": ["klook.com"], "path": "/**", "priority": 100 },
      "use": ["placePage", "placeNode"],
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlRegex": "^[^?#]*/activity/([0-9]+)-" } }] },
        { "name": "title", "candidates": [
          { "from": { "native": "jsonld.bestPlaceNode@1" }, "select": "name" },
          { "from": { "paste": "label" } },
          { "from": { "urlRegex": "^[^?#]*/activity/(?:[0-9]+-)?([^/?#]+)" }, "pipe": ["slugToTitle"] }
        ]}
      ],
      "label": ["title"],
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
      "id": "dining.reservations",
      "title": "Restaurant reservations",
      "kind": "food",
      "match": { "brand": ["opentable", "thefork", "tabelog"], "host": ["resy.com"], "path": "/**", "priority": 100 },
      "use": ["placePage", "placeNode", "ogCore"],
      "fields": [
        { "name": "title", "candidates": [{ "from": { "native": "jsonld.bestPlaceNode@1" }, "select": "name" }, { "from": { "paste": "label" } }] },
        { "name": "brand", "candidates": [
          { "from": { "urlRegex": "^https?://(?:[^/@?#]*@)?(?:[^/@?#.]*[.])*?opentable[.]" }, "pipe": [{ "regexReplace": ["^.*$", "OpenTable"] }] },
          { "from": { "urlRegex": "^https?://(?:[^/@?#]*@)?(?:[^/@?#.]*[.])*?thefork[.]" }, "pipe": [{ "regexReplace": ["^.*$", "TheFork"] }] },
          { "from": { "urlRegex": "^https?://(?:[^/@?#]*@)?(?:[^/@?#.]*[.])*?tabelog[.]" }, "pipe": [{ "regexReplace": ["^.*$", "Tabelog"] }] },
          { "from": { "urlRegex": "^https?://(?:[^/@?#]*@)?(?:[^/@?#.]*[.])*?resy[.]com" }, "pipe": [{ "regexReplace": ["^.*$", "Resy"] }] }
        ]}
      ],
      "label": ["title"],
      "examples": [
        { "input": "https://www.opentable.com/r/benu-san-francisco", "expect": { "kind": "food", "nonEmpty": ["title", "brand"] } },
        { "input": "https://tabelog.com/en/tokyo/A1301/A130101/13002251/", "expect": { "kind": "food", "nonEmpty": ["title", "brand"] } }
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
      "label": ["title"],
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
