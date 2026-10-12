import EluviumCore
import Foundation
import Testing

@Suite("Loaded pack merge (built-in + downloaded)")
struct ELVPackMergeTests {
    private let caps = ELVCapabilities(fetchModes: ["http", "json", "archive", "feed"], binaryVersion: "0.1")

    private let baseJSON = """
    {"schemaVersion":1,"packVersion":"base","sources":[
      {"id":"shared","kind":"place","title":"BASE","match":{"host":["a.com"],"path":["/x"]}},
      {"id":"baseOnly","kind":"place","title":"B","match":{"host":["b.com"],"path":["/y"]}}
    ]}
    """

    private let overlayJSON = """
    {"schemaVersion":1,"packVersion":"overlay","sources":[
      {"id":"shared","kind":"place","title":"OVERLAY","match":{"host":["a.com"],"path":["/x"]}},
      {"id":"overlayOnly","kind":"place","title":"O","match":{"host":["c.com"],"path":["/z"]}},
      {"id":"floor","kind":"generic","fetch":{"mode":"http"},"fields":[{"name":"title","candidates":[{"from":{"meta":"og:title"}}]}]}
    ]}
    """

    private func load(_ json: String) throws -> ELVLoadedPack {
        try ELVPackLoader.load(embedded: Data(json.utf8), capabilities: caps)
    }

    @Test
    func `The overlay wins on a shared id and its metadata is reported`() throws {
        let merged = try load(baseJSON).merging(load(overlayJSON))
        #expect(merged.pack.packVersion == "overlay")
        #expect(merged.source(withId: "shared")?.title == "OVERLAY")
        #expect(merged.sources.count(where: { $0.id == "shared" }) == 1)
    }

    @Test
    func `Base-only and overlay-only sources both survive and recognize`() throws {
        let merged = try load(baseJSON).merging(load(overlayJSON))
        #expect(merged.source(withId: "baseOnly") != nil)
        #expect(merged.source(withId: "overlayOnly") != nil)

        #expect(try merged.registry.recognize(#require(URL(string: "https://a.com/x")))?.sourceId == "shared")
        #expect(try merged.registry.recognize(#require(URL(string: "https://b.com/y")))?.sourceId == "baseOnly")
        #expect(try merged.registry.recognize(#require(URL(string: "https://c.com/z")))?.sourceId == "overlayOnly")
    }

    @Test
    func `Generic floors re-derive from the merged source set`() throws {
        // "floor" lives only in the overlay and is a catch-all http source, so
        // the merge must re-derive it into genericFloors (it is not in the
        // registry).
        let merged = try load(baseJSON).merging(load(overlayJSON))
        #expect(merged.genericFloors.contains { $0.id == "floor" })
    }

    @Test
    func `Layers fold left through merging so the last wins`() throws {
        let layers = try [load(baseJSON), load(overlayJSON)]
        let folded = layers.dropFirst().reduce(layers[0]) { $0.merging($1) }
        #expect(folded.pack.packVersion == "overlay")
        #expect(folded.source(withId: "shared")?.title == "OVERLAY")
    }

    private func dated(_ version: String, title: String, strong: String = "[]") -> String {
        """
        {"schemaVersion":1,"packVersion":"\(version)","strongNamespaces":\(strong),"sources":[
          {"id":"shared","kind":"place","title":"\(title)","match":{"host":["a.com"],"path":["/x"]}}
        ]}
        """
    }

    @Test
    func `An overlay older than the base is refused, an equal or newer one layers`() throws {
        let bundled = try load(dated("2026.10.10-starter.2", title: "BUNDLED"))
        let stale = try bundled.merging(load(dated("2026.09.10-remote.9", title: "STALE")))
        #expect(stale.pack.packVersion == "2026.10.10-starter.2")
        #expect(stale.source(withId: "shared")?.title == "BUNDLED")

        let newer = try bundled.merging(load(dated("2026.10.11-remote.1", title: "NEWER")))
        #expect(newer.source(withId: "shared")?.title == "NEWER")
        let same = try bundled.merging(load(dated("2026.10.10-remote.2", title: "SAME")))
        #expect(same.source(withId: "shared")?.title == "SAME")
    }

    @Test
    func `Strong namespaces union across merged layers`() throws {
        let merged = try load(dated("2026.10.10-starter.1", title: "A", strong: #"["goodreads.book"]"#))
            .merging(load(dated("2026.10.11-remote.1", title: "B", strong: #"["letterboxd.film"]"#)))
        #expect(merged.strongNamespaces == ["goodreads.book", "letterboxd.film"])
    }
}
