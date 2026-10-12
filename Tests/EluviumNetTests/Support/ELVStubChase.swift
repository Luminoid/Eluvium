import EluviumCore
import Foundation
@testable import EluviumNet

/// One deterministic chase stub for every suite that needs
/// `shortlink.expand`: the registry is process-global and suites run in
/// parallel, so each test registering its OWN stub would race. The landing
/// is keyed on the short URL's path, making re-registration idempotent.
enum ELVStubChase {
    static func register() {
        ELVNetOps.register(expander: ELVShortLinkExpander(chase: { url, _ in
            switch url.path {
            case "/to-pokeapi": URL(string: "https://pokeapi.co/api/v2/pokemon/25")
            case "/to-redirector": URL(string: "https://yelp.to/second-hop")
            case "/to-alltrails": URL(string: "https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail")
            case "/to-consent": URL(string: "https://consent.google.com/m?continue=https%3A%2F%2Fwww.google.com%2Fmaps%2Fplace%2FBenu")
            case "/to-dead": throw ELVFetchFailure.httpError(status: 404)
            default: nil
            }
        }))
    }
}
