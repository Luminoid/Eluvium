import Foundation
import Testing
@testable import EluviumCore

@Suite("Bounded cache")
struct ELVBoundedCacheTests {
    @Test
    func `Evicts in insertion order, keeps the first writer, and builds only on a miss`() {
        let cache = ELVBoundedCache<String, Int>(capacity: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        // The first writer wins; a duplicate insert never reorders eviction.
        #expect(cache.insert(9, for: "a") == 1)
        cache.insert(3, for: "c")
        #expect(cache.value(for: "a") == nil)
        #expect(cache.value(for: "b") == 2)
        #expect(cache.value(for: "c") == 3)

        var builds = 0
        #expect(cache.value(for: "b") { builds += 1; return 0 } == 2)
        #expect(cache.value(for: "d") { builds += 1; return 4 } == 4)
        #expect(builds == 1)
    }

    @Test
    func `An optional value type stores negative entries`() {
        let cache = ELVBoundedCache<String, Int?>(capacity: 4)
        var builds = 0
        let first = cache.value(for: "miss") { builds += 1; return nil }
        let second = cache.value(for: "miss") { builds += 1; return nil }
        #expect(first == nil && second == nil)
        #expect(builds == 1)
    }

    @Test
    func `Custom date formats share the bounded cache and keep parsing past capacity`() {
        for day in 1 ... 40 {
            let format = "yyyy-MM-dd'T\(day)'"
            #expect(ELVDateParser.parse("2026-08-\(String(format: "%02d", min(day, 28)))T\(day)", format: format) != nil)
        }
        #expect(ELVDateParser.parse("08/11/2026", format: "MM/dd/yyyy") == Date(timeIntervalSince1970: 1_786_406_400))
    }
}
