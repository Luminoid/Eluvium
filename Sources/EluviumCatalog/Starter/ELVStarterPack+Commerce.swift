/// The commerce chunk of the starter pack: `camera.lens` (2026-08-30), the
/// lens-db provider roster — one source over the lens-maker product-page
/// hosts lens-db's `productUrl` data actually uses, with path shapes
/// derived from that data, plus `camera.lens.sigma` for sigmaphoto's
/// bare-slug product paths (the primary Sigma host in lens-db; a dedicated
/// source keeps the `/:slug` catch-all off the other 17 hosts). Brand labels
/// ride host-anchored candidates, the carrental.brands idiom.
///
/// The kind gate (2026-10-10). The path list is shared by all 17 hosts, and
/// three of its shapes (`/products/**`, `/product/**`, `/*/product/**`) are
/// whole-shop patterns on Viltrox, Meike, 7Artisans, TTArtisan, and
/// Yongnuo, which also sell flashes, lights, adapters, and filters;
/// sigmaphoto's `/:slug` claims every page on its host. Neither source
/// authors a kind any more: a `category` field rides the inference table
/// (`lens` → lens, `product` → product). Evidence, first present wins: a
/// lens-scoped path (`/lenses/`, `/voigtlander/`, Zeiss's
/// `/consumer-products/*/photography/`; sigmaphoto's `10-18mm-f2-8-…`
/// slug) says lens; otherwise the title decides, `lens` when a focal length
/// is followed by an aperture (`9mm F2.8`, `XF8-16mmF2.8`, `F/2.8`,
/// `T2.2`), `product` when not (the aperture keeps a "58mm UV filter"
/// out). A walled shop page whose title was blanked has no evidence and
/// gets no kind (skip beats wrong). Per-host sources would have split the
/// roster and reordered the composition pin; per-host path rules are not
/// expressible (a match's hosts and paths combine freely). The gate keeps
/// every source id, its position, and every example's kind, and reads
/// evidence each record already has.
///
/// Plain `http(desktopSafari)`, no dom escalation: a 2026-08-30 lens-db
/// parity run proved dom recovers nothing here (electronics.sony.com's SPA
/// bounces a headless render to /not-found; venuslens.net's Cloudflare
/// challenge never clears in WKWebView), so the composite only added latency.
/// The three hosts that serve a non-product title on plain http instead have
/// it handled at the field level: Samyang's real name is read from its
/// `h3.page-h3` heading, and the known site-name / challenge / access-denied
/// strings are blanked so a lens record never carries "Just a moment..." or
/// "Sony Electronics" as its title (brand still lands; the title is honestly
/// empty where the product name is unreachable). The blanking regex is
/// written out on each of the three title candidates, deliberately: it must
/// run on every rung (a blanked og:title falls through to twitter:title,
/// then `<title>`), so it cannot move to one shared field without losing
/// the fall-through, and a helper field would surface as a record field.
///
/// sigmaphoto's `og:description` is not trustworthy: its 16-300mm page
/// carries the 24mm F2 I-series copy (a site-side template slip, caught by
/// the corpus log 2026-09-10) while the same page's `meta description` is
/// right, and the 10-18mm page's two tags agree — so `camera.lens.sigma`
/// reads `description` first and falls back to `og:description`. The generic
/// `camera.lens` keeps the OG-first order: none of its hosts showed the slip.
///
/// fujifilm-x.com's slip is different (2026-10-12 log): on most of its lens
/// pages (three of four checked; the newest is right) `og:description` is
/// one letter ("P") and `og:image` a bare WordPress attachment id
/// (`http://92884`), while `meta description` is right on all of them. So
/// `camera.lens` blanks an og:description under three characters and lets
/// the description rung produce, keeping the OG-first order the other hosts
/// earned. The image needs no pack rung: `ELVURLPolicy.resolve` refuses a
/// dotless host at the funnel every URL rides through, and the broken pages
/// carry no stable product image to fall back to, so `image` is honestly
/// empty there.
///
/// Fragment use (2026-09-10): `camera.lens.sigma` rides `ogCore` — its
/// `og:title` + trim candidate stays inline (the fragment's og:title has no
/// trim, and meta content is stored untrimmed), the `<title>`, image, and
/// siteName ladders come from the fragment, and its description-first
/// `summary` stays inline with the fragment's og:description / description
/// appended after it (harmless duplicates: a candidate that already failed
/// fails again). `camera.lens` deliberately does NOT use `ogCore`, even
/// though its summary / image / siteName ladders match the fragment
/// verbatim: `use` appends fragment candidates after the source's own, and
/// the extractor treats a candidate that pipes to "" as absent and moves on
/// — so the fragment's raw `og:title` would run right after the blanking
/// ladder and hand "Just a moment..." back as the title on every walled
/// host. The blanking only holds while nothing follows it.
///
/// Deliberately excluded hosts: usa.canon.com / nikonusa.com /
/// shop.panasonic.com / explore.omsystem.com / leicacamerausa.com (their
/// product paths are indistinguishable from camera pages, so a whole-shop
/// claim would mis-kind cameras as lenses), dpreview.com (`/products/**`
/// would swallow its camera pages), bhphotovideo.com (bot wall, the vrbo
/// precedent), and the one-off wikipedia/imaging-resource/pro.sony
/// stragglers.
///
/// Chewy and Amazon are NOT here: they moved to the opt-in commerce pack
/// (`ELVOptInPacks.commerce`, resource `OptIn/CommerceOptInPack.json`)
/// on 2026-08-30 because their terms restrict automated access and their
/// fetch escalates past bot protections. A host loads that pack only where
/// it has decided the targets permit it (LEGAL.md). The Petfolio parity
/// suite loads it directly.
/// Composition contract in ELVStarterPack.swift
/// (declaration order is behavior; chunks carry no trailing comma).
let starterCommerceJSON = """
    {
      "id": "camera.lens",
      "title": "Camera lenses",
      "match": { "host": [
        "electronics.sony.com", "fujifilm-x.com", "leica-camera.com", "zeiss.com", "sigma-global.com",
        "tamron.com", "voigtlaender.de", "cosina.co.jp", "yongnuo.eu", "th.hkyongnuo.com", "tokinalens.com",
        "venuslens.net", "viltrox.com", "7artisans.store", "ttartisan.store", "meikeglobal.com", "lksamyang.com"
      ], "path": [
        "/*/lenses/**", "/lenses/**", "/*/consumer/lenses/**", "/*/products/lenses/**",
        "/*/photography/lenses/**", "/consumer-products/*/photography/**", "/voigtlander/**",
        "/product/**", "/*/product/**", "/products/**"
      ], "priority": 100 },
      "fetch": { "mode": "http", "ua": "desktopSafari" },
      "fields": [
        { "name": "brand", "candidates": [
          { "from": { "urlRegex": "^https?://(?:[^/@?#]*@)?(?:[^/@?#.]*\\\\.)*?fujifilm-x\\\\." }, "pipe": [{ "regexReplace": ["^.*$", "Fujifilm"] }] },
          { "from": { "urlRegex": "^https?://(?:[^/@?#]*@)?(?:[^/@?#.]*\\\\.)*?leica-camera\\\\." }, "pipe": [{ "regexReplace": ["^.*$", "Leica"] }] },
          { "from": { "urlRegex": "^https?://(?:[^/@?#]*@)?(?:[^/@?#.]*\\\\.)*?sigma-global\\\\." }, "pipe": [{ "regexReplace": ["^.*$", "Sigma"] }] },
          { "from": { "urlRegex": "^https?://(?:[^/@?#]*@)?(?:[^/@?#.]*\\\\.)*?venuslens\\\\." }, "pipe": [{ "regexReplace": ["^.*$", "Laowa"] }] },
          { "from": { "urlRegex": "^https?://(?:[^/@?#]*@)?(?:[^/@?#.]*\\\\.)*?tokinalens\\\\." }, "pipe": [{ "regexReplace": ["^.*$", "Tokina"] }] },
          { "from": { "urlRegex": "^https?://(?:[^/@?#]*@)?(?:[^/@?#.]*\\\\.)*?lksamyang\\\\." }, "pipe": [{ "regexReplace": ["^.*$", "Samyang"] }] },
          { "from": { "urlRegex": "^https?://(?:[^/@?#]*@)?(?:[^/@?#.]*\\\\.)*?meikeglobal\\\\." }, "pipe": [{ "regexReplace": ["^.*$", "Meike"] }] },
          { "from": { "urlRegex": "^https?://(?:[^/@?#]*@)?(?:[^/@?#.]*\\\\.)*?7artisans\\\\." }, "pipe": [{ "regexReplace": ["^.*$", "7Artisans"] }] },
          { "from": { "urlRegex": "^https?://(?:[^/@?#]*@)?(?:[^/@?#.]*\\\\.)*?ttartisan\\\\." }, "pipe": [{ "regexReplace": ["^.*$", "TTArtisan"] }] },
          { "from": { "urlRegex": "^https?://(?:[^/@?#]*@)?(?:[^/@?#.]*\\\\.)*?(?:voigtlaender|cosina)\\\\." }, "pipe": [{ "regexReplace": ["^.*$", "Voigtländer"] }] },
          { "from": { "urlRegex": "^https?://(?:[^/@?#]*@)?(?:[^/@?#.]*\\\\.)*?(?:yongnuo|hkyongnuo)\\\\." }, "pipe": [{ "regexReplace": ["^.*$", "Yongnuo"] }] },
          { "from": { "urlRegex": "^https?://(?:[^/@?#]*@)?(?:[^/@?#.]*\\\\.)*?(sony|zeiss|tamron|viltrox)\\\\." }, "pipe": ["lower", "capitalizeFirst"] }
        ]},
        { "name": "title", "candidates": [
          { "from": { "textRegex": "<h3[^>]*page-h3[^>]*>([^<]+)</h3>" }, "pipe": ["decodeEntities", "collapseWhitespace", "trim"] },
          { "from": { "meta": "og:title" },
            "pipe": ["trim", { "regexReplace": ["^(?:Just a moment.*|Access Denied.*|Sony Electronics.*|Not Found Page.*|LK SAMYANG)$", ""] }] },
          { "from": { "meta": "twitter:title" },
            "pipe": ["trim", { "regexReplace": ["^(?:Just a moment.*|Access Denied.*|Sony Electronics.*|Not Found Page.*|LK SAMYANG)$", ""] }] },
          { "from": { "textRegex": "<title[^>]*>([\\\\s\\\\S]*?)</title>" },
            "pipe": ["decodeEntities", "collapseWhitespace", "trim",
              { "regexReplace": ["^(?:Just a moment.*|Access Denied.*|Sony Electronics.*|Not Found Page.*|LK SAMYANG)$", ""] }] }
        ]},
        { "name": "summary", "candidates": [
          { "from": { "meta": "og:description" }, "pipe": ["trim", { "regexReplace": ["^.{0,2}$", ""] }] },
          { "from": { "meta": "description" } }
        ]},
        { "name": "image", "candidates": [{ "from": { "meta": "og:image" }, "pipe": ["resolveURL"], "as": "image" }] },
        { "name": "siteName", "candidates": [{ "from": { "meta": "og:site_name" } }] },
        { "name": "category", "candidates": [
          { "from": { "urlRegex": "^https?://[^/?#]+/(?:[^?#]*/)?(?:lenses|voigtlander)/|^https?://[^/?#]+/consumer-products/[^/?#]+/photography/" },
            "pipe": [{ "regexReplace": ["^.*$", "lens"] }] },
          { "from": { "field": "title" },
            "pipe": [
              { "regexReplace": ["(?is)^.*?[0-9](?:\\\\.[0-9]+)?\\\\s?mm.*?(?:f\\\\s?/\\\\s?|(?<=mm)f|(?<![a-z])[ft])[0-9].*$", "lens"] },
              { "regexReplace": ["(?s)^(?!lens$).*$", "product"] }
            ]}
        ]}
      ],
      "inference": { "categoryKeyword": { "lens": "lens", "product": "product" } },
      "examples": [
        { "input": "https://www.sigma-global.com/en/lenses/a019_24_70_28/", "expect": { "kind": "lens", "nonEmpty": ["title", "brand"] } },
        { "input": "https://www.tamron.com/global/consumer/lenses/b060/", "expect": { "kind": "lens", "nonEmpty": ["title", "brand"] } },
        { "input": "https://www.fujifilm-x.com/en-us/products/lenses/xf8-16mmf28-r-lm-wr/", "expect": { "kind": "lens", "nonEmpty": ["title", "brand"] } },
        { "input": "https://viltrox.com/products/af-9mm-f2-8-xf", "expect": { "kind": "lens", "nonEmpty": ["title", "brand"] } },
        { "input": "https://www.lksamyang.com/en/product/product-view.php?seq=531", "expect": { "kind": "lens", "nonEmpty": ["title", "brand"] } }
      ]
    },
    {
      "id": "camera.lens.sigma",
      "title": "Sigma lenses",
      "match": { "host": ["sigmaphoto.com"], "path": ["/:slug"], "priority": 100 },
      "use": ["ogCore"],
      "fetch": { "mode": "http", "ua": "desktopSafari" },
      "fields": [
        { "name": "brand", "candidates": [{ "from": { "const": "Sigma" } }] },
        { "name": "title", "candidates": [{ "from": { "meta": "og:title" }, "pipe": ["trim"] }] },
        { "name": "summary", "candidates": [
          { "from": { "meta": "description" } },
          { "from": { "meta": "og:description" } }
        ]},
        { "name": "category", "candidates": [
          { "from": { "urlRegex": "^https?://[^/?#]+/[0-9]+(?:-[0-9]+)?mm-[ft][0-9]" }, "pipe": [{ "regexReplace": ["^.*$", "lens"] }] },
          { "from": { "field": "title" },
            "pipe": [
              { "regexReplace": ["(?is)^.*?[0-9](?:\\\\.[0-9]+)?\\\\s?mm.*?(?:f\\\\s?/\\\\s?|(?<=mm)f|(?<![a-z])[ft])[0-9].*$", "lens"] },
              { "regexReplace": ["(?s)^(?!lens$).*$", "product"] }
            ]}
        ]}
      ],
      "inference": { "categoryKeyword": { "lens": "lens", "product": "product" } },
      "examples": [
        { "input": "https://www.sigmaphoto.com/10-18mm-f2-8-dc-dn-c", "expect": { "kind": "lens", "nonEmpty": ["title", "brand"] } },
        { "input": "https://www.sigmaphoto.com/16-300mm-f3-5-6-7-dc-os-c", "expect": { "kind": "lens", "nonEmpty": ["title", "brand"] } }
      ]
    }
"""
