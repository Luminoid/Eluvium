import EluviumCore
import EluviumNet
import LumiKitUI
import SnapKit
import UIKit

/// The item browser: one screen for every record collection — feed
/// posts, podcast episodes, album tracks, and list entries. A show/list
/// header over windowed rows ("load more" reveals in pages, then chases the
/// record's `nextPage` feed pointer when one exists), with playback
/// accessories on audio rows and drill-through on the rest.
final class FeedItemsViewController: UIViewController {
    // MARK: - Properties

    /// `parentRecord`, not `parent`: UIViewController owns that name.
    private let parentRecord: ELVRecord
    private let collectionName: String
    private var items: [ELVRecord]
    private var window: RecordWindow
    /// The next feed page to chase once the window is exhausted, with a
    /// seen-URL set as the loop guard (a feed pointing at itself must not
    /// fetch forever).
    private var nextPageURL: URL?
    private var seenPageURLs: Set<URL> = []
    private var loadTask: Task<Void, Never>?
    /// The last playing URL applied to visible play accessories, so the
    /// half-second player ticks don't reconfigure cells for no change.
    private var accessoryPlayingURL: URL?
    /// The footer the table shows (load more, the cap note, or none);
    /// installed and re-fitted by `layoutTableChrome()`.
    private var footer: UIView?

    // MARK: - UI

    private lazy var navigationBar: LMKNavigationBar = {
        let bar = LMKNavigationBar()
        bar.title = parentRecord.displayTitle ?? collectionName.capitalized
        bar.showsBackButton = true
        return bar
    }()

    private lazy var headerLabel: UILabel = {
        let label = UILabel.lmk_make(.caption, text: headerText(), color: LMKColor.textSecondary)
        label.isHidden = label.text?.isEmpty != false
        return label
    }()

    private let statusLabel = LMKStatusLabel()

    /// The show/list header rides the table so it scrolls away with the
    /// rows instead of pinning a long summary over them.
    private lazy var tableHeader = ListHeaderScaffold.makeTableHeader(
        ListHeaderScaffold.makeHeaderStack([headerLabel, statusLabel], spacing: LMKSpacing.small, bottomMargin: LMKSpacing.small)
    )

    private lazy var tableView: UITableView = {
        let table = LMKListTable.makeInsetGrouped(dataSource: self, delegate: self)
        table.registerStaticRows()
        return table
    }()

    private lazy var emptyStateView: LMKEmptyStateView = {
        let view = LMKEmptyStateView()
        view.configure(LMKEmptyStateView.Content(message: "Nothing in this collection.", icon: .system("list.bullet")))
        return view
    }()

    private lazy var loadMoreButton = LMKButton(title: "Load more", style: .outlined(.primary), target: self, action: #selector(loadMoreTapped))

    /// Sized by fitting, never a fixed frame: the button's title wraps and
    /// grows with Dynamic Type, and the readable-width bounds keep a long
    /// title off the screen edges.
    private lazy var loadMoreFooter: UIView = {
        let container = UIView()
        container.addSubview(loadMoreButton)
        loadMoreButton.snp.makeConstraints { make in
            make.top.equalToSuperview().inset(LMKSpacing.large)
            make.bottom.equalToSuperview().inset(LMKSpacing.large).priority(999)
            make.centerX.equalTo(container.lmk_readableWidthGuide)
            make.leading.greaterThanOrEqualTo(container.lmk_readableWidthGuide)
            make.trailing.lessThanOrEqualTo(container.lmk_readableWidthGuide)
        }
        return container
    }()

    private lazy var capNoteLabel: UILabel = {
        let label = UILabel.lmk_make(.caption, color: LMKColor.textSecondary)
        label.textAlignment = .center
        return label
    }()

    private lazy var capNoteFooter: UIView = {
        let container = UIView()
        container.addSubview(capNoteLabel)
        capNoteLabel.snp.makeConstraints { make in
            make.top.equalToSuperview().inset(LMKSpacing.small)
            make.bottom.equalToSuperview().inset(LMKSpacing.small).priority(999)
            make.leading.trailing.equalTo(container.lmk_readableWidthGuide)
        }
        return container
    }()

    private lazy var playerBar = AudioPlayerBar()

    // MARK: - Init

    init(parent: ELVRecord, collectionName: String, items: [ELVRecord]) {
        parentRecord = parent
        self.collectionName = collectionName
        self.items = items
        window = RecordWindow(total: items.count)
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
        // A record with no feed continuation but a `feedUrl` (a podcast
        // show shipping a truncated embedded episode list) still has more
        // to load: chasing the full feed is the show's "next page".
        nextPageURL = RecordBrowsing.nextPage(of: parent) ?? RecordBrowsing.feedURL(of: parent)
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
        refreshFooter()
        refreshEmptyState()
        // Visible play accessories flip to Pause for the playing row.
        NotificationCenter.default.addObserver(self, selector: #selector(audioStateChanged), name: AppNotification.audioStateChanged, object: nil)
        // A text-size change resizes the header and footer content without
        // laying out this view, so ask for the pass that re-fits them.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _: UITraitCollection) in
            self.view.setNeedsLayout()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutTableChrome()
    }

    deinit {
        loadTask?.cancel()
    }

    // MARK: - Setup

    private func setupLayout() {
        view.addSubview(navigationBar)
        navigationBar.install(in: view)
        view.addSubview(tableView)
        view.addSubview(playerBar)
        tableView.snp.makeConstraints { make in
            make.top.equalTo(navigationBar.snp.bottom)
            make.leading.trailing.equalToSuperview()
        }
        // The bar collapses to zero height while nothing plays, so no
        // bottom inset here: collapsed means the table reaches the safe area.
        // Full screen width with padding, not readable width: a playback
        // bar is chrome, and the readable measure strands it in the middle
        // of an iPad screen.
        playerBar.snp.makeConstraints { make in
            make.top.equalTo(tableView.snp.bottom)
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(LMKSpacing.large)
            make.bottom.equalTo(view.safeAreaLayoutGuide)
        }
    }

    private func headerText() -> String? {
        var parts: [String] = []
        if case let .text(author)? = parentRecord.fields["author"] { parts.append(author) }
        if let count = episodeCount() { parts.append("\(count) episodes") }
        if case let .text(summary)? = parentRecord.fields["summary"] { parts.append(RecordBrowsing.snippet(summary, limit: 160)) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// The parent's declared episode total, nil when absent or not a
    /// displayable integer (a hostile `1e300` must not trap `Int(_:)`).
    private func episodeCount() -> Int? {
        guard case let .number(count)? = parentRecord.fields["episodeCount"] else { return nil }
        return RecordBrowsing.displayInteger(count)
    }

    // MARK: - Actions

    @objc private func loadMoreTapped() {
        if window.hasMore {
            window.revealMore()
            tableView.reloadData()
            refreshFooter()
            return
        }
        fetchNextPage()
    }

    @objc private func playTapped(_ sender: UIButton) {
        let visible = window.visible(of: items)
        guard visible.indices.contains(sender.tag) else { return }
        AudioPlayer.shared.play(item: visible[sender.tag])
    }

    /// Chases the record's `nextPage` pointer as a fresh resolve (full
    /// egress + recognition, logged like any paste), appends the new page's
    /// items, and adopts its own `nextPage`.
    private func fetchNextPage() {
        guard let url = nextPageURL, !seenPageURLs.contains(url) else { return }
        seenPageURLs.insert(url)
        loadTask?.cancel()
        loadMoreButton.isLoading = true
        statusLabel.show("Fetching the next page…", status: .neutral)
        layoutTableChrome()

        loadTask = ResolveFlow.run(.url(url, example: nil), status: statusLabel, showsStages: false, onRecord: { [weak self] record in
            guard let self else { return }
            statusLabel.clear()
            let incoming = record.collections[collectionName] ?? record.collections["items"] ?? []
            // A chased full feed re-ships the episodes the parent embedded:
            // drop rows the list already has so append never duplicates.
            let seen = Set(items.compactMap(RecordBrowsing.dedupKey))
            items.append(contentsOf: incoming.filter { item in RecordBrowsing.dedupKey(item).map { !seen.contains($0) } ?? true })
            window.extend(total: items.count)
            window.revealMore()
            nextPageURL = RecordBrowsing.nextPage(of: record)
            tableView.reloadData()
        }, completion: { [weak self] result in
            guard let self else { return }
            loadMoreButton.isLoading = false
            if case .failed = result {
                // A failed fetch is retryable: un-mark the URL so the button
                // survives a transient network error. Successful fetches stay
                // marked, which is all the self-pointing-feed guard needs.
                seenPageURLs.remove(url)
            }
            refreshFooter()
            refreshEmptyState()
        })
    }

    // MARK: - UI Updates

    private func refreshFooter() {
        let canFetch = nextPageURL.map { !seenPageURLs.contains($0) } ?? false
        if window.hasMore || canFetch {
            let remaining = window.total - window.visible(of: items).count
            let fetchTitle = nextPageURL == RecordBrowsing.feedURL(of: parentRecord) ? "Load more (fetch the full feed)" : "Load more (fetch next page)"
            // `title`, never `setTitle(_:for:)`: LMKButton re-resolves its
            // configuration on every state and appearance pass, and a title
            // set around it reverts to the last `title`.
            loadMoreButton.title = window.hasMore ? "Load more (\(remaining) left)" : fetchTitle
            footer = loadMoreFooter
        } else if let note = capNoteText() {
            capNoteLabel.lmk_setText(note)
            footer = capNoteFooter
        } else {
            footer = nil
        }
        layoutTableChrome()
    }

    /// Installs and re-fits the table's header and footer at the current
    /// width and text size.
    private func layoutTableChrome() {
        tableView.setFittedHeaderView(tableHeader)
        tableView.setFittedFooterView(footer)
    }

    private func refreshEmptyState() {
        tableView.backgroundView = window.visible(of: items).isEmpty ? emptyStateView : nil
    }

    /// The honest end-of-list note: when the parent says more episodes
    /// exist than any public surface ships (Xiaoyuzhou's episode API is
    /// auth-walled past the embedded list), say so instead of just ending.
    private func capNoteText() -> String? {
        guard let count = episodeCount(), count > items.count else { return nil }
        return "Showing the \(items.count) episodes the source's public page ships (of \(count))."
    }

    @objc private func audioStateChanged() {
        let state = AudioPlayer.shared.state
        let playingURL = state.isPlaying ? state.url : nil
        guard playingURL != accessoryPlayingURL else { return }
        accessoryPlayingURL = playingURL
        let visible = window.visible(of: items)
        for cell in tableView.visibleCells {
            guard let indexPath = tableView.indexPath(for: cell),
                  visible.indices.contains(indexPath.row),
                  let button = (cell.accessoryView as? AccessoryButtonStack)?.buttons.first else { continue }
            configurePlayAccessory(button, item: visible[indexPath.row])
        }
    }

    // MARK: - Helpers

    /// Whether a row has something to drill into; rows that don't must not
    /// pretend otherwise (no highlight, no hover, no selection).
    private static func isSelectable(_ item: ELVRecord) -> Bool {
        RecordBrowsing.hasDetailBody(item) || RecordBrowsing.memberURL(of: item) != nil
    }

    /// A fresh accessory per configure: reused cells otherwise keep a stale
    /// row tag (the prepareForReuse lesson). The cell frame-lays the
    /// accessory out, and the themed button carries its own height
    /// constraint, so it rides the stack host that keeps the cell's frame
    /// (`AccessoryButtonStack`); the touch target is the host's frame.
    private func makePlayAccessory(row: Int, item: ELVRecord) -> AccessoryButtonStack {
        let button = LMKButton(systemImage: "play.circle", style: .iconOnly(.primary), target: self, action: #selector(playTapped(_:)))
        button.tag = row
        configurePlayAccessory(button, item: item)
        return AccessoryButtonStack(buttons: [button])
    }

    /// Image and label track the shared player: the playing row's accessory
    /// reads as Pause, every other row as "Play <title>".
    private func configurePlayAccessory(_ button: LMKButton, item: ELVRecord) {
        let title = item.displayTitle
        let isPlayingThisRow = isPlaying(item)
        button.setSymbol(isPlayingThisRow ? "pause.circle" : "play.circle")
        if isPlayingThisRow {
            button.accessibilityLabel = title.map { "Pause \($0)" } ?? "Pause"
        } else {
            button.accessibilityLabel = title.map { "Play \($0)" } ?? "Play"
        }
    }

    private func isPlaying(_ item: ELVRecord) -> Bool {
        accessoryPlayingURL != nil && RecordBrowsing.audioURL(of: item) == accessoryPlayingURL
    }

    // MARK: - Key Commands

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(title: "Load More", action: #selector(loadMoreTapped), input: "l", modifierFlags: .command)]
    }
}

// MARK: - UITableViewDataSource

extension FeedItemsViewController: UITableViewDataSource {
    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        window.visible(of: items).count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = window.visible(of: items)[indexPath.row]
        let selectable = Self.isSelectable(item)
        // Static rows dequeue from their own pool, so a recycled cell never
        // brings a selectable row's pointer hover along.
        let identifier = selectable ? LMKListTable.cellReuseIdentifier : UITableView.staticRowReuseIdentifier
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier, for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = item.displayTitle ?? item.kind
        content.secondaryText = RecordBrowsing.rowSecondary(for: item)
        content.lmk_applyTextStyle(primary: .body)
        content.secondaryTextProperties.numberOfLines = 2
        cell.contentConfiguration = content
        cell.backgroundColor = LMKColor.backgroundSecondary
        cell.selectionStyle = selectable ? .default : .none
        if selectable { cell.lmk_installRowPointerInteraction() }
        cell.accessoryView = RecordBrowsing.audioURL(of: item) != nil ? makePlayAccessory(row: indexPath.row, item: item) : nil
        return cell
    }
}

// MARK: - UITableViewDelegate

extension FeedItemsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: LMKAnimation.shouldAnimate)
        let visible = window.visible(of: items)
        guard visible.indices.contains(indexPath.row) else { return }
        let item = visible[indexPath.row]
        if RecordBrowsing.hasDetailBody(item) {
            navigationController?.pushViewController(FeedItemDetailViewController(item: item), animated: LMKAnimation.shouldAnimate)
        } else if let url = RecordBrowsing.memberURL(of: item) {
            navigationController?.pushViewController(RecordCardViewController(url: url), animated: LMKAnimation.shouldAnimate)
        }
    }

    /// Play (or pause) an episode and copy an item's link without opening it.
    func tableView(_: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point _: CGPoint) -> UIContextMenuConfiguration? {
        let visible = window.visible(of: items)
        guard visible.indices.contains(indexPath.row) else { return nil }
        let item = visible[indexPath.row]
        var actions: [UIMenuElement] = []
        if RecordBrowsing.audioURL(of: item) != nil {
            let playing = isPlaying(item)
            actions.append(UIAction(title: playing ? "Pause" : "Play", image: UIImage(systemName: playing ? "pause" : "play")) { _ in
                AudioPlayer.shared.play(item: item)
            })
        }
        if let link = RecordBrowsing.memberURL(of: item) {
            actions.append(UIAction(title: "Copy Link", image: UIImage(systemName: "link")) { _ in
                UIPasteboard.general.url = link
            })
        }
        guard !actions.isEmpty else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: actions)
        }
    }
}
