import EluviumCore
import Foundation

/// The Twitter-archive-shaped jsJson source the Imports screen demonstrates
/// : the archive's `data/` folder splits one tweet list across JS
/// assignment shards (`window.YTD.tweets.part0 = […]` in `tweets.js`,
/// `part1` in `tweets-part1.js`, …), each a JSON literal behind the
/// assignment prefix `ELVJSJSONReader` strips. Rows key on `id_str` so
/// re-imports dedup instead of duplicating.
///
/// The file rule is glob-only by design: `ELVFileMatchRule`'s content probe
/// is CSV-header-shaped (`probe.csvHeader`), so jsJson recognition rides on
/// the name glob alone and the format mismatch surfaces at parse time.
enum TwitterArchiveSource {
    static let source = ELVSource(
        id: "twitter.archive",
        kind: "post",
        match: ELVMatchRule(file: ELVFileMatchRule(name: "tweets*.js")),
        fetch: ELVFetchPlan(mode: "archive", format: "jsJson"),
        rows: [
            ELVFieldSpec(name: "externalId", candidates: [ELVCandidate(from: .json("$.tweet.id_str"))]),
            ELVFieldSpec(name: "text", candidates: [ELVCandidate(from: .json("$.tweet.full_text"))]),
            // Twitter's created_at is its own fixed layout, declared as a
            // pack date format instead of special-casing the parser ladder.
            ELVFieldSpec(name: "date", candidates: [ELVCandidate(from: .json("$.tweet.created_at"), coercion: ELVCoercion(kind: "date", format: "EEE MMM dd HH:mm:ss Z yyyy"))]),
            ELVFieldSpec(name: "likes", candidates: [ELVCandidate(from: .json("$.tweet.favorite_count"), coercion: ELVCoercion(kind: "int"))]),
        ]
    )

    /// The canned two-shard sample: `part0` and `part1` concatenate in shard
    /// order into one list, exactly how a real archive export splits it.
    static let sampleShards: [(fileName: String, text: String)] = [
        ("tweets.js", """
        window.YTD.tweets.part0 = [
          {"tweet": {"id_str": "9001", "full_text": "Shipped the feed engine today", "created_at": "Mon May 04 17:05:00 +0000 2026", "favorite_count": "42"}},
          {"tweet": {"id_str": "9002", "full_text": "jsJson is a format: a JS assignment wrapping a JSON body", "created_at": "Tue May 05 09:30:00 +0000 2026", "favorite_count": "7"}}
        ];
        """),
        ("tweets-part1.js", """
        window.YTD.tweets.part1 = [
          {"tweet": {"id_str": "9003", "full_text": "The part1 shard continues the same list", "created_at": "Wed May 06 21:12:00 +0000 2026", "favorite_count": "3"}},
          {"tweet": {"id_str": "9004", "full_text": "Dedup on id_str keeps edits across re-imports", "created_at": "Thu May 07 08:44:00 +0000 2026", "favorite_count": "11"}}
        ];
        """),
    ]
}
