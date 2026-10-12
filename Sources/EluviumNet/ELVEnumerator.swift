import EluviumCore
import Foundation

/// Persisted enumeration position: enough to resume a walk after
/// interruption. The caller owns storage; the driver only produces and
/// consumes it.
public struct ELVEnumerationState: Sendable, Codable, Equatable {
    /// The next page URL to fetch, absent when the walk completed.
    public var nextURL: String?
    /// Pages fetched so far (counts toward `maxPages` across resumes).
    public var pagesFetched: Int
    /// Offset-cursor position, when the spec paginates by offset.
    public var offset: Int
    public var completed: Bool

    public init(nextURL: String? = nil, pagesFetched: Int = 0, offset: Int = 0, completed: Bool = false) {
        self.nextURL = nextURL
        self.pagesFetched = pagesFetched
        self.offset = offset
        self.completed = completed
    }
}

/// One fetched page of an enumeration.
public struct ELVEnumerationPage: Sendable {
    /// Shallow item records built from the source's `rows` specs.
    public var records: [ELVRecord]
    /// The resume state after this page.
    public var state: ELVEnumerationState
    /// Server-reported total, when the spec selects one (progress UI).
    public var totalCount: Int?
}

/// A list page the `.skip` policy stepped over, with why it failed.
public struct ELVSkippedPage: Sendable, Equatable {
    /// The page URL. May carry a share token: never log it publicly.
    public var url: String
    public var failure: ELVFetchFailure

    public init(url: String, failure: ELVFetchFailure) {
        self.url = url
        self.failure = failure
    }
}

/// The outcome of a walk.
public struct ELVEnumerationResult: Sendable {
    public var records: [ELVRecord]
    public var state: ELVEnumerationState
    public var totalCount: Int?
    /// Pages that failed and were skipped (`.skip` policy), each with its
    /// failure. Reported, never silent.
    public var skippedPages: [ELVSkippedPage]
    /// What the walk noticed along the way: a bound that cut it short (item
    /// ceiling, page cap, pagination loop), a page whose items path matched
    /// nothing, items that assembled to nothing, a seed that is not a URL.
    /// Reported, never silent. Pack text, counts, and hosts only.
    public var notes: [String]
    /// The failure that ended the walk early, if one did.
    public var failure: ELVFetchFailure?
    /// One trace per page requested, in walk order: host, status, bytes,
    /// truncation, records assembled, duration, and outcome. The walk's log
    /// lines are rendered from it.
    public var pages: [ELVStepTrace]
    /// Wall-clock time of the walk.
    public var duration: Duration
}

/// The enumeration driver: paginate a list source's seed, build one
/// shallow record per item via the source's `rows` specs, follow the
/// declared cursor, stay bounded, and stop cleanly at the page where a
/// caller's `onPage` returns `false` (pause) — the returned state resumes
/// the walk later.
public struct ELVEnumerator: Sendable {
    /// The binary's hard page ceiling, clamping any pack's `maxPages`.
    public static let pageCeiling = 500
    /// The binary's hard item ceiling, clamping any caller's `maxItems`.
    public static let itemCeiling = 20000

    private let fetcher: any ELVFetching

    public init(fetcher: any ELVFetching = ELVHTTPFetcher()) {
        self.fetcher = fetcher
    }

    /// Walks `source.list`. `onPage` is invoked after each page; return
    /// `false` to pause (the result's `state` resumes later). `maxItems`
    /// bounds total accumulation across the walk (clamped to
    /// `itemCeiling`); reaching it stops cleanly at page granularity with a
    /// note and a resumable state. The list's page cap (`maxPages`, counted
    /// across resumes) is final instead: reaching it completes the walk
    /// with a note.
    public func enumerate(
        source: ELVSource,
        params: [String: String] = [:],
        resumeFrom: ELVEnumerationState? = nil,
        maxItems: Int = 5000,
        onPage: @Sendable (ELVEnumerationPage) -> Bool = { _ in true }
    ) async -> ELVEnumerationResult {
        let started = ContinuousClock.now
        var state = resumeFrom ?? ELVEnumerationState()
        var records: [ELVRecord] = []
        var skippedPages: [ELVSkippedPage] = []
        var notes: [String] = []
        var pages: [ELVStepTrace] = []
        var totalCount: Int?

        // Every exit builds the result here, so every exit logs it.
        func finish(_ failure: ELVFetchFailure?) -> ELVEnumerationResult {
            let result = ELVEnumerationResult(
                records: records,
                state: state,
                totalCount: totalCount,
                skippedPages: skippedPages,
                notes: notes,
                failure: failure,
                pages: pages,
                duration: ContinuousClock.now - started
            )
            ELVRunLog.walk(result, sourceId: source.id)
            return result
        }

        guard let list = source.list else {
            state = ELVEnumerationState(completed: true)
            notes.append("source \(source.id) declares no list")
            return finish(nil)
        }

        let pageCap = min(max(list.maxPages, 1), Self.pageCeiling)
        let itemCap = min(max(maxItems, 1), Self.itemCeiling)
        var visited: Set<String> = []
        var pageURL = resolveStartURL(list: list, params: params, state: state)
        if pageURL == nil, !state.completed {
            // A seed (or persisted cursor) that does not parse as a URL used
            // to end the walk as complete with nothing in it. It is a pack or
            // storage bug, not an empty catalog: fail typed and say which.
            // The walk still completes, because it cannot continue: a host
            // that resumes incomplete walks would otherwise retry the same
            // failure forever.
            notes.append(state.nextURL == nil ? "seed did not resolve to a URL" : "resume cursor is not a URL")
            state.nextURL = nil
            state.completed = true
            return finish(.invalidURL)
        }

        while let url = pageURL, state.pagesFetched < pageCap, !state.completed {
            let pageNumber = state.pagesFetched + 1
            // A server handing back an already-walked page URL would spin
            // until the page cap; stop at the first repeat instead. Nothing
            // new lies behind a looping cursor, so the walk is complete.
            guard visited.insert(url.absoluteString).inserted else {
                notes.append("pagination loop detected at page \(pageNumber) on \(ELVLogFormat.host(url))")
                state.completed = true
                break
            }
            let pageStarted = ContinuousClock.now
            var page = ELVStepTrace(sourceId: source.id, index: pageNumber, mode: ELVFetchModes.json, host: url.host)
            let outcome: PageOutcome
            do {
                outcome = try await fetchPage(url: url, list: list, source: source, state: state, trace: &page)
            } catch is CancellationError {
                // `enumerate` doesn't throw, so cancellation can't propagate
                // as an error; stop the walk with a typed failure instead of
                // a misleading timeout.
                page.outcome = .cancelled
                page.duration = ContinuousClock.now - pageStarted
                pages.append(page)
                state.nextURL = url.absoluteString
                return finish(ELVPipeline.cancelledMarker)
            } catch {
                // A decode or transport-adjacent error survives to the host
                // as its type or domain and code, not a bare -1, and stays
                // free of user data so it can be logged.
                let failure = ELVFetchFailure.folding(error, category: .enumerate)
                page.outcome = .failed(failure)
                page.duration = ContinuousClock.now - pageStarted
                pages.append(page)
                // Only the transport's typed failures are skippable, as
                // before: an egress refusal or an unexpected error stops
                // the walk under either policy.
                if case .skip = list.onPageError, error is ELVFetchFailure {
                    skippedPages.append(ELVSkippedPage(url: url.absoluteString, failure: failure))
                    state.pagesFetched += 1
                    pageURL = advanceOnError(list: list, state: &state, currentURL: url)
                    continue
                }
                state.nextURL = url.absoluteString
                return finish(failure)
            }
            page.outcome = .produced
            page.extracted = outcome.records.count
            page.duration = ContinuousClock.now - pageStarted
            pages.append(page)
            notes += outcome.notes.map { "page \(pageNumber): \($0)" }

            state.pagesFetched += 1
            // The offset is caller-persisted state and can resume at any
            // value; saturate rather than trap on the way past Int.max.
            let (advanced, overflowed) = state.offset.addingReportingOverflow(outcome.itemCount)
            state.offset = overflowed ? Int.max : advanced
            state.nextURL = outcome.nextURL?.absoluteString
            state.completed = outcome.nextURL == nil
            if totalCount == nil { totalCount = outcome.totalCount }
            records.append(contentsOf: outcome.records)

            let enumerationPage = ELVEnumerationPage(records: outcome.records, state: state, totalCount: totalCount)
            guard onPage(enumerationPage) else {
                return finish(nil)
            }
            // The item ceiling bounds total accumulation: stop
            // cleanly, resumable from `state`, and say why.
            if records.count >= itemCap {
                notes.append("item ceiling reached (\(records.count) items, cap \(itemCap))")
                return finish(nil)
            }
            pageURL = outcome.nextURL
        }

        if pageURL == nil {
            state.completed = true
        } else if !state.completed, state.pagesFetched >= pageCap {
            // The page cap ends the walk for good: `pagesFetched` persists
            // across resumes, so a walk left incomplete here would resume to
            // a no-op forever and a host retrying incomplete walks would
            // never stop. Complete it, drop the cursor nothing will follow,
            // and say why.
            notes.append("page cap \(pageCap) reached")
            state.nextURL = nil
            state.completed = true
        }
        return finish(nil)
    }

    // MARK: - Page mechanics

    private struct PageOutcome {
        var records: [ELVRecord]
        var itemCount: Int
        var nextURL: URL?
        var totalCount: Int?
        /// What the page alone noticed (no items, items dropped).
        var notes: [String]
    }

    private func fetchPage(url: URL, list: ELVListSpec, source: ELVSource, state: ELVEnumerationState, trace page: inout ELVStepTrace) async throws -> PageOutcome {
        // The source's declared persona applies to its list pages too;
        // absent a declaration, the default mobile persona. Same rule for
        // the first step's byte budget.
        let persona = ELVUAPersona.resolve(source.fetch?.resolvedSteps.first?.ua)
        let budget = ELVFetchBudget(maxBytes: source.fetch?.resolvedSteps.first?.maxBytes ?? ELVFetchBudget.standard.maxBytes)
        let response = try await fetcher.fetch(url, persona: persona, referer: nil, accept: "application/json,*/*;q=0.8", budget: budget)
        page.status = response.status
        page.finalURL = response.finalURL
        page.bytes = response.data.count
        page.truncated = response.truncated
        guard let json = ELVRawJSON.parse(response.data) else {
            throw ELVFetchFailure.formatDrift(response.truncated ? "list page truncated at byte cap before it parsed" : "list page is not JSON")
        }
        let document = ELVDocument(json: json)
        let context = ELVExtractionContext(url: response.finalURL, document: document)

        let items: [ELVRawJSON] = if case let .json(path) = list.items {
            ELVJSONPath(path).evaluate(json)
        } else {
            []
        }

        let records = items.compactMap { ELVAssembler.assembleItem(source: source, itemJSON: $0, url: response.finalURL) }
        var notes: [String] = []
        if items.isEmpty {
            notes.append(Self.itemsPath(list) == nil ? "list items selector is not a json path" : "items path matched nothing")
        } else if records.count < items.count {
            notes.append("\(items.count - records.count) of \(items.count) items assembled to nothing")
        }

        let totalCount = list.total
            .flatMap { ELVAssembler.evaluateString($0, context: context) }
            .flatMap { Int($0) }

        return PageOutcome(
            records: records,
            itemCount: items.count,
            nextURL: nextPageURL(list: list, pageJSON: json, context: context, currentURL: url, state: state, itemCount: items.count),
            totalCount: totalCount,
            notes: notes
        )
    }

    /// The list's items json path, nil when `items` is not a json selector.
    private static func itemsPath(_ list: ELVListSpec) -> String? {
        if case let .json(path) = list.items { path } else { nil }
    }

    private func nextPageURL(list: ELVListSpec, pageJSON: ELVRawJSON, context: ELVExtractionContext, currentURL: URL, state: ELVEnumerationState, itemCount: Int) -> URL? {
        switch list.next {
        case nil:
            return nil
        case let .nextURL(selector):
            guard let value = ELVAssembler.evaluateString(selector, context: context),
                  !value.isEmpty else { return nil }
            // Page text becomes a fetch URL here, so it takes the
            // scheme-allowlisted resolution: a `javascript:` or `data:`
            // next pointer ends the walk instead of becoming a request.
            return ELVURLPolicy.resolve(value, relativeTo: currentURL)
        case let .cursorToken(path, param):
            guard let token = ELVJSONPath(path).first(pageJSON)?.stringValue, !token.isEmpty,
                  var components = URLComponents(url: currentURL, resolvingAgainstBaseURL: false) else { return nil }
            var items = (components.queryItems ?? []).filter { $0.name != param }
            items.append(URLQueryItem(name: param, value: token))
            components.queryItems = items
            return components.url
        case let .offset(param, pageSize):
            // A short page is the last page; otherwise advance the offset.
            guard itemCount >= pageSize, itemCount > 0 else { return nil }
            // `pageSize` is pack input and the offset is persisted state: an
            // advance that would overflow completes the walk, never traps.
            let (next, overflowed) = state.offset.addingReportingOverflow(itemCount)
            guard !overflowed else { return nil }
            return urlWithOffset(next, param: param, on: currentURL)
        }
    }

    private func resolveStartURL(list: ELVListSpec, params: [String: String], state: ELVEnumerationState) -> URL? {
        if let next = state.nextURL { return URL(string: next) }
        guard !state.completed else { return nil }
        // The shared filler percent-encodes param values; a raw substitution
        // let a reserved character in a param reshape the seed's query.
        return URL(string: ELVURLTemplate.fill(list.seed, params: params))
    }

    private func advanceOnError(list: ELVListSpec, state: inout ELVEnumerationState, currentURL: URL) -> URL? {
        // Only offset cursors can advance past a dead page deterministically.
        guard case let .offset(param, pageSize) = list.next else { return nil }
        let (next, overflowed) = state.offset.addingReportingOverflow(pageSize)
        guard !overflowed, let advanced = urlWithOffset(next, param: param, on: currentURL) else { return nil }
        state.offset = next
        return advanced
    }

    /// Rewrites the offset query param on a page URL — the one URL surgery
    /// the next-page cursor and the skip-policy advance share.
    private func urlWithOffset(_ offset: Int, param: String, on url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var items = (components.queryItems ?? []).filter { $0.name != param }
        items.append(URLQueryItem(name: param, value: String(offset)))
        components.queryItems = items
        return components.url
    }
}
