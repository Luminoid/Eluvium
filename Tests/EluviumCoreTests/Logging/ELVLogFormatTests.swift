import Foundation
import Testing
@testable import EluviumCore

@Suite("Log format")
struct ELVLogFormatTests {
    @Test
    func `A log line names a web link's host and an app link's scheme`() throws {
        let web = try #require(URL(string: "https://www.flightaware.com/live/flight/UAL1"))
        let flighty = try #require(URL(string: "flighty://flight/UA123"))
        let maps = try #require(URL(string: "comgooglemaps://?q=Tokyo+Tower"))
        #expect(ELVLogFormat.host(web) == "www.flightaware.com")
        // An app link's "host" is a path word or absent, so the scheme
        // names it instead.
        #expect(ELVLogFormat.host(flighty) == "flighty:")
        #expect(ELVLogFormat.host(maps) == "comgooglemaps:")
        #expect(ELVLogFormat.host(nil) == "-")
    }
}
