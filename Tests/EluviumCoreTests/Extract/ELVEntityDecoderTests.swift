import Foundation
import Testing
@testable import EluviumCore

@Suite("HTML entity decoding")
struct ELVEntityDecoderTests {
    @Test
    func `Named, decimal, and hex entities decode; unknown entities stay verbatim`() {
        #expect(ELVEntityDecoder.decode("Tom &amp; Jerry") == "Tom & Jerry")
        #expect(ELVEntityDecoder.decode("It&#8217;s here") == "It\u{2019}s here")
        #expect(ELVEntityDecoder.decode("A &#x2192; B") == "A \u{2192} B")
        #expect(ELVEntityDecoder.decode("Caf&eacute; &euro;9") == "Café €9")
        #expect(ELVEntityDecoder.decode("&notarealentity; stays") == "&notarealentity; stays")
        #expect(ELVEntityDecoder.decode("no entities") == "no entities")
        #expect(ELVEntityDecoder.decode("dangling & ampersand") == "dangling & ampersand")
        #expect(ELVEntityDecoder.decode("&quot;&lt;tag&gt;&quot;") == "\"<tag>\"")
    }

    @Test
    func `A long ampersand run decodes unchanged in linear time`() {
        // Regression tripwire: an unbounded ";" search made this quadratic
        // (each "&" scanned to the end of the string) — a multi-MB "&" run
        // hung the decoder. Bounded to the entity window, this completes
        // instantly and verbatim.
        let run = String(repeating: "&", count: 300_000)
        #expect(ELVEntityDecoder.decode(run) == run)
        #expect(ELVEntityDecoder.decode(run + "amp;") == String(run.dropLast()) + "&")
    }
}
