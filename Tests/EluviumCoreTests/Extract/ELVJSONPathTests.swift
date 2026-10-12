import Foundation
import Testing
@testable import EluviumCore

@Suite("JSONPath subset")
struct ELVJSONPathTests {
    private let root: ELVRawJSON = .object([
        "items": .array([
            .object(["id": .string("a"), "n": .number(1)]),
            .object(["id": .string("b"), "n": .number(2)]),
            .object(["id": .string("c"), "n": .number(3)]),
        ]),
        "meta": .object(["total": .number(3)]),
    ])

    @Test
    func `Key paths, indexes, wildcards, and slices evaluate`() {
        #expect(ELVJSONPath("$.meta.total").first(root) == .number(3))
        #expect(ELVJSONPath("$.items[0].id").first(root) == .string("a"))
        #expect(ELVJSONPath("$.items[-1].id").first(root) == .string("c"))
        #expect(ELVJSONPath("$.items[*].id").evaluate(root) == [.string("a"), .string("b"), .string("c")])
        #expect(ELVJSONPath("$.items[0:2].id").evaluate(root) == [.string("a"), .string("b")])
        #expect(ELVJSONPath("$.items[9].id").evaluate(root).isEmpty)
        #expect(ELVJSONPath("$.missing.key").evaluate(root).isEmpty)
    }

    @Test
    func `Invalid paths evaluate to nothing instead of crashing`() {
        #expect(!ELVJSONPath("$.items[").isValid)
        #expect(!ELVJSONPath("$.items[x]").isValid)
        #expect(ELVJSONPath("$.items[x]").evaluate(root).isEmpty)
        #expect(!ELVJSONPath("$..deep").isValid)
    }
}
