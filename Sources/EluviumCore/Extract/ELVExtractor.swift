import Foundation

/// Stage ③–④: ordered candidate evaluation with provenance.
public enum ELVExtractor {
    public struct FieldResult: Sendable, Equatable {
        public var values: [String: ELVValue]
        public var provenance: [String: ELVProvenance]
        /// Async native ops that threw during `extractAsync`, in field order.
        /// Their candidates yielded no value; this says why. Always empty
        /// from the synchronous `extract`, whose ops cannot throw.
        public var nativeOpFailures: [ELVNativeOpFailure]

        public init(values: [String: ELVValue] = [:], provenance: [String: ELVProvenance] = [:], nativeOpFailures: [ELVNativeOpFailure] = []) {
            self.values = values
            self.provenance = provenance
            self.nativeOpFailures = nativeOpFailures
        }
    }

    /// The fields in `fields` that `result` holds no value for, each with
    /// its candidates' selector tags in ladder order. Computed from the
    /// specs after the fact, so the per-row extraction hot path pays
    /// nothing for it; when no candidate wins, every candidate was tried,
    /// so the ladder is exactly what ran.
    public static func misses(fields: [ELVFieldSpec], result: FieldResult) -> [ELVFieldMiss] {
        var seen = Set<String>()
        var misses: [ELVFieldMiss] = []
        for field in fields where result.values[field.name] == nil && seen.insert(field.name).inserted {
            misses.append(ELVFieldMiss(field: field.name, candidates: field.candidates.map(\.from.provenanceTag)))
        }
        return misses
    }

    /// Evaluates `fields` in order. The first candidate producing a
    /// non-empty, successfully-coerced value wins its field; later fields
    /// see earlier fields' values through `context.fields`.
    ///
    /// A multi-output native op runs once per extraction for each distinct
    /// input set (`ELVNativeOpMemo`): the fields that `select` its outputs
    /// share the one run.
    public static func extract(fields: [ELVFieldSpec], context: ELVExtractionContext) -> FieldResult {
        var context = context
        var values: [String: ELVValue] = [:]
        var provenance: [String: ELVProvenance] = [:]
        var memo = ELVNativeOpMemo()

        for field in fields {
            for (index, candidate) in field.candidates.enumerated() {
                guard let value = evaluate(candidate, context: context, memo: &memo), !value.isEmpty else { continue }
                values[field.name] = value
                provenance[field.name] = ELVProvenance(origin: candidate.from.provenanceTag, candidateIndex: index)
                context.fields[field.name] = value
                break
            }
        }
        return FieldResult(values: values, provenance: provenance)
    }

    /// `extract`'s awaited mirror, for the pipeline's field extraction
    /// : the identical ordered walk, except a `native` candidate whose
    /// op is registered async (a platform lookup — MapKit, HealthKit) is
    /// awaited through `ELVNativeOps.lookupAsync`. Sync-only callers
    /// (collections, archive rows, identities, list drivers) keep `extract`,
    /// where an async-only op never produces — the validator says so.
    ///
    /// Throws only `CancellationError` (so the pipeline's typed-cancellation
    /// handling sees it); an op's own failure invalidates its candidate,
    /// exactly like a sync coercion failure — skip beats wrong. The failure
    /// itself is kept in `nativeOpFailures`, so "MapKit failed" stays
    /// distinguishable from "MapKit found nothing".
    ///
    /// Ops, sync and async alike, run once per distinct input set for the
    /// whole walk (`ELVNativeOpMemo`), so the four fields reading one MapKit
    /// lookup cost one search. A thrown failure is remembered too: it is
    /// recorded once, under the first field that hit it, and the other
    /// candidates calling the same op with the same inputs fall through
    /// without waiting on the backend again.
    public static func extractAsync(fields: [ELVFieldSpec], context: ELVExtractionContext) async throws -> FieldResult {
        var context = context
        var values: [String: ELVValue] = [:]
        var provenance: [String: ELVProvenance] = [:]
        var opFailures: [ELVNativeOpFailure] = []
        var memo = ELVNativeOpMemo()

        for field in fields {
            for (index, candidate) in field.candidates.enumerated() {
                let evaluated = try await evaluateAsyncKeepingFailure(candidate, context: context, memo: &memo)
                if let failure = evaluated.failure {
                    ELVLog.debug(.extract, "Native op \(failure.op) failed for field \(field.name)", error: failure.error)
                    opFailures.append(ELVNativeOpFailure(field: field.name, op: failure.op, error: ELVLog.describe(failure.error).summary))
                }
                guard let value = evaluated.value, !value.isEmpty else { continue }
                values[field.name] = value
                provenance[field.name] = ELVProvenance(origin: candidate.from.provenanceTag, candidateIndex: index)
                context.fields[field.name] = value
                break
            }
        }
        return FieldResult(values: values, provenance: provenance, nativeOpFailures: opFailures)
    }

    /// Evaluates one candidate end to end: selector → pipes → coercion.
    /// `nil` means the candidate did not produce.
    public static func evaluate(candidate: ELVCandidate, context: ELVExtractionContext) -> ELVValue? {
        var memo = ELVNativeOpMemo()
        return evaluate(candidate, context: context, memo: &memo)
    }

    private static func evaluate(_ candidate: ELVCandidate, context: ELVExtractionContext, memo: inout ELVNativeOpMemo) -> ELVValue? {
        if case let .native(op, input) = candidate.from {
            guard let nativeOp = ELVNativeOps.lookup(op),
                  let resolved = resolveNativeInputs(input, context: context)
            else { return nil }
            let key = ELVNativeOpMemo.Key(op: ELVNativeOps.canonical(op), input: resolved)
            let outputs: [String: ELVValue]?
            if case let .outputs(cached)? = memo.entries[key] {
                outputs = cached
            } else {
                outputs = nativeOp(resolved, context)
                memo.entries[key] = .outputs(outputs)
            }
            guard let outputs, !outputs.isEmpty, let typed = selectOutput(outputs, select: candidate.select) else { return nil }
            return shapeNativeOutput(typed, candidate: candidate, context: context)
        }
        guard let extracted = ELVSelectorEngine.evaluate(candidate.from, context: context), !extracted.isEmpty else { return nil }
        return runPipesAndCoercion(extracted, candidate: candidate, context: context)
    }

    /// `evaluate`'s awaited mirror: identical for everything except a
    /// `native` candidate with no sync registration — that one is served
    /// through `lookupAsync` and awaited. A thrown op failure (a backend
    /// error, a lookup deadline) invalidates the candidate; cancellation
    /// alone rethrows.
    public static func evaluateAsync(candidate: ELVCandidate, context: ELVExtractionContext) async throws -> ELVValue? {
        var memo = ELVNativeOpMemo()
        return try await evaluateAsyncKeepingFailure(candidate, context: context, memo: &memo).value
    }

    /// `evaluateAsync` plus the op error it folds into "no value", for
    /// `extractAsync`'s trace. Cancellation alone rethrows (and is never
    /// memoized). A failure served from the memo reports no error: it was
    /// recorded when the op actually threw.
    private static func evaluateAsyncKeepingFailure(
        _ candidate: ELVCandidate,
        context: ELVExtractionContext,
        memo: inout ELVNativeOpMemo
    ) async throws -> (value: ELVValue?, failure: (op: String, error: any Error)?) {
        guard case let .native(op, input) = candidate.from, ELVNativeOps.lookup(op) == nil,
              let asyncOp = ELVNativeOps.lookupAsync(op)
        else { return (evaluate(candidate, context: context, memo: &memo), nil) }
        guard let resolved = resolveNativeInputs(input, context: context) else { return (nil, nil) }
        let key = ELVNativeOpMemo.Key(op: ELVNativeOps.canonical(op), input: resolved)
        let outputs: [String: ELVValue]?
        switch memo.entries[key] {
        case let .outputs(cached)?:
            outputs = cached
        case .failed?:
            return (nil, nil)
        case nil:
            do {
                outputs = try await asyncOp(resolved, context)
                memo.entries[key] = .outputs(outputs)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                memo.entries[key] = .failed
                return (nil, (op, error))
            }
        }
        guard let outputs, !outputs.isEmpty, let typed = selectOutput(outputs, select: candidate.select) else { return (nil, nil) }
        return (shapeNativeOutput(typed, candidate: candidate, context: context), nil)
    }

    private static func runPipesAndCoercion(_ initial: ELVExtractedValue, candidate: ELVCandidate, context: ELVExtractionContext) -> ELVValue? {
        var extracted = initial
        for pipe in candidate.pipes {
            guard let piped = pipe.apply(extracted, context: context) else { return nil }
            extracted = piped
        }
        guard !extracted.isEmpty else { return nil }
        return ELVCoercionEngine.apply(candidate.coercion, to: extracted, context: context)
    }

    /// Resolves a native op's declared inputs: `$field.x` reads an earlier
    /// field's resolved value, `$param.y` a recognition param, `$paste.z` a
    /// paste value (`ELVPasteContext`), anything else is a literal. A
    /// dangling reference invalidates the candidate, unless it ends in `?`
    /// (schemaMinor 5): an optional reference that cannot resolve leaves its
    /// input out, so one candidate serves every shape of input (a link with
    /// a pin, one with only a viewport, one with neither) and the per-walk
    /// op memo runs a lookup once for all of them.
    static func resolveNativeInputs(_ input: [String: String], context: ELVExtractionContext) -> [String: String]? {
        var resolved: [String: String] = [:]
        for (key, rawTemplate) in input {
            let optional = rawTemplate.hasPrefix("$") && rawTemplate.hasSuffix("?")
            let template = optional ? String(rawTemplate.dropLast()) : rawTemplate
            guard let value = resolveNativeInput(template, context: context) else {
                if optional { continue }
                return nil
            }
            resolved[key] = value
        }
        return resolved
    }

    /// One input reference resolved, or nil when it dangles.
    private static func resolveNativeInput(_ template: String, context: ELVExtractionContext) -> String? {
        if template.hasPrefix("$field.") {
            let name = String(template.dropFirst("$field.".count))
            guard let value = context.fields[name] else { return nil }
            return ELVSelectorEngine.stringForm(of: value)?.singleString
        }
        if template.hasPrefix("$param.") {
            return context.params[String(template.dropFirst("$param.".count))]
        }
        if template.hasPrefix("$paste.") {
            return context.paste?.value(String(template.dropFirst("$paste.".count)))
        }
        return template
    }

    /// Picks the selected output. A multi-output op with no `select` is a
    /// pack authoring error and produces nothing.
    private static func selectOutput(_ outputs: [String: ELVValue], select: String?) -> ELVValue? {
        if let select { return outputs[select] }
        return outputs.count == 1 ? outputs.values.first : nil
    }

    /// A native op's output is already typed; pipes and coercions apply only
    /// when the pack asks for further shaping.
    private static func shapeNativeOutput(_ typed: ELVValue, candidate: ELVCandidate, context: ELVExtractionContext) -> ELVValue? {
        guard !candidate.pipes.isEmpty || candidate.coercion != nil else { return typed }
        guard let stringified = ELVSelectorEngine.stringForm(of: typed) else { return nil }
        return runPipesAndCoercion(stringified, candidate: candidate, context: context)
    }
}

/// One extraction's native-op results, keyed by the canonical op
/// reference plus its resolved inputs. Sound because an op is a function
/// of its inputs and the extraction context, and within one walk only
/// `context.fields` changes, which ops read solely through their
/// resolved `$field` inputs (part of the key). `flighty.flightFromPage`
/// selected by fourteen fields parses its blob once, and an async
/// lookup feeding four fields searches once.
struct ELVNativeOpMemo {
    struct Key: Hashable {
        var op: String
        var input: [String: String]
    }

    enum Entry {
        case outputs([String: ELVValue]?)
        /// The async op threw (not cancellation); retrying inside the
        /// same walk would only wait on the backend again.
        case failed
    }

    var entries: [Key: Entry] = [:]
}
