import Foundation
import Testing
@testable import EluviumCore

@Suite("Native op registry")
struct ELVNativeOpsTests {
    @Test
    func `Ops are versioned: bare names resolve @1, pinned versions resolve exactly`() {
        ELVNativeOps.register("test.echo", version: 1) { input, _ in ["out": .text(input["value"] ?? "")] }
        ELVNativeOps.register("test.echo", version: 2) { input, _ in ["out": .text((input["value"] ?? "") + "!")] }
        #expect(ELVNativeOps.isRegistered("test.echo"))
        #expect(ELVNativeOps.isRegistered("test.echo@2"))
        #expect(!ELVNativeOps.isRegistered("test.echo@3"))
        #expect(!ELVNativeOps.isRegistered("test.missing"))
    }

    @Test
    func `A native candidate resolves $field and $param inputs and picks the selected output`() {
        ELVNativeOps.register("test.stats", version: 1) { input, _ in
            guard let text = input["text"] else { return nil }
            return [
                "length": .number(Double(text.count)),
                "upper": .text(text.uppercased()),
            ]
        }
        let context = ELVExtractionContext(params: ["slug": "hidden-falls"], fields: ["title": .text("Hidden Falls")])
        let fields = [
            ELVFieldSpec(name: "len", candidates: [
                ELVCandidate(from: .native(op: "test.stats", input: ["text": "$field.title"]), select: "length"),
            ]),
            ELVFieldSpec(name: "loud", candidates: [
                ELVCandidate(from: .native(op: "test.stats@1", input: ["text": "$param.slug"]), select: "upper"),
            ]),
            ELVFieldSpec(name: "noSelect", candidates: [
                ELVCandidate(from: .native(op: "test.stats", input: ["text": "x"])),
            ]),
        ]
        let result = ELVExtractor.extract(fields: fields, context: context)
        #expect(result.values["len"] == .number(12))
        #expect(result.values["loud"] == .text("HIDDEN-FALLS"))
        #expect(result.values["noSelect"] == nil)
        #expect(result.provenance["len"]?.origin == "native:test.stats")
    }

    @Test
    func `An unregistered op invalidates the candidate so the field falls through`() {
        let fields = [
            ELVFieldSpec(name: "title", candidates: [
                ELVCandidate(from: .native(op: "test.never", input: [:])),
                ELVCandidate(from: .const("fallback")),
            ]),
        ]
        let result = ELVExtractor.extract(fields: fields, context: ELVExtractionContext())
        #expect(result.values["title"] == .text("fallback"))
    }

    @Test
    func `placeMatch treats out-of-range and null-island coordinates as absent`() throws {
        ELVNativeOps.registerBuiltins()
        let op = try #require(ELVNativeOps.lookup("entity.placeMatch"))
        let context = ELVExtractionContext()

        // Valid nearby pair: coordinates participate and lift confidence.
        let scored = try #require(op([
            "name": "Benu", "lat": "37.7854", "lng": "-122.3993",
            "candidateName": "Benu", "candidateLat": "37.7855", "candidateLng": "-122.3994",
        ], context))
        guard case let .rating(withGeo, _)? = scored["confidence"] else {
            Issue.record("Expected a confidence rating")
            return
        }

        // Junk coordinates (out-of-range, null island) degrade to name-only
        // scoring — identical to passing no coordinates at all, never fed to
        // the haversine.
        let baseline = try #require(op(["name": "Benu", "candidateName": "Benu"], context))
        let junk = try #require(op([
            "name": "Benu", "lat": "999", "lng": "370",
            "candidateName": "Benu", "candidateLat": "0", "candidateLng": "0",
        ], context))
        #expect(junk["confidence"] == baseline["confidence"])
        guard case let .rating(nameOnly, _)? = junk["confidence"] else {
            Issue.record("Expected a confidence rating")
            return
        }
        #expect(withGeo > nameOnly)
    }

    @Test
    func `The syndication token matches X's own client computation`() {
        // Reference values computed with V8: ((id / 1e15) * Math.PI)
        //   .toString(36).replace(/(0+|\.)/g, "").
        #expect(ELVSyndicationToken.compute(tweetId: "20") == "6dq1a2xwd93")
        #expect(ELVSyndicationToken.compute(tweetId: "1585341984679469056") == "3uchycv2wqc")
        #expect(ELVSyndicationToken.compute(tweetId: "junk") == nil)
        #expect(ELVSyndicationToken.compute(tweetId: "") == nil)
    }

    @Test
    func `The built-in ops register and evaluate`() {
        ELVNativeOps.registerBuiltins()
        let context = ELVExtractionContext(params: ["id": "20"])
        let fields = [
            ELVFieldSpec(name: "token", candidates: [
                ELVCandidate(from: .native(op: "x.syndicationToken", input: ["id": "$param.id"]), select: "token"),
            ]),
            ELVFieldSpec(name: "digits", candidates: [
                ELVCandidate(from: .native(op: "text.digits", input: ["text": "id152249110"]), select: "digits"),
            ]),
        ]
        let result = ELVExtractor.extract(fields: fields, context: context)
        #expect(result.values["token"] == .text("6dq1a2xwd93"))
        #expect(result.values["digits"] == .text("152249110"))
    }

    @Test
    func `text digits lifts the first numeric run under any input key and rejects digitless input`() throws {
        // The computed-param caller passes one value keyed by the param
        // name, so the op must read any single input (Apple Podcasts'
        // "id152249110" path segment → the lookup API's numeric id).
        ELVNativeOps.registerBuiltins()
        let op = try #require(ELVNativeOps.lookup("text.digits"))
        let context = ELVExtractionContext()
        #expect(op(["id": "id152249110"], context)?["digits"] == .text("152249110"))
        #expect(op(["text": "b7-and-then-42"], context)?["digits"] == .text("7"))
        #expect(op(["id": "no numbers here"], context) == nil)
    }

    @Test
    func `text join composes a key from its parts in order and never from a partial set`() throws {
        ELVNativeOps.registerBuiltins()
        let op = try #require(ELVNativeOps.lookup("text.join"))
        let context = ELVExtractionContext()
        #expect(op(["part2": "Turdus migratorius", "part1": "S44230333"], context)?["text"] == .text("S44230333|Turdus migratorius"))
        #expect(op(["part1": "a", "part2": "b", "separator": ":"], context)?["text"] == .text("a:b"))
        #expect(op(["part1": "S1", "part2": ""], context) == nil)
        #expect(op(["separator": "|"], context) == nil)
    }

    @Test
    func `A join over a missing field drops the candidate instead of keying on half the parts`() {
        // Input resolution invalidates the candidate on a dangling
        // `$field` reference, so a row missing its species gets no key.
        ELVNativeOps.registerBuiltins()
        let candidate = ELVCandidate(from: .native(op: "text.join@1", input: ["part1": "$field.checklist", "part2": "$field.species"]))
        var context = ELVExtractionContext()
        context.fields = ["checklist": .text("S1")]
        #expect(ELVExtractor.evaluate(candidate: candidate, context: context) == nil)
        context.fields["species"] = .text("Corvus corax")
        #expect(ELVExtractor.evaluate(candidate: candidate, context: context) == .text("S1|Corvus corax"))
    }
}
