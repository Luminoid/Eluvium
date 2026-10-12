import EluviumCatalog
import Foundation
import Testing
@testable import EluviumCore

/// The nature chunk (2026-10-10): iNaturalist over its API, Merlin and All
/// About Birds species pages, and the iNaturalist / eBird export files.
/// Recognition across every network host and URL shape, hostile
/// lookalikes, assembly from trimmed live captures, CSV import, and the
/// `ebird.species` link between the two bird sources.
@Suite("Starter pack nature sources")
struct ELVStarterNatureSourcesTests {
    private func loaded() throws -> ELVLoadedPack {
        try ELVStarterPack.load(capabilities: ELVCapabilities(fetchModes: ["http", "json", "archive", "feed", "dom"], binaryVersion: "0.1"))
    }

    private func assemble(_ url: String, document: ELVDocument) throws -> ELVRecord {
        let pack = try loaded()
        let target = try #require(URL(string: url))
        let recognition = try #require(pack.registry.recognize(target), "\(url) did not recognize")
        let source = try #require(pack.source(withId: recognition.sourceId))
        return ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: target, params: recognition.params, document: document))
    }

    private func json(_ text: String) throws -> ELVDocument {
        let node: ELVRawJSON = try #require(ELVRawJSON.parse(Data(text.utf8)))
        return ELVDocument(json: node)
    }

    // MARK: - Recognition

    @Test
    func `Every nature URL shape recognizes to its source, on every iNaturalist network host`() throws {
        let cases: [(url: String, sourceId: String)] = [
            ("https://www.inaturalist.org/observations/9000000001", "inat.observation"),
            ("https://inaturalist.org/observations/00000000-0000-4000-8000-000000000001", "inat.observation"),
            ("https://www.inaturalist.ca/observations/141610425", "inat.observation"),
            ("https://mexico.inaturalist.org/observations/5890862", "inat.observation"),
            ("https://www.biodiversity4all.org/observations/3459686", "inat.observation"),
            ("https://inaturalist.ala.org.au/observations/9000000001", "inat.observation"),
            ("https://www.inaturalist.org/taxa/48662-Danaus-plexippus", "inat.taxon"),
            ("https://www.inaturalist.nz/taxa/3017", "inat.taxon"),
            ("https://www.inaturalist.org/people/kueda", "inat.user"),
            ("https://www.argentinat.org/users/477", "inat.user"),
            ("https://merlinbirds.org/species/norcar", "merlin.species"),
            ("https://www.merlinbirds.org/species/amerob", "merlin.species"),
            ("https://ebird.org/species/comrav", "merlin.species"),
            ("https://ebird.org/species/sonspa/US-NY", "merlin.species"),
            ("https://www.allaboutbirds.org/guide/Northern_Cardinal", "allaboutbirds.guide"),
            ("https://www.allaboutbirds.org/guide/American_Robin/sounds", "allaboutbirds.guide"),
        ]
        let registry = try loaded().registry
        for (url, sourceId) in cases {
            let target = try #require(URL(string: url))
            #expect(registry.recognize(target)?.sourceId == sourceId, "\(url)")
        }
    }

    @Test
    func `Lookalike hosts and non-record paths never match a nature source`() throws {
        let registry = try loaded().registry
        for url in [
            "https://inaturalist.org.evil.com/observations/9000000001",
            "https://evil.com@inaturalist.org.attacker.io/taxa/48662",
            "https://ebird.org.evil.dev/species/norcar",
            "https://www.inaturalist.org/projects/city-nature-challenge-2026",
            "https://ebird.org/checklist/S44230333",
            "https://www.merlinbirds.org/posters-and-resources/",
        ] {
            let target = try #require(URL(string: url))
            let match = registry.recognize(target)?.sourceId
            #expect(match == nil || !["inat.observation", "inat.taxon", "inat.user", "merlin.species", "allaboutbirds.guide"].contains(match ?? ""), "\(url) matched \(match ?? "")")
        }
    }

    @Test
    func `iNaturalist routes both observation id shapes to their API endpoints`() throws {
        let source = try #require(try loaded().source(withId: "inat.observation"))
        let steps = try #require(source.fetch?.resolvedSteps)
        #expect(steps.count == 2)
        let numeric = try #require(URL(string: "https://www.inaturalist.org/observations/9000000001"))
        let uuid = try #require(URL(string: "https://www.inaturalist.org/observations/00000000-0000-4000-8000-000000000001"))
        let login = try #require(URL(string: "https://www.inaturalist.org/observations/kueda"))
        #expect(steps.map { $0.when?.urlPermits(numeric) ?? true } == [true, false])
        #expect(steps.map { $0.when?.urlPermits(uuid) ?? true } == [false, true])
        // A login under /observations/ is a list page: neither step runs.
        #expect(steps.map { $0.when?.urlPermits(login) ?? true } == [false, false])
        #expect(steps.allSatisfy { $0.url?.hasPrefix("https://api.inaturalist.org/v2/") == true })
    }

    // MARK: - Assembly from captures

    @Test
    func `An iNaturalist observation assembles from its v2 body with photos upsized and a strong identity`() throws {
        let body = """
        {"total_results": 1, "results": [{
          "id": 9000000001, "uri": "https://www.inaturalist.org/observations/9000000001",
          "observed_on": "2018-09-19", "time_observed_at": "2018-09-19T11:58:00-04:00",
          "place_guess": "Montpelier, VT, USA", "location": "44.2623,-72.5809",
          "geoprivacy": null, "public_positional_accuracy": 61, "quality_grade": "research", "license_code": "cc-by-nc",
          "description": null, "species_guess": "Monarch",
          "user": {"id": 999999999, "login": "sample_observer", "name": "Sample Observer"},
          "taxon": {"id": 48662, "name": "Danaus plexippus", "rank": "species", "preferred_common_name": "Monarch", "iconic_taxon_name": "Insecta"},
          "photos": [
            {"id": 9000000011, "url": "https://inaturalist-open-data.s3.amazonaws.com/photos/9000000011/square.jpg",
             "attribution": "(c) Sample Observer, some rights reserved (CC BY-NC)", "license_code": "cc-by-nc"},
            {"id": 9000000012, "url": "https://inaturalist-open-data.s3.amazonaws.com/photos/9000000012/square.jpeg", "attribution": "(c) Sample Observer", "license_code": "cc-by-nc"}
          ]
        }]}
        """
        let record = try assemble("https://www.inaturalist.org/observations/9000000001", document: json(body))
        #expect(record.kind == "observation")
        #expect(record.externalId == "9000000001")
        #expect(record.fields["title"] == .text("Monarch"))
        #expect(record.fields["scientificName"] == .text("Danaus plexippus"))
        #expect(record.fields["geo"] == .geo(latitude: 44.2623, longitude: -72.5809))
        #expect(record.fields["positionalAccuracy"] == .number(61))
        #expect(record.fields["observer"] == .text("sample_observer"))
        #expect(record.fields["geoprivacy"] == nil)
        let large = try #require(URL(string: "https://inaturalist-open-data.s3.amazonaws.com/photos/9000000011/large.jpg"))
        #expect(record.fields["image"] == .media(ELVMediaRef(url: large, kind: ELVMediaRef.image)))
        // The size swap keeps each photo's own extension (.jpg vs .jpeg).
        let photos = try #require(record.collections["photos"])
        #expect(photos.count == 2)
        let second = try #require(URL(string: "https://inaturalist-open-data.s3.amazonaws.com/photos/9000000012/large.jpeg"))
        #expect(photos[1].fields["image"] == .media(ELVMediaRef(url: second, kind: ELVMediaRef.image)))
        #expect(photos.allSatisfy { $0.kind == "photo" })
        #expect(record.identities.contains(ELVIdentity(namespace: "inat.observation", value: "9000000001", origin: .declared)))
        #expect(ELVIdentityNamespaces.isStrong("inat.observation"))
    }

    @Test
    func `An iNaturalist taxon assembles its ancestors, a plain-text summary, and a usable Wikipedia link`() throws {
        let body = """
        {"results": [{
          "id": 48662, "name": "Danaus plexippus", "rank": "species", "preferred_common_name": "Monarch",
          "iconic_taxon_name": "Insecta", "observations_count": 557398,
          "wikipedia_summary": "The <b>monarch butterfly</b> (<i>Danaus plexippus</i>) is a milkweed butterfly &amp; more.",
          "wikipedia_url": "https://en.wikipedia.org/wiki/Danaus plexippus",
          "default_photo": {"medium_url": "https://inaturalist-open-data.s3.amazonaws.com/photos/227923335/medium.jpeg", "attribution": "(c) someone"},
          "conservation_status": {"status": "G4"},
          "ancestors": [{"id": 1, "name": "Animalia", "rank": "kingdom", "preferred_common_name": "Animals"}, {"id": 47120, "name": "Arthropoda", "rank": "phylum"}]
        }]}
        """
        let record = try assemble("https://www.inaturalist.org/taxa/48662-Danaus-plexippus", document: json(body))
        #expect(record.kind == "taxon")
        #expect(record.externalId == "48662")
        #expect(record.fields["summary"] == .text("The monarch butterfly (Danaus plexippus) is a milkweed butterfly & more."))
        #expect(record.fields["observationsCount"] == .number(557_398))
        #expect(record.fields["conservationStatus"] == .text("G4"))
        #expect(try record.fields["wikipedia"] == .url(#require(URL(string: "https://en.wikipedia.org/wiki/Danaus_plexippus"))))
        let ancestors = try #require(record.collections["ancestors"])
        #expect(ancestors.map { $0.fields["title"] } == [.text("Animals"), .text("Arthropoda")])
        #expect(ancestors.first?.identities.contains { $0.namespace == "inat.taxon" && $0.value == "1" } == true)
    }

    @Test
    func `Merlin and All About Birds both read a species page and link through the eBird code`() throws {
        let merlin = try assemble("https://ebird.org/species/norcar/US-NY", document: ELVDocument(html: """
        <html><head><meta property="og:title" content="Check out this bird - Northern Cardinal">
        <meta property="og:image" content="https://cdn.download.ams.birds.cornell.edu/api/v2/asset/297087301/1200"></head>
        <body><div class="sciName" data-v-863f9111>Cardinalis cardinalis</div>
        <script>[{},"audio",551661,[894,895],"production","song"]</script></body></html>
        """))
        #expect(merlin.kind == "species")
        #expect(merlin.externalId == "norcar")
        #expect(merlin.fields["title"] == .text("Northern Cardinal"))
        #expect(merlin.fields["scientificName"] == .text("Cardinalis cardinalis"))
        let song = try #require(URL(string: "https://cdn.download.ams.birds.cornell.edu/api/v1/asset/551661/mp3"))
        #expect(merlin.fields["audio"] == .media(ELVMediaRef(url: song, kind: ELVMediaRef.audio)))

        let guide = try assemble("https://www.allaboutbirds.org/guide/Northern_Cardinal/sounds", document: ELVDocument(html: """
        <html><head><link rel="canonical" href="https://www.allaboutbirds.org/guide/Northern_Cardinal/overview">
        <meta property="og:title" content="Northern Cardinal Overview, All About Birds, Cornell Lab of Ornithology">
        <meta property="og:description" content="The male Northern Cardinal is perhaps responsible for getting more people to open up a field guide.">
        <meta property="og:image" content="https://www.allaboutbirds.org/guide/assets/og/528151391-1200px.jpg"></head>
        <body><div class="species-info"><span class="species-name">Northern Cardinal</span><em>Cardinalis cardinalis</em>
        <ul class="additional-info"><li><span>ORDER:</span> Passeriformes</li><li><span>FAMILY:</span> Cardinalidae</li></ul></div>
        <div class="jp-jplayer player-audio" id="jquery_jplayer_audio_1" name="https://www.allaboutbirds.org/guide/assets/sound/551661.mp3"></div>
        <a href="https://birdsoftheworld.org/bow/species/norcar/cur/introduction">Birds of the World</a></body></html>
        """))
        #expect(guide.externalId == "Northern_Cardinal")
        #expect(guide.fields["title"] == .text("Northern Cardinal"))
        #expect(guide.fields["scientificName"] == .text("Cardinalis cardinalis"))
        #expect(guide.fields["family"] == .text("Cardinalidae"))
        #expect(guide.fields["ebirdCode"] == .text("norcar"))
        #expect(guide.fields["audio"] != nil)

        var index = ELVEntityIndex()
        for record in [merlin, guide] {
            try index.register(key: ELVRecordKey(sourceId: record.sourceId, externalId: #require(record.externalId)), identities: record.identities)
        }
        #expect(index.entities().count == 1)
    }

    @Test
    func `Every All About Birds tab fetches the overview, the only tab carrying the species block`() throws {
        let source = try #require(try loaded().source(withId: "allaboutbirds.guide"))
        #expect(source.fetch?.resolvedSteps.first?.url == "https://www.allaboutbirds.org/guide/{param.name}/overview")
    }

    // MARK: - Export files

    @Test
    func `The eBird data download imports one record per species row, keyed by checklist and species`() throws {
        let pack = try loaded()
        let csv = """
        Submission ID,Common Name,Scientific Name,Taxonomic Order,Count,State/Province,County,Location ID,Location,Latitude,Longitude,Date,Time,\
        Protocol,Duration (Min),All Obs Reported,Distance Traveled (km),Area Covered (ha),Number of Observers,Breeding Code,Observation Details,\
        Checklist Comments,ML Catalog Numbers
        S44230333,Northern Cardinal,Cardinalis cardinalis,31270,2,US-NY,Tompkins,L99381,Sapsucker Woods,42.4797,-76.4527,2018-04-03,07:00 AM,Traveling,45,1,1.2,,1,,singing,,551661
        S44230333,American Robin,Turdus migratorius,26421,X,US-NY,Tompkins,L99381,Sapsucker Woods,42.4797,-76.4527,2018-04-03,07:00 AM,Traveling,45,1,1.2,,1,,,,
        """
        let data = Data(csv.utf8)
        let source = try #require(ELVFileRecognizer.recognize(fileName: "MyEBirdData.csv", data: data, sources: pack.fileSources))
        #expect(source.id == "ebird.mydata")
        let records = try ELVArchiveImporter.importRecords(source: source, fileName: "MyEBirdData.csv", data: data)
        #expect(records.map(\.externalId) == ["S44230333|Cardinalis cardinalis", "S44230333|Turdus migratorius"])
        #expect(records.map { $0.fields["title"] } == [.text("Northern Cardinal"), .text("American Robin")])
        #expect(records[1].fields["count"] == .text("X"))
        #expect(records[0].fields["latitude"] == .number(42.4797))
        #expect(records.allSatisfy { $0.kind == "observation" })
    }

    @Test
    func `The iNaturalist export imports by header name and links to the API's observation`() throws {
        let pack = try loaded()
        let csv = """
        id,uuid,observed_on,time_observed_at,user_login,quality_grade,license,url,image_url,description,place_guess,latitude,longitude,species_guess,\
        scientific_name,common_name,iconic_taxon_name,taxon_id
        9000000001,00000000-0000-4000-8000-000000000001,2018-09-19,2018-09-19 15:58:00 UTC,sample_observer,research,CC-BY-NC,\
        https://www.inaturalist.org/observations/9000000001,https://inaturalist-open-data.s3.amazonaws.com/photos/9000000011/medium.jpg,,"Montpelier, VT,\
         USA",44.2623,-72.5809,Monarch,Danaus plexippus,Monarch,Insecta,48662
        """
        let data = Data(csv.utf8)
        let source = try #require(ELVFileRecognizer.recognize(fileName: "observations-512345.csv", data: data, sources: pack.fileSources))
        #expect(source.id == "inat.export")
        let records = try ELVArchiveImporter.importRecords(source: source, fileName: "observations-512345.csv", data: data)
        let row = try #require(records.first)
        #expect(row.externalId == "9000000001")
        #expect(row.fields["title"] == .text("Monarch"))
        #expect(row.fields["place"] == .text("Montpelier, VT, USA"))
        #expect(row.identities.contains { $0.namespace == "inat.observation" && $0.value == "9000000001" })
    }

    @Test
    func `File sources stay out of URL recognition and the floors`() throws {
        let pack = try loaded()
        let fileIds = Set(pack.fileSources.map(\.id))
        #expect(fileIds.isSuperset(of: ["inat.export", "ebird.mydata", "weread.notes"]))
        #expect(pack.genericFloors.allSatisfy { !fileIds.contains($0.id) })
    }
}
