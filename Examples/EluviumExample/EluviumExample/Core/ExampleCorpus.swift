import EluviumCatalog
import EluviumCore
import Foundation

/// The corpus grouping behind the examples browser: one section per catalog
/// family (Travel, Reference, Media, …) in the order the families first
/// appear in the pack, the generic floors after the rest; inside a family
/// the rows sort by provider (a Chinese title by its pinyin: 豆瓣 under D),
/// so a provider's variants sit together (the Google Maps place, share,
/// directions, and app-link sources), and keep pack order within a
/// provider. The short-link redirector dissolves: each of
/// its examples files beside the source its `previewAs` hint names, and
/// anything unmapped stays visible in a trailing "Short links" section
/// rather than vanishing. Sources outside the catalog (the bundled file
/// pack's) get a section of their own after the catalog's. Pure over the
/// loaded pack so tests assert the grouping directly.
enum ExampleCorpus {
    /// One example as the browser lists it, with the provider and record
    /// kind of the source that runs it.
    struct Row {
        var provider: String
        var kind: String
        var example: ELVExample
    }

    /// One family's examples, sorted by provider.
    struct Section {
        var title: String
        var rows: [Row]
    }

    /// Each catalog source id's family (`travel`, `media`, …), from the
    /// catalog's own chunk table.
    static let catalogFamilyById: [String: String] = {
        var map: [String: String] = [:]
        for (family, ids) in ELVCatalogFamilies.families {
            for id in ids {
                map[id] = family
            }
        }
        return map
    }()

    /// The family key for sources outside the catalog.
    private static let bundledFamily = "bundled"
    /// The catch-all floors' family, listed last: they answer any link.
    private static let floorsFamily = "floors"

    /// Groups `sources` into family sections; rearranges, never drops. A
    /// short link files under the source its redirector's `previewAs` hint
    /// names for that host, so the filing is pack data, like recognition.
    static func sections(from sources: [ELVSource], familyById: [String: String] = catalogFamilyById) -> [Section] {
        // One group per provider, in pack order, tagged with its family.
        struct Group {
            var family: String
            var provider: String
            var sortName: String
            var rows: [Row]
        }
        var groups: [Group] = []
        var groupIndexByProvider: [String: Int] = [:]
        var sourceById: [String: ELVSource] = [:]
        var shortLinks: [(example: ELVExample, hints: [String: String])] = []
        for source in sources {
            sourceById[source.id] = source
        }
        for source in sources where !source.examples.isEmpty {
            if source.resolvesVia != nil {
                shortLinks += source.examples.map { ($0, source.previewAs) }
                continue
            }
            let key = source.title ?? source.id
            let provider = source.displayName
            let rows = source.examples.map { Row(provider: provider, kind: kind(of: source, example: $0), example: $0) }
            if let index = groupIndexByProvider[key] {
                groups[index].rows += rows
            } else {
                groupIndexByProvider[key] = groups.count
                groups.append(Group(family: familyById[source.id] ?? bundledFamily, provider: provider, sortName: source.sortName, rows: rows))
            }
        }
        var unrouted: [Row] = []
        for (example, hints) in shortLinks {
            if let host = URL(string: example.input)?.host?.lowercased(),
               let destinationId = hints.first(where: { host == $0.key || host.hasSuffix("." + $0.key) })?.value,
               let destination = sourceById[destinationId],
               let index = groupIndexByProvider[destination.title ?? destination.id] {
                groups[index].rows.append(Row(provider: groups[index].provider, kind: kind(of: destination, example: example), example: example))
            } else {
                unrouted.append(Row(provider: "Short link", kind: "link", example: example))
            }
        }

        var families: [String] = []
        for group in groups where !families.contains(group.family) {
            families.append(group.family)
        }
        // The catch-all floors close the catalog's families; the file
        // pack's own section follows them.
        for last in [floorsFamily, bundledFamily] {
            if let index = families.firstIndex(of: last) {
                families.append(families.remove(at: index))
            }
        }
        var sections = families.map { family in
            let rows = groups
                .filter { $0.family == family }
                .sorted { $0.sortName.localizedStandardCompare($1.sortName) == .orderedAscending }
                .flatMap(\.rows)
            return Section(title: title(forFamily: family), rows: rows)
        }
        if !unrouted.isEmpty {
            sections.append(Section(title: "Short links", rows: unrouted))
        }
        return sections
    }

    /// The kind a row shows: the source's own, or, for a source that
    /// infers its kind per link (Douban's album, movie, book, and game),
    /// the kind the example expects, else every kind it can infer.
    static func kind(of source: ELVSource, example: ELVExample) -> String {
        if !source.kind.isEmpty { return source.kind }
        if let expected = example.expectedKind { return expected }
        let inferred = source.inferredKinds
        return inferred.isEmpty ? "record" : inferred.joined(separator: " / ")
    }

    private static func title(forFamily family: String) -> String {
        switch family {
        case floorsFamily: "Generic floors"
        case bundledFamily: "Bundled file pack"
        default: family.capitalized
        }
    }
}
