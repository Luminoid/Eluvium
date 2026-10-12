import EluviumCore
import Foundation
import LumiKitUI
import Testing
import UIKit
@testable import EluviumUI

@Suite("Record card")
@MainActor
struct ELVRecordCardViewTests {
    @Test
    func `Configuring a card builds a row per field plus meta, identity, and collection lines`() {
        var record = ELVRecord(sourceId: "pokeapi.pokemon", kind: "creature", fields: [
            "title": .text("Pikachu"),
            "height": .number(4),
        ])
        record.externalId = "25"
        record.identities = [ELVIdentity(namespace: "pokeapi.pokemon", value: "25", origin: .declared)]
        record.collections = ["types": [ELVRecord(sourceId: "pokeapi.pokemon", kind: "type")]]
        record.provenance["height"] = ELVProvenance(origin: "json:$.height", candidateIndex: 0)

        let card = ELVRecordCardView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        card.configure(with: record)
        card.layoutIfNeeded()

        let labels = allViews(of: UILabel.self, in: card)
        let texts = labels.compactMap(\.text)
        #expect(texts.contains("Pikachu"))
        #expect(texts.contains { $0.contains("source: pokeapi.pokemon") && $0.contains("id: 25") })
        #expect(texts.contains("height"))
        #expect(texts.contains("json:$.height")) // the provenance chip
        #expect(texts.contains("identities: pokeapi.pokemon=25"))
        #expect(texts.contains("types: 1 item"))

        // The container is the design-system card; provenance is a design-system chip.
        #expect(allViews(of: LMKCardView.self, in: card).count == 1)
        #expect(allViews(of: LMKChipView.self, in: card).count == 1)

        // Each field row is one VoiceOver element with a combined label.
        let fieldRows = allViews(of: UIStackView.self, in: card).filter(\.isAccessibilityElement)
        #expect(fieldRows.count == 1)
        #expect(fieldRows.first?.accessibilityLabel == "height: 4, json:$.height")

        // Reconfiguring replaces the rows instead of stacking them.
        card.configure(with: record)
        #expect(allViews(of: UILabel.self, in: card).count == labels.count)
    }

    @Test
    func `A media image field renders a thumbnail through the injected loader; without one, URL text only`() async throws {
        let imageURL = try #require(URL(string: "https://image.chewy.com/catalog/47885_MAIN.jpg"))
        let record = ELVRecord(sourceId: "chewy.product", kind: "product", fields: [
            "title": .text("i/d Digestive Care"),
            "image": .media(ELVMediaRef(url: imageURL, kind: ELVMediaRef.image)),
        ])

        // No loader injected: the field renders as its URL text, no image view.
        let plain = ELVRecordCardView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        plain.configure(with: record)
        #expect(allViews(of: UIImageView.self, in: plain).isEmpty)
        #expect(allViews(of: UILabel.self, in: plain).compactMap(\.text).contains(imageURL.absoluteString))

        // Loader injected: the row gains a thumbnail that fills in once the
        // load task lands; the URL text stays.
        let expected = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let card = ELVRecordCardView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        card.imageLoader = { _ in expected }
        card.configure(with: record)
        for task in card.imageLoadTasks {
            await task.value
        }
        let thumbnails = allViews(of: UIImageView.self, in: card)
        #expect(thumbnails.count == 1)
        #expect(thumbnails.first?.image === expected)
    }

    @Test
    func `The card's own copy is localized from the target's bundle, with a correct plural`() {
        // A missing compiled .lproj makes every lookup return its key.
        let source = ELVCardStrings.source("x")
        #expect(source == "source: x")
        #expect(!source.hasPrefix("card."))
        #expect(ELVCardStrings.collectionSummary(name: "items", count: 1) == "items: 1 item")
        #expect(ELVCardStrings.collectionSummary(name: "items", count: 2) == "items: 2 items")
        #expect(ELVCardStrings.collectionSummary(name: "items", count: 0) == "items: 0 items")
        #expect(ELVCardStrings.identities("imdb=tt1") == "identities: imdb=tt1")
    }

    @Test
    func `The title is a VoiceOver heading and a tappable collection carries a mirroring chevron`() throws {
        let record = ELVRecord(sourceId: "s", kind: "show", fields: ["title": .text("Show")], collections: ["items": [ELVRecord(sourceId: "s", kind: "episode")]])
        let card = ELVRecordCardView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        card.collectionTapHandler = { _, _ in }
        card.configure(with: record)

        let title = try #require(allViews(of: UILabel.self, in: card).first { $0.text == "Show" })
        #expect(title.accessibilityTraits.contains(.header))
        let button = try #require(allViews(of: LMKButton.self, in: card).first)
        #expect(button.title == "items: 1 item")
        #expect(button.accessibilityLabel == "items: 1 item")
        // `chevron.forward`, not a "→" glyph in the title: it mirrors in RTL.
        #expect(button.image == UIImage(systemName: "chevron.forward"))
    }

    @Test
    func `Fields read inline only in regular width at non-accessibility text sizes`() {
        let regular = UITraitCollection { traits in
            traits.horizontalSizeClass = .regular
            traits.preferredContentSizeCategory = .large
        }
        let compact = UITraitCollection { traits in
            traits.horizontalSizeClass = .compact
            traits.preferredContentSizeCategory = .large
        }
        let accessible = UITraitCollection { traits in
            traits.horizontalSizeClass = .regular
            traits.preferredContentSizeCategory = .accessibilityExtraLarge
        }
        #expect(ELVRecordCardView.usesInlineFields(regular))
        #expect(!ELVRecordCardView.usesInlineFields(compact))
        #expect(!ELVRecordCardView.usesInlineFields(accessible))
    }

    @Test
    func `Supporting lines use the secondary text color, never tertiary`() {
        var record = ELVRecord(sourceId: "s", kind: "movie", fields: ["year": .number(1977)])
        record.identities = [ELVIdentity(namespace: "imdb", value: "tt0076759", origin: .declared)]
        let card = ELVRecordCardView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        card.configure(with: record)
        let identities = allViews(of: UILabel.self, in: card).first { $0.text?.hasPrefix("identities:") == true }
        let traits = UITraitCollection(userInterfaceStyle: .light)
        #expect(identities?.textColor.resolvedColor(with: traits) == LMKColor.textSecondary.resolvedColor(with: traits))
    }

    private func allViews<T: UIView>(of type: T.Type, in view: UIView) -> [T] {
        view.subviews.flatMap { subview -> [T] in
            var found = allViews(of: type, in: subview)
            if let match = subview as? T { found.append(match) }
            return found
        }
    }
}
