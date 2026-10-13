import EluviumCore
import LumiKitUI
import SnapKit
import UIKit

/// The pack's example corpus as a full-page tap-to-run browser: one
/// section per catalog family, each row one example link under its
/// provider (`ExampleCorpus`). Tapping a
/// row resolves it through the live pipeline right here, with the result in
/// a panel at the bottom of the page (beside the list on regular width), so
/// the corpus and what each parser produces stay visible together.
final class ExamplesViewController: UIViewController {
    // MARK: - Types

    /// How a tapped example's result presents: the results panel at the
    /// bottom of this page, or a pushed record page.
    private enum ResultsPresentation: String {
        case panel
        case page
    }

    // MARK: - Properties

    /// Sticky across launches: a per-viewer convenience, not record state.
    private var resultsPresentation: ResultsPresentation {
        didSet {
            UserDefaults.standard.set(resultsPresentation.rawValue, forKey: Self.presentationKey)
            refreshPresentationToggle()
            applyPanelLayout()
        }
    }

    /// Populated once the store's background pack load lands; empty before.
    private var sections: [ExampleCorpus.Section] = []
    /// Internal so tests can await the corpus load deterministically.
    private(set) var packLoadTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?

    private lazy var navigationBar: LMKNavigationBar = {
        let bar = LMKNavigationBar()
        bar.title = "Examples"
        bar.showsBackButton = true
        return bar
    }()

    private lazy var tableView = LMKListTable.makeInsetGrouped(dataSource: self, delegate: self)

    private lazy var loadingView = LMKLoadingStateView()

    private lazy var emptyStateView: LMKEmptyStateView = {
        let view = LMKEmptyStateView()
        view.configure(LMKEmptyStateView.Content(message: "The loaded pack ships no example links.", icon: .system("doc.text.magnifyingglass")))
        return view
    }()

    /// Separates the list from the results panel; its orientation follows
    /// the layout (a rule under the list, a rule beside it).
    private lazy var panelDivider = LMKDividerView()

    private lazy var resultsScrollView: UIScrollView = {
        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        scrollView.contentInsetAdjustmentBehavior = .automatic
        return scrollView
    }()

    private lazy var resultsStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = LMKSpacing.medium
        stack.isLayoutMarginsRelativeArrangement = true
        // Horizontal insets come from the readable-width pinning in
        // `setupLayout`; only the vertical breathing room lives here.
        stack.layoutMargins = UIEdgeInsets(top: LMKSpacing.medium, left: 0, bottom: LMKSpacing.large, right: 0)
        return stack
    }()

    /// Status line, record card, and record actions: the shared panel. The
    /// status starts visible with the tap prompt.
    private lazy var recordPanel: RecordPanelView = {
        let panel = RecordPanelView()
        panel.status.show("Tap an example to run it through the live pipeline.", status: .neutral)
        panel.onBrowse = { [weak self] record, name in
            self?.pushItems(of: record, collection: name)
        }
        panel.onEpisodes = { [weak self] feed in
            self?.pushItems(of: feed, collection: "items")
        }
        return panel
    }()

    // MARK: - Constants

    /// Share of the page the results panel takes in the stacked
    /// (compact-width) layout.
    private static let resultsPanelHeightRatio: CGFloat = 0.42
    /// Share of the width the example list keeps in the side-by-side
    /// (regular-width) layout.
    private static let regularListWidthRatio: CGFloat = 0.55
    private static let presentationKey = "examples.resultsPresentation"

    // MARK: - Init

    init() {
        resultsPresentation = ResultsPresentation(rawValue: UserDefaults.standard.string(forKey: Self.presentationKey) ?? "") ?? .panel
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LMKColor.backgroundPrimary
        setupLayout()
        refreshPresentationToggle()
        tableView.backgroundView = loadingView
        loadingView.startLoading(message: "Loading the starter pack…")
        packLoadTask = Task { [weak self] in
            await ExampleStore.shared.ready()
            guard let self, !Task.isCancelled else { return }
            sections = ExampleCorpus.sections(from: ExampleStore.shared.allSources)
            loadingView.stopLoading()
            tableView.backgroundView = sections.isEmpty ? emptyStateView : nil
            tableView.reloadData()
        }
    }

    deinit {
        runTask?.cancel()
        packLoadTask?.cancel()
    }

    // MARK: - Setup

    private func setupLayout() {
        view.addSubview(navigationBar)
        navigationBar.install(in: view)
        view.addSubview(tableView)
        view.addSubview(panelDivider)
        view.addSubview(resultsScrollView)
        resultsScrollView.addSubview(resultsStack)

        applyPanelLayout()
        // Vertical edges size the scroll content; horizontal edges follow
        // the panel's readable guide, like the Paste and record screens.
        resultsStack.snp.makeConstraints { make in
            make.top.bottom.equalToSuperview()
            make.leading.trailing.equalTo(resultsScrollView.readableContentGuide)
        }

        resultsStack.addArrangedSubview(recordPanel)

        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (self: Self, _: UITraitCollection) in
            self.applyPanelLayout()
        }
    }

    /// The nav-bar toggle shows the mode a tap switches TO, so the icon
    /// reads as an action, with the accessibility label spelling it out.
    /// Whether the list and the results panel sit side by side (panel mode
    /// in regular width): there the tapped row stays selected while its
    /// result shows; stacked or paged, the selection clears on tap.
    private var showsResultBesideList: Bool {
        resultsPresentation == .panel && traitCollection.horizontalSizeClass == .regular
    }

    private func refreshPresentationToggle() {
        let item: LMKNavigationBarItem = switch resultsPresentation {
        case .panel:
            .init(systemName: "rectangle.portrait.and.arrow.right", accessibilityLabel: "Open results on a separate page") { [weak self] in
                self?.togglePresentation()
            }
        case .page:
            .init(systemName: "rectangle.bottomhalf.inset.filled", accessibilityLabel: "Show results in the bottom panel") { [weak self] in
                self?.togglePresentation()
            }
        }
        navigationBar.setRightItems([item])
    }

    private func togglePresentation() {
        resultsPresentation = resultsPresentation == .panel ? .page : .panel
    }

    /// Stacked list-over-panel in compact width; list beside panel in
    /// regular width so iPad landscape doesn't waste a 1024pt-wide panel.
    /// In page mode the panel leaves entirely: the list takes the full
    /// height and results open as pushed record pages.
    private func applyPanelLayout() {
        if !showsResultBesideList, let selected = tableView.indexPathForSelectedRow {
            tableView.deselectRow(at: selected, animated: false)
        }
        let showsPanel = resultsPresentation == .panel
        panelDivider.isHidden = !showsPanel
        resultsScrollView.isHidden = !showsPanel
        // Clear all three views before installing the new set: the layout
        // engine solves at constraint-ADD time, so per-view remakes create
        // infeasible intermediates (a page-mode table bottom against the
        // still-installed panel constraints) and UIKit "recovers by
        // breaking" one per toggle or rotation. The corpus log caught it.
        for pinned in [tableView, panelDivider, resultsScrollView] {
            pinned.snp.removeConstraints()
        }
        guard showsPanel else {
            tableView.snp.makeConstraints { make in
                make.top.equalTo(navigationBar.snp.bottom)
                make.leading.trailing.bottom.equalToSuperview()
            }
            // Parked below the view, at panel size: a zero height would
            // fight the scroll view's own readable-guide margins (~50pt).
            panelDivider.orientation = .horizontal
            panelDivider.snp.makeConstraints { make in
                make.top.equalTo(view.snp.bottom)
                make.leading.trailing.equalToSuperview()
                make.height.equalTo(panelDivider.resolvedThickness)
            }
            resultsScrollView.snp.makeConstraints { make in
                make.top.equalTo(panelDivider.snp.bottom)
                make.leading.trailing.equalToSuperview()
                make.height.equalTo(view).multipliedBy(Self.resultsPanelHeightRatio)
            }
            return
        }
        if traitCollection.horizontalSizeClass == .regular {
            tableView.snp.makeConstraints { make in
                make.top.equalTo(navigationBar.snp.bottom)
                make.leading.bottom.equalToSuperview()
                make.width.equalToSuperview().multipliedBy(Self.regularListWidthRatio)
            }
            panelDivider.orientation = .vertical
            panelDivider.snp.makeConstraints { make in
                make.top.equalTo(navigationBar.snp.bottom)
                make.leading.equalTo(tableView.snp.trailing)
                make.bottom.equalToSuperview()
                make.width.equalTo(panelDivider.resolvedThickness)
            }
            resultsScrollView.snp.makeConstraints { make in
                make.top.equalTo(navigationBar.snp.bottom)
                make.leading.equalTo(panelDivider.snp.trailing)
                make.trailing.bottom.equalToSuperview()
            }
        } else {
            tableView.snp.makeConstraints { make in
                make.top.equalTo(navigationBar.snp.bottom)
                make.leading.trailing.equalToSuperview()
            }
            panelDivider.orientation = .horizontal
            panelDivider.snp.makeConstraints { make in
                make.top.equalTo(tableView.snp.bottom)
                make.leading.trailing.equalToSuperview()
                make.height.equalTo(panelDivider.resolvedThickness)
            }
            resultsScrollView.snp.makeConstraints { make in
                make.top.equalTo(panelDivider.snp.bottom)
                make.leading.trailing.bottom.equalToSuperview()
                make.height.equalTo(view).multipliedBy(Self.resultsPanelHeightRatio)
            }
        }
    }

    // MARK: - Actions

    private func run(_ example: ELVExample) {
        guard let url = URL(string: example.input) else {
            // The corpus is pack data: a malformed example is a pack bug and
            // must read as one, not as a dead tap.
            let message = "\(example.input)\nThat example is not a valid URL, so it cannot run."
            if resultsPresentation == .panel {
                recordPanel.status.showOutcome(message, status: .warning)
            } else {
                LMKErrorHandler.present(from: self, message: message, severity: .warning)
            }
            return
        }
        if resultsPresentation == .page {
            // The pushed page runs the resolve itself and carries the
            // example through, so the corpus verdict still logs and shows.
            navigationController?.pushViewController(
                RecordCardViewController(url: url, example: example),
                animated: LMKAnimation.shouldAnimate
            )
            return
        }
        runTask?.cancel()
        // Clear the previous record before running, so a failed run can't
        // leave stale browse affordances live.
        recordPanel.clear()
        resultsScrollView.setContentOffset(.zero, animated: false)
        runTask = ResolveFlow.run(.url(url, example: example), status: recordPanel.status, messagePrefix: url.absoluteString, onRecord: { [weak self] record in
            guard let self else { return }
            // The corpus's declared expectations, asserted at run time right
            // where the row surfaces them, via the same check the log line
            // records (kind must match, expected fields must be non-empty).
            let unmet = example.unmetExpectations(for: record)
            if unmet.isEmpty {
                recordPanel.status.show(url.absoluteString, status: .neutral)
            } else {
                recordPanel.status.showOutcome("\(url.absoluteString)\nExpectations unmet: \(unmet.joined(separator: "; ")).", status: .warning)
            }
            recordPanel.present(record)
        })
    }
}

// MARK: - UITableViewDataSource

extension ExamplesViewController: UITableViewDataSource {
    func numberOfSections(in _: UITableView) -> Int {
        sections.count
    }

    func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: LMKListTable.cellReuseIdentifier, for: indexPath)
        let row = sections[indexPath.section].rows[indexPath.row]
        let example = row.example
        var expectations: [String] = []
        if let kind = example.expectedKind { expectations.append("kind \(kind)") }
        expectations.append(contentsOf: example.expectedNonEmpty)
        expectations.append(contentsOf: example.expectedNonEmptyCollections.map { "collection \($0)" })
        // Every row runs: the system highlight and the pointer hover stay on.
        cell.lmk_applyListRow(
            LMKListRowConfiguration(
                title: "\(row.provider)\(Separator.dot)\(row.kind)",
                subtitle: ([example.input] + (expectations.isEmpty ? [] : ["expects \(expectations.joined(separator: ", "))"]))
                    .joined(separator: "\n"),
                trailing: .none,
                style: LMKListRowConfiguration.Style(subtitleTextStyle: .caption, titleLines: 1, subtitleLines: 4)
            ),
            backgroundColor: LMKColor.backgroundSecondary
        )
        return cell
    }
}

// MARK: - UITableViewDelegate

extension ExamplesViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        // Side by side, the selection marks whose result the panel shows.
        if !showsResultBesideList {
            tableView.deselectRow(at: indexPath, animated: LMKAnimation.shouldAnimate)
        }
        guard let example = example(at: indexPath) else { return }
        run(example)
    }

    /// Copy an example's link, or open its result as a page whatever the
    /// presentation toggle says.
    func tableView(_: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point _: CGPoint) -> UIContextMenuConfiguration? {
        guard let example = example(at: indexPath) else { return nil }
        let url = URL(string: example.input)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var actions: [UIMenuElement] = [
                UIAction(title: "Copy URL", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = example.input
                },
            ]
            if let url {
                actions.append(UIAction(title: "Open as Page", image: UIImage(systemName: "rectangle.portrait.and.arrow.right")) { _ in
                    self?.navigationController?.pushViewController(RecordCardViewController(url: url, example: example), animated: LMKAnimation.shouldAnimate)
                })
            }
            return UIMenu(children: actions)
        }
    }

    private func example(at indexPath: IndexPath) -> ELVExample? {
        guard sections.indices.contains(indexPath.section), sections[indexPath.section].rows.indices.contains(indexPath.row) else { return nil }
        return sections[indexPath.section].rows[indexPath.row].example
    }
}
