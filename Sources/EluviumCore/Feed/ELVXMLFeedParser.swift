import Foundation

/// Streaming RSS 2.0 / Atom parser built on `XMLParser`, with
/// external-entity resolution disabled (XXE / entity-expansion defense).
/// Matches on local element names so undeclared namespace prefixes
/// still resolve. `itunes:*` and Podcasting 2.0 `podcast:*` fold into the
/// envelope.
final class ELVXMLFeedParser: NSObject, XMLParserDelegate {
    static func parse(_ data: Data) -> ELVFeedEnvelope? {
        let parser = XMLParser(data: data)
        let delegate = ELVXMLFeedParser()
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        guard parser.parse() || !delegate.envelope.items.isEmpty || delegate.envelope.title != nil else { return nil }
        guard delegate.sawFeedRoot else { return nil }
        var envelope = delegate.envelope
        // The root's xml:lang (the Atom way) backstops the RSS <language> element.
        if envelope.language == nil { envelope.language = delegate.rootLanguage }
        return envelope
    }

    // MARK: - Parse state

    private var envelope = ELVFeedEnvelope()
    private var sawFeedRoot = false
    private var isAtom = false
    private var rootLanguage: String?
    private var text = ""

    private var currentItem: ELVFeedEnvelope.Item?
    private var currentGuid: String?
    private var currentAtomId: String?
    private var currentEnclosure: ELVFeedEnvelope.Enclosure?
    private var currentAuthors: [String] = []
    private var currentTags: [String] = []
    private var currentDuration: String?
    private var currentEpisode: Int?
    private var currentSeason: Int?
    private var currentEpisodeType: String?
    private var currentExplicit: Bool?
    private var currentItemImage: String?
    private var currentTranscripts: [ELVFeedEnvelope.Transcript] = []
    private var currentChaptersURL: String?
    private var categoryTerm: String?
    private var inItem = false
    private var inImageBlock = false
    private var inAuthorBlock = false
    /// Set while a channel-level `podcast:funding` element is open, so its
    /// text content becomes the label on the end tag.
    private var awaitingFundingLabel = false
    private func local(_ name: String) -> String {
        if let colon = name.firstIndex(of: ":") { return String(name[name.index(after: colon)...]).lowercased() }
        return name.lowercased()
    }

    // MARK: - XMLParserDelegate

    func parser(_: XMLParser, didStartElement elementName: String, namespaceURI _: String?, qualifiedName _: String?, attributes: [String: String]) {
        let name = local(elementName)
        text = ""

        switch name {
        case "rss", "rdf", "feed":
            sawFeedRoot = true
            if name == "feed" { isAtom = true }
            if rootLanguage == nil, let lang = attributes["xml:lang"], !lang.isEmpty { rootLanguage = lang }
        case "item", "entry":
            beginItem()
        case "image":
            inImageBlock = true
            if let url = attributes["href"] ?? attributes["url"] { assignImage(url) }
        case "author":
            inAuthorBlock = true
        case "category":
            // Atom carries the tag on the `term` attribute and the element is
            // usually empty, so capture it here; consumed on the end tag.
            categoryTerm = attributes["term"].flatMap { $0.isEmpty ? nil : $0 }
        case "enclosure":
            if let url = attributes["url"] {
                currentEnclosure = ELVFeedEnvelope.Enclosure(url: url, type: attributes["type"], lengthBytes: attributes["length"].flatMap { Int($0) })
            }
        case "transcript":
            // Podcasting 2.0 podcast:transcript — item-level, repeatable
            // (one element per rendition type).
            if inItem, let url = attributes["url"], !url.isEmpty {
                currentTranscripts.append(ELVFeedEnvelope.Transcript(url: url, type: attributes["type"], language: attributes["language"]))
            }
        case "chapters":
            // Podcasting 2.0 podcast:chapters — item-level, first wins.
            if inItem, currentChaptersURL == nil, let url = attributes["url"], !url.isEmpty {
                currentChaptersURL = url
            }
        case "funding":
            // Podcasting 2.0 podcast:funding — channel-level; the URL rides
            // the attribute, the label is the element text (end tag).
            if !inItem, envelope.fundingURL == nil, let url = attributes["url"], !url.isEmpty {
                envelope.fundingURL = url
                awaitingFundingLabel = true
            }
        case "link":
            handleStartLink(attributes: attributes)
        case "thumbnail", "content":
            if let url = attributes["href"] ?? attributes["url"], name == "thumbnail" || inItem {
                assignImage(url)
            }
        default:
            break
        }
    }

    private func beginItem() {
        inItem = true
        currentItem = ELVFeedEnvelope.Item(externalId: "")
        currentGuid = nil
        currentAtomId = nil
        currentEnclosure = nil
        currentAuthors = []
        currentTags = []
        currentDuration = nil
        currentEpisode = nil
        currentSeason = nil
        currentEpisodeType = nil
        currentExplicit = nil
        currentItemImage = nil
        currentTranscripts = []
        currentChaptersURL = nil
    }

    /// Atom `<link>`: `href` + `rel` distinguishes alternate from enclosure.
    private func handleStartLink(attributes: [String: String]) {
        // RFC 5005 pagination: RSS documents declare it through <atom:link>
        // too, so the next pointer is captured regardless of dialect.
        if !inItem, attributes["rel"] == "next", envelope.nextURL == nil,
           let next = attributes["href"], !next.isEmpty {
            envelope.nextURL = next
        }
        guard isAtom, let href = attributes["href"] else { return }
        let rel = attributes["rel"] ?? "alternate"
        if rel == "enclosure" {
            currentEnclosure = ELVFeedEnvelope.Enclosure(url: href, type: attributes["type"], lengthBytes: attributes["length"].flatMap { Int($0) })
        } else if rel == "alternate" || rel == "self" {
            if inItem {
                if currentItem?.link == nil { currentItem?.link = href }
            } else if envelope.link == nil {
                envelope.link = href
            }
        }
    }

    /// itunes:image / media:thumbnail carry the image on an attribute;
    /// route it to the item or the feed, first-wins.
    private func assignImage(_ url: String) {
        if inItem {
            if currentItemImage == nil { currentItemImage = url }
        } else if envelope.image == nil {
            envelope.image = url
        }
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_: XMLParser, foundCDATA CDATABlock: Data) {
        // swiftlint:disable:next optional_data_string_conversion
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_: XMLParser, didEndElement elementName: String, namespaceURI _: String?, qualifiedName _: String?) {
        let name = local(elementName)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { text = "" }

        if inItem {
            handleItemElement(name: name, value: value)
        } else {
            handleFeedElement(name: name, value: value)
        }

        switch name {
        case "item", "entry":
            finishItem()
        case "image":
            inImageBlock = false
        case "author":
            inAuthorBlock = false
        case "category":
            categoryTerm = nil
        default:
            break
        }
    }

    // MARK: - Element handlers

    private func handleFeedElement(name: String, value: String) {
        guard !applyChannelMetadata(name: name, value: value) else { return }
        switch name {
        case "title" where !inImageBlock:
            if envelope.title == nil { envelope.title = ELVEntityDecoder.decode(value) }
        case "description", "subtitle", "summary":
            if envelope.feedDescription == nil, !value.isEmpty { envelope.feedDescription = ELVEntityDecoder.decode(value) }
        case "link" where !isAtom:
            if envelope.link == nil, !value.isEmpty { envelope.link = value }
        case "language":
            if envelope.language == nil, !value.isEmpty { envelope.language = value }
        case "url" where inImageBlock:
            if envelope.image == nil { envelope.image = value }
        case "logo", "icon":
            // Atom's feed-image elements carry the URL as text; RSS's
            // <image><url> arrives via the image block above. First-wins.
            if envelope.image == nil, !value.isEmpty { envelope.image = value }
        case "new-feed-url", "id":
            break
        default:
            break
        }
    }

    /// Channel-level identity and Podcasting 2.0 metadata. Returns whether
    /// it consumed `name`.
    private func applyChannelMetadata(name: String, value: String) -> Bool {
        switch name {
        case "guid":
            // Podcasting 2.0 podcast:guid at feed level.
            if envelope.podcastGuid == nil, !value.isEmpty { envelope.podcastGuid = value }
        case "author":
            // itunes:author at channel level (the show's author line).
            if envelope.author == nil, !value.isEmpty { envelope.author = ELVEntityDecoder.decode(value) }
        case "name" where inAuthorBlock:
            // Atom's feed-level <author><name>; <itunes:owner><name> never
            // sets the author block, so it can't leak in.
            if envelope.author == nil, !value.isEmpty { envelope.author = ELVEntityDecoder.decode(value) }
        case "funding":
            // The element text is the funding label ("Support the show"),
            // taken only for the funding URL captured on this start tag.
            if awaitingFundingLabel {
                if envelope.fundingLabel == nil, !value.isEmpty { envelope.fundingLabel = ELVEntityDecoder.decode(value) }
                awaitingFundingLabel = false
            }
        case "type":
            // itunes:type at channel level, validated to its two defined
            // values so a stray <type> element can't leak arbitrary text in.
            let lowered = value.lowercased()
            if envelope.itunesType == nil, lowered == "episodic" || lowered == "serial" { envelope.itunesType = lowered }
        default:
            return false
        }
        return true
    }

    private func handleItemElement(name: String, value: String) {
        guard !applyItemText(name: name, value: value) else { return }
        applyItemMetadata(name: name, value: value)
    }

    /// The item's text-bearing fields. Returns whether it consumed `name`.
    private func applyItemText(name: String, value: String) -> Bool {
        switch name {
        case "title":
            if currentItem?.title == nil { currentItem?.title = ELVEntityDecoder.decode(value) }
        case "description", "summary":
            if currentItem?.summary == nil, !value.isEmpty { currentItem?.summary = ELVEntityDecoder.decode(value) }
        case "encoded", "content":
            if !value.isEmpty { currentItem?.contentHTML = value }
        case "link" where !isAtom:
            if !value.isEmpty { currentItem?.link = value }
        case "guid":
            if !value.isEmpty { currentGuid = value }
        case "id":
            if !value.isEmpty { currentAtomId = value }
        case "creator", "author":
            appendAuthor(value)
        case "name" where inAuthorBlock:
            // A bare <name> is an author only inside an <author> block —
            // <podcast:person><name>, <itunes:owner><name>, <source><name>
            // must not leak in.
            appendAuthor(value)
        case "category":
            // Atom carries the tag on `term` (captured at the start tag);
            // RSS carries it as element text. Prefer term when present.
            let tag = categoryTerm ?? value
            if !tag.isEmpty { currentTags.append(tag) }
        default:
            return false
        }
        return true
    }

    private func appendAuthor(_ value: String) {
        if !value.isEmpty, !currentAuthors.contains(value) { currentAuthors.append(value) }
    }

    /// The item's dates and podcast metadata.
    private func applyItemMetadata(name: String, value: String) {
        switch name {
        case "pubdate", "published", "date":
            if currentItem?.published == nil, !value.isEmpty { currentItem?.published = ELVFeedNormalizer.normalizeDate(value) }
        case "updated", "modified":
            if !value.isEmpty { currentItem?.updated = ELVFeedNormalizer.normalizeDate(value) }
        case "duration":
            currentDuration = value
        case "episode":
            currentEpisode = Int(value)
        case "season":
            currentSeason = Int(value)
        case "episodetype":
            currentEpisodeType = value
        case "explicit":
            currentExplicit = (value.lowercased() == "yes" || value.lowercased() == "true")
        default:
            break
        }
    }

    private func finishItem() {
        guard var item = currentItem else { inItem = false; return }
        item.guid = currentGuid
        item.authors = currentAuthors
        item.tags = currentTags
        item.enclosure = currentEnclosure
        item.image = currentItemImage
        item.durationSeconds = ELVFeedNormalizer.durationSeconds(currentDuration)
        item.episode = currentEpisode
        item.season = currentSeason
        item.episodeType = currentEpisodeType
        item.explicit = currentExplicit
        item.transcripts = currentTranscripts
        item.chaptersURL = currentChaptersURL
        item.externalId = ELVFeedNormalizer.itemIdentity(
            guid: currentGuid,
            atomId: currentAtomId,
            jsonId: nil,
            enclosureURL: currentEnclosure?.url,
            link: item.link,
            title: item.title,
            published: item.published,
            ordinal: envelope.items.count
        )
        envelope.items.append(item)
        currentItem = nil
        inItem = false
    }
}
