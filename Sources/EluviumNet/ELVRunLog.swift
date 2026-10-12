import EluviumCore
import Foundation

/// Renders the framework's per-run log lines from the returned data, so the
/// log mirrors the trace a test can assert on. One outcome line per run at
/// a level that matches what happened, plus per-step detail at debug.
///
/// Public text carries source ids, hosts, steps, codes, counts, and
/// durations only. Full URLs and field values go in `private:`.
enum ELVRunLog {
    /// Caps keep a debug field dump to one legible line.
    private static let maxDumpedFields = 16
    private static let maxDumpedValueLength = 120

    // MARK: - Resolve

    /// The outcome line for one `ELVPipeline` run:
    /// - info for a record, or for an input nothing recognized. Missed
    ///   fields ride the info line: optional fields (a gate, a terminal) and
    ///   drift sentinels (Flighty's `formatDrift` field) miss on healthy
    ///   runs, so a miss alone is not a warning;
    /// - warning for a degraded record (a step failed or was truncated, a
    ///   render did not settle, a native op threw, a capture timed out) and
    ///   for `formatDrift`;
    /// - error for every other failure;
    /// - debug for the cancellation marker, which is a user action.
    static func resolve(_ result: ELVPipelineResult, trace: ELVRunTrace, input: URL?) {
        for step in trace.steps {
            logStep(step, category: .fetch)
        }
        let source = trace.sourceIds.isEmpty ? "-" : trace.sourceIds.joined(separator: ">")
        let host = trace.inputHost ?? "-"
        let timing = "in \(ELVLogFormat.milliseconds(trace.duration))ms"
        let privateInput = input.map { "input=\($0.absoluteString)" }

        switch result {
        case let .record(record):
            let collections = record.collections.values.reduce(0) { $0 + $1.count }
            var line = "Resolved source=\(source) host=\(host) kind=\(record.kind.isEmpty ? "-" : record.kind) fields=\(record.fields.count) children=\(collections) steps=\(trace.steps.count)"
            let missedCapture = record.provenance["captureCanonical"] != nil
            if !trace.fieldMisses.isEmpty {
                line += " missed=[\(trace.fieldMisses.map(\.field).joined(separator: ","))]"
            }
            let degradations = degradationSummary(trace, missedCapture: missedCapture)
            if !degradations.isEmpty {
                line += " degraded=[\(degradations.joined(separator: "; "))]"
            }
            line += " \(timing)"
            if trace.isDegraded || missedCapture {
                ELVLog.warning(.fetch, line, private: privateInput)
            } else {
                ELVLog.info(.fetch, line, private: privateInput)
            }
            for miss in trace.fieldMisses {
                ELVLog.debug(.extract, "Field \(miss.field) missed on source=\(record.sourceId); tried \(miss.candidates.joined(separator: ", "))")
            }
            ELVLog.debug(.extract, "Record source=\(record.sourceId) kind=\(record.kind) fields=\(record.fields.count)", private: fieldDump(record))
        case .unrecognized:
            ELVLog.info(.fetch, "Unrecognized host=\(host): no source matched and no floor ran \(timing)", private: privateInput)
        case let .failed(failure, sourceId):
            let owner = sourceId ?? (trace.sourceIds.last ?? "-")
            if failure == ELVPipeline.cancelledMarker {
                ELVLog.debug(.fetch, "Resolve cancelled source=\(owner) host=\(host) \(timing)", private: privateInput)
                return
            }
            let line = "Resolve failed source=\(owner) host=\(host) failure=\(failure.logSummary) steps=\(trace.steps.count) \(timing)"
            if case .formatDrift = failure {
                ELVLog.warning(.fetch, line, private: privateInput)
            } else {
                ELVLog.error(.fetch, line, private: privateInput)
            }
        }
    }

    // MARK: - Walk

    /// The outcome line for one `ELVEnumerator` walk: a notice summary, an
    /// error when a failure ended it early (debug for cancellation), and a
    /// debug line per page.
    static func walk(_ result: ELVEnumerationResult, sourceId: String) {
        for page in result.pages {
            logStep(page, category: .enumerate)
        }
        let cursor = result.state.completed ? "complete" : "paused"
        var line = "Walk \(cursor) source=\(sourceId) records=\(result.records.count) pages=\(result.state.pagesFetched) skipped=\(result.skippedPages.count)"
        if let total = result.totalCount {
            line += " total=\(total)"
        }
        if !result.notes.isEmpty {
            line += " notes=[\(result.notes.joined(separator: "; "))]"
        }
        line += " in \(ELVLogFormat.milliseconds(result.duration))ms"
        let privateCursor = result.state.nextURL.map { "next=\($0)" }
        for skipped in result.skippedPages {
            ELVLog.warning(.enumerate, "Walk skipped a page source=\(sourceId) failure=\(skipped.failure.logSummary)", private: "page=\(skipped.url)")
        }
        guard let failure = result.failure else {
            ELVLog.notice(.enumerate, line, private: privateCursor)
            return
        }
        if failure == ELVPipeline.cancelledMarker {
            ELVLog.debug(.enumerate, "\(line) (cancelled)", private: privateCursor)
        } else {
            ELVLog.error(.enumerate, "\(line) failure=\(failure.logSummary)", private: privateCursor)
        }
    }

    // MARK: - Helpers

    private static func logStep(_ step: ELVStepTrace, category: ELVLog.Category) {
        guard ELVLog.isLogging(.debug) else { return }
        var parts = ["Step \(step.index) \(step.mode) source=\(step.sourceId ?? "floors") host=\(step.host ?? "-") outcome=\(step.outcome.logSummary)"]
        if let status = step.status { parts.append("status=\(status)") }
        if let bytes = step.bytes { parts.append("bytes=\(bytes)") }
        if step.truncated { parts.append("truncated") }
        if let settled = step.settled { parts.append("settled=\(settled)") }
        if let extracted = step.extracted { parts.append("extracted=\(extracted)") }
        if !step.notes.isEmpty { parts.append("notes=[\(step.notes.joined(separator: "; "))]") }
        parts.append("in \(ELVLogFormat.milliseconds(step.duration))ms")
        ELVLog.debug(category, parts.joined(separator: " "), private: step.finalURL.map { "final=\($0.absoluteString)" })
    }

    /// Why a record is degraded, step by step, in public terms.
    private static func degradationSummary(_ trace: ELVRunTrace, missedCapture: Bool) -> [String] {
        var reasons: [String] = []
        for step in trace.steps where step.isDegraded {
            if case let .failed(failure) = step.outcome {
                reasons.append("step \(step.index) \(step.mode) failed \(failure.logSummary)")
            }
            if step.truncated { reasons.append("step \(step.index) truncated") }
            if step.settled == false { reasons.append("step \(step.index) render unsettled") }
        }
        for failure in trace.nativeOpFailures {
            reasons.append("op \(failure.op) failed for \(failure.field): \(failure.error)")
        }
        if missedCapture { reasons.append("canonical capture timed out") }
        return reasons
    }

    /// The record's values, one line, for a private debug line.
    private static func fieldDump(_ record: ELVRecord) -> String {
        let keys = record.fields.keys.sorted()
        var parts: [String] = []
        if let externalId = record.externalId { parts.append("id=\(externalId)") }
        if let sourceURL = record.sourceURL { parts.append("url=\(sourceURL.absoluteString)") }
        for key in keys.prefix(maxDumpedFields) {
            guard let value = record.fields[key] else { continue }
            let flattened = ELVValueDisplay.string(value).split(whereSeparator: \.isNewline).joined(separator: " ")
            let shown = flattened.count > maxDumpedValueLength ? String(flattened.prefix(maxDumpedValueLength)) + "..." : flattened
            parts.append("\(key)=\(shown)")
        }
        if keys.count > maxDumpedFields { parts.append("+\(keys.count - maxDumpedFields) more") }
        return parts.joined(separator: " | ")
    }
}

extension ELVFetchFailure {
    /// The failure in public log terms: the case plus its code or reason.
    /// Every payload is public by construction: statuses and codes are
    /// numbers, and the pipeline builds `formatDrift` and `egressBlocked`
    /// reasons from framework and pack text only (an unexpected error is
    /// folded to its `ELVLog.describe` summary first).
    var logSummary: String {
        switch self {
        case let .blocked(status): "blocked \(status)"
        case let .httpError(status): "httpError \(status)"
        case let .transport(code): "transport \(code)"
        case .unauthenticated: "unauthenticated"
        case .timeout: "timeout"
        case .offline: "offline"
        case let .formatDrift(reason): "formatDrift: \(reason)"
        case .invalidURL: "invalidURL"
        case let .egressBlocked(reason): "egressBlocked: \(reason)"
        }
    }
}

extension ELVStepTrace.Outcome {
    var logSummary: String {
        switch self {
        case .pending: "pending"
        case .produced: "produced"
        case .declined: "declined"
        case .skipped: "skipped"
        case .redirected: "redirected"
        case .capturedCanonical: "capturedCanonical"
        case let .failed(failure): "failed(\(failure.logSummary))"
        case .cancelled: "cancelled"
        }
    }
}
