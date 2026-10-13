import EluviumCatalog
import EluviumCore
import Foundation
import Testing

@Suite("Pack subset (catalog curation)")
struct ELVPackSubsetTests {
    private let caps = ELVCapabilities(fetchModes: ["http", "json", "archive", "feed", "dom"], binaryVersion: "0.1")

    @Test
    func `A curated subset carries its fragment/trigger closure and loads with zero diagnostics`() throws {
        let ids: Set = ["alltrails.trail", "booking.lodging", "generic.opengraph"]
        let data = try ELVPackSubset.subset(fromPackJSON: ELVStarterPack.data, ids: ids, packVersion: "test.subset")
        let loaded = try ELVPackLoader.load(embedded: data, capabilities: caps)

        // Closure-correct ⇒ no dangling/unused fragment or trigger diagnostics.
        #expect(loaded.diagnostics.isEmpty, "unexpected diagnostics: \(loaded.diagnostics)")
        #expect(loaded.pack.packVersion == "test.subset")
        for id in ids {
            #expect(loaded.source(withId: id) != nil, "missing selected source \(id)")
        }
    }

    @Test
    func `A subset excludes every source not selected`() throws {
        let data = try ELVPackSubset.subset(fromPackJSON: ELVStarterPack.data, ids: ["generic.opengraph"])
        let loaded = try ELVPackLoader.load(embedded: data, capabilities: caps)
        #expect(loaded.source(withId: "booking.lodging") == nil)
        #expect(loaded.source(withId: "camera.lens") == nil)
        // The one selected source (a catch-all floor) is present.
        #expect(loaded.genericFloors.contains { $0.id == "generic.opengraph" })
    }

    @Test
    func `An unknown source id is rejected rather than silently dropped`() throws {
        #expect(throws: ELVPackSubsetError.self) {
            _ = try ELVPackSubset.subset(fromPackJSON: ELVStarterPack.data, ids: ["booking.lodging", "does.not.exist"])
        }
    }

    @Test
    func `A curated subset recognizes selected sources and not excluded ones`() throws {
        let ids = Set(ELVCatalogFamilies.ids(forFamilies: ["travel", "floors"]))
        let data = try ELVPackSubset.subset(fromPackJSON: ELVStarterPack.data, ids: ids)
        let loaded = try ELVPackLoader.load(embedded: data, capabilities: caps)

        let trail = try #require(URL(string: "https://www.alltrails.com/trail/us/california/half-dome-trail"))
        #expect(loaded.registry.recognize(trail)?.sourceId == "alltrails.trail")

        // A commerce host is not in travel+floors, so it must not recognize.
        let lens = try #require(URL(string: "https://www.sigma-global.com/en/lenses/a019_24_70_28/"))
        #expect(loaded.registry.recognize(lens) == nil)
    }

    @Test
    func `Every single-source subset of the starter loads with zero diagnostics`() throws {
        // The closure is exact for every source, not only the sampled
        // three: one subset per starter id, each loading clean.
        let ids = try ELVPackLoader.load(embedded: ELVStarterPack.data, capabilities: caps).pack.sources.map(\.id)
        #expect(ids.count == 74)
        for id in ids {
            let data = try ELVPackSubset.subset(fromPackJSON: ELVStarterPack.data, ids: [id])
            let loaded = try ELVPackLoader.load(embedded: data, capabilities: caps)
            #expect(loaded.diagnostics.isEmpty, "\(id): \(loaded.diagnostics)")
            #expect(loaded.pack.sources.map(\.id) == [id])
        }
    }

    @Test
    func `The trigger closure follows only the fetch plan a source runs`() throws {
        // `shared` carries a fetch whose step names `viaFragment`. `own`
        // uses it for fields only (its own fetch wins, so the fragment's
        // steps never run and their trigger stays out); `inherits` runs the
        // fragment's plan, so the trigger comes along. A name inside an
        // inline trigger's `anyOf` is inert and pulls nothing in.
        let pack = """
        {
          "schemaVersion": 1, "packVersion": "t",
          "fragments": {
            "shared": {
              "fetch": { "mode": "composite", "steps": [{ "mode": "http" }, { "mode": "http", "ua": "crawler", "when": "viaFragment" }] },
              "fields": [{ "name": "title", "candidates": [{ "from": { "meta": "og:title" } }] }]
            }
          },
          "triggers": {
            "viaFragment": { "missingAny": ["title"] },
            "viaOwn": { "status": [403] },
            "inert": { "emptyRecord": true }
          },
          "sources": [
            { "id": "own", "title": "Own", "kind": "link", "match": { "host": ["own.example"], "priority": 100 }, "use": ["shared"],
              "fetch": { "mode": "composite", "steps": [
                { "mode": "http" },
                { "mode": "http", "ua": "crawler", "when": "viaOwn" },
                { "mode": "http", "ua": "desktopSafari", "when": { "anyOf": [{ "status": [429] }, "inert"] } }
              ]}},
            { "id": "inherits", "title": "Inherits", "kind": "link", "match": { "host": ["inherits.example"], "priority": 100 }, "use": ["shared"] }
          ]
        }
        """
        func triggers(_ ids: Set<String>) throws -> Set<String> {
            let data = try ELVPackSubset.subset(fromPackJSON: Data(pack.utf8), ids: ids)
            let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            return Set(((root["triggers"] as? [String: Any]) ?? [:]).keys)
        }
        #expect(try triggers(["own"]) == ["viaOwn"])
        #expect(try triggers(["inherits"]) == ["viaFragment"])
        #expect(try triggers(["own", "inherits"]) == ["viaOwn", "viaFragment"])
    }

    @Test
    func `A subset keeps exactly the strong namespaces its sources declare`() throws {
        func strong(_ ids: Set<String>) throws -> [String]? {
            let data = try ELVPackSubset.subset(fromPackJSON: ELVStarterPack.data, ids: ids)
            let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            return root["strongNamespaces"] as? [String]
        }
        // A list's collection identity counts: the TGA entries declare igdb.game.
        #expect(try strong(["lists.tga.goty"]) == ["igdb.game"])
        // Built-ins are never listed, so a source declaring only those keeps none.
        #expect(try strong(["pokeapi.pokemon"]) == nil)
        // Weak namespaces stay weak in the subset too.
        #expect(try strong(["booking.lodging"]) == nil)
        // A source's own spec and a collection's both survive, in pack order.
        #expect(try strong(["xiaoyuzhou.podcast"]) == ["xiaoyuzhou.podcast", "xiaoyuzhou.episode"])
        #expect(try strong(["generic.opengraph"]) == nil)

        let data = try ELVPackSubset.subset(fromPackJSON: ELVStarterPack.data, ids: ["lists.tga.goty", "igdb.game"])
        let loaded = try ELVPackLoader.load(embedded: data, capabilities: caps)
        #expect(Set(loaded.strongNamespaces) == ["igdb.game"])
    }

    @Test
    func `Families derive from the catalog chunks`() {
        #expect(ELVCatalogFamilies.known.contains("travel"))
        #expect(ELVCatalogFamilies.known.contains("floors"))
        #expect(ELVCatalogFamilies.families["travel"]?.contains("booking.lodging") == true)
        #expect(ELVCatalogFamilies.families["floors"]?.contains("generic.opengraph") == true)
        // Expansion dedups across families and preserves membership.
        let travelFloors = ELVCatalogFamilies.ids(forFamilies: ["travel", "floors"])
        #expect(Set(travelFloors).count == travelFloors.count)
        #expect(travelFloors.contains("alltrails.trail"))
    }
}
