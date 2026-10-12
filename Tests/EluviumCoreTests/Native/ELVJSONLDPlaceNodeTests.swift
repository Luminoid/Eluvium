import Foundation
import Testing
@testable import EluviumCore

@Suite("JSON-LD best place node")
struct ELVJSONLDPlaceNodeTests {
    private func nodes(_ json: String) throws -> [ELVRawJSON] {
        let parsed = try #require(ELVRawJSON.parse(Data(json.utf8)))
        return parsed.arrayValue ?? [parsed]
    }

    @Test
    func `A physical place beats an event; geo-bearing unmapped nodes qualify last`() throws {
        let ranked = try nodes("""
        [
          {"@type": "Event", "name": "Dinner Show"},
          {"@type": "Restaurant", "name": "Benu"},
          {"@type": "LocalBusiness", "name": "Trailhead", "geo": {"latitude": 43.7, "longitude": -110.7}}
        ]
        """)
        let best = try #require(ELVJSONLDPlaceNode.best(in: ranked))
        #expect(ELVJSONLDPlaceNode.asString(best.raw["name"]) == "Benu")
        #expect(best.category == "food")

        // Alone, the unmapped-but-located node still qualifies (the
        // AllTrails LocalBusiness case) with no category.
        let trailOnly = try nodes("""
        [{"@type": "LocalBusiness", "name": "Trailhead", "geo": {"latitude": 43.7, "longitude": -110.7}}]
        """)
        let trail = try #require(ELVJSONLDPlaceNode.best(in: trailOnly))
        #expect(trail.category == nil)
        #expect(ELVJSONLDPlaceNode.geo(from: trail.raw)?.latitude == 43.7)
    }

    @Test
    func `The op normalizes address, price, rating, stars, and duration defensively`() throws {
        ELVNativeOps.registerBuiltins()
        let json = """
        {"@type": ["Thing", "Hotel"], "name": "The Ritz",
         "address": {"@type": "PostalAddress", "streetAddress": "150 Piccadilly", "addressLocality": "London", "addressCountry": "GB"},
         "telephone": "+44 20 7300 2345",
         "geo": {"latitude": "51.5074", "longitude": "-0.1418"},
         "aggregateRating": {"ratingValue": 4.7, "reviewCount": 2000},
         "starRating": {"ratingValue": 1e300},
         "offers": [{"price": "1299.50", "priceCurrency": "gbp"}],
         "timeRequired": "PT2H30M"}
        """
        let document = try ELVDocument(jsonLDNodes: nodes(json))
        let op = try #require(ELVNativeOps.lookup("jsonld.bestPlaceNode"))
        let outputs = try #require(op([:], ELVExtractionContext(document: document)))
        #expect(outputs["category"] == .text("lodging"))
        #expect(outputs["name"] == .text("The Ritz"))
        #expect(outputs["address"] == .text("150 Piccadilly, London, GB"))
        #expect(outputs["geo"] == .geo(latitude: 51.5074, longitude: -0.1418))
        #expect(outputs["rating"] == .rating(value: 4.7, scale: 0 ... 5))
        #expect(outputs["onlineRating"] == nil)
        #expect(outputs["hotelStars"] == .number(5)) // clamped in Double space, no trap
        #expect(outputs["price"] == .money(minorUnits: 129_950, currencyCode: "GBP"))
        #expect(outputs["duration"] == .duration(9000))
    }

    @Test
    func `Non-finite and out-of-range coordinates are absent, and a record built from a valid node encodes`() throws {
        for latitude in ["\"NaN\"", "\"inf\"", "\"-Infinity\"", "200", "-91"] {
            let node = try #require(ELVRawJSON.parse(Data("{\"@type\": \"Restaurant\", \"geo\": {\"latitude\": \(latitude), \"longitude\": 10}}".utf8)))
            #expect(ELVJSONLDPlaceNode.geo(from: node) == nil, "latitude \(latitude)")
        }
        let longitude = try #require(ELVRawJSON.parse(Data(#"{"@type": "Restaurant", "geo": {"latitude": 10, "longitude": "181"}}"#.utf8)))
        #expect(ELVJSONLDPlaceNode.geo(from: longitude) == nil)
        #expect(ELVJSONLDPlaceNode.asDouble(.string("nan")) == nil)
        #expect(ELVJSONLDPlaceNode.asDouble(.number(.infinity)) == nil)
        #expect(ELVJSONLDPlaceNode.asDouble(.string(" 4.5 ")) == 4.5)

        let valid = try #require(ELVRawJSON.parse(Data(#"{"@type": "Restaurant", "name": "Benu", "geo": {"latitude": "37.7854", "longitude": "-122.3993"}}"#.utf8)))
        let geo = try #require(ELVJSONLDPlaceNode.geo(from: valid))
        let record = ELVRecord(sourceId: "s", kind: "food", fields: ["geo": .geo(latitude: geo.latitude, longitude: geo.longitude)])
        let data = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(ELVRecord.self, from: data) == record)
    }

    @Test
    func `A zero-zero geo and a rating of zero are treated as absent`() throws {
        let node = try #require(ELVRawJSON.parse(Data("""
        {"@type": "Restaurant", "geo": {"latitude": 0, "longitude": 0}, "aggregateRating": {"ratingValue": 0}}
        """.utf8)))
        #expect(ELVJSONLDPlaceNode.geo(from: node) == nil)
        #expect(ELVJSONLDPlaceNode.rating(from: node) == nil)
    }

    @Test
    func `The aggregate rating keeps a declared bestRating scale and drops off-scale values`() throws {
        let tenScale = try #require(ELVRawJSON.parse(Data(#"{"aggregateRating": {"ratingValue": "8.7", "bestRating": 10}}"#.utf8)))
        #expect(ELVJSONLDPlaceNode.rating(from: tenScale) == .rating(value: 8.7, scale: 0 ... 10))
        // No bestRating: the schema.org default of 5, so 87 is off-scale.
        let offScale = try #require(ELVRawJSON.parse(Data(#"{"aggregateRating": {"ratingValue": 87}}"#.utf8)))
        #expect(ELVJSONLDPlaceNode.rating(from: offScale) == nil)
        let hostile = try #require(ELVRawJSON.parse(Data(#"{"aggregateRating": {"ratingValue": 4, "bestRating": 1e300}}"#.utf8)))
        #expect(ELVJSONLDPlaceNode.rating(from: hostile) == .rating(value: 4, scale: 0 ... 5))
    }
}
