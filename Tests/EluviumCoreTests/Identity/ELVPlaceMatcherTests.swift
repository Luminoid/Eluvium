import Foundation
import Testing
@testable import EluviumCore

@Suite("Place matcher")
struct ELVPlaceMatcherTests {
    private let benuMichelin = ELVPlaceMatcher.Place(name: "Benu", latitude: 37.7854, longitude: -122.3993)
    private let benuSwarm = ELVPlaceMatcher.Place(name: "Benu Restaurant", latitude: 37.7855, longitude: -122.3994)

    @Test
    func `A same-name, same-location pair scores high`() throws {
        let match = try #require(ELVPlaceMatcher.score(benuMichelin, benuSwarm))
        #expect(match.confidence > 0.85)
        #expect(match.nameSimilarity > 0.4)
        #expect((match.distanceMeters ?? .infinity) < 50)
    }

    @Test
    func `Same name far apart scores lower than same name same place`() throws {
        let farAway = ELVPlaceMatcher.Place(name: "Benu", latitude: 40.0, longitude: -70.0)
        let near = try #require(ELVPlaceMatcher.score(benuMichelin, benuSwarm))
        let far = try #require(ELVPlaceMatcher.score(benuMichelin, farAway))
        #expect(far.confidence < near.confidence)
    }

    @Test
    func `Unrelated names that are far apart are rejected outright (skip beats wrong)`() {
        let unrelated = ELVPlaceMatcher.Place(name: "Joe's Pizza", latitude: 40.7, longitude: -74.0)
        #expect(ELVPlaceMatcher.score(benuMichelin, unrelated) == nil)
    }

    @Test
    func `Name similarity folds case, diacritics, punctuation, and word order`() {
        #expect(ELVPlaceMatcher.similarity("Benu", "benu") == 1)
        #expect(ELVPlaceMatcher.similarity("Café Crenn", "Cafe Crenn") == 1)
        #expect(ELVPlaceMatcher.similarity("Atelier Crenn", "Crenn Atelier") == 1)
        #expect(ELVPlaceMatcher.similarity("The French Laundry", "French Laundry") > 0.6)
        #expect(ELVPlaceMatcher.similarity("Benu", "Saison") < 0.3)
    }

    @Test
    func `Name-only matches (no coordinates) still score but are discounted`() throws {
        let a = ELVPlaceMatcher.Place(name: "Le Bernardin")
        let b = ELVPlaceMatcher.Place(name: "Le Bernardin")
        let match = try #require(ELVPlaceMatcher.score(a, b))
        #expect(match.distanceMeters == nil)
        #expect(match.confidence <= 0.7)
        #expect(match.confidence > 0.5)
    }

    @Test
    func `A match's confidence rides a heuristic identity, which is never a declared one`() throws {
        let match = try #require(ELVPlaceMatcher.score(benuMichelin, benuSwarm))
        let suggestion = ELVIdentity(namespace: "michelin.restaurant", value: "benu", origin: .heuristic(confidence: match.confidence))
        #expect(suggestion.origin == .heuristic(confidence: match.confidence))
        #expect(suggestion != ELVIdentity(namespace: "michelin.restaurant", value: "benu", origin: .declared))
    }

    @Test
    func `The entity.placeMatch native op scores from string inputs`() {
        ELVNativeOps.registerBuiltins()
        let op = ELVNativeOps.lookup("entity.placeMatch")
        let result = op?([
            "name": "Benu", "lat": "37.7854", "lng": "-122.3993",
            "candidateName": "Benu Restaurant", "candidateLat": "37.7855", "candidateLng": "-122.3994",
        ], ELVExtractionContext())
        guard case let .rating(confidence, _)? = result?["confidence"] else {
            Issue.record("Expected a confidence rating")
            return
        }
        #expect(confidence > 0.85)

        // A hopeless pair returns nothing (the op invalidates its candidate).
        let miss = op?(["name": "Benu", "candidateName": "Joe's Pizza", "lat": "37.7", "lng": "-122.3", "candidateLat": "1", "candidateLng": "1"], ELVExtractionContext())
        #expect(miss == nil)
    }

    @Test
    func `The full heuristic showcase: Michelin ∩ Swarm links only on confirm, veto persists`() throws {
        var index = ELVEntityIndex()
        let michelin = ELVRecordKey(sourceId: "michelin.favorite", externalId: "benu")
        let swarm = ELVRecordKey(sourceId: "swarm.checkin", externalId: "c-9981")
        index.register(key: michelin, identities: [ELVIdentity(namespace: "michelin.restaurant", value: "benu", origin: .declared)])

        let match = try #require(ELVPlaceMatcher.score(benuMichelin, benuSwarm))
        let suggestion = ELVIdentity(namespace: "michelin.restaurant", value: "benu", origin: .heuristic(confidence: match.confidence))
        index.register(key: swarm, identities: [
            ELVIdentity(namespace: "fsq.venue", value: "4abc", origin: .declared),
            suggestion,
        ])
        // The suggestion does not auto-link — two separate entities.
        #expect(index.entities().count == 2)

        // Confirm links them; veto splits and persists across a re-register.
        index.confirmLink(michelin, swarm)
        #expect(index.entities().count == 1)
        index.vetoLink(michelin, swarm)
        index.register(key: swarm, identities: [ELVIdentity(namespace: "fsq.venue", value: "4abc", origin: .declared), suggestion])
        #expect(index.entities().count == 2)
    }
}
