import EluviumCore
import EluviumNet
import LumiKitUI
import SnapKit
import UIKit

/// Screen ③: the pack's walkable catalogs (`list` sources) as a
/// config-driven roster — pick one, run its enumeration with visible cursor
/// state and deliberate pause / resume / stop / restart controls — proving
/// the walk resumes — then browse the accumulated items. Exercises enumeration end
/// to end.
final class CatalogsViewController: UIViewController {
    // MARK: - Types

    /// The three table sections, top to bottom: the walkable catalogs, the
    /// seeded browsable lists, then the active walk's accumulated records
    /// (unbounded growth, so it stays last).
    private enum Section: Int, CaseIterable {
        case catalogs
        case lists
        case records
    }

    // MARK: - Properties

    /// The pack's walkable inventory: every source with a `list`
    /// enumeration spec, in pack order. The roster is config — a pack that
    /// ships another catalog surfaces it here with no app change.
    private var catalogSources: [ELVSource] = []
    /// The catalog the walk controls drive, defaulting to the roster's first
    /// entry. Resolved after the store's background pack load lands (never
    /// in a stored-property initializer).
    private var activeCatalog: ELVSource?
    private var state = ELVEnumerationState()
    private var records: [ELVRecord] = []
    /// Persistent externalId dedup set alongside `records`: pages append in
    /// place at O(1) per record instead of re-scanning the whole list on
    /// every merge.
    private var seenIds: Set<String> = []
    private var totalCount: Int?
    private var walkTask: Task<Void, Never>?
    /// Bumped by every reset (restart, catalog switch, memory release), so
    /// a walk that ends after its state was thrown away lands nowhere. Stop
    /// leaves it alone: a stopped walk's partial result still applies, with
    /// its cursor ready to resume.
    private var walkGeneration = 0
    /// Internal so tests can await the roster load deterministically.
    private(set) var loadTask: Task<Void, Never>?
    private var seedTask: Task<Void, Never>?
    private var isRunning = false
    /// The pack's browsable inventory: seeded list sources (award
    /// lists, editorial rankings, an author's books) shown between the
    /// catalog roster and the walked records; tapping one resolves its seed
    /// and browses entries.
    private var seededSources: [ELVSource] = []

    // MARK: - UI

    /// Walk state plus failures, tinted per status like every other screen's
    /// status line.
    private let statusLabel = LMKStatusLabel()

    private lazy var runButton = LMKButton(title: "Run one page", style: .filled(.primary), target: self, action: #selector(runOnePage))
    private lazy var autoButton = LMKButton(title: "Run to end", style: .filled(.primary), target: self, action: #selector(runToEnd))
    /// "Restart" at rest, "Stop" while a walk runs.
    private lazy var resetButton = LMKButton(title: "Restart", style: .outlined(.primary), target: self, action: #selector(restartOrStop))

    /// Side by side normally; stacked at accessibility text sizes, where
    /// three equal columns would truncate every title.
    private lazy var controls: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [runButton, autoButton, resetButton])
        stack.spacing = LMKSpacing.small
        return stack
    }()

    /// Status and controls ride the table, so they scroll with the rows.
    private lazy var tableHeader = ListHeaderScaffold.makeTableHeader(ListHeaderScaffold.makeHeaderStack([statusLabel, controls], spacing: LMKSpacing.medium))

    private lazy var tableView: UITableView = {
        let table = LMKListTable.makeInsetGrouped(dataSource: self, delegate: self)
        table.registerStaticRows()
        return table
    }()

    private lazy var loadingView = LMKLoadingStateView()

    private lazy var emptyStateView: LMKEmptyStateView = {
        let view = LMKEmptyStateView()
        view.configure(LMKEmptyStateView.Content(message: "No pages loaded yet. Run one page to start the catalog walk.", icon: .system("square.stack.3d.up")))
        return view
    }()

    private lazy var navigationBar: LMKNavigationBar = {
        let bar = LMKNavigationBar()
        bar.title = "Catalogs"
        return bar
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LMKColor.backgroundPrimary
        setupLayout()
        updateControlsAxis()
        refreshControls()
        tableView.backgroundView = loadingView
        loadingView.startLoading(message: "Loading the starter pack…")
        // The AppDelegate relays UIKit's memory warning through
        // AppNotification; this screen is its consumer (it can accumulate
        // thousands of walked records).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: AppNotification.memoryWarningReceived,
            object: nil
        )
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _: UITraitCollection) in
            self.updateControlsAxis()
            self.view.setNeedsLayout()
        }
        loadTask = Task { [weak self] in
            await ExampleStore.shared.ready()
            guard let self, !Task.isCancelled else { return }
            let pack = ExampleStore.shared.loadedPack
            catalogSources = pack.enumerableSources
            activeCatalog = catalogSources.first
            seededSources = pack.seededSources
            if catalogSources.isEmpty, seededSources.isEmpty {
                emptyStateView.configure(LMKEmptyStateView.Content(message: "The loaded pack ships no catalogs or lists.", icon: .system("square.stack.3d.up")))
            }
            loadingView.stopLoading()
            tableView.reloadData()
            updateEmptyState()
            refreshStatus()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tableView.setFittedHeaderView(tableHeader)
    }

    deinit {
        walkTask?.cancel()
        loadTask?.cancel()
        seedTask?.cancel()
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

    // MARK: - Actions

    @objc private func runOnePage() {
        walk(toEnd: false)
    }

    @objc private func runToEnd() {
        walk(toEnd: true)
    }

    /// Restart throws the walk away; while one runs, the same control stops
    /// it, keeping what it fetched and the cursor to resume from.
    @objc private func restartOrStop() {
        if isRunning {
            walkTask?.cancel()
        } else {
            resetWalk()
            refreshStatus()
        }
    }

    @objc private func handleMemoryWarning() {
        shedAccumulatedRecords()
    }

    private func walk(toEnd: Bool) {
        guard let catalog = activeCatalog, !isRunning, !state.completed else { return }
        isRunning = true
        refreshControls(running: toEnd ? autoButton : runButton)
        statusLabel.show("Fetching page \(state.pagesFetched + 1)…", status: .neutral)
        tableView.setFittedHeaderView(tableHeader)

        // Captured up front so the task holds no strong `self` across the
        // await: a walk can run for a while, and it must not pin a popped
        // screen alive for its whole duration.
        let startPages = state.pagesFetched
        let resumeState = state
        let generation = walkGeneration
        walkTask = Task { [weak self] in
            let result = await ExampleStore.shared.enumerate(source: catalog, resumeFrom: resumeState) { page in
                // Pause after one page unless "run to end" was tapped.
                toEnd ? true : page.state.pagesFetched <= startPages
            }
            // A reset in the meantime owns the screen now; a stop does not,
            // so the stopped walk's pages and cursor still land.
            guard let self, generation == walkGeneration else { return }
            state = result.state
            totalCount = result.totalCount
            appendDeduped(result.records)
            isRunning = false
            tableView.reloadData()
            updateEmptyState()
            if result.failure == ELVPipeline.cancelledMarker {
                refreshStatus(note: "Stopped. Run again to resume from the cursor.", noteStatus: .neutral, announcing: true)
            } else {
                refreshStatus(failure: result.failure, announcing: true)
            }
        }
    }

    /// Switches the walk target: the running walk cancels and the cursor,
    /// records, and dedup set reset — resumable state never spans two
    /// catalogs.
    private func selectCatalog(at index: Int) {
        guard catalogSources.indices.contains(index) else { return }
        guard catalogSources[index].id != activeCatalog?.id else { return }
        activeCatalog = catalogSources[index]
        resetWalk()
        refreshStatus()
    }

    /// Dedup on externalId as pages accumulate (a re-walk of the same offset
    /// must not double-list), in place against the persistent `seenIds` set.
    private func appendDeduped(_ incoming: [ELVRecord]) {
        for record in incoming {
            guard let id = record.externalId else { continue }
            if seenIds.insert(id).inserted { records.append(record) }
        }
    }

    /// Drops the walk: any running one is cancelled and its result
    /// orphaned (the generation moves on).
    private func resetWalk() {
        walkGeneration += 1
        walkTask?.cancel()
        state = ELVEnumerationState()
        records = []
        seenIds = []
        totalCount = nil
        isRunning = false
        tableView.reloadData()
        updateEmptyState()
    }

    /// Memory pressure: the accumulated walk can hold thousands of records,
    /// so release them all and reset the cursor; the status line plus the Run
    /// buttons are the reload affordance. Trimming only the tail would strand
    /// records the cursor has already passed with no way to re-fetch them.
    private func shedAccumulatedRecords() {
        guard !records.isEmpty else { return }
        resetWalk()
        refreshStatus(note: "Memory was low, so the loaded pages were released. Run one page to start again.")
    }

    /// Resolves a seeded list's entries and pushes the item browser.
    private func openList(_ source: ELVSource) {
        // Cancel-first, like every other resolve entry point: a double-tap
        // must not push two browsers.
        seedTask?.cancel()
        let name = source.displayName
        statusLabel.show("Fetching \(name)…", status: .neutral)
        tableView.setFittedHeaderView(tableHeader)
        seedTask = ResolveFlow.run(.seed(source), status: statusLabel, showsStages: false, onRecord: { [weak self] record in
            guard let self else { return }
            guard let browsable = RecordBrowsing.browsableCollections(of: record).first else {
                refreshStatus(note: "\(name) returned no entries.", announcing: true)
                return
            }
            refreshStatus()
            pushItems(of: record, collection: browsable.name)
        }, completion: { [weak self] result in
            guard let self else { return }
            // The funnel leaves its failure copy on the status line; fold it
            // back into the walk readout so the cursor state never vanishes
            // behind a list's failure.
            switch result {
            case .record:
                break
            case .unrecognized:
                refreshStatus(note: FailureCopy.unrecognized(host: ResolveFlow.Input.seed(source).host))
            case let .failed(failure, _):
                refreshStatus(note: "\(name): \(FailureCopy.message(for: failure))", noteStatus: .error)
            }
        })
    }

    // MARK: - UI Updates

    /// Enables the controls for the current state. While a walk runs, the
    /// tapped Run button carries the spinner, the other Run button is off,
    /// and Restart turns into Stop.
    private func refreshControls(running tapped: LMKButton? = nil) {
        let hasCatalog = activeCatalog != nil
        let canWalk = hasCatalog && !state.completed && !isRunning
        for button in [runButton, autoButton] {
            if isRunning {
                button.isLoading = button === tapped || (tapped == nil && button.isLoading)
                button.isEnabled = button.isLoading
            } else {
                button.isLoading = false
                button.isEnabled = canWalk
            }
        }
        resetButton.title = isRunning ? "Stop" : "Restart"
        resetButton.isEnabled = hasCatalog
    }

    private func updateControlsAxis() {
        let accessible = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        controls.axis = accessible ? .vertical : .horizontal
        controls.distribution = accessible ? .fill : .fillEqually
    }

    private func refreshStatus(failure: ELVFetchFailure? = nil, note: String? = nil, noteStatus: LMKStatus = .warning, announcing: Bool = false) {
        defer {
            refreshControls()
            tableView.setFittedHeaderView(tableHeader)
        }
        guard let catalog = activeCatalog else {
            // Post-load only (the walk paths all guard on a catalog): the
            // pack ships no `list` sources, so there is nothing to walk. Any
            // seeded lists above still browse.
            statusLabel.show("The loaded pack ships no walkable catalogs.", status: .warning)
            return
        }
        let total = totalCount.map(String.init) ?? "?"
        var lines = ["\(catalog.displayName)\(Separator.dot)loaded \(records.count) of \(total)\(Separator.dot)pages fetched: \(state.pagesFetched)"]
        if state.completed {
            lines.append("Walk complete.")
        } else if let next = state.nextURL {
            lines.append("Next cursor: \(next)")
        }
        if let failure {
            lines.append("Stopped: \(FailureCopy.message(for: failure))")
        }
        if let note {
            lines.append(note)
        }
        let status: LMKStatus = failure != nil ? .error : (note != nil ? noteStatus : .neutral)
        if announcing {
            statusLabel.showOutcome(lines.joined(separator: "\n"), status: status)
        } else {
            statusLabel.show(lines.joined(separator: "\n"), status: status)
        }
    }

    private func updateEmptyState() {
        let empty = records.isEmpty && seededSources.isEmpty && catalogSources.isEmpty
        tableView.backgroundView = empty ? emptyStateView : nil
    }

    // MARK: - Key Commands

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(title: "Run One Page", action: #selector(runOnePage), input: "r", modifierFlags: .command)]
    }
}

// MARK: - UITableViewDataSource

extension CatalogsViewController: UITableViewDataSource {
    func numberOfSections(in _: UITableView) -> Int {
        Section.allCases.count
    }

    func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .catalogs: catalogSources.count
        case .lists: seededSources.count
        case .records: records.count
        case nil: 0
        }
    }

    func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .catalogs: catalogSources.isEmpty ? nil : "Catalogs"
        case .lists: seededSources.isEmpty ? nil : "Lists"
        case .records: records.isEmpty ? nil : "Walked records"
        case nil: nil
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section) {
        case .catalogs:
            let cell = tableView.dequeueReusableCell(withIdentifier: LMKListTable.cellReuseIdentifier, for: indexPath)
            let source = catalogSources[indexPath.row]
            // The checkmark trailing reads as selected to VoiceOver.
            cell.lmk_applyListRow(
                LMKListRowConfiguration(title: source.displayName, subtitle: source.kind, trailing: source.id == activeCatalog?.id ? .checkmark : .none),
                backgroundColor: LMKColor.backgroundSecondary
            )
            return cell
        case .lists:
            let cell = tableView.dequeueReusableCell(withIdentifier: LMKListTable.cellReuseIdentifier, for: indexPath)
            let source = seededSources[indexPath.row]
            cell.lmk_applyListRow(
                LMKListRowConfiguration(title: source.displayName, subtitle: source.collections.first?.kind ?? source.kind, trailing: .disclosure),
                backgroundColor: LMKColor.backgroundSecondary
            )
            return cell
        case .records, nil:
            // Walked records are read-only: the static pool, so no recycled
            // hover from a catalog row rides along.
            let cell = tableView.dequeueReusableCell(withIdentifier: UITableView.staticRowReuseIdentifier, for: indexPath)
            guard records.indices.contains(indexPath.row) else { return cell }
            let record = records[indexPath.row]
            cell.lmk_applyListRow(
                LMKListRowConfiguration(title: record.displayTitle ?? record.kind, subtitle: "#\(record.externalId ?? "?")", trailing: .none),
                backgroundColor: LMKColor.backgroundSecondary,
                pointer: nil
            )
            cell.selectionStyle = .none
            return cell
        }
    }
}

// MARK: - UITableViewDelegate

extension CatalogsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: LMKAnimation.shouldAnimate)
        switch Section(rawValue: indexPath.section) {
        case .catalogs:
            selectCatalog(at: indexPath.row)
        case .lists:
            guard seededSources.indices.contains(indexPath.row) else { return }
            openList(seededSources[indexPath.row])
        case .records, nil:
            break
        }
    }
}
