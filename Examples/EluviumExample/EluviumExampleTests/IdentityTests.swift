import EluviumCore
import Foundation
import Testing
@testable import EluviumExample

/// The Identity tab's canned corpus: entity collapse, place suggestions,
/// and the anchor ladder through the registered ops.
@Suite("Identity")
@MainActor
struct IdentityTests {
    @Test
    func `The anchor-ladder demo pins the URL coordinate and refuses viewport-only input`() async throws {
        // ELVPlacesOps registers geo.anchorLadder@1 in the store's init.
        await ExampleStore.shared.ready()
        try #require(AnchorLadderDemo.cases.count == 2)
        // Case 1: the URL pin wins outright; the far-off geocode never lands.
        let pinned = try #require(AnchorLadderDemo.resolve(AnchorLadderDemo.cases[0].input))
        #expect(pinned.origin == "urlPin")
        #expect(abs(pinned.latitude - 37.7854) < 0.0001)
        #expect(abs(pinned.longitude - -122.3993) < 0.0001)
        // Case 2: viewport-only earns no trust; skip beats wrong.
        #expect(AnchorLadderDemo.resolve(AnchorLadderDemo.cases[1].input) == nil)
        #expect(AnchorLadderDemo.verdict(for: AnchorLadderDemo.cases[1]).contains("skip beats wrong"))
    }

    @Test
    func `The identity movie showcase collapses shared films while lists stay intact`() {
        // The exact fixtures the Identity screen renders: Star Wars on three
        // source lists collapses to one entity via declared + crosswalk ids.
        var index = ELVEntityIndex()
        for sample in IdentityShowcase.movieSamples {
            index.register(key: sample.key, identities: sample.identities)
        }
        let entity = index.entity(for: ELVRecordKey(sourceId: "imdb.ratings", externalId: "tt0076759"))
        #expect(entity?.members.count == 3)
        // Six list rows collapse into three entities; no list loses a row.
        #expect(index.entities().count == 3)
    }

    @Test
    func `The identity places showcase suggests Benu ∩ Benu Restaurant only on confirm`() throws {
        // placePairs scores through entity.placeMatch@1; ops register in the
        // store's init.
        _ = ExampleStore.shared
        let pairs = IdentityShowcase.placePairs()
        try #require(pairs.count == 2)
        let benu = try #require(pairs.first)
        #expect(benu.confidence > 0.8)

        var index = ELVEntityIndex()
        for sample in IdentityShowcase.placeSamples {
            index.register(key: sample.key, identities: sample.identities)
        }
        #expect(index.entities().count == 4) // the heuristic never auto-links
        index.confirmLink(benu.michelin, benu.swarm)
        #expect(index.entities().count == 3)
    }

    @Test
    func `A rejected pair reads Rejected and the keyboard's next suggestion skips decided pairs`() throws {
        _ = ExampleStore.shared
        let pairs = IdentityShowcase.placePairs()
        try #require(pairs.count == 2)
        let benu = pairs[0]
        let crenn = pairs[1]

        let fresh = IdentityShowcase.makeIndex(strongNamespaces: [], decisions: [:])
        #expect(IdentityShowcase.linkState(of: benu, in: fresh) == .suggested(percent: Int((benu.confidence * 100).rounded())))
        #expect(IdentityShowcase.firstPending(pairs, in: fresh)?.michelin == benu.michelin)

        // A veto shows as Rejected, not as a still-open suggestion, and the
        // next ⌘↩ / ⌘⌫ acts on the following pair instead of overriding it.
        let rejected = IdentityShowcase.makeIndex(strongNamespaces: [], decisions: [benu.recordPair: .rejected])
        #expect(IdentityShowcase.linkState(of: benu, in: rejected) == .rejected)
        #expect(IdentityShowcase.LinkState.rejected.label == "Rejected")
        #expect(IdentityShowcase.firstPending(pairs, in: rejected)?.michelin == crenn.michelin)

        // Both decided: nothing left for the keyboard.
        let decided = IdentityShowcase.makeIndex(strongNamespaces: [], decisions: [benu.recordPair: .rejected, crenn.recordPair: .confirmed])
        #expect(IdentityShowcase.linkState(of: crenn, in: decided) == .linked)
        #expect(IdentityShowcase.firstPending(pairs, in: decided) == nil)

        // Undo is dropping the decision: the pair is a suggestion again.
        let undone = IdentityShowcase.makeIndex(strongNamespaces: [], decisions: [crenn.recordPair: .confirmed])
        #expect(!IdentityShowcase.linkState(of: benu, in: undone).isDecided)
    }

    @Test
    func `The showcase index adopts the loaded pack's strong namespaces`() async {
        await ExampleStore.shared.ready()
        let namespaces = ExampleStore.shared.loadedPack.strongNamespaces
        let index = IdentityShowcase.makeIndex(strongNamespaces: namespaces, decisions: [:])
        #expect(index.extraStrongNamespaces.isSuperset(of: namespaces))
        // Pack vocabulary never breaks the movie collapse.
        let entity = index.entity(for: ELVRecordKey(sourceId: "imdb.ratings", externalId: "tt0076759"))
        #expect(entity?.members.count == 3)
    }
}
