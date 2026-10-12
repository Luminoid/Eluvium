import EluviumCore
import Foundation

/// One fetch step as it ran, or why it did not: the per-step half of
/// `ELVRunTrace`, and the per-page record of an enumeration walk.
///
/// `finalURL` is the only field that can carry a share token (a
/// Komoot `share_token`, a Swarm `?s=`, a shared-list path). Everything else
/// is safe to show or log; `finalURL` belongs in private log detail only.
public struct ELVStepTrace: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        /// Not run yet; never left on a trace a run returns.
        case pending
        /// Transport and extraction ran (`extracted` counts what they
        /// yielded, which can be zero).
        case produced
        /// The step's `when` declined the input, or the previous step's
        /// response.
        case declined
        /// The binary cannot run the step's mode: a `dom` step with no
        /// renderer injected.
        case skipped
        /// A redirector's op expanded the input; the run re-entered
        /// recognition with the expanded URL.
        case redirected
        /// A `dom` step captured the canonical URL; the run re-entered
        /// recognition with it.
        case capturedCanonical
        /// The step failed. A later step may still have produced the
        /// record, so a failure here does not mean the run failed.
        case failed(ELVFetchFailure)
        case cancelled
    }

    /// The source the step belongs to; nil for the floor pass's shared
    /// fetch, which serves every floor.
    public var sourceId: String?
    /// Zero-based position in the source's resolved steps (the page number,
    /// from one, for an enumeration page).
    public var index: Int
    /// `none`, `http`, `json`, `feed`, `dom`, or `native` for a redirector's
    /// chase.
    public var mode: String
    /// The host the step requested.
    public var host: String?
    /// The HTTP status, when the transport reported one.
    public var status: Int?
    /// The redirect-resolved URL the step's document came from (the render's
    /// landing for `dom`, the expansion for a redirect). May carry a share
    /// token: never log it publicly.
    public var finalURL: URL?
    /// Body bytes received, or rendered HTML bytes for `dom`.
    public var bytes: Int?
    /// The byte cap cut the body. Reported whether or not the step still
    /// extracted something (a truncated body is partial output).
    public var truncated: Bool
    /// For `dom` steps: whether the render settled before its budget ran
    /// out. Nil for every other mode.
    public var settled: Bool?
    /// Field values the step extracted, or records an enumeration page
    /// assembled.
    public var extracted: Int?
    public var duration: Duration
    public var outcome: Outcome
    /// Step detail: a followed feed link, a render's load error, a missed
    /// canonical capture. Pack text and codes only, never page content.
    public var notes: [String]

    public init(
        sourceId: String?,
        index: Int,
        mode: String,
        host: String? = nil,
        status: Int? = nil,
        finalURL: URL? = nil,
        bytes: Int? = nil,
        truncated: Bool = false,
        settled: Bool? = nil,
        extracted: Int? = nil,
        duration: Duration = .zero,
        outcome: Outcome = .pending,
        notes: [String] = []
    ) {
        self.sourceId = sourceId
        self.index = index
        self.mode = mode
        self.host = host
        self.status = status
        self.finalURL = finalURL
        self.bytes = bytes
        self.truncated = truncated
        self.settled = settled
        self.extracted = extracted
        self.duration = duration
        self.outcome = outcome
        self.notes = notes
    }

    /// Whether this step's own result was impaired: it failed, its body
    /// was cut at the byte cap, or its render never settled.
    public var isDegraded: Bool {
        if case .failed = outcome { return true }
        return truncated || settled == false
    }
}

/// What one pipeline run did, step by step. This is the primary diagnostic:
/// provenance says which candidate won each field, the trace says what ran
/// to get there and what came up empty. The framework's log lines are
/// rendered from it, so a test asserting on the trace asserts on what the
/// log will say.
public struct ELVRunTrace: Sendable, Equatable {
    /// The input's host (the seed's, for `runSeed`).
    public var inputHost: String?
    /// Every source that ran, in order. A redirector chase or a canonical
    /// capture re-enters recognition, so one run can visit two sources;
    /// the last one owns the outcome. A floor that claimed the input is
    /// listed too. Empty when nothing recognized and no floor ran.
    public var sourceIds: [String]
    /// Every step of every source that ran, including declined and skipped
    /// ones and steps that failed before or after another step produced.
    public var steps: [ELVStepTrace]
    /// Declared fields the outcome's record lacks, with the candidates tried
    /// (merged across the steps that produced). On a "no fields extracted"
    /// drift it lists every declared field; empty for runs where no step
    /// produced.
    public var fieldMisses: [ELVFieldMiss]
    /// Async native ops that threw while the record's fields extracted.
    public var nativeOpFailures: [ELVNativeOpFailure]
    /// Run-level detail: floors that came up empty, a canonical capture that
    /// timed out, why recognition re-entered.
    public var notes: [String]
    /// Whether the generic-floor pass produced the outcome. Floors
    /// are generic by design, so their missed fields are expected.
    public var usedFloors: Bool
    /// Set by `ELVIngestSession` when the outcome came from its cache: the
    /// trace is the original run's, and no request left this time.
    public var servedFromCache: Bool
    /// Wall-clock time of the whole run.
    public var duration: Duration

    public init(
        inputHost: String? = nil,
        sourceIds: [String] = [],
        steps: [ELVStepTrace] = [],
        fieldMisses: [ELVFieldMiss] = [],
        nativeOpFailures: [ELVNativeOpFailure] = [],
        notes: [String] = [],
        usedFloors: Bool = false,
        servedFromCache: Bool = false,
        duration: Duration = .zero
    ) {
        self.inputHost = inputHost
        self.sourceIds = sourceIds
        self.steps = steps
        self.fieldMisses = fieldMisses
        self.nativeOpFailures = nativeOpFailures
        self.notes = notes
        self.usedFloors = usedFloors
        self.servedFromCache = servedFromCache
        self.duration = duration
    }

    /// Whether something went wrong on the way to the outcome even if a
    /// record came out: a step failed, a body was truncated, a render did
    /// not settle, or a native op threw.
    public var isDegraded: Bool {
        steps.contains(where: \.isDegraded) || !nativeOpFailures.isEmpty
    }
}

/// One pipeline run: its outcome and the trace that explains it.
public struct ELVPipelineRun: Sendable {
    public var result: ELVPipelineResult
    public var trace: ELVRunTrace

    public init(result: ELVPipelineResult, trace: ELVRunTrace) {
        self.result = result
        self.trace = trace
    }

    /// The produced record, nil for any other outcome.
    public var record: ELVRecord? {
        if case let .record(record) = result { record } else { nil }
    }
}
