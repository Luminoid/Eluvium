import EluviumCore
import Foundation
import Testing

/// Field misses (what the pack looked for when nothing won) and async
/// native-op failures (an op that threw, kept apart from an op that found
/// nothing).
@Suite("Extraction diagnostics")
struct ELVExtractionDiagnosticsTests {
    private let fields = [
        ELVFieldSpec(name: "title", candidates: [ELVCandidate(from: .meta("og:title"))]),
        ELVFieldSpec(name: "rating", candidates: [
            ELVCandidate(from: .jsonld("Product.aggregateRating.ratingValue")),
            ELVCandidate(from: .meta("rating")),
        ]),
    ]

    @Test
    func `Misses list each unfilled field once, with its candidates in ladder order`() {
        let context = ELVExtractionContext(document: ELVDocument(metas: ["og:title": "Hidden Falls"]))
        let result = ELVExtractor.extract(fields: fields + [fields[1]], context: context)
        #expect(ELVExtractor.misses(fields: fields + [fields[1]], result: result) == [
            ELVFieldMiss(field: "rating", candidates: ["jsonld:Product.aggregateRating.ratingValue", "meta:rating"]),
        ])
        #expect(result.nativeOpFailures.isEmpty)
    }

    @Test
    func `A filled record has no misses`() {
        let context = ELVExtractionContext(document: ELVDocument(metas: ["og:title": "Hidden Falls", "rating": "4"]))
        let result = ELVExtractor.extract(fields: fields, context: context)
        #expect(ELVExtractor.misses(fields: fields, result: result).isEmpty)
    }

    @Test
    func `extractAsync keeps a thrown op error in the result while the field falls through to its next candidate`() async throws {
        ELVNativeOps.registerAsync("test.diagnostics.throwing", version: 1) { _, _ in
            throw URLError(.notConnectedToInternet)
        }
        let specs = [
            ELVFieldSpec(name: "address", candidates: [
                ELVCandidate(from: .native(op: "test.diagnostics.throwing@1", input: [:])),
                ELVCandidate(from: .meta("address")),
            ]),
        ]
        let context = ELVExtractionContext(document: ELVDocument(metas: ["address": "1 Trail Rd"]))

        let result = try await ELVExtractor.extractAsync(fields: specs, context: context)

        #expect(result.values["address"] == .text("1 Trail Rd"))
        #expect(result.nativeOpFailures == [
            ELVNativeOpFailure(field: "address", op: "test.diagnostics.throwing@1", error: "NSURLErrorDomain -1009"),
        ])
        // The public single-candidate form still folds the failure into
        // "no value", as documented.
        let folded = try await ELVExtractor.evaluateAsync(candidate: specs[0].candidates[0], context: context)
        #expect(folded == nil)
    }
}
