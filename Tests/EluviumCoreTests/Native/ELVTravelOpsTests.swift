import Foundation
import Testing
@testable import EluviumCore

@Suite("Google Maps URL parsing")
struct ELVGoogleMapsURLTests {
    private let placeURL = "https://www.google.com/maps/place/Jenny+Lake/@43.7,-110.7,15z/"
        + "data=!3m1!4b1!4m6!3m5!8m2!3d43.765278!4d-110.729167!16s?utm_source=share"

    @Test
    func `The pin is the data blob pair, the at-segment is only the viewport`() throws {
        let pin = try #require(ELVGoogleMapsURL.pinCoordinate(in: placeURL))
        #expect(pin.latitude == 43.765278)
        #expect(pin.longitude == -110.729167)
        let viewport = try #require(ELVGoogleMapsURL.viewportCoordinate(in: placeURL))
        #expect(viewport.latitude == 43.7)
        #expect(viewport.longitude == -110.7)
    }

    @Test
    func `A tracking param echoing a coordinate can never inject a pin`() {
        let url = "https://www.google.com/maps/place/Spot?fake=/data=!3d11.1!4d22.2&also=/@33.3,44.4,15z"
        #expect(ELVGoogleMapsURL.pinCoordinate(in: url) == nil)
        #expect(ELVGoogleMapsURL.viewportCoordinate(in: url) == nil)
    }

    @Test
    func `A coordinate-shaped q is a dropped-pin share whose coordinate IS the place`() throws {
        let pin = try #require(ELVGoogleMapsURL.pinCoordinate(in: "https://maps.google.com/?q=48.858,2.294"))
        #expect(pin.latitude == 48.858)
        let named = ELVGoogleMapsURL.pinCoordinate(in: "https://maps.google.com/?q=Benu")
        #expect(named == nil)
    }

    @Test
    func `The last data pair wins over intermediate markers`() throws {
        let url = "https://www.google.com/maps/dir/x/data=!3d1.0!4d2.0!5m2!3d43.1!4d-110.2"
        let pin = try #require(ELVGoogleMapsURL.pinCoordinate(in: url))
        #expect(pin.latitude == 43.1)
        #expect(pin.longitude == -110.2)
    }

    @Test
    func `Place labels come from the path segment or a non-coordinate query`() {
        #expect(ELVGoogleMapsURL.placeLabel(in: placeURL) == "Jenny Lake")
        #expect(ELVGoogleMapsURL.placeLabel(in: "https://maps.google.com/?q=Caf%C3%A9+du+Monde") == "Café du Monde")
        #expect(ELVGoogleMapsURL.placeLabel(in: "https://maps.google.com/?q=48.858,2.294") == nil)
    }

    @Test
    func `Split keeps the leading component as the name and the rest as locality`() {
        let (name, locality) = ELVGoogleMapsURL.splitPlaceLabel("Jenny Lake, Wyoming 83424, USA")
        #expect(name == "Jenny Lake")
        #expect(locality == "Wyoming 83424, USA")
        let (bare, none) = ELVGoogleMapsURL.splitPlaceLabel("Benu")
        #expect(bare == "Benu")
        #expect(none == nil)
    }

    @Test
    func `A big-endian share label folds back to name-first order`() {
        let bigEndian = "United States, California, Los Angeles, S Western Ave, COIN DE RUE bakery and cafe"
        let (name, locality) = ELVGoogleMapsURL.splitPlaceLabel(bigEndian)
        #expect(name == "COIN DE RUE bakery and cafe")
        #expect(locality == "S Western Ave, Los Angeles, California, United States")
    }

    @Test
    func `A little-endian address merely starting with a country-shaped name is left alone`() {
        let label = "Jordan, 123 Main St, Springfield, USA"
        #expect(ELVGoogleMapsURL.littleEndianLabel(label) == label)
        let (name, _) = ELVGoogleMapsURL.splitPlaceLabel(label)
        #expect(name == "Jordan")
    }
}

@Suite("Country names")
struct ELVCountryNamesTests {
    @Test
    func `Codes, English names, and alias spellings all resolve to ISO codes`() {
        #expect(ELVCountryNames.code(for: "Italy") == "IT")
        #expect(ELVCountryNames.code(for: "italy") == "IT")
        #expect(ELVCountryNames.code(for: "IT") == "IT")
        #expect(ELVCountryNames.code(for: "it") == "IT")
        #expect(ELVCountryNames.code(for: "  Japan ") == "JP")
        #expect(ELVCountryNames.code(for: "United States") == "US")
        #expect(ELVCountryNames.code(for: "USA") == "US")
        #expect(ELVCountryNames.code(for: "u.k.") == "GB")
        #expect(ELVCountryNames.code(for: "Narnia") == nil)
        #expect(ELVCountryNames.code(for: "") == nil)
        #expect(ELVCountryNames.code(for: nil) == nil)
    }

    @Test
    func `namesCountry accepts spelled-out countries and never two-letter tokens`() {
        #expect(ELVCountryNames.namesCountry("Japan"))
        #expect(ELVCountryNames.namesCountry("United States"))
        #expect(ELVCountryNames.namesCountry("USA"))
        #expect(!ELVCountryNames.namesCountry("LA"))
        #expect(!ELVCountryNames.namesCountry("Springfield"))
    }
}

@Suite("Maps meta classification")
struct ELVMapsMetaClassifierTests {
    @Test
    func `Segments route by shape across serving variants, not position`() {
        // Variant: address in the title, glyph stars + type in the description.
        let first = ELVMapsMetaClassifier.classify(
            title: "Benu · 22 Hawthorne St, San Francisco",
            description: "★★★★☆ · Fine dining restaurant"
        )
        #expect(first.name == "Benu")
        #expect(first.address == "22 Hawthorne St, San Francisco")
        #expect(first.typeText == "Fine dining restaurant")
        #expect(first.rating == nil)

        // Swapped variant: numeric rating + type in the title.
        let second = ELVMapsMetaClassifier.classify(
            title: "St Mary's Cathedral · 4.6★(3,067) · Catholic church",
            description: "Calle Santa Apolonia 576"
        )
        #expect(second.rating == 4.6)
        #expect(second.typeText == "Catholic church")
        #expect(second.address == "Calle Santa Apolonia 576")
        #expect(ELVMapsMetaClassifier.category(forTypeText: "Catholic church") == "attraction")
    }

    @Test
    func `A comma-less keyworded type with a digit routes as type, not address`() {
        let meta = ELVMapsMetaClassifier.classify(title: "The Ritz · 4-star hotel", description: nil)
        #expect(meta.typeText == "4-star hotel")
        #expect(meta.address == nil)
        #expect(ELVMapsMetaClassifier.category(forTypeText: "4-star hotel") == "lodging")
    }

    @Test
    func `A plain segment is a bare locality without rating context`() {
        let meta = ELVMapsMetaClassifier.classify(title: "Benu · Lima", description: nil)
        #expect(meta.locality == "Lima")
        #expect(meta.typeText == nil)
    }

    @Test
    func `The Google Maps boilerplate description is dropped whole`() {
        let meta = ELVMapsMetaClassifier.classify(
            title: "Spot",
            description: "Find local businesses, view maps and get driving directions in Google Maps."
        )
        #expect(meta.address == nil)
        #expect(meta.locality == nil)
    }

    @Test
    func `A bare Google Maps title names no place`() {
        // A page with no place behind it (a region-served shell) carries
        // only the product's title.
        #expect(ELVMapsMetaClassifier.classify(title: "Google Maps", description: nil).name == nil)
        #expect(ELVMapsMetaClassifier.classify(title: "Google Maps HQ · 1600 Amphitheatre Pkwy", description: nil).name == "Google Maps HQ")
    }

    @Test
    func `Word-bounded keywords keep parking lots out of parks`() {
        #expect(ELVMapsMetaClassifier.category(forTypeText: "Parking lot") == nil)
        #expect(ELVMapsMetaClassifier.category(forTypeText: "National park") == "attraction")
        // Categories are kind tokens: hiking types map to `trail`, the
        // kind every trail source records.
        #expect(ELVMapsMetaClassifier.category(forTypeText: "Hiking area") == "trail")
        #expect(ELVMapsMetaClassifier.category(forTypeText: "Bed & breakfast") == "lodging")
        #expect(ELVMapsMetaClassifier.category(forTypeText: "Embed and breakfast") == nil)
    }
}

@Suite("Trail stats")
struct ELVTrailStatsTests {
    @Test
    func `A share blurb parses leniently`() throws {
        let stats = try #require(ELVTrailStats.parse(fromText: "Mist Trail · Moderate · 3.0 mi · 2 h 30 m"))
        #expect(stats.distance == "3.0 mi")
        #expect(stats.difficulty == "Moderate")
        #expect(stats.duration == "2 h 30 m")
    }

    @Test
    func `A share token inside the URL never reads as a distance`() {
        let text = "Check out Hidden Falls Trail https://www.alltrails.com/trail/x?p=1&sh=7mixyz"
        #expect(ELVTrailStats.parse(fromText: text) == nil)
    }

    @Test
    func `Page text is skeptical: a lone prose distance never counts`() {
        let prose = "A lovely preserve with 15 miles of multi-use trails through the redwoods."
        #expect(ELVTrailStats.parseFromPage(prose) == nil)
    }

    @Test
    func `A clustered stats block parses with the Est anchor keeping metric gain out`() throws {
        let stats = try #require(ELVTrailStats.parseFromPage("Easy · 0.9 mi · Est. 15m · 22 m gain"))
        #expect(stats.distance == "0.9 mi")
        #expect(stats.difficulty == "Easy")
        #expect(stats.duration == "15m")
    }

    @Test
    func `The label-value stats block parses with distance gated on the Length label`() throws {
        let block = "Hidden Falls Trail\nModerate\n3.9mi\nLength\n518ft\nElevation gain\n1.5–2hr\nEstimated time"
        let stats = try #require(ELVTrailStats.parseLabeled(fromText: block))
        #expect(stats.distance == "3.9 mi")
        #expect(stats.difficulty == "Moderate")
        #expect(stats.duration == "1.5–2hr")
        // Elevation alone (no Length label) yields nothing.
        #expect(ELVTrailStats.parseLabeled(fromText: "518ft\nElevation gain\nHard") == nil)
    }

    @Test
    func `The template phrasing parses and the line-scoped variant needs two fields`() throws {
        let template = "Try this 0.9-mile out-and-back trail. Generally considered an easy route, it takes an average of 15 min to complete."
        let stats = try #require(ELVTrailStats.parseTemplate(fromText: template))
        #expect(stats.distance == "0.9 mi")
        #expect(stats.difficulty == "Easy")
        #expect(stats.duration == "15 min")
        #expect(ELVTrailStats.parseTemplateLine(fromText: "a 28-mile scenic drive\nsome other line") == nil)
        #expect(ELVTrailStats.parseTemplateLine(fromText: template) != nil)
    }
}

@Suite("Travel native ops")
struct ELVTravelOpsTests {
    init() {
        ELVNativeOps.registerBuiltins()
    }

    private func run(_ op: String, input: [String: String] = [:], context: ELVExtractionContext = ELVExtractionContext()) -> [String: ELVValue]? {
        ELVNativeOps.lookup(op)?(input, context)
    }

    @Test
    func `maps pinCoordinate separates pin outputs from viewport outputs`() throws {
        let url = "https://www.google.com/maps/place/X/@43.7,-110.7,15z/data=!8m2!3d43.765278!4d-110.729167"
        let outputs = try #require(run("maps.pinCoordinate", input: ["url": url]))
        #expect(outputs["geo"] == .geo(latitude: 43.765278, longitude: -110.729167))
        #expect(outputs["viewportGeo"] == .geo(latitude: 43.7, longitude: -110.7))

        // Viewport-only URL: a `select: "geo"` candidate gets nothing.
        let viewportOnly = try #require(run("maps.pinCoordinate", input: ["url": "https://www.google.com/maps/place/X/@43.7,-110.7,15z"]))
        #expect(viewportOnly["geo"] == nil)
        #expect(viewportOnly["viewportGeo"] != nil)
    }

    @Test
    func `maps ops fall back to the context URL`() throws {
        let url = try #require(URL(string: "https://www.google.com/maps/place/Jenny+Lake/@43.7,-110.7,15z"))
        let context = ELVExtractionContext(url: url)
        let outputs = try #require(run("maps.splitPlaceLabel", context: context))
        #expect(outputs["name"] == .text("Jenny Lake"))
    }

    @Test
    func `littleEndianLabel folds only gated labels`() throws {
        let folded = try #require(run("place.littleEndianLabel", input: ["label": "Japan, Tokyo, Shibuya, Sushi Dai"]))
        #expect(folded["label"] == .text("Sushi Dai, Shibuya, Tokyo, Japan"))
    }

    @Test
    func `littleEndianLabel falls back to the scanned document`() throws {
        // The roster promise: with no explicit input, every op reads the
        // extraction context. littleEndianLabel reads the title metas.
        let mapsDocument = ELVDocument(metas: ["og:title": "Japan, Tokyo, Shibuya, Sushi Dai"])
        let folded = try #require(run("place.littleEndianLabel", context: ELVExtractionContext(document: mapsDocument)))
        #expect(folded["label"] == .text("Sushi Dai, Shibuya, Tokyo, Japan"))
        #expect(run("place.littleEndianLabel") == nil)
    }

    @Test
    func `classifyMetaSegments reads explicit inputs or the scanned document`() throws {
        let document = ELVDocument(metas: [
            "og:title": "Benu · 22 Hawthorne St, San Francisco",
            "og:description": "★★★★☆ · Fine dining restaurant",
        ])
        let outputs = try #require(run("maps.classifyMetaSegments", context: ELVExtractionContext(document: document)))
        #expect(outputs["name"] == .text("Benu"))
        #expect(outputs["address"] == .text("22 Hawthorne St, San Francisco"))
        #expect(outputs["type"] == .text("Fine dining restaurant"))
        #expect(outputs["category"] == .text("food"))
        // A glyph-only star row carries no number, so no rating.
        #expect(outputs["rating"] == nil)
    }

    @Test
    func `classifyMetaSegments emits a numeric rating segment as a 0-5 rating`() throws {
        let outputs = try #require(run("maps.classifyMetaSegments", input: ["title": "St Mary's Cathedral · 4,6★(3,067) · Catholic church"]))
        #expect(outputs["rating"] == .rating(value: 4.6, scale: 0 ... 5))
        #expect(outputs["onlineRating"] == nil)
    }

    @Test
    func `The renamed maps ops leave no gmaps aliases behind`() {
        #expect(ELVNativeOps.lookup("maps.pinCoordinate@1") != nil)
        #expect(ELVNativeOps.lookup("maps.splitPlaceLabel@1") != nil)
        #expect(ELVNativeOps.lookup("gmaps.pinCoordinate@1") == nil)
        #expect(ELVNativeOps.lookup("gmaps.splitPlaceLabel@1") == nil)
        #expect(ELVNativeOps.lookup("text.shareBlurb@1") == nil)
        #expect(ELVNativeOps.lookup("duration.fromISO8601@1") == nil)
    }

    @Test
    func `trail statsFromText v2 merges lenient text over skeptical page text`() throws {
        let outputs = try #require(run("trail.statsFromText@2", input: [
            "text": "Mist Trail · Moderate · 3.0 mi",
            "pageText": "Generally considered a hard route, it takes an average of 5 h to complete. A 4.2-mile trail.",
        ]))
        #expect(outputs["distance"] == .text("3.0 mi")) // lenient wins
        #expect(outputs["difficulty"] == .text("Moderate"))
        #expect(outputs["duration"] == .text("5 h")) // page fills the gap
    }

    @Test
    func `trail statsFromText v2 falls back to the document description metas`() throws {
        let document = ELVDocument(metas: [
            "og:description": "Try this 0.9-mile out-and-back trail. Generally considered an easy route, it takes an average of 15 min to complete.",
        ])
        let outputs = try #require(run("trail.statsFromText@2", context: ELVExtractionContext(document: document)))
        #expect(outputs["distance"] == .text("0.9 mi"))
        #expect(outputs["difficulty"] == .text("Easy"))
    }

    @Test
    func `flight designatorFromURL finds IATA and ICAO idents in path segments`() throws {
        let iata = try #require(run("flight.designatorFromURL", input: ["url": "https://flighty.app/flight/UA123"]))
        #expect(iata["designator"] == .text("UA123"))
        let icao = try #require(run("flight.designatorFromURL", input: ["url": "https://flightaware.com/live/flight/UAL123"]))
        #expect(icao["designator"] == .text("UAL123"))
        #expect(run("flight.designatorFromURL", input: ["url": "https://example.com/about"]) == nil)
    }
}

@Suite("Async native op registry")
struct ELVAsyncNativeOpsTests {
    @Test
    func `An async op registers, gates capabilities, and runs through lookupAsync`() async throws {
        ELVNativeOps.registerAsync("test.asyncEcho", version: 1) { input, _ in
            ["echo": .text(input["value"] ?? "")]
        }
        #expect(ELVNativeOps.isRegistered("test.asyncEcho"))
        #expect(ELVNativeOps.isRegistered("test.asyncEcho@1"))
        // The sync extraction path never sees async ops.
        #expect(ELVNativeOps.lookup("test.asyncEcho") == nil)
        let op = try #require(ELVNativeOps.lookupAsync("test.asyncEcho"))
        let outputs = try await op(["value": "hi"], ELVExtractionContext())
        #expect(outputs?["echo"] == .text("hi"))
    }

    @Test
    func `lookupAsync wraps sync ops so enrichment needs one code path`() async throws {
        ELVNativeOps.registerBuiltins()
        let op = try #require(ELVNativeOps.lookupAsync("text.digits"))
        let outputs = try await op(["text": "id152249110"], ELVExtractionContext())
        #expect(outputs?["digits"] == .text("152249110"))
    }
}
