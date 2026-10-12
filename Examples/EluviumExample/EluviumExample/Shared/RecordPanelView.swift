import EluviumCore
import EluviumUI
import LumiKitUI
import SnapKit
import UIKit

/// The record panel every record-presenting screen shows (Paste, the
/// examples browser, the pushed record page): the status line a resolve
/// writes to, the framework's record card, and the shared record actions,
/// stacked. Hosts hand it a record with `present(_:)`, empty it with
/// `clear()`, and wire two navigations: a tapped collection and the
/// resolved episode feed. Keeping the card wiring here means the image
/// loader and the collection tap can't drift between the three screens.
final class RecordPanelView: UIView {
    // MARK: - Properties

    /// A collection was tapped on the card: the presented record and the
    /// collection's name. Hosts push the item browser.
    var onBrowse: ((ELVRecord, String) -> Void)?

    /// "Load episodes" resolved the show's feed; hosts push its items.
    var onEpisodes: ((ELVRecord) -> Void)?

    /// The record behind the visible card, nil while empty.
    private(set) var record: ELVRecord?

    /// The inline status line: `ResolveFlow` writes stage lines and failure
    /// copy here, hosts seed or clear it as their flow needs. Hidden until
    /// the first `show`.
    let status = LMKStatusLabel()

    private lazy var card: ELVRecordCardView = {
        let card = ELVRecordCardView()
        // Image bytes go through the app's own loader; the framework card
        // never fetches (the pipeline's egress policy is not a UI concern).
        card.imageLoader = { await RecordImageLoader.image(for: $0) }
        card.collectionTapHandler = { [weak self] name, _ in
            guard let self, let record else { return }
            onBrowse?(record, name)
        }
        card.isHidden = true
        return card
    }()

    private lazy var actions: RecordActionsView = {
        let view = RecordActionsView()
        view.statusLabel = status
        view.onEpisodes = { [weak self] feed in
            self?.onEpisodes?(feed)
        }
        return view
    }()

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        let stack = UIStackView(arrangedSubviews: [status, card, actions])
        stack.axis = .vertical
        stack.spacing = LMKSpacing.medium
        addSubview(stack)
        stack.snp.makeConstraints { $0.edges.equalToSuperview() }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UI Updates

    /// Shows `record` on the card with its supported actions.
    func present(_ record: ELVRecord) {
        self.record = record
        card.configure(with: record)
        card.isHidden = false
        actions.configure(with: record)
    }

    /// Empties the panel. Called before every resolve so a failed run can
    /// never leave the previous record's browse affordances live.
    func clear() {
        record = nil
        card.isHidden = true
        actions.configure(with: nil)
    }
}
