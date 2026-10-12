import Foundation
import Testing
@testable import EluviumCore

@Suite("Note pyramid")
struct ELVNotePyramidTests {
    @Test
    func `The tiered template parses into top, heart, and base`() throws {
        let prose = "Top notes are Bergamot, Lemon and Neroli; middle notes are Jasmine and Ylang-Ylang; base notes are Sandalwood, Musk and Vetiver."
        let pyramid = try #require(ELVNotePyramid.parse(fromText: prose))
        #expect(pyramid.top == ["Bergamot", "Lemon", "Neroli"])
        #expect(pyramid.heart == ["Jasmine", "Ylang-Ylang"])
        #expect(pyramid.base == ["Sandalwood", "Musk", "Vetiver"])
        #expect(pyramid.flat.isEmpty)
    }

    @Test
    func `Heart is a synonym for middle and tiers are never invented`() throws {
        let heart = try #require(ELVNotePyramid.parse(fromText: "Heart notes: Rose and Iris. Base note is Amber."))
        #expect(heart.heart == ["Rose", "Iris"])
        #expect(heart.base == ["Amber"])
        #expect(heart.top.isEmpty)

        // No tier phrasing at all: the flat form lands in `flat`, not a tier.
        let flat = try #require(ELVNotePyramid.parse(fromText: "A woody scent with notes of Cedar, Oakmoss and Tonka Bean."))
        #expect(flat.flat == ["Cedar", "Oakmoss", "Tonka Bean"])
        #expect(flat.top.isEmpty)

        #expect(ELVNotePyramid.parse(fromText: "A lovely fragrance with no pyramid.") == nil)
    }

    @Test
    func `Review prose never reads as a tier, and a list the page cut short yields to the full one`() throws {
        // Santal 33 (2026-10-11 log): no tiered pyramid; the first "top
        // note is" and "base notes" sit in reviews, and the page's own
        // og:description, ahead of the body in the HTML, cuts the untiered
        // template short.
        let page = """
        <meta property="og:description" content="Santal 33 by Le Labo is a Woody Aromatic fragrance. The fragrance features Sandalwood, Leather, Papyru...">
        <p>Santal 33 by Le Labo is a Woody Aromatic fragrance for women and men. \
        The fragrance features Sandalwood, Leather, Papyrus, Virginia Cedar, Cardamom, Violet, Iris and Amber. </p>
        <p>The top note is iris set on a nice base of sandalwood, nothing more nothing less. \
        For me, the consecutive top, heart and base notes capture exactly the layers of scent, as time passes it evolves.</p>
        <p>The top notes are a bit harsh for the first 10 minutes.</p>
        """
        let pyramid = try #require(ELVNotePyramid.parse(fromText: page))
        #expect(pyramid.top.isEmpty)
        #expect(pyramid.heart.isEmpty)
        #expect(pyramid.base.isEmpty)
        #expect(pyramid.flat == ["Sandalwood", "Leather", "Papyrus", "Virginia Cedar", "Cardamom", "Violet", "Iris", "Amber"])
        // The ellipsis alone, with no full list behind it, yields nothing.
        #expect(ELVNotePyramid.parse(fromText: "The fragrance features Sandalwood, Leather, Papyru...") == nil)
    }

    @Test
    func `A note runs up to four words; anything longer or numbered is prose`() throws {
        let lily = try #require(ELVNotePyramid.parse(fromText: "Top notes are Lily of the Valley and Pear; base notes are Musk."))
        #expect(lily.top == ["Lily of the Valley", "Pear"])
        #expect(lily.base == ["Musk"])
        #expect(ELVNotePyramid.parse(fromText: "Top notes are too strong for my taste honestly.") == nil)
        #expect(ELVNotePyramid.parse(fromText: "Base notes are gone after 2 hours.") == nil)
        // A prose hit ahead of the template does not hide the template.
        let later = try #require(ELVNotePyramid.parse(fromText: "The top notes are way too loud for an office. Top notes are Pear and Freesia."))
        #expect(later.top == ["Pear", "Freesia"])
    }

    @Test
    func `The op emits tags per tier with the document description fallback`() throws {
        ELVNativeOps.registerBuiltins()
        let op = try #require(ELVNativeOps.lookup("notePyramid.fromProse"))
        let outputs = try #require(op(["text": "Top notes are Pear and Freesia; base notes are Musk and Cedar."], ELVExtractionContext()))
        #expect(outputs["top"] == .tags(["Pear", "Freesia"]))
        #expect(outputs["base"] == .tags(["Musk", "Cedar"]))
        #expect(outputs["heart"] == nil)

        let document = ELVDocument(metas: ["og:description": "notes of Vanilla and Tobacco"])
        let fallback = try #require(op([:], ELVExtractionContext(document: document)))
        #expect(fallback["notes"] == .tags(["Vanilla", "Tobacco"]))
    }
}
