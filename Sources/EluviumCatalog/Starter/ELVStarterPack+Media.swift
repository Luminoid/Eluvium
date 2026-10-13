/// The record-media chunks of the starter pack: the media roster (X, IMDb,
/// Spotify, Apple Music/Podcasts, 小宇宙, YouTube, Douban, Goodreads, IGDB,
/// IGN, Threads, Fragrantica), the 2026-08-29 feed-backed trio (Reddit via
/// its `.rss` URL template, YouTube channels via the id-template +
/// handle-page feed autodiscovery, Mastodon flagship instances via
/// profile-page autodiscovery; Telegram was surveyed and skipped — no feed,
/// no autodiscovery, only the t.me/s preview scrape), Xiaohongshu, and the
/// 微信读书 trio. (PokéAPI and themeparks.wiki live in +Reference.)
/// Composition contract in ELVStarterPack.swift (declaration order is
/// behavior; chunks carry no trailing comma).
///
/// `x.post` fetches the syndication JSON via a computed-param
/// URL template (`{native:x.syndicationToken@1(param.id)}`), falling to
/// oEmbed then the page's own OG tags on `{}` churn or blocks (both
/// fallback rungs name the prologue's `noTweetText` trigger).
/// `fragrantica.perfume` is http(crawler) → dom with the note
/// pyramid extracted by `notePyramid.fromProse@1`.
///
/// The 2026-08-23 media pass adds the record-media roster (Spotify, Apple
/// Music, Apple Podcasts, 小宇宙, YouTube, Douban, Goodreads, IGDB, IGN,
/// Threads) with the owner's picks corpus as examples — real curated
/// links, every fetch-based one curl-verified with the binary's persona
/// headers — and introduces the pack's first `fragments` (the shared
/// mobileSafari→crawler ladder, the OG field floor), multi-pattern
/// `match.path` lists, and URL-gated fetch steps (`when.hostMatches`).
/// Douban is one source across four shapes: the movie shape reroutes to
/// the m.douban.com mirror (movie.douban.com serves a login interstitial
/// to every UA), the game shape's OG only answers the mobileSafari
/// persona, and kinds come from host + category inference. The music,
/// book, and game shapes 302 the mobile persona to m.douban.com
/// themselves, and redirect canonicalization makes that the inference
/// context — so the category candidates also read the post-redirect
/// `m.douban.com/<category>/subject/` path, while `hostBrand` covers the
/// pre-redirect hosts (the movie template keeps its page URL). The
/// `m.douban.com/<category>/subject/:id` shapes are also match patterns in
/// their own right (the mobile site's share sheet produces them), ordered
/// before `/game/:id` so the game paste shape cannot mis-capture
/// "subject" as its id. IGDB sits
/// behind a Cloudflare wall, so it parses URL-only from its clean slugs;
/// Threads serves the author line as og:title and the post text as
/// og:description on both threads.com and threads.net. Goodreads resolves
/// by numeric id alone — the picks corpus caught id 15891700 serving a
/// different book than its slug claims, so example ids must be verified
/// against the returned og:title, never the slug.
///
/// The 2026-09-10 audit pass: imdb.title resolves its og:image against the
/// page URL like every other image ladder (IMDb serves absolute URLs
/// today; the pipe is the same defensive shape the rest of the pack uses);
/// fragrantica.perfume maps a `summary` (og:description, then
/// description); the feed-backed trio (reddit.subreddit, youtube.channel,
/// mastodon.profile) maps the envelope's `nextPage` pointer exactly as
/// generic.feed does (continuation stays host-driven); Xiaoyuzhou's
/// episodes collection carries the `episode` kind (the parent already says
/// podcast, so `podcastEpisode` repeated it, and no other kind token is
/// camelCase). (xiaohongshu.post rode `ogCore` from that pass until
/// 2026-10-10: the crawler persona now lands on /login, whose generic title
/// satisfied the fragment and made dead fetches read green. It fetches as
/// mobileSafari, which gets the server-rendered note, reads title, desc,
/// and the first image from the page's `noteData` state, and blanks the
/// wall titles (小红书, the login and 404 shells, 安全限制) so a walled
/// fetch escalates to dom and fails visibly instead.) Fragrantica dropped
/// its JSON-LD the same season: the rating and vote count now come from
/// the page's schema.org microdata and the title from its `h1`, with the
/// JSON-LD candidates kept first in case the block returns; the og:title
/// fallback loses its "cologne - a fragrance for men 2015" tail.
///
/// The 2026-10-10 audit. Fields: x.post maps generic.feed's names (`image`
/// for the photo, `author`, `handle` like threads.post, `published`).
/// `ogCore` now backs imdb.title and fragrantica.perfume too; each keeps
/// inline only the ladder the fragment cannot express. IMDb's JSON-LD title
/// and summary must outrank the fragment's OG candidates. Fragrantica's
/// whole title ladder stays inline because it is order-dependent: JSON-LD,
/// then the `h1`, then an og:title whose descriptor tail is cut, then the
/// URL slug, which always produces, so the fragment's raw og:title appended
/// after it is inert by design. Identity: Spotify and Apple Music tracks
/// declare `spotify` / `applemusic.song`, Apple Podcasts declares the
/// built-in `itunes.podcast`, youtube.video reads its identity from
/// `externalId` (so youtu.be and /shorts/ links carry one, not only
/// `?v=`), Douban movie shapes add the built-in `douban.film`, and the feed
/// trio keys on the channel id, the lowercased subreddit, and
/// `handle@instance`. YouTube channel items strip the feed's `yt:video:`
/// prefix and declare `youtube.video`, so an item and the pasted video are
/// one entity. Xiaoyuzhou authors no kind: the path segment rides a
/// `category` field into the inference table (`/episode/` is an `episode`,
/// matching the collection children that share its record key), and
/// episodes get their own `xiaoyuzhou.episode` namespace. Douban's movie
/// shape fetches through a template step that keeps the movie.douban.com
/// page URL, so its `category` reads that host (it was the one shape
/// whose category never filled). youtube.channel opens with a channel-page
/// step whose scoped fields read og:image and og:description, which the
/// channel feed never carries; the @handle shape pays a second fetch of the
/// same page (the feed step's autodiscovery hop discards the page document).
/// Since 2026-10-12 that step also reads og:title and the page's
/// `identifier` meta (the UC id, guarded by shape): youtube.com's feed
/// endpoint answered 404 for every channel that day (an upstream spell
/// feeder.co documents), and a failed feed step keeps only what the page
/// step extracted, so the record stays titled and keyed while `items` is
/// honestly unmet. Where the feed produces, its title and id win by the
/// fill-empty merge.
let starterMediaJSON = """
    {
      "id": "x.post",
      "title": "X",
      "kind": "post",
      "match": { "host": ["x.com", "twitter.com"], "path": "/:user/status/:id", "priority": 100 },
      "canonicalize": { "strip": ["s", "t", "ref_src", "ref_url"] },
      "fetch": { "mode": "composite", "steps": [
        { "mode": "json", "url": "https://cdn.syndication.twimg.com/tweet-result?id={param.id}&token={native:x.syndicationToken@1(param.id)}" },
        { "mode": "json", "url": "https://publish.x.com/oembed?url=https%3A%2F%2Fx.com%2F{param.user}%2Fstatus%2F{param.id}", "when": "noTweetText" },
        { "mode": "http", "ua": "desktopSafari", "when": "noTweetText" }
      ]},
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlParam": "id" } }] },
        { "name": "text", "candidates": [
          { "from": { "json": "$.text" } },
          { "from": { "json": "$.html" }, "pipe": [{ "regexReplace": ["<[^>]*>", " "] }, "decodeEntities", "collapseWhitespace", "trim"] },
          { "from": { "meta": "og:description" } }
        ]},
        { "name": "title", "candidates": [
          { "from": { "field": "text" } },
          { "from": { "meta": "og:title" } }
        ]},
        { "name": "author", "candidates": [
          { "from": { "json": "$.user.name" } },
          { "from": { "json": "$.author_name" } }
        ]},
        { "name": "handle", "candidates": [
          { "from": { "json": "$.user.screen_name" } },
          { "from": { "json": "$.author_url" }, "pipe": [{ "regexReplace": ["^.*/", ""] }] }
        ]},
        { "name": "published", "candidates": [{ "from": { "json": "$.created_at" }, "as": "date" }] },
        { "name": "likeCount", "candidates": [{ "from": { "json": "$.favorite_count" }, "as": "int" }] },
        { "name": "image", "candidates": [
          { "from": { "json": "$.photos[0].url" }, "as": "image" },
          { "from": { "json": "$.mediaDetails[0].media_url_https" }, "as": "image" }
        ]},
        { "name": "video", "candidates": [{ "from": { "json": "$.video.variants[0].src" }, "as": "video" }] }
      ],
      "identities": [{ "ns": "x.tweet", "from": { "urlParam": "id" } }],
      "requires": ["native:x.syndicationToken@1"],
      "examples": [
        { "input": "https://x.com/jack/status/20", "expect": { "kind": "post", "nonEmpty": ["text", "handle"] } },
        { "input": "https://twitter.com/naval/status/1002103360646823936", "expect": { "kind": "post", "nonEmpty": ["text"] } },
        { "input": "https://x.com/i/status/440322224407314432", "expect": { "kind": "post", "nonEmpty": ["text", "image"] } }
      ]
    },
    {
      "id": "imdb.title",
      "title": "IMDb",
      "kind": "movie",
      "match": { "host": ["imdb.com"], "path": "/title/:id/**", "priority": 100 },
      "canonicalize": { "strip": ["ref_", "ref"] },
      "use": ["httpEscalate", "ogCore"],
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlParam": "id" } }] },
        { "name": "title", "candidates": [{ "from": { "jsonld": "Movie.name" } }] },
        { "name": "summary", "candidates": [{ "from": { "jsonld": "Movie.description" } }] },
        { "name": "rating", "candidates": [{ "from": { "jsonld": "Movie.aggregateRating.ratingValue" }, "as": "rating", "scale": { "min": 0, "max": 10 } }] }
      ],
      "identities": [{ "ns": "imdb", "from": { "urlParam": "id" } }],
      "examples": [
        { "input": "https://www.imdb.com/title/tt0076759/", "expect": { "kind": "movie", "nonEmpty": ["title"] } },
        { "input": "https://www.imdb.com/title/tt0080684/", "expect": { "kind": "movie", "nonEmpty": ["title"] } },
        { "input": "https://www.imdb.com/title/tt0086190/", "expect": { "kind": "movie", "nonEmpty": ["title"] } }
      ]
    },
    {
      "id": "spotify.media",
      "title": "Spotify",
      "match": { "host": ["open.spotify.com"], "path": ["/album/:id", "/track/:id", "/show/:id"], "priority": 100 },
      "use": ["ogCore"],
      "fetch": { "mode": "composite", "steps": [
        { "mode": "http", "ua": "mobileSafari" },
        { "mode": "http", "ua": "crawler", "when": "blockedOrThin" },
        { "mode": "http", "ua": "mobileSafari", "url": "https://open.spotify.com/embed/track/{param.id}", "jsonIsland": "__NEXT_DATA__", "when": { "pathRegex": "^/track/" },
          "fields": [
            { "name": "externalId", "candidates": [{ "from": { "urlParam": "id" } }] },
            { "name": "audio", "candidates": [{ "from": { "json": "$.props.pageProps.state.data.entity.audioPreview.url" }, "as": "audio" }] }
          ]},
        { "mode": "http", "ua": "mobileSafari", "url": "https://open.spotify.com/embed/album/{param.id}", "jsonIsland": "__NEXT_DATA__", "when": { "pathRegex": "^/album/" },
          "fields": [{ "name": "externalId", "candidates": [{ "from": { "urlParam": "id" } }] }],
          "collections": [
            {
              "name": "tracks",
              "from": { "json": "$.props.pageProps.state.data.entity.trackList[*]" },
              "kind": "song",
              "item": [
                { "name": "externalId", "candidates": [{ "from": { "json": "$.uri" }, "pipe": [{ "regexReplace": ["^spotify:track:", ""] }] }] },
                { "name": "title", "candidates": [{ "from": { "json": "$.title" } }] },
                { "name": "artist", "candidates": [{ "from": { "json": "$.subtitle" } }] },
                { "name": "audio", "candidates": [{ "from": { "json": "$.audioPreview.url" }, "as": "audio" }] }
              ],
              "identities": [{ "ns": "spotify", "from": { "field": "externalId" } }]
            }
          ]}
      ] },
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlParam": "id" } }] },
        { "name": "title", "candidates": [
          { "from": { "meta": "og:title" }, "pipe": [{ "regexReplace": [" - (?:Album|Single|EP) by .*$", ""] }, { "stripSuffix": " | Spotify" }, "trim"] }
        ]},
        { "name": "category", "candidates": [{ "from": { "urlRegex": "^https?://open\\\\.spotify\\\\.com/(album|track|show)/" } }] }
      ],
      "inference": { "categoryKeyword": { "album": "album", "track": "song", "show": "podcast" } },
      "identities": [{ "ns": "spotify", "from": { "urlRegex": "^https?://open\\\\.spotify\\\\.com/(?:album|track|show)/([A-Za-z0-9]+)" } }],
      "examples": [
        { "input": "https://open.spotify.com/album/6dVIqQ8qmQ5GBnJ9shOYGE", "expect": { "kind": "album", "nonEmpty": ["title"] } },
        { "input": "https://open.spotify.com/album/1Lzi2p6CUH156zbJTcOjNX", "expect": { "kind": "album", "nonEmpty": ["title"] } },
        { "input": "https://open.spotify.com/track/2EuMREhmnIPQFaqXUH5yPu", "expect": { "kind": "song", "nonEmpty": ["title"] } },
        { "input": "https://open.spotify.com/track/1JIzFhI9Lt5FyslawmHCBi", "expect": { "kind": "song", "nonEmpty": ["title"] } },
        { "input": "https://open.spotify.com/show/4rOoJ6Egrf8K2IrywzwOMk", "expect": { "kind": "podcast", "nonEmpty": ["title"] } }
      ]
    },
    {
      "id": "applemusic.album",
      "title": "Apple Music",
      "kind": "album",
      "match": { "host": ["music.apple.com"], "path": "/:storefront/album/:slug/:id", "priority": 100 },
      "use": ["ogCore"],
      "fetch": { "mode": "composite", "steps": [
        { "mode": "http", "ua": "mobileSafari" },
        { "mode": "http", "ua": "crawler", "when": "blockedOrThin" },
        { "mode": "json", "url": "https://itunes.apple.com/lookup?id={param.id}&entity=song",
          "fields": [{ "name": "externalId", "candidates": [{ "from": { "urlParam": "id" } }] }],
          "collections": [
            {
              "name": "tracks",
              "from": { "json": "$.results[*]" },
              "kind": "song",
              "item": [
                { "name": "externalId", "candidates": [{ "from": { "json": "$.trackId" } }] },
                { "name": "title", "candidates": [{ "from": { "json": "$.trackName" } }] },
                { "name": "trackNumber", "candidates": [{ "from": { "json": "$.trackNumber" }, "as": "int" }] },
                { "name": "audio", "candidates": [{ "from": { "json": "$.previewUrl" }, "as": "audio" }] }
              ],
              "identities": [{ "ns": "applemusic.song", "from": { "field": "externalId" } }]
            }
          ]}
      ] },
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlParam": "id" } }] },
        { "name": "title", "candidates": [
          { "from": { "jsonld": "MusicAlbum.name" }, "pipe": ["decodeEntities", "trim"] },
          { "from": { "meta": "og:title" }, "pipe": [{ "regexReplace": [" by .+ on Apple Music$", ""] }] }
        ]},
        { "name": "artist", "candidates": [{ "from": { "jsonld": "MusicAlbum.byArtist.name" }, "pipe": ["decodeEntities", "trim"] }] }
      ],
      "identities": [{ "ns": "applemusic.album", "from": { "urlParam": "id" } }],
      "examples": [
        { "input": "https://music.apple.com/us/album/in-the-court-of-the-crimson-king-expanded-edition/918534711", "expect": { "kind": "album", "nonEmpty": ["title"] } },
        { "input": "https://music.apple.com/us/album/the-dark-side-of-the-moon/1065973699", "expect": { "kind": "album", "nonEmpty": ["title"] } },
        { "input": "https://music.apple.com/us/album/hymn-to-the-immortal-wind-anniversary-edition/318889559", "expect": { "kind": "album", "nonEmpty": ["title"] } },
        { "input": "https://music.apple.com/us/album/%E9%BB%91%E5%A4%A2/158796449", "expect": { "kind": "album", "nonEmpty": ["title"] } }
      ]
    },
    {
      "id": "applepodcasts.show",
      "title": "Apple Podcasts",
      "kind": "podcast",
      "match": { "host": ["podcasts.apple.com"], "path": "/:storefront/podcast/:slug/:id", "priority": 100 },
      "use": ["ogCore"],
      "fetch": { "mode": "composite", "steps": [
        { "mode": "http", "ua": "mobileSafari" },
        { "mode": "http", "ua": "crawler", "when": "blockedOrThin" },
        { "mode": "json", "url": "https://itunes.apple.com/lookup?id={native:text.digits@1(param.id)}",
          "fields": [
            { "name": "externalId", "candidates": [{ "from": { "urlRegex": "/podcast/[^/]+/id([0-9]+)" } }] },
            { "name": "feedUrl", "candidates": [{ "from": { "json": "$.results[0].feedUrl" }, "as": "url" }] },
            { "name": "author", "candidates": [{ "from": { "json": "$.results[0].artistName" } }] },
            { "name": "episodeCount", "candidates": [{ "from": { "json": "$.results[0].trackCount" }, "as": "int" }] }
          ]}
      ] },
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlRegex": "/podcast/[^/]+/id([0-9]+)" } }] }
      ],
      "identities": [{ "ns": "itunes.podcast", "from": { "urlRegex": "/podcast/[^/]+/id([0-9]+)" } }],
      "examples": [
        { "input": "https://podcasts.apple.com/us/podcast/the-daily/id1200361736", "expect": { "kind": "podcast", "nonEmpty": ["title"] } },
        { "input": "https://podcasts.apple.com/us/podcast/this-american-life/id201671138", "expect": { "kind": "podcast", "nonEmpty": ["title"] } },
        { "input": "https://podcasts.apple.com/us/podcast/radiolab/id152249110", "expect": { "kind": "podcast", "nonEmpty": ["title"] } },
        { "input": "https://podcasts.apple.com/us/podcast/planet-money/id290783428", "expect": { "kind": "podcast", "nonEmpty": ["title"] } }
      ]
    },
    {
      "id": "xiaoyuzhou.podcast",
      "title": "小宇宙",
      "match": { "host": ["xiaoyuzhoufm.com"], "path": ["/podcast/:id", "/episode/:id"], "priority": 100 },
      "use": ["ogCore"],
      "fetch": { "mode": "composite", "steps": [
        { "mode": "http", "ua": "mobileSafari", "jsonIsland": "__NEXT_DATA__" },
        { "mode": "http", "ua": "crawler", "jsonIsland": "__NEXT_DATA__", "when": "blockedOrThin" }
      ] },
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlParam": "id" } }] },
        { "name": "author", "candidates": [
          { "from": { "json": "$.props.pageProps.podcast.author" } },
          { "from": { "json": "$.props.pageProps.episode.podcast.author" } }
        ]},
        { "name": "episodeCount", "candidates": [{ "from": { "json": "$.props.pageProps.podcast.episodeCount" }, "as": "int" }] },
        { "name": "audio", "candidates": [{ "from": { "json": "$.props.pageProps.episode.enclosure.url" }, "as": "audio" }] },
        { "name": "duration", "candidates": [{ "from": { "json": "$.props.pageProps.episode.duration" }, "as": "duration" }] },
        { "name": "category", "candidates": [{ "from": { "urlRegex": "^https?://(?:www\\\\.)?xiaoyuzhoufm\\\\.com/(podcast|episode)/" } }] }
      ],
      "inference": { "categoryKeyword": { "podcast": "podcast", "episode": "episode" } },
      "collections": [
        {
          "name": "episodes",
          "from": { "json": "$.props.pageProps.podcast.episodes[*]" },
          "kind": "episode",
          "item": [
            { "name": "externalId", "candidates": [{ "from": { "json": "$.eid" } }] },
            { "name": "title", "candidates": [{ "from": { "json": "$.title" } }] },
            { "name": "summary", "candidates": [{ "from": { "json": "$.description" } }] },
            { "name": "audio", "candidates": [
              { "from": { "json": "$.enclosure.url" }, "as": "audio" },
              { "from": { "json": "$.media.source.url" }, "as": "audio" }
            ]},
            { "name": "duration", "candidates": [{ "from": { "json": "$.duration" }, "as": "duration" }] },
            { "name": "published", "candidates": [{ "from": { "json": "$.pubDate" }, "as": "date" }] },
            { "name": "image", "candidates": [{ "from": { "json": "$.image.picUrl" }, "as": "image" }] }
          ],
          "identities": [{ "ns": "xiaoyuzhou.episode", "from": { "field": "externalId" } }]
        }
      ],
      "identities": [
        { "ns": "xiaoyuzhou.podcast", "from": { "urlRegex": "/podcast/([A-Za-z0-9]+)" } },
        { "ns": "xiaoyuzhou.episode", "from": { "urlRegex": "/episode/([A-Za-z0-9]+)" } }
      ],
      "examples": [
        { "input": "https://www.xiaoyuzhoufm.com/podcast/5e4ee557418a84a0466737b7", "expect": { "kind": "podcast", "nonEmpty": ["title"], "nonEmptyCollections": ["episodes"] } },
        { "input": "https://www.xiaoyuzhoufm.com/podcast/5e7cc741418a84a046b0c2bd", "expect": { "kind": "podcast", "nonEmpty": ["title"] } },
        { "input": "https://www.xiaoyuzhoufm.com/episode/60c5f47cc2ec9bd456ec633b", "expect": { "kind": "episode", "nonEmpty": ["title", "audio"] } }
      ]
    },
    {
      "id": "youtube.video",
      "title": "YouTube",
      "kind": "video",
      "match": { "host": ["youtube.com", "youtu.be"], "path": "/**", "priority": 100 },
      "use": ["httpEscalate", "ogCore"],
      "fields": [
        { "name": "externalId", "candidates": [
          { "from": { "urlQuery": "v" } },
          { "from": { "urlRegex": "^https?://youtu\\\\.be/([A-Za-z0-9_-]+)" } },
          { "from": { "urlRegex": "/shorts/([A-Za-z0-9_-]+)" } }
        ]}
      ],
      "identities": [{ "ns": "youtube.video", "from": { "field": "externalId" } }],
      "examples": [
        { "input": "https://www.youtube.com/watch?v=cQcE4_7-X78", "expect": { "kind": "video", "nonEmpty": ["title"] } },
        { "input": "https://www.youtube.com/watch?v=dQw4w9WgXcQ", "expect": { "kind": "video", "nonEmpty": ["title"] } },
        { "input": "https://www.youtube.com/watch?v=hTWKbfoikeg", "expect": { "kind": "video", "nonEmpty": ["title"] } },
        { "input": "https://youtu.be/dQw4w9WgXcQ", "expect": { "kind": "video", "nonEmpty": ["title"] } }
      ]
    },
    {
      "id": "douban.subject",
      "title": "豆瓣",
      "imageReferer": "page",
      "match": { "host": ["douban.com"], "priority": 100,
        "path": ["/subject/:id/**", "/movie/subject/:id/**", "/music/subject/:id/**", "/book/subject/:id/**", "/game/subject/:id/**", "/game/:id/**"] },
      "fetch": { "mode": "composite", "steps": [
        { "mode": "http", "ua": "mobileSafari", "url": "https://m.douban.com/movie/subject/{param.id}/", "when": { "hostMatches": ["movie.douban.com"] } },
        { "mode": "http", "ua": "mobileSafari", "when": { "hostMatches": ["music.douban.com", "book.douban.com", "www.douban.com", "m.douban.com"] } },
        { "mode": "http", "ua": "crawler", "when": { "hostMatches": ["music.douban.com", "book.douban.com", "www.douban.com", "m.douban.com"], "anyOf": [
          { "status": [403, 429, 503] },
          { "emptyRecord": true },
          { "missingAny": ["title"] }
        ]}}
      ]},
      "use": ["ogCore"],
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlParam": "id" } }] },
        { "name": "title", "candidates": [
          { "from": { "meta": "og:title" }, "pipe": [{ "stripSuffix": " - 唱片" }, { "stripSuffix": " - 电影" }, { "stripSuffix": " - 图书" }, { "stripSuffix": " - 游戏" }, "trim"] }
        ]},
        { "name": "category", "candidates": [
          { "from": { "urlRegex": "^https?://(?:www\\\\.)?douban\\\\.com/(game)/" } },
          { "from": { "urlRegex": "^https?://m\\\\.douban\\\\.com/(music|movie|book|game)/subject/" } },
          { "from": { "urlRegex": "^https?://(music|movie|book)\\\\.douban\\\\.com/subject/" } }
        ]}
      ],
      "inference": {
        "hostBrand": { "music.douban.com": "album", "movie.douban.com": "movie", "book.douban.com": "book" },
        "categoryKeyword": { "game": "game", "music": "album", "movie": "movie", "book": "book" }
      },
      "identities": [
        { "ns": "douban.subject", "from": { "urlParam": "id" } },
        { "ns": "douban.film", "from": { "urlRegex": "^https?://(?:movie\\\\.douban\\\\.com|m\\\\.douban\\\\.com/movie)/subject/([0-9]+)" } }
      ],
      "examples": [
        { "input": "https://music.douban.com/subject/1394653/", "expect": { "kind": "album", "nonEmpty": ["title"] } },
        { "input": "https://music.douban.com/subject/1417523/", "expect": { "kind": "album", "nonEmpty": ["title"] } },
        { "input": "https://movie.douban.com/subject/1292226/", "expect": { "kind": "movie", "nonEmpty": ["title"] } },
        { "input": "https://movie.douban.com/subject/1295399/", "expect": { "kind": "movie", "nonEmpty": ["title"] } },
        { "input": "https://book.douban.com/subject/6518605/", "expect": { "kind": "book", "nonEmpty": ["title"] } },
        { "input": "https://book.douban.com/subject/24257486/", "expect": { "kind": "book", "nonEmpty": ["title"] } },
        { "input": "https://www.douban.com/game/26362172/", "expect": { "kind": "game", "nonEmpty": ["title"] } },
        { "input": "https://www.douban.com/game/26817171/", "expect": { "kind": "game", "nonEmpty": ["title"] } },
        { "input": "https://m.douban.com/movie/subject/1292226/", "expect": { "kind": "movie", "nonEmpty": ["title"] } },
        { "input": "https://m.douban.com/game/subject/26362172/", "expect": { "kind": "game", "nonEmpty": ["title"] } }
      ]
    },
    {
      "id": "goodreads.book",
      "title": "Goodreads",
      "kind": "book",
      "match": { "host": ["goodreads.com"], "path": "/book/show/:slug", "priority": 100 },
      "use": ["ogCore"],
      "fetch": { "mode": "composite", "steps": [
        { "mode": "http", "ua": "mobileSafari" },
        { "mode": "http", "ua": "crawler", "when": "blockedOrThin" },
        { "mode": "dom", "ua": "mobileSafari", "settle": { "signals": ["og:title", "jsonld"] }, "when": "blockedOrThin" }
      ]},
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlRegex": "/book/show/([0-9]+)" } }] },
        { "name": "title", "candidates": [{ "from": { "jsonld": "Book.name" }, "pipe": ["decodeEntities", "trim"] }] },
        { "name": "author", "candidates": [{ "from": { "jsonld": "Book.author.name" }, "pipe": ["decodeEntities", "trim"] }] },
        { "name": "rating", "candidates": [{ "from": { "jsonld": "Book.aggregateRating.ratingValue" }, "as": "rating" }] }
      ],
      "identities": [{ "ns": "goodreads.book", "from": { "urlRegex": "/book/show/([0-9]+)" } }],
      "examples": [
        { "input": "https://www.goodreads.com/book/show/20518872-the-three-body-problem", "expect": { "kind": "book", "nonEmpty": ["title"] } },
        { "input": "https://www.goodreads.com/book/show/49552.The_Stranger", "expect": { "kind": "book", "nonEmpty": ["title"] } },
        { "input": "https://www.goodreads.com/book/show/70535.2001", "expect": { "kind": "book", "nonEmpty": ["title"] } },
        { "input": "https://www.goodreads.com/book/show/5129.Brave_New_World", "expect": { "kind": "book", "nonEmpty": ["title"] } }
      ]
    },
    {
      "id": "igdb.game",
      "title": "IGDB",
      "kind": "game",
      "match": { "host": ["igdb.com"], "path": "/games/:slug/**", "priority": 100 },
      "fetch": { "mode": "none" },
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlParam": "slug" } }] },
        { "name": "title", "candidates": [{ "from": { "urlParam": "slug" }, "pipe": ["slugToTitle"] }] }
      ],
      "identities": [{ "ns": "igdb.game", "from": { "urlParam": "slug" } }],
      "examples": [
        { "input": "https://www.igdb.com/games/outer-wilds", "expect": { "kind": "game", "nonEmpty": ["title"] } },
        { "input": "https://www.igdb.com/games/the-legend-of-zelda-breath-of-the-wild", "expect": { "kind": "game", "nonEmpty": ["title"] } },
        { "input": "https://www.igdb.com/games/the-witness", "expect": { "kind": "game", "nonEmpty": ["title"] } },
        { "input": "https://www.igdb.com/games/stardew-valley", "expect": { "kind": "game", "nonEmpty": ["title"] } }
      ]
    },
    {
      "id": "ign.game",
      "title": "IGN",
      "kind": "game",
      "match": { "host": ["ign.com"], "path": "/games/:slug/**", "priority": 100 },
      "use": ["httpEscalate", "ogCore"],
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlParam": "slug" } }] },
        { "name": "title", "candidates": [
          { "from": { "meta": "og:title" }, "pipe": [{ "stripSuffix": " - IGN" }] },
          { "from": { "urlParam": "slug" }, "pipe": ["slugToTitle"] }
        ]}
      ],
      "identities": [{ "ns": "ign.game", "from": { "urlParam": "slug" } }],
      "examples": [
        { "input": "https://www.ign.com/games/outer-wilds", "expect": { "kind": "game", "nonEmpty": ["title"] } },
        { "input": "https://www.ign.com/games/the-witness", "expect": { "kind": "game", "nonEmpty": ["title"] } },
        { "input": "https://www.ign.com/games/journey", "expect": { "kind": "game", "nonEmpty": ["title"] } },
        { "input": "https://www.ign.com/games/red-dead-redemption-2", "expect": { "kind": "game", "nonEmpty": ["title"] } }
      ]
    },
    {
      "id": "threads.post",
      "title": "Threads",
      "kind": "post",
      "match": { "host": ["threads.com", "threads.net"], "path": "/:handle/post/:code/**", "priority": 100 },
      "use": ["httpEscalate", "ogCore"],
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlParam": "code" } }] },
        { "name": "handle", "candidates": [{ "from": { "urlParam": "handle" }, "pipe": [{ "stripPrefix": "@" }] }] }
      ],
      "identities": [{ "ns": "threads.post", "from": { "urlParam": "code" } }],
      "examples": [
        { "input": "https://www.threads.com/@zuck/post/DIFAsupTS7Z", "expect": { "kind": "post", "nonEmpty": ["title"] } },
        { "input": "https://www.threads.com/@mosseri/post/Cy1rb6TPfXY", "expect": { "kind": "post", "nonEmpty": ["title"] } },
        { "input": "https://www.threads.com/@nasa/post/DXDP0zPF4a3", "expect": { "kind": "post", "nonEmpty": ["title"] } },
        { "input": "https://www.threads.com/@threads/post/DDFkqNuPil1", "expect": { "kind": "post", "nonEmpty": ["title"] } }
      ]
    },
    {
      "id": "fragrantica.perfume",
      "title": "Fragrantica",
      "kind": "perfume",
      "match": { "host": ["fragrantica.com"], "path": "/perfume/:brand/:slug", "priority": 100 },
      "use": ["ogCore"],
      "fetch": { "mode": "composite", "steps": [
        { "mode": "http", "ua": "crawler" },
        { "mode": "dom", "ua": "desktopSafari", "settle": { "signals": ["h1", "jsonld", "og:title"] }, "when": "blockedOrThin"}
      ]},
      "fields": [
        { "name": "externalId", "candidates": [
          { "from": { "urlRegex": "/perfume/[^/]+/[^/]+-([0-9]+)\\\\.html" } },
          { "from": { "urlParam": "slug" } }
        ]},
        { "name": "title", "candidates": [
          { "from": { "jsonld": "Product.name" }, "pipe": ["decodeEntities", "trim"] },
          { "from": { "textRegex": "<h1 itemprop=\\"name\\"[^>]*>\\\\s*([^<]+?)\\\\s*<" }, "pipe": ["decodeEntities", "collapseWhitespace", "trim"] },
          { "from": { "meta": "og:title" }, "pipe": [{ "regexReplace": ["\\\\s+(?:perfume|cologne)\\\\s+-\\\\s+a fragrance for .*$", ""] }, "trim"] },
          { "from": { "urlParam": "slug" }, "pipe": [{ "regexReplace": ["-[0-9]+\\\\.html$", ""] }, "slugToTitle"] }
        ]},
        { "name": "brand", "candidates": [
          { "from": { "jsonld": "Product.brand.name" }, "pipe": ["decodeEntities", "trim"] },
          { "from": { "jsonld": "Product.brand" }, "pipe": ["decodeEntities", "trim"] },
          { "from": { "urlParam": "brand" }, "pipe": ["slugToTitle"] }
        ]},
        { "name": "rating", "candidates": [
          { "from": { "jsonld": "Product.aggregateRating.ratingValue" }, "as": "rating" },
          { "from": { "textRegex": "itemprop=\\"ratingValue\\"[^>]*>\\\\s*([0-9]+(?:\\\\.[0-9]+)?)\\\\s*<" }, "as": "rating" }
        ]},
        { "name": "ratingCount", "candidates": [{ "from": { "textRegex": "itemprop=\\"ratingCount\\" content=\\"([0-9]+)\\"" }, "as": "int" }] },
        { "name": "topNotes", "candidates": [{ "from": { "native": "notePyramid.fromProse@1" }, "select": "top" }] },
        { "name": "heartNotes", "candidates": [{ "from": { "native": "notePyramid.fromProse@1" }, "select": "heart" }] },
        { "name": "baseNotes", "candidates": [{ "from": { "native": "notePyramid.fromProse@1" }, "select": "base" }] },
        { "name": "notes", "candidates": [{ "from": { "native": "notePyramid.fromProse@1" }, "select": "notes" }] }
      ],
      "identities": [{ "ns": "fragrantica.perfume", "from": { "urlRegex": "/perfume/[^/]+/[^/]+-([0-9]+)\\\\.html" } }],
      "requires": ["native:notePyramid.fromProse@1"],
      "examples": [
        { "input": "https://www.fragrantica.com/perfume/Chanel/Bleu-de-Chanel-Eau-de-Parfum-25967.html", "expect": { "kind": "perfume", "nonEmpty": ["title"] } },
        { "input": "https://www.fragrantica.com/perfume/Christian-Dior/Sauvage-31861.html", "expect": { "kind": "perfume", "nonEmpty": ["title"] } },
        { "input": "https://www.fragrantica.com/perfume/Hermes/Terre-d-Hermes-17.html", "expect": { "kind": "perfume", "nonEmpty": ["title"] } },
        { "input": "https://www.fragrantica.com/perfume/Le-Labo/Santal-33-12201.html", "expect": { "kind": "perfume", "nonEmpty": ["title"] } }
      ]
    },
    {
      "id": "reddit.subreddit",
      "title": "Reddit",
      "kind": "feed",
      "match": { "host": ["reddit.com"], "path": "/r/:name", "priority": 100 },
      "fetch": { "mode": "feed", "url": "https://www.reddit.com/r/{param.name}/.rss", "ua": "desktopSafari" },
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "urlParam": "name" }, "pipe": ["lower"] }] },
        { "name": "title", "candidates": [{ "from": { "json": "$.title" } }] },
        { "name": "summary", "candidates": [{ "from": { "json": "$.description" } }] },
        { "name": "link", "candidates": [{ "from": { "json": "$.link" }, "as": "url" }] },
        { "name": "image", "candidates": [{ "from": { "json": "$.image" }, "pipe": [{ "stripSuffix": "/" }], "as": "image" }] },
        { "name": "nextPage", "candidates": [{ "from": { "json": "$.nextURL" }, "as": "url" }] }
      ],
      "collections": [
        {
          "name": "items",
          "from": { "json": "$.items[*]" },
          "kind": "post",
          "item": [
            { "name": "externalId", "candidates": [{ "from": { "json": "$.externalId" } }] },
            { "name": "title", "candidates": [{ "from": { "json": "$.title" } }] },
            { "name": "summary", "candidates": [{ "from": { "json": "$.summary" } }] },
            { "name": "content", "candidates": [{ "from": { "json": "$.contentHTML" }, "pipe": ["rewriteLazyImages"] }] },
            { "name": "link", "candidates": [{ "from": { "json": "$.link" }, "as": "url" }] },
            { "name": "published", "candidates": [{ "from": { "json": "$.published" }, "as": "date" }] },
            { "name": "image", "candidates": [{ "from": { "json": "$.image" }, "as": "image" }] }
          ]
        }
      ],
      "identities": [{ "ns": "reddit.subreddit", "from": { "field": "externalId" } }],
      "examples": [
        { "input": "https://www.reddit.com/r/iOSProgramming/", "expect": { "kind": "feed", "nonEmpty": ["title"], "nonEmptyCollections": ["items"] } },
        { "input": "https://www.reddit.com/r/programming/", "expect": { "kind": "feed", "nonEmpty": ["title"] } },
        { "input": "https://www.reddit.com/r/apple/", "expect": { "kind": "feed", "nonEmpty": ["title"] } },
        { "input": "https://www.reddit.com/r/podcasts/", "expect": { "kind": "feed", "nonEmpty": ["title"] } }
      ]
    },
    {
      "id": "youtube.channel",
      "title": "YouTube channel",
      "kind": "feed",
      "match": { "host": ["youtube.com"], "path": ["/channel/:id", "/@:handle"], "priority": 110 },
      "fetch": { "mode": "composite", "steps": [
        { "mode": "http", "ua": "desktopSafari",
          "fields": [
            { "name": "title", "candidates": [{ "from": { "meta": "og:title" }, "pipe": ["decodeEntities", "trim"] }] },
            { "name": "externalId", "candidates": [{ "from": { "meta": "identifier" }, "pipe": ["trim", { "regexReplace": ["^(?!UC[A-Za-z0-9_-]{22}$).*$", ""] }] }] },
            { "name": "summary", "candidates": [{ "from": { "meta": "og:description" }, "pipe": ["decodeEntities", "trim"] }] },
            { "name": "image", "candidates": [{ "from": { "meta": "og:image" }, "pipe": ["resolveURL"], "as": "image" }] }
          ]},
        { "mode": "feed", "url": "https://www.youtube.com/feeds/videos.xml?channel_id={param.id}", "when": { "pathRegex": "^/channel/" } },
        { "mode": "feed", "ua": "desktopSafari", "when": { "pathRegex": "^/@" } }
      ]},
      "fields": [
        { "name": "externalId", "candidates": [
          { "from": { "urlParam": "id" } },
          { "from": { "urlQuery": "channel_id" } }
        ]},
        { "name": "title", "candidates": [{ "from": { "json": "$.title" } }] },
        { "name": "author", "candidates": [{ "from": { "json": "$.author" } }] },
        { "name": "link", "candidates": [{ "from": { "json": "$.link" }, "as": "url" }] },
        { "name": "nextPage", "candidates": [{ "from": { "json": "$.nextURL" }, "as": "url" }] }
      ],
      "collections": [
        {
          "name": "items",
          "from": { "json": "$.items[*]" },
          "kind": "video",
          "item": [
            { "name": "externalId", "candidates": [{ "from": { "json": "$.externalId" }, "pipe": [{ "stripPrefix": "yt:video:" }] }] },
            { "name": "title", "candidates": [{ "from": { "json": "$.title" } }] },
            { "name": "summary", "candidates": [{ "from": { "json": "$.summary" } }] },
            { "name": "link", "candidates": [{ "from": { "json": "$.link" }, "as": "url" }] },
            { "name": "published", "candidates": [{ "from": { "json": "$.published" }, "as": "date" }] },
            { "name": "image", "candidates": [{ "from": { "json": "$.image" }, "as": "image" }] }
          ],
          "identities": [{ "ns": "youtube.video", "from": { "field": "externalId" } }]
        }
      ],
      "identities": [{ "ns": "youtube.channel", "from": { "field": "externalId" } }],
      "examples": [
        { "input": "https://www.youtube.com/channel/UCE_M8A5yxnLfW0KghEeajjw", "expect": { "kind": "feed", "nonEmpty": ["title", "externalId"], "nonEmptyCollections": ["items"] } },
        { "input": "https://www.youtube.com/@NASA", "expect": { "kind": "feed", "nonEmpty": ["title", "image"], "nonEmptyCollections": ["items"] } },
        { "input": "https://www.youtube.com/@kurzgesagt", "expect": { "kind": "feed", "nonEmpty": ["title"] } },
        { "input": "https://www.youtube.com/@veritasium", "expect": { "kind": "feed", "nonEmpty": ["title"] } }
      ]
    },
    {
      "id": "mastodon.profile",
      "title": "Mastodon",
      "kind": "feed",
      "match": { "host": ["mastodon.social", "mastodon.online", "fosstodon.org", "hachyderm.io", "mstdn.social"], "path": "/@:user", "priority": 100 },
      "fetch": { "mode": "feed", "ua": "desktopSafari" },
      "fields": [
        { "name": "externalId", "candidates": [
          { "from": { "urlRegex": "^https?://(?:www\\\\.)?([^/?#]+/@[A-Za-z0-9_]+)" }, "pipe": [{ "regexReplace": ["^([^/]+)/@(.+)$", "$2@$1"] }, "lower"] }
        ]},
        { "name": "title", "candidates": [{ "from": { "json": "$.title" } }] },
        { "name": "summary", "candidates": [{ "from": { "json": "$.description" } }] },
        { "name": "link", "candidates": [{ "from": { "json": "$.link" }, "as": "url" }] },
        { "name": "image", "candidates": [{ "from": { "json": "$.image" }, "as": "image" }] },
        { "name": "nextPage", "candidates": [{ "from": { "json": "$.nextURL" }, "as": "url" }] }
      ],
      "collections": [
        {
          "name": "items",
          "from": { "json": "$.items[*]" },
          "kind": "post",
          "item": [
            { "name": "externalId", "candidates": [{ "from": { "json": "$.externalId" } }] },
            { "name": "title", "candidates": [{ "from": { "json": "$.title" } }] },
            { "name": "summary", "candidates": [{ "from": { "json": "$.summary" } }] },
            { "name": "content", "candidates": [{ "from": { "json": "$.contentHTML" }, "pipe": ["rewriteLazyImages"] }] },
            { "name": "link", "candidates": [{ "from": { "json": "$.link" }, "as": "url" }] },
            { "name": "published", "candidates": [{ "from": { "json": "$.published" }, "as": "date" }] },
            { "name": "image", "candidates": [{ "from": { "json": "$.image" }, "as": "image" }] }
          ]
        }
      ],
      "identities": [{ "ns": "mastodon.account", "from": { "field": "externalId" } }],
      "examples": [
        { "input": "https://mastodon.social/@Mastodon", "expect": { "kind": "feed", "nonEmpty": ["title"], "nonEmptyCollections": ["items"] } },
        { "input": "https://mastodon.social/@Gargron", "expect": { "kind": "feed", "nonEmpty": ["title", "externalId"], "nonEmptyCollections": ["items"] } },
        { "input": "https://fosstodon.org/@nova", "expect": { "kind": "feed", "nonEmpty": ["title"] } },
        { "input": "https://hachyderm.io/@nova", "expect": { "kind": "feed", "nonEmpty": ["title"] } },
        { "input": "https://mstdn.social/@feditips", "expect": { "kind": "feed", "nonEmpty": ["title"] } }
      ]
    }
"""

/// Xiaohongshu (2026-10-11). The note page's `noteData` state object no
/// longer lists its keys in one order (one note opens with `imageList`,
/// another with `tagList` and `desc`, a third with `noteId`), so the
/// island candidates anchor on `"data":{"noteData":{` and take the FIRST
/// `noteId` / `title` / `desc` key after it (no nested object in the
/// state carries those names; the island is one line, well inside the
/// regex cap), instead of the old `noteId,title,desc` adjacency that now
/// misses two notes in three. A note may carry an empty title, and the
/// shells then print an empty `og:title` (" - 小红书", " - rednote"), so
/// the wall-title strip blanks those too and the ladder ends on the
/// desc's first line. The app's share sheet mints `xhslink.cn/o/…`
/// links that expand to a note URL stamped with the SHARER's identity
/// (`shareRedId`, `share_id`, `apptime`, app build) beside the note id and
/// the `xsec_token` that gates the page. The canonicalize keep-list holds
/// only what the page needs (`xsec_token`, `xsec_source`, `type`; the token
/// alone 302s), so the sharer's ids never reach a record, a log line, or a
/// fetch. Both ship no examples (owner rulings): the
/// `shortlinks.media` redirector that claims the xhslink hosts because any
/// short link resolves to its minter's account on the platform's side
/// (2026-10-11), and the note source because its only loadable URLs carry
/// an `xsec_token` minted by somebody's share, and a bare note URL lands on
/// the `/404/sec_…` wall (2026-10-12). The redirector lives here,
/// not in the travel chunk, so `--families media` keeps its expander.
let starterXiaohongshuJSON = """
    {
      "id": "xiaohongshu.post",
      "title": "小红书",
      "kind": "post",
      "match": { "host": ["xiaohongshu.com"], "path": "/**", "priority": 100 },
      "canonicalize": { "keep": ["xsec_token", "xsec_source", "type"] },
      "fetch": { "mode": "composite", "steps": [
        { "mode": "http", "ua": "mobileSafari" },
        { "mode": "dom", "ua": "desktopSafari", "settle": { "signals": ["og:title", "h1"] }, "when": "blockedOrThin"}
      ]},
      "fields": [
        { "name": "externalId", "candidates": [
          { "from": { "urlRegex": "/(?:explore|discovery/item|item)/([0-9a-f]{16,40})" } },
          { "from": { "textRegex": "(?s)\\"data\\":\\\\{\\"noteData\\":\\\\{.{0,50000}?\\"noteId\\":\\"([0-9a-f]{16,40})\\"" } }
        ]},
        { "name": "title", "candidates": [
          { "from": { "textRegex": "(?s)\\"data\\":\\\\{\\"noteData\\":\\\\{.{0,50000}?\\"title\\":\\"((?:[^\\"\\\\\\\\]|\\\\\\\\.)*)\\"" }, "pipe": ["trim"] },
          { "from": { "meta": "og:title" }, "pipe": ["trim", { "regexReplace": ["^(?:-\\\\s*)?(?:小红书|rednote|小红书 - 你的生活兴趣社区|你访问的页面不见了|安全限制)$", ""] }] },
          { "from": { "textRegex": "<title[^>]*>([^<]*)</title>" }, "pipe": ["decodeEntities", "trim", { "regexReplace": ["^(?:-\\\\s*)?(?:小红书|rednote|小红书 - 你的生活兴趣社区|你访问的页面不见了|安全限制)$", ""] }] },
          { "from": { "textRegex": "(?s)\\"data\\":\\\\{\\"noteData\\":\\\\{.{0,50000}?\\"desc\\":\\"((?:[^\\"\\\\\\\\]|\\\\\\\\.)*)\\"" },
            "pipe": [{ "regexReplace": ["\\\\\\\\[nrt][\\\\s\\\\S]*$", ""] }, "collapseWhitespace", "trim"] },
          { "from": { "paste": "title" } }
        ]},
        { "name": "summary", "candidates": [
          { "from": { "textRegex": "(?s)\\"data\\":\\\\{\\"noteData\\":\\\\{.{0,50000}?\\"desc\\":\\"((?:[^\\"\\\\\\\\]|\\\\\\\\.)*)\\"" },
            "pipe": [{ "regexReplace": ["\\\\\\\\[nrt]", " "] }, "collapseWhitespace", "trim"] },
          { "from": { "meta": "og:description" } }
        ]},
        { "name": "image", "candidates": [
          { "from": { "textRegex": "\\"imageList\\":\\\\[\\\\{[^\\\\]]*?\\"url\\":\\"([^\\"]+)\\"" }, "pipe": [{ "regexReplace": ["\\\\\\\\u002F", "/"] }], "as": "image" },
          { "from": { "meta": "og:image" }, "pipe": ["resolveURL"], "as": "image" }
        ]}
      ],
      "label": ["title"],
      "identities": [{ "ns": "xiaohongshu.note", "from": { "field": "externalId" } }],
      "examples": []
    },
    {
      "id": "shortlinks.media",
      "title": "小红书 short links",
      "kind": "link",
      "match": { "host": ["xhslink.com", "xhslink.cn"], "path": "/**", "priority": 90 },
      "resolvesVia": "shortlink.expand",
      "previewAs": { "xhslink.com": "xiaohongshu.post", "xhslink.cn": "xiaohongshu.post" },
      "requires": ["native:shortlink.expand@1"]
    }
"""

/// 微信读书 (2026-10-10): book pages, shared 想法/书评, and the app's own
/// notes export. Book pages answer unauthenticated with JSON-LD (`@Id` is
/// the numeric bookId, `isbn` may be empty); the page's state island also
/// carries a stale, different book first (`sState`), so nothing here reads
/// it. The app's share sheet hands out `book-detail?v=…&senderVid=…`: the
/// canonicalize keep-list drops the sharer's ids, and the `{query.v}` step
/// fetches the same book's detail page. Shared notes read the public
/// `review/single` JSON; other readers' likes and comments in that payload
/// are never mapped. Highlights have no public link at all, so the user's
/// highlights and thoughts arrive through weread.notes, the export the app
/// copies to the clipboard (the `wereadNotes` archive format); every
/// file-producing exporter needs a logged-in cookie, which is out of scope.
let starterWeReadJSON = """
    {
      "id": "weread.book",
      "title": "微信读书",
      "kind": "book",
      "match": { "host": ["weread.qq.com"], "path": ["/web/bookDetail/:v", "/web/reader/:v", "/book-detail"], "priority": 100 },
      "canonicalize": { "keep": ["v", "type"] },
      "fetch": { "mode": "composite", "steps": [
        { "mode": "http", "ua": "mobileSafari", "when": { "pathRegex": "^/web/(?:bookDetail|reader)/" } },
        { "mode": "http", "ua": "mobileSafari", "url": "https://weread.qq.com/web/bookDetail/{query.v}", "when": { "pathRegex": "^/book-detail" } }
      ]},
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "jsonld": "Book.@Id" } }] },
        { "name": "title", "candidates": [
          { "from": { "jsonld": "Book.name" }, "pipe": ["decodeEntities", "trim"] },
          { "from": { "meta": "og:title" }, "pipe": ["decodeEntities", "trim"] }
        ]},
        { "name": "author", "candidates": [{ "from": { "jsonld": "Book.author.name" }, "pipe": ["decodeEntities", "trim"] }] },
        { "name": "isbn", "candidates": [{ "from": { "jsonld": "Book.isbn" } }] },
        { "name": "summary", "candidates": [{ "from": { "meta": "og:description" }, "pipe": ["decodeEntities", "trim"] }] },
        { "name": "image", "candidates": [{ "from": { "meta": "og:image" }, "pipe": ["resolveURL"], "as": "image" }] }
      ],
      "identities": [
        { "ns": "weread.book", "from": { "jsonld": "Book.@Id" } },
        { "ns": "isbn13", "from": { "jsonld": "Book.isbn" } }
      ],
      "examples": [
        { "input": "https://weread.qq.com/web/bookDetail/ce032b305a9bc1ce0b0dd2a", "expect": { "kind": "book", "nonEmpty": ["title", "author", "externalId"] } },
        { "input": "https://weread.qq.com/web/bookDetail/33332bf05cbba0333b1efb4", "expect": { "kind": "book", "nonEmpty": ["title", "isbn"] } },
        { "input": "https://weread.qq.com/web/reader/8bc329705e46708bcb0c164", "expect": { "kind": "book", "nonEmpty": ["title"] } },
        { "input": "https://weread.qq.com/book-detail?type=1&v=d4a322a05d0f04d4a01f0d6&wfrom=app&scene=bottomSheetShare", "expect": { "kind": "book", "nonEmpty": ["title", "externalId"] } }
      ]
    },
    {
      "id": "weread.review",
      "title": "微信读书想法",
      "kind": "note",
      "match": { "host": ["weread.qq.com"], "path": "/web/review/detail/:id", "priority": 100 },
      "fetch": { "mode": "json", "url": "https://weread.qq.com/web/review/single?reviewId={param.id}" },
      "fields": [
        { "name": "externalId", "candidates": [{ "from": { "json": "$.review.reviewId" } }, { "from": { "urlParam": "id" } }] },
        { "name": "title", "candidates": [{ "from": { "json": "$.review.book.title" } }] },
        { "name": "summary", "candidates": [{ "from": { "json": "$.review.content" }, "pipe": ["trim"] }] },
        { "name": "passage", "candidates": [{ "from": { "json": "$.review.abstract" }, "pipe": ["trim"] }] },
        { "name": "chapter", "candidates": [{ "from": { "json": "$.review.chapterTitle" } }] },
        { "name": "bookAuthor", "candidates": [{ "from": { "json": "$.review.book.author" } }] },
        { "name": "noteAuthor", "candidates": [{ "from": { "json": "$.review.author.name" } }] },
        { "name": "rating", "candidates": [{ "from": { "json": "$.review.star" }, "as": "rating", "scale": { "min": 0, "max": 100 } }] },
        { "name": "created", "candidates": [{ "from": { "json": "$.review.createTime" }, "as": "date" }] },
        { "name": "image", "candidates": [{ "from": { "json": "$.review.book.cover" }, "as": "image" }] },
        { "name": "bookId", "candidates": [{ "from": { "json": "$.review.book.bookId" } }] }
      ],
      "identities": [{ "ns": "weread.review", "from": { "json": "$.review.reviewId" } }],
      "examples": [
        { "input": "https://weread.qq.com/web/review/detail/2100205_73IB5RiZD", "expect": { "kind": "note", "nonEmpty": ["title", "summary", "passage"] } },
        { "input": "https://weread.qq.com/web/review/detail/19988907_7G8T1a6WD", "expect": { "kind": "note", "nonEmpty": ["title", "summary"] } },
        { "input": "https://weread.qq.com/web/review/detail/21047721_74PYjKtTO", "expect": { "kind": "note", "nonEmpty": ["title"] } }
      ]
    },
    {
      "id": "weread.notes",
      "title": "微信读书笔记导出",
      "kind": "note",
      "match": { "file": { "name": "*", "probe": { "contains": ["《", "个笔记"] } } },
      "fetch": { "mode": "archive", "format": "wereadNotes" },
      "rows": [
        { "name": "externalId", "candidates": [{ "from": { "json": "$.id" } }] },
        { "name": "title", "candidates": [
          { "from": { "json": "$.comment" } },
          { "from": { "json": "$.text" } }
        ]},
        { "name": "noteType", "candidates": [{ "from": { "json": "$.type" } }] },
        { "name": "passage", "candidates": [{ "from": { "json": "$.text" } }] },
        { "name": "thought", "candidates": [{ "from": { "json": "$.comment" } }] },
        { "name": "book", "candidates": [{ "from": { "json": "$.book" } }] },
        { "name": "author", "candidates": [{ "from": { "json": "$.author" } }] },
        { "name": "chapter", "candidates": [{ "from": { "json": "$.chapter" } }] },
        { "name": "date", "candidates": [{ "from": { "json": "$.date" }, "as": "date", "format": "yyyy/M/d" }] }
      ]
    }
"""
