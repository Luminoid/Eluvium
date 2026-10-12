import EluviumCore
import LumiKitUI
import SnapKit
import UIKit

/// The record preview: a record rendered as a titled card with a field
/// table showing each field's value and provenance chip, identity and
/// collection summaries. This is the framework's default record rendering;
/// apps with their own record UI simply don't use it.
///
/// Composes `LMKCardView` (it is `final`, so composition over subclassing):
/// corner radius, shadow elevation, and content insets all come from the
/// active `LMKTheme`. Labels come from `UILabel.lmk_make`, which also opts
/// every line into Dynamic Type; the provenance origin renders as
/// `LMKChipView`. In a regular-width layout each field reads inline (key
/// beside value); compact widths and accessibility text sizes stack the key
/// above the value. The card's own copy is localized (`Localizable.strings`
/// and a `.stringsdict` plural in the target's resources).
///
/// Not `LMKDetailCardView`: its key/value rows carry text only, so the
/// per-field provenance chip, the media thumbnail with its cancellable
/// load, and the one combined VoiceOver label per field would all become
/// custom rows, leaving the detail card little more than a header.
public final class ELVRecordCardView: UIView {
    /// Loads a thumbnail for `.media` image fields. Injected by the host and
    /// nil by default: the framework renders records, it never fetches — the
    /// image bytes go through the host's own network stack and policy, not
    /// this view. With no loader, media fields render as their URL text only.
    public var imageLoader: ((ELVMediaRef) async -> UIImage?)?

    /// One task per thumbnail in the current configuration; cancelled on
    /// reconfigure so a slow load can't land on a rebuilt card. Internal so
    /// tests can await the loads deterministically.
    private(set) var imageLoadTasks: [Task<Void, Never>] = []

    /// Invoked when the user taps a collection line ("items: 20 items").
    /// Injected by the host; nil keeps the line a plain summary label — the
    /// framework renders records, navigation belongs to the host.
    public var collectionTapHandler: ((String, [ELVRecord]) -> Void)?

    /// The collections behind the current configuration's tappable lines,
    /// indexed by button tag.
    private var tappableCollections: [(name: String, children: [ELVRecord])] = []

    /// The key/value pair of every field row, so a size-class or text-size
    /// change re-lays them out without a rebuild.
    private var fieldPairs: [FieldPair] = []

    private lazy var card = LMKCardView()

    private lazy var stack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = LMKSpacing.small
        return stack
    }()

    override public init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(card)
        card.snp.makeConstraints { $0.edges.equalToSuperview() }
        card.contentView.addSubview(stack)
        stack.snp.makeConstraints { $0.edges.equalToSuperview() }
        registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitPreferredContentSizeCategory.self]) { (view: Self, _: UITraitCollection) in
            view.applyFieldLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Tears down and rebuilds the arranged-subview tree on every call.
    /// Reusing rows (diff the count, reconfigure in place) would need typed
    /// row views with add/remove paths for the optional chip and summary
    /// lines; the card reconfigures on user action, not on a scroll path, so
    /// the rebuild cost is accepted over that complexity.
    deinit {
        for task in imageLoadTasks {
            task.cancel()
        }
    }

    public func configure(with record: ELVRecord) {
        for task in imageLoadTasks {
            task.cancel()
        }
        imageLoadTasks.removeAll()
        fieldPairs.removeAll()
        stack.lmk_removeAllArrangedSubviews()

        let title = record.fields["title"].map(ELVValueDisplay.string) ?? record.kind
        let titleLabel = UILabel.lmk_make(.h3, text: title)
        // VoiceOver's rotor jumps between records by their titles.
        titleLabel.accessibilityTraits = .header
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(makeMetaRow(sourceId: record.sourceId, kind: record.kind, externalId: record.externalId))

        let orderedKeys = record.fields.keys.filter { $0 != "title" }.sorted()
        for key in orderedKeys {
            guard let value = record.fields[key] else { continue }
            stack.addArrangedSubview(makeFieldRow(key: key, value: value, provenance: record.provenance[key]))
        }

        if !record.identities.isEmpty {
            let identities = record.identities.map { "\($0.namespace)=\($0.value)" }.joined(separator: "  ")
            // Secondary, not tertiary: tertiary text reads about 2:1 on the
            // card, and ids are load-bearing.
            stack.addArrangedSubview(UILabel.lmk_make(.caption, text: ELVCardStrings.identities(identities), color: LMKColor.textSecondary))
        }
        tappableCollections.removeAll()
        for (name, children) in record.collections.sorted(by: { $0.key < $1.key }) {
            let summary = ELVCardStrings.collectionSummary(name: name, count: children.count)
            if collectionTapHandler != nil, !children.isEmpty {
                var style = LMKButton.Style.ghost(.primary)
                style.imagePlacement = .trailing
                let button = LMKButton(title: summary, style: style, target: self, action: #selector(collectionTapped(_:)))
                // `chevron.forward` mirrors in right-to-left layouts; the
                // glyph is visual, so VoiceOver reads the summary alone.
                button.image = UIImage(systemName: "chevron.forward")
                button.accessibilityLabel = summary
                button.tag = tappableCollections.count
                tappableCollections.append((name, children))
                stack.addArrangedSubview(makeLeadingAligned(button))
            } else {
                stack.addArrangedSubview(UILabel.lmk_make(.subbodyMedium, text: summary))
            }
        }
        applyFieldLayout()
    }

    /// Whether fields read inline (key beside value) under `traits`: in a
    /// regular-width layout, unless the text is at an accessibility size,
    /// where an inline value would get a few characters of width.
    static func usesInlineFields(_ traits: UITraitCollection) -> Bool {
        traits.horizontalSizeClass == .regular && !traits.preferredContentSizeCategory.isAccessibilityCategory
    }

    @objc private func collectionTapped(_ sender: UIButton) {
        guard tappableCollections.indices.contains(sender.tag) else { return }
        let collection = tappableCollections[sender.tag]
        collectionTapHandler?(collection.name, collection.children)
    }

    private func makeMetaRow(sourceId: String, kind: String, externalId: String?) -> UIView {
        var parts = [ELVCardStrings.source(sourceId), ELVCardStrings.kind(kind)]
        if let externalId { parts.append(ELVCardStrings.id(externalId)) }
        return UILabel.lmk_make(.caption, text: parts.joined(separator: "   "))
    }

    /// One field: key and value (stacked, or inline in regular width), plus
    /// the provenance origin as a chip. The row is a single VoiceOver
    /// element ("key: value, provenance") so a ten-field record reads as one
    /// swipe per field, not three.
    private func makeFieldRow(key: String, value: ELVValue, provenance: ELVProvenance?) -> UIView {
        let row = UIStackView()
        row.axis = .vertical
        row.spacing = LMKSpacing.xxs

        let valueString = ELVValueDisplay.string(value)
        let pair = FieldPair(key: UILabel.lmk_make(.subbodyMedium, text: key), value: UILabel.lmk_make(.body, text: valueString))
        fieldPairs.append(pair)
        row.addArrangedSubview(pair.stack)
        if let imageLoader, case let .media(media) = value, media.kind == ELVMediaRef.image {
            row.addArrangedSubview(makeLeadingAligned(makeThumbnail(media: media, loader: imageLoader)))
        }
        if let provenance {
            row.addArrangedSubview(makeLeadingAligned(makeProvenanceChip(provenance.origin)))
        }

        var accessibilityParts = ["\(key): \(valueString)"]
        if let provenance { accessibilityParts.append(provenance.origin) }
        row.isAccessibilityElement = true
        row.accessibilityLabel = accessibilityParts.joined(separator: ", ")
        row.accessibilityTraits = .staticText
        return row
    }

    private func applyFieldLayout() {
        let inline = Self.usesInlineFields(traitCollection)
        for pair in fieldPairs {
            pair.setInline(inline)
        }
    }

    /// The thumbnail box for `.media` image fields; the loaded image
    /// aspect-fits inside, letterboxed against the secondary background.
    /// Public so hosts can derive their decode budgets from the rendered
    /// side (EluviumExample's RecordImageLoader sizes its pixel ceiling off
    /// this) instead of a silently-coupled magic number.
    public static let thumbnailSide: CGFloat = 160

    /// A square placeholder that fills in asynchronously through the host's
    /// injected loader. The load task is cancelled on reconfigure, so a slow
    /// image can't land on a rebuilt card; a failed load simply leaves the
    /// placeholder (the URL text above the thumbnail already names the
    /// image). Decorative for VoiceOver: the row's combined label reads.
    private func makeThumbnail(media: ELVMediaRef, loader: @escaping (ELVMediaRef) async -> UIImage?) -> UIView {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = LMKCornerRadius.small
        imageView.backgroundColor = LMKColor.backgroundSecondary
        imageView.snp.makeConstraints { make in
            make.size.equalTo(Self.thumbnailSide)
        }
        let task = Task { [weak imageView] in
            let image = await loader(media)
            guard !Task.isCancelled, let imageView, let image else { return }
            imageView.image = image
            imageView.backgroundColor = .clear
        }
        imageLoadTasks.append(task)
        return imageView
    }

    /// Display-only chip, quieter than the value it annotates through the
    /// outline style; `textSecondary` keeps its text readable (tertiary sat
    /// near 2:1).
    private func makeProvenanceChip(_ origin: String) -> LMKChipView {
        LMKChipView(text: origin, style: .outlined.tint(LMKColor.textSecondary))
    }

    /// Pins a self-sizing view (the chip) to the leading edge so the
    /// fill-aligned row doesn't stretch it full width.
    private func makeLeadingAligned(_ view: UIView) -> UIView {
        let wrapper = UIView()
        wrapper.addSubview(view)
        view.snp.makeConstraints { make in
            make.top.bottom.leading.equalToSuperview()
            make.trailing.lessThanOrEqualToSuperview()
        }
        return wrapper
    }
}

/// One field's key and value labels in a stack that switches between
/// stacked (key over value) and inline (key beside value, the key capped at
/// a share of the row so a long key wraps instead of crowding the value).
@MainActor
private final class FieldPair {
    let stack = UIStackView()
    private let key: UILabel
    private var keyWidthCap: Constraint?

    /// The most of the row an inline key may take.
    private static let inlineKeyShare: CGFloat = 0.4

    init(key: UILabel, value: UILabel) {
        self.key = key
        stack.addArrangedSubview(key)
        stack.addArrangedSubview(value)
        value.setContentHuggingPriority(.defaultLow, for: .horizontal)
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        key.snp.makeConstraints { make in
            keyWidthCap = make.width.lessThanOrEqualTo(stack).multipliedBy(Self.inlineKeyShare).constraint
        }
        setInline(false)
    }

    func setInline(_ inline: Bool) {
        stack.axis = inline ? .horizontal : .vertical
        stack.alignment = inline ? .firstBaseline : .fill
        stack.spacing = inline ? LMKSpacing.small : LMKSpacing.xxs
        key.setContentHuggingPriority(inline ? .required : .defaultLow, for: .horizontal)
        if inline {
            keyWidthCap?.activate()
        } else {
            keyWidthCap?.deactivate()
        }
    }
}
