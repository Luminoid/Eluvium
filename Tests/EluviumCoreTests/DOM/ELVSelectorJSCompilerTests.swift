import Foundation
import Testing
@testable import EluviumCore

@Suite("Selector→JS compiler")
struct ELVSelectorJSCompilerTests {
    @Test
    func `The compiled program is one IIFE that returns a JSON string`() {
        let js = ELVSelectorJSCompiler.compile(
            css: [ELVCSSQuery(key: "h1", selector: "h1", attr: nil)],
            maxHTMLBytes: 3_000_000
        )
        #expect(js.hasPrefix("(function () {"))
        #expect(js.contains("return JSON.stringify({"))
        #expect(js.contains("document.querySelector"))
        // The renderer destructures results/url/html only; the signals map
        // (and its signalPresent helper) ship in the settle probe, not here.
        #expect(!js.contains("signals"))
        #expect(!js.contains("signalPresent"))
    }

    @Test
    func `Pack strings are JSON-escaped into the program, never interpolated as code`() {
        let hostile = ELVCSSQuery(key: "x", selector: "\"); alert('xss'); //", attr: nil)
        let js = ELVSelectorJSCompiler.compile(css: [hostile], maxHTMLBytes: 3_000_000)
        // The break-out quote is escaped (\"), so the payload can never close
        // the string literal and run as code. The escaped form is present;
        // an unescaped break-out that opens executable code is not.
        #expect(js.contains("\\\"); alert('xss');"))
        #expect(!js.contains("[\"x\", \"\"); alert"))
    }

    @Test
    func `jsString escapes quotes, backslashes, and non-ASCII correctly`() {
        #expect(ELVSelectorJSCompiler.jsString("plain") == "\"plain\"")
        #expect(ELVSelectorJSCompiler.jsString("a\"b") == "\"a\\\"b\"")
        #expect(ELVSelectorJSCompiler.jsString("a\\b") == "\"a\\\\b\"")
        // Non-ASCII stays representable (JSONEncoder may escape or pass through).
        let cafe = ELVSelectorJSCompiler.jsString("Café")
        #expect(cafe.hasPrefix("\"") && cafe.hasSuffix("\""))
    }

    @Test
    func `The settle probe returns length and anySignal as a JSON string`() {
        let js = ELVSelectorJSCompiler.settleProbe(settleSignals: ["og:title"])
        #expect(js.contains("return JSON.stringify({ length: len, anySignal: anySignal })"))
        // og:title is a hardcoded literal in the probe (single-quoted), not a
        // pack string, so it appears with real inner double quotes.
        #expect(js.contains("meta[property=\"og:title\"]"))
    }

    @Test
    func `A source's CSS queries are collected from fields and collections, deduplicated`() {
        let source = ELVSource(
            id: "s",
            kind: "k",
            fields: [
                ELVFieldSpec(name: "title", candidates: [
                    ELVCandidate(from: .css(selector: "h1", attr: nil)),
                    ELVCandidate(from: .meta("og:title")),
                ]),
                ELVFieldSpec(name: "image", candidates: [ELVCandidate(from: .css(selector: "img.cover", attr: "@src"))]),
            ],
            collections: [
                ELVCollectionSpec(name: "notes", from: .css(selector: ".note", attr: nil), item: [
                    ELVFieldSpec(name: "text", candidates: [ELVCandidate(from: .css(selector: "h1", attr: nil))]),
                ]),
            ]
        )
        // A dom step without scoped fields resolves the source ladder.
        let queries = source.cssQueries(for: ELVFetchStep(mode: ELVFetchModes.dom))
        // h1 appears twice but dedups; the collection's selector isn't a
        // field candidate so it isn't collected, only item candidates are.
        #expect(queries.map(\.key).sorted() == ["h1", "img.cover@@src"])
        // Scoped fields replace the ladder; source collections stay.
        let scoped = ELVFetchStep(mode: ELVFetchModes.dom, fields: [ELVFieldSpec(name: "only", candidates: [ELVCandidate(from: .css(selector: ".only", attr: nil))])])
        #expect(source.cssQueries(for: scoped).map(\.key).sorted() == [".only", "h1"])
    }
}
