import EluviumCore
import Foundation
import Synchronization
import Testing
@testable import EluviumNet

/// Serves canned pages keyed by full URL string.
private struct PagedStubFetcher: ELVFetching {
    var pages: [String: String]
    var failing: Set<String> = []

    func fetch(_ url: URL, persona _: ELVUAPersona, referer _: URL?, accept _: String?, budget _: ELVFetchBudget) async throws -> ELVFetchResponse {
        let key = url.absoluteString
        if failing.contains(key) { throw ELVFetchFailure.httpError(status: 500) }
        guard let body = pages[key] else { throw ELVFetchFailure.httpError(status: 404) }
        return ELVFetchResponse(finalURL: url, status: 200, data: Data(body.utf8), bodyText: body, truncated: false)
    }
}

@Suite("Enumeration")
struct ELVEnumeratorTests {
    private let dexSource = ELVSource(
        id: "pokeapi.list",
        kind: "pokemon",
        rows: [
            ELVFieldSpec(name: "externalId", candidates: [ELVCandidate(from: .json("$.url"), pipes: [.regexReplace(pattern: ".*/pokemon/(\\d+)/?$", template: "$1")])]),
            ELVFieldSpec(name: "title", candidates: [ELVCandidate(from: .json("$.name"), pipes: [.capitalizeFirst])]),
        ],
        list: ELVListSpec(
            seed: "https://pokeapi.co/api/v2/pokemon?limit=2",
            items: .json("$.results[*]"),
            next: .nextURL(.json("$.next")),
            total: .json("$.count"),
            maxPages: 100
        )
    )

    private func page(_ names: [(String, Int)], next: String?) -> String {
        let results = names.map { #"{"name": "\#($0.0)", "url": "https://pokeapi.co/api/v2/pokemon/\#($0.1)/"}"# }.joined(separator: ",")
        let nextField = next.map { #""\#($0)""# } ?? "null"
        return #"{"count": 6, "next": \#(nextField), "results": [\#(results)]}"#
    }

    private var threePages: [String: String] {
        [
            "https://pokeapi.co/api/v2/pokemon?limit=2": page([("bulbasaur", 1), ("ivysaur", 2)], next: "https://pokeapi.co/api/v2/pokemon?limit=2&offset=2"),
            "https://pokeapi.co/api/v2/pokemon?limit=2&offset=2": page([("venusaur", 3), ("charmander", 4)], next: "https://pokeapi.co/api/v2/pokemon?limit=2&offset=4"),
            "https://pokeapi.co/api/v2/pokemon?limit=2&offset=4": page([("charmeleon", 5), ("charizard", 6)], next: nil),
        ]
    }

    @Test
    func `A cursor walk pages to completion with totals and per-item records`() async {
        let enumerator = ELVEnumerator(fetcher: PagedStubFetcher(pages: threePages))
        let result = await enumerator.enumerate(source: dexSource)
        #expect(result.records.count == 6)
        #expect(result.state.completed)
        #expect(result.state.pagesFetched == 3)
        #expect(result.totalCount == 6)
        #expect(result.failure == nil)
        #expect(result.records.first?.externalId == "1")
        #expect(result.records.first?.fields["title"] == .text("Bulbasaur"))
        #expect(result.records.last?.externalId == "6")
    }

    @Test
    func `Pausing mid-walk returns a resumable state; resuming completes without refetching`() async {
        let enumerator = ELVEnumerator(fetcher: PagedStubFetcher(pages: threePages))
        let paused = await enumerator.enumerate(source: dexSource) { page in
            page.state.pagesFetched < 2
        }
        #expect(paused.records.count == 4)
        #expect(!paused.state.completed)
        #expect(paused.state.nextURL == "https://pokeapi.co/api/v2/pokemon?limit=2&offset=4")

        // Resume: only the third page is fetched (the stub would 404 an
        // already-fetched URL if the walk restarted from the seed with a
        // fresh state — count proves one page).
        let resumed = await enumerator.enumerate(source: dexSource, resumeFrom: paused.state)
        #expect(resumed.records.count == 2)
        #expect(resumed.state.completed)
        #expect(resumed.state.pagesFetched == 3)
    }

    @Test
    func `maxPages bounds the walk, completing it with a note`() async {
        var source = dexSource
        source.list?.maxPages = 2
        let enumerator = ELVEnumerator(fetcher: PagedStubFetcher(pages: threePages))
        let result = await enumerator.enumerate(source: source)
        #expect(result.records.count == 4)
        #expect(result.failure == nil)
        // `pagesFetched` counts toward the cap across resumes, so an
        // incomplete state here could only ever resume to nothing: the walk
        // completes and says why instead.
        #expect(result.state.completed)
        #expect(result.state.pagesFetched == 2)
        #expect(result.state.nextURL == nil)
        #expect(result.notes.contains("page cap 2 reached"))
    }

    @Test
    func `A walk persisted at its page cap completes on resume without fetching, so a host retry loop ends`() async {
        var source = dexSource
        source.list?.maxPages = 2
        // The state an earlier build left behind: cap reached, still marked
        // incomplete, cursor pointing at the third page.
        let stranded = ELVEnumerationState(nextURL: "https://pokeapi.co/api/v2/pokemon?limit=2&offset=4", pagesFetched: 2)
        let enumerator = ELVEnumerator(fetcher: PagedStubFetcher(pages: threePages))
        let resumed = await enumerator.enumerate(source: source, resumeFrom: stranded)
        #expect(resumed.pages.isEmpty)
        #expect(resumed.records.isEmpty)
        #expect(resumed.failure == nil)
        #expect(resumed.state.completed)
        #expect(resumed.notes.contains("page cap 2 reached"))

        // And the completed state is final: resuming it again is a no-op.
        let again = await enumerator.enumerate(source: source, resumeFrom: resumed.state)
        #expect(again.pages.isEmpty)
        #expect(again.state.completed)
        #expect(again.notes.isEmpty)
    }

    @Test
    func `A pause that lands on the page cap completes the walk on resume`() async {
        var source = dexSource
        source.list?.maxPages = 2
        let enumerator = ELVEnumerator(fetcher: PagedStubFetcher(pages: threePages))
        // Pausing after page 2 leaves the cap reached but the walk open.
        let paused = await enumerator.enumerate(source: source) { page in
            page.state.pagesFetched < 2
        }
        #expect(!paused.state.completed)
        #expect(paused.state.pagesFetched == 2)

        let resumed = await enumerator.enumerate(source: source, resumeFrom: paused.state)
        #expect(resumed.pages.isEmpty)
        #expect(resumed.state.completed)
        #expect(resumed.notes.contains("page cap 2 reached"))
    }

    @Test
    func `A failing page stops the walk by default, keeping what was gathered and the retry cursor`() async {
        var stub = PagedStubFetcher(pages: threePages)
        stub.failing = ["https://pokeapi.co/api/v2/pokemon?limit=2&offset=2"]
        let enumerator = ELVEnumerator(fetcher: stub)
        let result = await enumerator.enumerate(source: dexSource)
        #expect(result.records.count == 2)
        #expect(result.failure == .httpError(status: 500))
        #expect(result.state.nextURL == "https://pokeapi.co/api/v2/pokemon?limit=2&offset=2")
        #expect(!result.state.completed)
    }

    @Test
    func `Offset cursors advance by page and end on a short page`() async {
        let source = ELVSource(
            id: "offset.list",
            kind: "row",
            rows: [
                ELVFieldSpec(name: "externalId", candidates: [ELVCandidate(from: .json("$.id"))]),
                ELVFieldSpec(name: "title", candidates: [ELVCandidate(from: .json("$.id"))]),
            ],
            list: ELVListSpec(
                seed: "https://api.example.com/rows?count=2",
                items: .json("$.rows[*]"),
                next: .offset(param: "offset", pageSize: 2)
            )
        )
        let pages = [
            "https://api.example.com/rows?count=2": #"{"rows": [{"id": "a"}, {"id": "b"}]}"#,
            "https://api.example.com/rows?count=2&offset=2": #"{"rows": [{"id": "c"}]}"#,
        ]
        let enumerator = ELVEnumerator(fetcher: PagedStubFetcher(pages: pages))
        let result = await enumerator.enumerate(source: source)
        #expect(result.records.map(\.externalId) == ["a", "b", "c"])
        #expect(result.state.completed)
    }

    @Test
    func `The skip policy records skipped offset pages instead of dying, and the report is not silent`() async {
        var source = ELVSource(
            id: "offset.list",
            kind: "row",
            rows: [
                ELVFieldSpec(name: "externalId", candidates: [ELVCandidate(from: .json("$.id"))]),
                ELVFieldSpec(name: "title", candidates: [ELVCandidate(from: .json("$.id"))]),
            ],
            list: ELVListSpec(
                seed: "https://api.example.com/rows?count=2",
                items: .json("$.rows[*]"),
                next: .offset(param: "offset", pageSize: 2),
                onPageError: .skip
            )
        )
        source.list?.maxPages = 10
        var stub = PagedStubFetcher(pages: [
            "https://api.example.com/rows?count=2": #"{"rows": [{"id": "a"}, {"id": "b"}]}"#,
            "https://api.example.com/rows?count=2&offset=4": #"{"rows": [{"id": "e"}]}"#,
        ])
        stub.failing = ["https://api.example.com/rows?count=2&offset=2"]
        let enumerator = ELVEnumerator(fetcher: stub)
        let result = await enumerator.enumerate(source: source)
        #expect(result.records.map(\.externalId) == ["a", "b", "e"])
        #expect(result.skippedPages.map(\.url) == ["https://api.example.com/rows?count=2&offset=2"])
        // The skipped page keeps why it failed, and its trace says so too.
        #expect(result.skippedPages.map(\.failure) == [.httpError(status: 500)])
        #expect(result.pages.map(\.outcome) == [.produced, .failed(.httpError(status: 500)), .produced])
        #expect(result.failure == nil)
    }

    @Test
    func `A source without a list spec completes empty rather than erroring`() async {
        let enumerator = ELVEnumerator(fetcher: PagedStubFetcher(pages: [:]))
        let result = await enumerator.enumerate(source: ELVSource(id: "x", kind: "y"))
        #expect(result.records.isEmpty)
        #expect(result.state.completed)
    }

    @Test
    func `The item ceiling stops the walk cleanly with a note and a resumable cursor`() async {
        let enumerator = ELVEnumerator(fetcher: PagedStubFetcher(pages: threePages))
        let result = await enumerator.enumerate(source: dexSource, maxItems: 3)
        // Page granularity: the page that crossed the cap is kept whole.
        #expect(result.records.count == 4)
        #expect(result.state.pagesFetched == 2)
        #expect(!result.state.completed)
        #expect(result.state.nextURL?.contains("offset=4") == true)
        #expect(result.notes.first?.contains("item ceiling") == true)
        #expect(result.failure == nil)
    }

    private func offsetSource(pageSize: Int, onPageError: ELVPageErrorPolicy = .stop) -> ELVSource {
        ELVSource(
            id: "offset.list",
            kind: "row",
            rows: [
                ELVFieldSpec(name: "externalId", candidates: [ELVCandidate(from: .json("$.id"))]),
                ELVFieldSpec(name: "title", candidates: [ELVCandidate(from: .json("$.id"))]),
            ],
            list: ELVListSpec(
                seed: "https://api.example.com/rows?count=2",
                items: .json("$.rows[*]"),
                next: .offset(param: "offset", pageSize: pageSize),
                maxPages: 10,
                onPageError: onPageError
            )
        )
    }

    @Test
    func `Seed params are percent-encoded, so a reserved character cannot reshape the query`() async {
        // The enumerator substituted params raw while the pipeline encoded
        // them; both now ride `ELVURLTemplate.fill`.
        let source = ELVSource(
            id: "search.list",
            kind: "row",
            rows: [
                ELVFieldSpec(name: "externalId", candidates: [ELVCandidate(from: .json("$.id"))]),
                ELVFieldSpec(name: "title", candidates: [ELVCandidate(from: .json("$.id"))]),
            ],
            list: ELVListSpec(seed: "https://api.example.com/rows?q={param.q}", items: .json("$.rows[*]"))
        )
        let pages = ["https://api.example.com/rows?q=a%20b%23c": #"{"rows": [{"id": "a"}]}"#]
        let result = await ELVEnumerator(fetcher: PagedStubFetcher(pages: pages)).enumerate(source: source, params: ["q": "a b#c"])
        #expect(result.records.map(\.externalId) == ["a"])
        #expect(result.failure == nil)
    }

    @Test
    func `An Int.max page size is clamped by the spec, so a skip-policy walk advances by the clamp and never traps`() async {
        // The spec's memberwise init clamps the page size into
        // `ELVListSpec.pageSizeRange` before the enumerator ever adds it, so
        // an author's Int.max becomes the ceiling: every failed page under
        // the skip policy advances by exactly that, up to the page cap, and
        // the offset arithmetic never approaches overflow. (The saturating
        // advance for a resumed offset is pinned separately below.)
        var stub = PagedStubFetcher(pages: [:])
        stub.failing = ["https://api.example.com/rows?count=2"]
        let result = await ELVEnumerator(fetcher: stub).enumerate(source: offsetSource(pageSize: Int.max, onPageError: .skip))
        let clamp = ELVListSpec.pageSizeRange.upperBound
        #expect(result.state.pagesFetched == 10)
        #expect(result.state.offset == 10 * clamp)
        #expect(result.skippedPages.count == 10)
        #expect(result.failure == nil)
    }

    @Test
    func `A resumed offset near Int.max saturates and completes`() async {
        let nearMax = Int.max - 1
        let resumeURL = "https://api.example.com/rows?count=2&offset=\(nearMax)"
        let pages = [resumeURL: #"{"rows": [{"id": "y"}, {"id": "z"}]}"#]
        let result = await ELVEnumerator(fetcher: PagedStubFetcher(pages: pages)).enumerate(
            source: offsetSource(pageSize: 2),
            resumeFrom: ELVEnumerationState(nextURL: resumeURL, offset: nearMax)
        )
        #expect(result.records.map(\.externalId) == ["y", "z"])
        #expect(result.state.completed)
        #expect(result.state.offset == Int.max)
        #expect(result.failure == nil)
    }

    @Test
    func `A repeated next URL stops the walk instead of spinning to the page cap`() async {
        let seed = "https://pokeapi.co/api/v2/pokemon?limit=2"
        let looping = [seed: page([("bulbasaur", 1), ("ivysaur", 2)], next: seed)]
        let enumerator = ELVEnumerator(fetcher: PagedStubFetcher(pages: looping))
        let result = await enumerator.enumerate(source: dexSource)
        #expect(result.records.count == 2)
        #expect(result.state.pagesFetched == 1)
        #expect(result.state.completed)
        #expect(result.notes.first?.contains("pagination loop") == true)
        #expect(result.failure == nil)
    }

    @Test
    func `Each walked page is traced with its host, status, bytes, and record count`() async {
        let enumerator = ELVEnumerator(fetcher: PagedStubFetcher(pages: threePages))
        let result = await enumerator.enumerate(source: dexSource)
        #expect(result.pages.map(\.index) == [1, 2, 3])
        #expect(result.pages.allSatisfy { $0.host == "pokeapi.co" && $0.status == 200 && $0.outcome == .produced })
        #expect(result.pages.map(\.extracted) == [2, 2, 2])
        #expect(result.notes.isEmpty)
    }

    @Test
    func `A page whose items path matches nothing, or whose items assemble to nothing, says so in the notes`() async {
        let seed = "https://pokeapi.co/api/v2/pokemon?limit=2"
        let empty = PagedStubFetcher(pages: [seed: #"{"count": 0, "next": null, "items": []}"#])
        let emptyResult = await ELVEnumerator(fetcher: empty).enumerate(source: dexSource)
        #expect(emptyResult.notes == ["page 1: items path matched nothing"])
        #expect(emptyResult.state.completed)

        let nameless = PagedStubFetcher(pages: [seed: #"{"count": 2, "next": null, "results": [{"name": "bulbasaur", "url": "https://pokeapi.co/api/v2/pokemon/1/"}, {"other": 1}]}"#])
        let namelessResult = await ELVEnumerator(fetcher: nameless).enumerate(source: dexSource)
        #expect(namelessResult.records.count == 1)
        #expect(namelessResult.notes == ["page 1: 1 of 2 items assembled to nothing"])
    }

    @Test
    func `A seed that does not resolve to a URL fails typed and completes, so a resume never retries it`() async {
        var source = dexSource
        source.list?.seed = "https://[not-closed"
        let result = await ELVEnumerator(fetcher: PagedStubFetcher(pages: [:])).enumerate(source: source)
        #expect(result.failure == .invalidURL)
        #expect(result.state.completed)
        #expect(result.state.nextURL == nil)
        #expect(result.notes == ["seed did not resolve to a URL"])
        #expect(result.pages.isEmpty)
    }

    @Test
    func `A persisted cursor that does not parse fails typed once, and resuming the completed walk is a no-op`() async {
        let enumerator = ELVEnumerator(fetcher: PagedStubFetcher(pages: threePages))
        let broken = ELVEnumerationState(nextURL: "https://[not-closed", pagesFetched: 1, offset: 2)

        let result = await enumerator.enumerate(source: dexSource, resumeFrom: broken)

        #expect(result.failure == .invalidURL)
        #expect(result.notes == ["resume cursor is not a URL"])
        #expect(result.state.completed)
        let resumed = await enumerator.enumerate(source: dexSource, resumeFrom: result.state)
        #expect(resumed.failure == nil)
        #expect(resumed.records.isEmpty)
        #expect(resumed.pages.isEmpty)
    }
}
