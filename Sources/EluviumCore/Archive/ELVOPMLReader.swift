import Foundation

/// OPML 1.0/2.0 subscription-list reader: the universal export every
/// feed reader and podcast app speaks. Leaf `<outline>` elements carrying
/// `xmlUrl` are subscriptions; enclosing outline titles become the group
/// path. Streaming `XMLParser` with external entities disabled, like every
/// XML surface.
public enum ELVOPMLReader {
    public struct Subscription: Sendable, Equatable {
        public var title: String?
        public var feedURL: String
        public var siteURL: String?
        /// Enclosing outline titles, outermost first, joined with " / ".
        public var group: String?
    }

    /// Parses OPML text. Returns nil when the document has no `<opml>` root;
    /// an OPML document with no feed outlines returns an empty list.
    public static func parse(_ text: String) -> [Subscription]? {
        let parser = XMLParser(data: Data(text.utf8))
        let delegate = Delegate()
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        parser.parse()
        guard delegate.sawOPMLRoot else { return nil }
        return delegate.subscriptions
    }

    /// The subscriptions as item JSON for the archive assembly path, so a
    /// source's `rows` specs select with ordinary `json` candidates.
    public static func itemsJSON(_ subscriptions: [Subscription]) -> [ELVRawJSON] {
        subscriptions.map { subscription in
            var node: [String: ELVRawJSON] = ["feedUrl": .string(subscription.feedURL)]
            node["title"] = subscription.title.map(ELVRawJSON.string)
            node["htmlUrl"] = subscription.siteURL.map(ELVRawJSON.string)
            node["group"] = subscription.group.map(ELVRawJSON.string)
            return .object(node.compactMapValues { $0 })
        }
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var sawOPMLRoot = false
        var subscriptions: [Subscription] = []
        /// Titles of the outline elements currently open around the cursor.
        private var outlineTitles: [String] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI _: String?, qualifiedName _: String?, attributes: [String: String]) {
            switch elementName.lowercased() {
            case "opml":
                sawOPMLRoot = true
            case "outline":
                // OPML attribute casing drifts (xmlUrl / xmlURL / xmlurl);
                // key everything lowercased once.
                var lowered: [String: String] = [:]
                for (key, value) in attributes where lowered[key.lowercased()] == nil {
                    lowered[key.lowercased()] = value
                }
                let title = firstNonEmpty(lowered["text"], lowered["title"])
                if let feedURL = lowered["xmlurl"], !feedURL.isEmpty {
                    // The same ceiling as every archive surface: past it,
                    // stop parsing rather than growing without bound.
                    guard subscriptions.count < ELVArchiveLimits.maxTotalItems else {
                        parser.abortParsing()
                        return
                    }
                    subscriptions.append(Subscription(
                        title: title,
                        feedURL: feedURL,
                        siteURL: firstNonEmpty(lowered["htmlurl"]),
                        group: outlineTitles.isEmpty ? nil : outlineTitles.joined(separator: " / ")
                    ))
                }
                // Every outline nests: a subscription outline rarely has
                // children, but when it does the group path stays honest.
                outlineTitles.append(title ?? "")
            default:
                break
            }
        }

        func parser(_: XMLParser, didEndElement elementName: String, namespaceURI _: String?, qualifiedName _: String?) {
            if elementName.lowercased() == "outline", !outlineTitles.isEmpty {
                outlineTitles.removeLast()
            }
        }

        private func firstNonEmpty(_ candidates: String?...) -> String? {
            for candidate in candidates {
                if let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !candidate.isEmpty {
                    return ELVEntityDecoder.decode(candidate)
                }
            }
            return nil
        }
    }
}
