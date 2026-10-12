import EluviumCore
import Foundation

/// The corpus grouping behind the examples browser: sources grouped by
/// provider display title (the three Google Maps variants collapse into one
/// section), with the short-link redirector dissolved — each of its
/// examples files under its destination provider's section, and anything
/// unmapped stays visible in an explicit trailing "Short links" section
/// rather than vanishing. Pure over the loaded pack so tests assert the
/// grouping directly.
enum ExampleCorpus {
    /// One display section: a provider's examples plus any short-link
    /// examples that land on that provider.
    struct Section {
        var title: String
        var kind: String
        var rows: [ELVExample]
    }

    /// Where each live short-link host redirects. Display filing only —
    /// recognition and the chase stay entirely pack-driven. The app knows
    /// only the redirect target's *host*; the provider's display title comes
    /// from the loaded pack's match rules, so a pack retitle cannot strand
    /// this table. Hosts whose tokens the corpus policy dropped as dead
    /// (goo.gl, g.co, maps.apple, yelp.to, abnb.me, gyg.me) have no entry:
    /// were their examples ever to return, they would surface in the
    /// explicit "Short links" section instead of vanishing.
    private static let shortLinkDestinationHosts: [String: String] = [
        "maps.app.goo.gl": "google.com",
        "xhslink.com": "xiaohongshu.com",
        "xhslink.cn": "xiaohongshu.com",
    ]

    /// Groups `sources` into display sections; rearranges, never drops.
    static func sections(from sources: [ELVSource]) -> [Section] {
        var sections: [Section] = []
        var indexByTitle: [String: Int] = [:]
        var titleByHost: [String: String] = [:]
        var shortLinks: [ELVExample] = []
        for source in sources where !source.examples.isEmpty {
            if source.resolvesVia != nil {
                shortLinks.append(contentsOf: source.examples)
                continue
            }
            let title = source.title ?? source.id
            for host in source.match?.hosts ?? [] where titleByHost[host.lowercased()] == nil {
                titleByHost[host.lowercased()] = title
            }
            if let index = indexByTitle[title] {
                sections[index].rows.append(contentsOf: source.examples)
            } else {
                indexByTitle[title] = sections.count
                sections.append(Section(title: title, kind: source.kind, rows: source.examples))
            }
        }
        var unrouted: [ELVExample] = []
        for example in shortLinks {
            if let host = URL(string: example.input)?.host?.lowercased(),
               let destinationHost = shortLinkDestinationHosts[host],
               let destinationTitle = titleByHost[destinationHost],
               let index = indexByTitle[destinationTitle] {
                sections[index].rows.append(example)
            } else {
                unrouted.append(example)
            }
        }
        if !unrouted.isEmpty {
            sections.append(Section(title: "Short links", kind: "link", rows: unrouted))
        }
        return sections
    }
}
