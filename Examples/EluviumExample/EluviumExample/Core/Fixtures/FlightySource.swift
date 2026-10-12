import EluviumCore

/// The Flighty-shaped archive source the Imports screen demonstrates.
/// Pack-authoring data, kept out of the view controller: the header probe
/// (`csvHeader`) is what `ELVArchiveImporter` verifies against picked bytes
/// before any assembly.
enum FlightySource {
    static let source = ELVSource(
        id: "flighty.export",
        kind: "flight",
        match: ELVMatchRule(file: ELVFileMatchRule(name: "*.csv", csvHeader: ["Date", "Flight"])),
        fetch: ELVFetchPlan(mode: "archive", format: "csv"),
        rows: [
            ELVFieldSpec(name: "externalId", candidates: [ELVCandidate(from: .column("Flight Flighty ID"))]),
            ELVFieldSpec(name: "designator", candidates: [ELVCandidate(from: .column("Flight"))]),
            ELVFieldSpec(name: "from", candidates: [ELVCandidate(from: .column("From"))]),
            ELVFieldSpec(name: "to", candidates: [ELVCandidate(from: .column("To"))]),
            ELVFieldSpec(name: "seat", candidates: [ELVCandidate(from: .column("Seat"))]),
            ELVFieldSpec(name: "date", candidates: [ELVCandidate(from: .column("Date"), coercion: ELVCoercion(kind: "date"))]),
            // Flighty timestamps are local and offset-less; the IATA columns
            // are the only timezone signal, resolved through the
            // airport.timeZone@1 native op. Pack order matters:
            // `$field.from` / `$field.to` read fields already resolved above.
            ELVFieldSpec(name: "departureTimeZone", candidates: [ELVCandidate(from: .native(op: "airport.timeZone@1", input: ["iata": "$field.from"]), select: "timeZone")]),
            ELVFieldSpec(name: "arrivalTimeZone", candidates: [ELVCandidate(from: .native(op: "airport.timeZone@1", input: ["iata": "$field.to"]), select: "timeZone")]),
        ]
    )

    /// The bundled sample export the Imports screen and the app tests run
    /// through the archive path; pack-authoring data lives with its source.
    static let sampleCSV = """
    Date,Airline,Flight,Flight Flighty ID,From,To,Seat
    2026-05-01,UAL,UA123,uuid-1,SFO,JFK,12A
    2026-06-12,ASA,AS1276,uuid-2,SEA,SFO,6F
    2026-07-04,DAL,DL9,uuid-3,ATL,LAX,1A
    """
}
