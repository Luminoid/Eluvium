import Foundation

/// The TripDays-parity travel op roster: Maps URL
/// parsing and meta classification, trail stats, and flight designators,
/// registered as native ops so packs call them like any selector. Every op
/// in this roster falls back to the extraction context (the matched URL,
/// the scanned document) when the pack passes no explicit input, so most
/// call sites are just `{"native": "maps.pinCoordinate@1"}`. Product and
/// place-node ops live in `ELVProductOps.swift`.
extension ELVNativeOps {
    static func registerTravelOps() {
        registerMapsOps()
        registerTrailOps()
        registerTrailOpsV3()
        registerFlightOps()
    }

    private static func registerFlightOps() {
        // @2 per the plan: v1 was the shipped TripDays behavior (silent nil);
        // v2 adds the drift sentinel that names the vanished key.
        register("flighty.flightFromPage", version: 2) { input, context in
            guard let html = input["html"] ?? context.document.html else { return nil }
            switch ELVFlightPage.parse(html: html) {
            case let .drift(missing):
                return ["formatDrift": .text(missing)]
            case let .flight(flight):
                var outputs: [String: ELVValue] = [
                    "designator": .text(flight.designator),
                    "departureIata": .text(flight.departureIata),
                    "arrivalIata": .text(flight.arrivalIata),
                    "departureAirport": .text(flight.departureAirport),
                    "arrivalAirport": .text(flight.arrivalAirport),
                    "departureTime": .date(flight.departure, precision: .time),
                    "arrivalTime": .date(flight.arrival, precision: .time),
                ]
                if let name = flight.airlineName { outputs["airlineName"] = .text(name) }
                if let zone = flight.departureTimeZoneId { outputs["departureTimeZone"] = .text(zone) }
                if let zone = flight.arrivalTimeZoneId { outputs["arrivalTimeZone"] = .text(zone) }
                if let terminal = flight.terminal { outputs["terminal"] = .text(terminal) }
                if let gate = flight.gate { outputs["gate"] = .text(gate) }
                if let lat = flight.arrivalLatitude, let lng = flight.arrivalLongitude {
                    outputs["arrivalGeo"] = .geo(latitude: lat, longitude: lng)
                }
                return outputs
            }
        }
        register("airport.timeZone", version: 1) { input, context in
            let iata = input["iata"] ?? context.params["iata"] ?? ""
            guard let zone = ELVAirportTimeZones.timeZoneId(forIATA: iata) else { return nil }
            return ["timeZone": .text(zone)]
        }
        register("flight.designatorFromURL", version: 1) { input, context in
            guard let url = input["url"] ?? context.url?.absoluteString,
                  let designator = ELVFlightDesignator.designator(in: url) else { return nil }
            return ["designator": .text(designator)]
        }
    }

    /// Maps ops share the `maps.` prefix: they parse Google Maps URLs and
    /// place-page metas today, but the names describe the job, not a brand.
    private static func registerMapsOps() {
        register("maps.pinCoordinate", version: 1) { input, context in
            guard let url = input["url"] ?? context.url?.absoluteString else { return nil }
            var outputs: [String: ELVValue] = [:]
            if let pin = ELVGoogleMapsURL.pinCoordinate(in: url) {
                outputs["geo"] = .geo(latitude: pin.latitude, longitude: pin.longitude)
                outputs["lat"] = .number(pin.latitude)
                outputs["lng"] = .number(pin.longitude)
            }
            // The viewport rides separate keys so a `select: "geo"` candidate
            // can never be fed the map center: viewport biases, never pins.
            if let viewport = ELVGoogleMapsURL.viewportCoordinate(in: url) {
                outputs["viewportGeo"] = .geo(latitude: viewport.latitude, longitude: viewport.longitude)
                outputs["viewportLat"] = .number(viewport.latitude)
                outputs["viewportLng"] = .number(viewport.longitude)
            }
            return outputs.isEmpty ? nil : outputs
        }
        register("maps.splitPlaceLabel", version: 1) { input, context in
            let raw = input["label"] ?? (input["url"] ?? context.url?.absoluteString).flatMap(ELVGoogleMapsURL.placeLabel(in:))
            guard let raw, !raw.isEmpty else { return nil }
            let (name, locality) = ELVGoogleMapsURL.splitPlaceLabel(raw)
            var outputs: [String: ELVValue] = ["name": .text(name)]
            if let locality { outputs["locality"] = .text(locality) }
            return outputs
        }
        register("place.littleEndianLabel", version: 1) { input, context in
            // Falls back to the share page's title metas — the same label
            // surface the sibling classifier reads.
            let label = input["label"] ?? context.document.metas["og:title"] ?? context.document.title
            guard let label, !label.isEmpty else { return nil }
            return ["label": .text(ELVGoogleMapsURL.littleEndianLabel(label))]
        }
        register("maps.classifyMetaSegments", version: 1) { input, context in
            let metas = context.document.metas
            let title = input["title"] ?? metas["og:title"] ?? context.document.title
            let description = input["description"] ?? metas["og:description"] ?? metas["description"]
            let meta = ELVMapsMetaClassifier.classify(title: title, description: description)
            var outputs: [String: ELVValue] = [:]
            if let name = meta.name { outputs["name"] = .text(name) }
            if let address = meta.address { outputs["address"] = .text(address) }
            if let locality = meta.locality { outputs["locality"] = .text(locality) }
            if let type = meta.typeText {
                outputs["type"] = .text(type)
                if let category = ELVMapsMetaClassifier.category(forTypeText: type) {
                    outputs["category"] = .text(category)
                }
            }
            if let rating = meta.rating { outputs["rating"] = .rating(value: rating, scale: 0 ... 5) }
            return outputs.isEmpty ? nil : outputs
        }
    }

    private static func registerTrailOps() {
        // @2 per the plan: the shipped TripDays parser is v1's behavior; the
        // port adds URL stripping and the document fallback, and packs pin
        // `trail.statsFromText@2` explicitly.
        register("trail.statsFromText", version: 2) { input, context in
            var stats: ELVTrailStats?
            // Share text gets the benefit of the doubt; page text is
            // skeptical; the lenient source wins per field.
            if let text = input["text"] {
                stats = ELVTrailStats.parse(fromText: text)
            }
            if let pageText = input["pageText"] {
                stats = stats?.merging(ELVTrailStats.parseFromPage(pageText)) ?? ELVTrailStats.parseFromPage(pageText)
            }
            if stats == nil, input["text"] == nil, input["pageText"] == nil {
                stats = documentStats(in: context)
            }
            guard let stats else { return nil }
            var outputs: [String: ELVValue] = [:]
            if let distance = stats.distance { outputs["distance"] = .text(distance) }
            if let difficulty = stats.difficulty { outputs["difficulty"] = .text(difficulty) }
            if let duration = stats.duration { outputs["duration"] = .text(duration) }
            return outputs.isEmpty ? nil : outputs
        }
    }

    /// `trail.statsFromText@3`, the page-region ladder: lenient share text
    /// (`text`, typically `$paste.text`) wins per field, then the page
    /// sources `ELVTrailStats.pageSources` ranks (anchored header, anchored
    /// body, template prose, og, meta). `sources` names, comma-joined, the
    /// sources that contributed, so a wrong stat is attributable. Raw
    /// document text never contributes: an http document offers only its
    /// metas, and a dom step offers its declared `regions`.
    private static func registerTrailOpsV3() {
        register("trail.statsFromText", version: 3) { input, context in
            var merged: ELVTrailStats?
            var sources: [String] = []
            func fold(_ tag: String, _ stats: ELVTrailStats?) {
                guard let stats else { return }
                let next = merged?.merging(stats) ?? stats
                if next != merged { sources.append(tag) }
                merged = next
            }
            fold("share", input["text"].flatMap(ELVTrailStats.parse(fromText:)))
            for source in ELVTrailStats.pageSources(in: context.document) {
                fold(source.tag, source.stats)
            }
            guard let merged, merged.hasAny else { return nil }
            var outputs: [String: ELVValue] = ["sources": .text(sources.joined(separator: ","))]
            if let distance = merged.distance { outputs["distance"] = .text(distance) }
            if let difficulty = merged.difficulty { outputs["difficulty"] = .text(difficulty) }
            if let duration = merged.duration { outputs["duration"] = .text(duration) }
            return outputs
        }
        // The trail's own locality, finest first: the site's template
        // sentence ("…0.9-mile out-and-back trail near Palo Alto,
        // California.") in the og or plain description or the place node's
        // own description, then any other "near X." in the same order
        // (AllTrails' og:description can lead with fee boilerplate or an
        // editor's "…reserve near Monterey." while the node keeps the
        // template), then the node's digit-free postal address (a
        // street-bearing address is not a locality), then the URL path's
        // region seed ("Wyoming, US" from `region` + a two-letter `country`).
        register("trail.locality", version: 1) { input, context in
            let document = context.document
            let node = ELVJSONLDPlaceNode.best(in: document.jsonLDNodes)?.raw
            let blurbs = [document.metas["og:description"], document.metas["description"], node.flatMap { ELVJSONLDPlaceNode.asString($0["description"]) }]
                .compactMap(\.self)
            if let near = blurbs.lazy.compactMap({ nearLocality(in: $0, templateOnly: true) }).first
                ?? blurbs.lazy.compactMap({ nearLocality(in: $0) }).first {
                return ["locality": .text(near)]
            }
            if let address = node.flatMap({ ELVJSONLDPlaceNode.addressString(from: $0["address"]) }),
               address.rangeOfCharacter(from: .decimalDigits) == nil {
                return ["locality": .text(address)]
            }
            if let region = input["region"], let country = input["country"], country.count == 2, country.allSatisfy(\.isLetter) {
                let name = region.split(whereSeparator: { $0 == "-" || $0 == "_" })
                    .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                    .joined(separator: " ")
                guard !name.isEmpty else { return nil }
                return ["locality": .text("\(name), \(country.uppercased())")]
            }
            return nil
        }
    }

    // A place name starts with a capital: "near the tide pools, sneakers
    // are fine" is prose, not a locality.
    // swiftlint:disable:next force_try
    private static let nearLocalityRegex = try! NSRegularExpression(pattern: "\\b[Nn]ear\\s+(\\p{Lu}[^.!\\n]{1,79}?)\\s*[.!\\n]")
    // The same phrase led by the template's distance ("this 3.2-mile loop
    // trail near …"), so an editor's earlier "near X." can't outrank it.
    // swiftlint:disable:next force_try
    private static let templateNearLocalityRegex = try! NSRegularExpression(
        pattern: "\\b\\d+(?:[.,]\\d+)?-(?:mile|kilometer|km)\\b[^.!\\n]{0,60}?\\b[Nn]ear\\s+(\\p{Lu}[^.!\\n]{1,79}?)\\s*[.!\\n]"
    )

    /// "Experience this 0.9-mile out-and-back trail near Palo Alto,
    /// California." → "Palo Alto, California". `templateOnly` takes only a
    /// phrase led by the template's distance. Bounded by the pattern itself
    /// (fixed delimiters around lazy runs of at most 60 and 80 characters).
    static func nearLocality(in text: String, templateOnly: Bool = false) -> String? {
        let bounded = String(text.prefix(4096))
        let regex = templateOnly ? templateNearLocalityRegex : nearLocalityRegex
        guard let match = regex.firstMatch(in: bounded, range: NSRange(bounded.startIndex..., in: bounded)),
              match.numberOfRanges >= 2, let range = Range(match.range(at: 1), in: bounded)
        else { return nil }
        let locality = bounded[range].trimmingCharacters(in: .whitespacesAndNewlines)
        return locality.isEmpty ? nil : locality
    }

    /// The no-input fallback: skeptical parses over the scanned document's
    /// rendered text and description metas, most-trusted first (rendered
    /// body, then template-line prose, then the og / plain description).
    private static func documentStats(in context: ELVExtractionContext) -> ELVTrailStats? {
        let document = context.document
        let sources: [ELVTrailStats?] = [
            document.text.flatMap(ELVTrailStats.parseFromPage),
            document.text.flatMap(ELVTrailStats.parseTemplateLine(fromText:)),
            document.metas["og:description"].flatMap(ELVTrailStats.parseFromPage),
            document.metas["description"].flatMap(ELVTrailStats.parseFromPage),
        ]
        let merged = sources.compactMap(\.self).reduce(nil as ELVTrailStats?) { $0?.merging($1) ?? $1 }
        return (merged?.hasAny ?? false) ? merged : nil
    }
}
