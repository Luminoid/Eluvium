import EluviumCore
import LumiKitUI
import SnapKit
import UIKit

/// Screen ⑤, the identity showcase. Movies: three source lists whose
/// shared films collapse to one entity via declared + crosswalk ids, with
/// each source list still intact. Places: `entity.placeMatch` suggestions
/// with confidence, confirm/reject (and undo), and a veto that survives
/// re-import, plus the `geo.anchorLadder@1` trust ladder over canned
/// coordinates. The canned corpus and the index readings live in
/// `IdentityShowcase`, shared with the app tests.
final class IdentityViewController: UIViewController {
    // MARK: - Types

    private enum Mode: Int { case movies, places }

    // MARK: - Properties

    /// The user's answers, by pair. The index is rebuilt from these (plus
    /// the fixtures and the pack's strong namespaces) on every change, so
    /// undo is dropping an entry.
    private var decisions: [ELVRecordPair: IdentityShowcase.LinkDecision] = [:]
    /// The loaded pack's strong-namespace vocabulary, empty until the
    /// store's background load lands.
    private var strongNamespaces: Set<String> = []
    private var index = ELVEntityIndex()
    private var samplesByKey: [ELVRecordKey: IdentityShowcase.Sample] = [:]
    private var placeSuggestions: [IdentityShowcase.PlacePair] = []
    private var mode: Mode = .movies
    private var loadTask: Task<Void, Never>?

    /// Derived once per mutation, never per data-source callback:
    /// `index.entities()` is a full union-find rebuild, far too heavy for
    /// numberOfSections / per-cell configure to call repeatedly.
    private var movieEntities: [ELVEntity] = []
    /// Link state per `placeSuggestions` element, same index order.
    private var placeLinkStates: [IdentityShowcase.LinkState] = []
    /// Verdict per `AnchorLadderDemo.cases` element, same index order,
    /// resolved once through the native-op registry at load.
    private var anchorVerdicts: [String] = []

    // MARK: - UI

    private lazy var segmented: LMKSegmentedControl = {
        let control = LMKSegmentedControl(items: ["Movies", "Places"])
        control.selectedSegmentIndex = 0
        control.onValueChange = { [weak self] index in self?.modeChanged(to: index) }
        return control
    }()

    private lazy var captionLabel = UILabel.lmk_make(.caption, color: LMKColor.textSecondary)

    /// The mode switch and caption ride the table, so a long caption at
    /// accessibility text sizes scrolls away instead of covering the rows.
    private lazy var tableHeader = ListHeaderScaffold.makeTableHeader(ListHeaderScaffold.makeHeaderStack([segmented, captionLabel], spacing: LMKSpacing.small))

    private lazy var tableView: UITableView = {
        let table = LMKListTable.makeInsetGrouped(dataSource: self, delegate: self)
        table.registerStaticRows()
        return table
    }()

    private lazy var navigationBar: LMKNavigationBar = {
        let bar = LMKNavigationBar()
        bar.title = "Identity"
        return bar
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LMKColor.backgroundPrimary
        buildShowcases()
        rebuildDerivedState()
        setupLayout()
        refreshCaption()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _: UITraitCollection) in
            self.view.setNeedsLayout()
        }
        // The pack's strong namespaces arrive with the background pack load;
        // the fixtures render right away and re-derive once they land.
        loadTask = Task { [weak self] in
            await ExampleStore.shared.ready()
            guard let self, !Task.isCancelled else { return }
            strongNamespaces = ExampleStore.shared.loadedPack.strongNamespaces
            rebuildDerivedState()
            tableView.reloadData()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tableView.setFittedHeaderView(tableHeader)
    }

    deinit {
        loadTask?.cancel()
    }

    // MARK: - Setup

    private func setupLayout() {
        view.addSubview(navigationBar)
        navigationBar.install(in: view)
        view.addSubview(tableView)
        tableView.snp.makeConstraints { make in
            make.top.equalTo(navigationBar.snp.bottom)
            make.leading.trailing.bottom.equalToSuperview()
        }
    }

    /// Indexes the shared canned corpus and resolves the op-backed
    /// showcases. Op registration (entity.placeMatch, geo.anchorLadder)
    /// lives in the store's init, so touch it before the first lookup.
    private func buildShowcases() {
        _ = ExampleStore.shared
        for sample in IdentityShowcase.allSamples {
            samplesByKey[sample.key] = sample
        }
        placeSuggestions = IdentityShowcase.placePairs()
        anchorVerdicts = AnchorLadderDemo.cases.map(AnchorLadderDemo.verdict(for:))
    }

    // MARK: - Actions

    private func modeChanged(to selectedIndex: Int) {
        mode = Mode(rawValue: selectedIndex) ?? .movies
        refreshCaption()
        tableView.reloadData()
    }

    private func decide(_ pair: IdentityShowcase.PlacePair, _ decision: IdentityShowcase.LinkDecision?) {
        decisions[pair.recordPair] = decision
        rebuildDerivedState()
        tableView.reloadData()
    }

    @objc private func confirmFirstSuggestion() {
        guard mode == .places, let pair = IdentityShowcase.firstPending(placeSuggestions, in: index) else { return }
        decide(pair, .confirmed)
    }

    @objc private func rejectFirstSuggestion() {
        guard mode == .places, let pair = IdentityShowcase.firstPending(placeSuggestions, in: index) else { return }
        decide(pair, .rejected)
    }

    /// The menu bar's ⌘↩ on iPad and Mac, while this screen is in front:
    /// the screen's primary action, so it confirms (and the item reads so).
    @objc func resolveFromMenu(_: Any?) {
        confirmFirstSuggestion()
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(resolveFromMenu(_:)) {
            return mode == .places && IdentityShowcase.firstPending(placeSuggestions, in: index) != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func validate(_ command: UICommand) {
        super.validate(command)
        if command.action == #selector(resolveFromMenu(_:)) {
            command.title = "Confirm First Suggestion"
        }
    }

    // MARK: - UI Updates

    private func refreshCaption() {
        let caption = switch mode {
        case .movies: "Three source lists (Douban, an IMDb export, and a Wikipedia list) with shared films collapsed to one entity via declared + Wikidata-crosswalk ids. No heuristics."
        case .places: "Michelin favorites vs Swarm check-ins share no id namespace. entity.placeMatch scores each pair; you confirm or reject. A rejection persists. "
            + "Below: geo.anchorLadder decides which coordinate may pin a place."
        }
        captionLabel.lmk_setText(caption)
        view.setNeedsLayout()
    }

    /// Rebuilds the index from the fixtures and decisions, then the entity
    /// view and per-pair link states; the table data source only ever reads
    /// the stored results.
    private func rebuildDerivedState() {
        index = IdentityShowcase.makeIndex(strongNamespaces: strongNamespaces, decisions: decisions)
        movieEntities = index.entities().filter { entity in
            entity.members.contains { samplesByKey[$0]?.place == nil }
        }
        placeLinkStates = placeSuggestions.map { IdentityShowcase.linkState(of: $0, in: index) }
    }

    // MARK: - Helpers

    private func placeName(of pair: IdentityShowcase.PlacePair) -> String {
        samplesByKey[pair.michelin]?.title ?? "this place"
    }

    // MARK: - Key Commands

    override var keyCommands: [UIKeyCommand]? {
        // ⌘↩ is the menu bar's on iPad and Mac (it routes to
        // `resolveFromMenu(_:)` here), so only iPhone registers it.
        var commands = [UIKeyCommand(title: "Reject First Suggestion", action: #selector(rejectFirstSuggestion), input: "\u{8}", modifierFlags: .command)]
        if traitCollection.userInterfaceIdiom == .phone {
            commands.insert(UIKeyCommand(title: "Confirm First Suggestion", action: #selector(confirmFirstSuggestion), input: "\r", modifierFlags: .command), at: 0)
        }
        return commands
    }
}

// MARK: - UITableViewDataSource

extension IdentityViewController: UITableViewDataSource {
    func numberOfSections(in _: UITableView) -> Int {
        switch mode {
        case .movies: movieEntities.count
        case .places: placeSuggestions.count + 1 // trailing anchor-ladder demo
        }
    }

    func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch mode {
        case .movies:
            guard movieEntities.indices.contains(section) else { return nil }
            let entity = movieEntities[section]
            let anchor = entity.members.compactMap { samplesByKey[$0]?.title }.first
            return entity.members.count > 1 ? "\(anchor ?? "Film"): one entity, \(entity.members.count) sources" : anchor
        case .places:
            guard section < placeSuggestions.count else { return "geo.anchorLadder: which coordinate may pin" }
            return "\(placeName(of: placeSuggestions[section]))\(Separator.dot)\(placeLinkStates[section].label)"
        }
    }

    func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch mode {
        case .movies: movieEntities.indices.contains(section) ? movieEntities[section].members.count : 0
        case .places: section < placeSuggestions.count ? 3 : AnchorLadderDemo.cases.count // michelin row, swarm row, action row
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // Only a pending suggestion's action row is tappable; every other
        // row comes from the static pool, so no recycled hover rides along.
        let identifier = isPendingActionRow(indexPath) ? LMKListTable.cellReuseIdentifier : UITableView.staticRowReuseIdentifier
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier, for: indexPath)
        cell.backgroundColor = LMKColor.backgroundSecondary
        cell.selectionStyle = .none
        cell.accessoryView = nil

        switch mode {
        case .movies:
            configureMovieCell(cell, at: indexPath)
        case .places:
            configurePlaceCell(cell, at: indexPath)
        }
        return cell
    }

    private func isPendingActionRow(_ indexPath: IndexPath) -> Bool {
        mode == .places && indexPath.section < placeSuggestions.count && indexPath.row == 2 && !placeLinkStates[indexPath.section].isDecided
    }

    private func configureMovieCell(_ cell: UITableViewCell, at indexPath: IndexPath) {
        let member = movieEntities[indexPath.section].members[indexPath.row]
        guard let sample = samplesByKey[member] else { return }
        var content = cell.defaultContentConfiguration()
        content.text = "\(sample.membership)"
        content.secondaryText = "\(sample.key.sourceId)\(Separator.dot)\(sample.title)"
        content.lmk_applyTextStyle()
        cell.contentConfiguration = content
    }

    private func configurePlaceCell(_ cell: UITableViewCell, at indexPath: IndexPath) {
        guard indexPath.section < placeSuggestions.count else {
            configureAnchorCell(cell, at: indexPath)
            return
        }
        let pair = placeSuggestions[indexPath.section]
        let state = placeLinkStates[indexPath.section]
        var content = cell.defaultContentConfiguration()
        switch indexPath.row {
        case 0:
            let sample = samplesByKey[pair.michelin]
            content.text = sample?.title
            content.secondaryText = sample?.membership
        case 1:
            let sample = samplesByKey[pair.swarm]
            content.text = sample?.title
            content.secondaryText = sample?.membership
        default:
            content.text = state.label
            if state.isDecided {
                // A decided pair offers the way back, not a second answer.
                content.secondaryText = "Undo to decide again"
                cell.accessoryView = makeUndoButton(for: pair)
            } else {
                // The copy names what the row actually does: tap confirms,
                // the ✕ button rejects, and the context menu offers both.
                content.secondaryText = "Tap to confirm; ✕ to reject"
                cell.accessoryView = makeDecisionButtons(for: pair)
                cell.selectionStyle = .default
                cell.lmk_installRowPointerInteraction()
            }
        }
        content.lmk_applyTextStyle()
        cell.contentConfiguration = content
    }

    /// One anchor-ladder case: the canned trust decision plus its verdict,
    /// resolved through the registered `geo.anchorLadder@1` op at load.
    private func configureAnchorCell(_ cell: UITableViewCell, at indexPath: IndexPath) {
        guard indexPath.row < AnchorLadderDemo.cases.count, indexPath.row < anchorVerdicts.count else { return }
        let demoCase = AnchorLadderDemo.cases[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = demoCase.title
        content.secondaryText = "\(anchorVerdicts[indexPath.row]). \(demoCase.detail)"
        content.lmk_applyTextStyle()
        cell.contentConfiguration = content
    }

    private func makeDecisionButtons(for pair: IdentityShowcase.PlacePair) -> UIView {
        let name = placeName(of: pair)
        let confirmButton = LMKButton(systemImage: "checkmark.circle.fill", style: .iconOnly(.success)) { [weak self] in
            self?.decide(pair, .confirmed)
        }
        confirmButton.accessibilityLabel = "Confirm link for \(name)"

        let rejectButton = LMKButton(systemImage: "xmark.circle.fill", style: .iconOnly(.destructive)) { [weak self] in
            self?.decide(pair, .rejected)
        }
        rejectButton.accessibilityLabel = "Reject link for \(name)"
        return AccessoryButtonStack(buttons: [confirmButton, rejectButton])
    }

    private func makeUndoButton(for pair: IdentityShowcase.PlacePair) -> UIView {
        let undoButton = LMKButton(systemImage: "arrow.uturn.backward.circle", style: .iconOnly(.primary)) { [weak self] in
            self?.decide(pair, nil)
        }
        undoButton.accessibilityLabel = "Undo decision for \(placeName(of: pair))"
        return AccessoryButtonStack(buttons: [undoButton])
    }
}

// MARK: - UITableViewDelegate

extension IdentityViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: LMKAnimation.shouldAnimate)
        guard isPendingActionRow(indexPath) else { return }
        decide(placeSuggestions[indexPath.section], .confirmed)
    }

    /// Confirm or reject a pending suggestion (undo a decided one) from any
    /// row of its section.
    func tableView(_: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point _: CGPoint) -> UIContextMenuConfiguration? {
        guard mode == .places, placeSuggestions.indices.contains(indexPath.section) else { return nil }
        let pair = placeSuggestions[indexPath.section]
        let name = placeName(of: pair)
        let actions: [UIMenuElement] = if placeLinkStates[indexPath.section].isDecided {
            [UIAction(title: "Undo Decision", image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in self?.decide(pair, nil) }]
        } else {
            [
                UIAction(title: "Confirm Link", image: UIImage(systemName: "checkmark.circle")) { [weak self] _ in self?.decide(pair, .confirmed) },
                UIAction(title: "Reject Link", image: UIImage(systemName: "xmark.circle"), attributes: .destructive) { [weak self] _ in self?.decide(pair, .rejected) },
            ]
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(title: name, children: actions)
        }
    }
}
