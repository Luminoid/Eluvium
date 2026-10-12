import EluviumCore
import LumiKitUI
import SnapKit
import UIKit
import UniformTypeIdentifiers

/// Screen ④: document picker (or a dropped file) → archive import with
/// row-level results; re-import the same file to show `externalId` dedup
/// and merge policies preserving an edited record. Bundled samples seed the
/// demo when no file is at hand: a Flighty-shaped CSV, a
/// Twitter-archive-shaped pair of jsJson shards, an OPML subscription list
/// whose rows chain into `generic.feed` by their feed URL, and a 微信读书
/// notes export. Picked files also match the loaded pack's own file sources
/// (iNaturalist and eBird CSVs, the WeRead export), which import into one
/// generic section each. The demos, their merge arithmetic, and the file
/// reader live in `ImportDemo` / `CatalogImport` / `ImportFileReader`.
final class ImportsViewController: UIViewController {
    // MARK: - Types

    /// One table section: a demo's mirror rows or a catalog source's.
    private enum ImportSection {
        case demo(ImportDemo, [ELVRecord])
        case catalog(ELVSource, [ELVRecord])

        var title: String {
            switch self {
            case let .demo(demo, _): demo.headerTitle
            case let .catalog(source, _): CatalogImport.headerTitle(for: source)
            }
        }

        var records: [ELVRecord] {
            switch self {
            case let .demo(_, records), let .catalog(_, records): records
            }
        }
    }

    // MARK: - Properties

    /// The account mirrors, one per demo: a record whose collection
    /// accumulates imported rows, deduped on `externalId` across re-imports.
    private var mirrors: [ImportDemo: ELVRecord] = Dictionary(uniqueKeysWithValues: ImportDemo.allCases.map { ($0, $0.emptyMirror) })
    /// Mirrors for the catalog's file sources, in first-import order.
    private var catalogMirrors: [(source: ELVSource, mirror: ELVRecord)] = []

    private var lastSummary = "No import yet."
    /// Failed outcomes render in the error tone; everything else stays
    /// informational.
    private var lastSummaryIsFailure = false
    private var importTask: Task<Void, Never>?

    /// Sections with imported rows, demos first; drives the table. Cached
    /// and rebuilt in `refresh()`: the computed form re-filtered the mirrors
    /// on every data-source callback, and a mid-mutation layout pass could
    /// see different sections than the last `reloadData`.
    private var visibleSections: [ImportSection] = []

    // MARK: - UI

    /// The import summary or failure copy, tinted per status like every
    /// other screen's status line.
    private let statusLabel = LMKStatusLabel()

    private lazy var pickButton = LMKButton(title: "Pick a file to import", style: .filled(.primary), target: self, action: #selector(pickFile))

    /// The bundled samples, folded into one menu so the controls stay a
    /// short block at any text size.
    private lazy var sampleButton: LMKButton = {
        var style = LMKButton.Style.outlined(.primary)
        style.showsMenuIndicator = true
        let button = LMKButton(title: "Import a sample", style: style)
        button.menu = UIMenu(children: [
            UIAction(title: "Flighty CSV", image: UIImage(systemName: "airplane")) { [weak self] _ in
                self?.runDemo(.flighty, policy: .preferIncoming)
            },
            UIAction(title: "Twitter archive (2 shards)", image: UIImage(systemName: "text.bubble")) { [weak self] _ in
                self?.runDemo(.twitter, policy: .preferIncoming)
            },
            UIAction(title: "OPML subscriptions", image: UIImage(systemName: "dot.radiowaves.up.forward")) { [weak self] _ in
                self?.runDemo(.opml, policy: .preferIncoming)
            },
            UIAction(title: "微信读书 notes export", image: UIImage(systemName: "book")) { [weak self] _ in
                self?.importWeReadSample()
            },
        ])
        button.showsMenuAsPrimaryAction = true
        return button
    }()

    /// A plain configuration already wraps a long title; nothing to tweak.
    private lazy var editButton = LMKButton(title: "Edit first flight's note, then re-import sample", style: .outlined(.primary), target: self, action: #selector(editThenReimport))

    /// Status and controls ride the table, so they scroll with the rows
    /// instead of pinning a block that outgrows the screen at accessibility
    /// text sizes, in iPhone landscape, or in Slide Over.
    private lazy var tableHeader: UIView = {
        let controls = UIStackView(arrangedSubviews: [pickButton, sampleButton, editButton])
        controls.axis = .vertical
        controls.spacing = LMKSpacing.small
        return ListHeaderScaffold.makeTableHeader(ListHeaderScaffold.makeHeaderStack([statusLabel, controls], spacing: LMKSpacing.medium))
    }()

    private lazy var tableView: UITableView = {
        let table = LMKListTable.makeInsetGrouped(dataSource: self)
        table.registerStaticRows()
        return table
    }()

    private lazy var emptyStateView: LMKEmptyStateView = {
        let view = LMKEmptyStateView()
        view.configure(LMKEmptyStateView.Content(message: "Nothing imported yet. Pick or drop a file, or run a bundled sample.", icon: .system("square.and.arrow.down")))
        return view
    }()

    private lazy var navigationBar: LMKNavigationBar = {
        let bar = LMKNavigationBar()
        bar.title = "Imports"
        return bar
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LMKColor.backgroundPrimary
        // The Flighty source's timezone fields resolve through the
        // airport.timeZone@1 native op, and op registration lives in the
        // store's init; touch it before the first import can run.
        _ = ExampleStore.shared
        setupLayout()
        refresh()
        // Files dropped anywhere on the screen import like a picked one.
        view.addInteraction(UIDropInteraction(delegate: self))
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _: UITraitCollection) in
            self.view.setNeedsLayout()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tableView.setFittedHeaderView(tableHeader)
    }

    deinit {
        importTask?.cancel()
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

    /// Internal: the menu bar's File ▸ Import… (⌘O) lands here through
    /// `MainTabBarController` on iPad and Mac.
    @objc func pickFile() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: ImportFileReader.importableTypes)
        picker.delegate = self
        present(picker, animated: LMKAnimation.shouldAnimate)
    }

    @objc private func editThenReimport() {
        let demo = ImportDemo.flighty
        guard var mirror = mirrors[demo], var flights = mirror.collections[demo.collection], !flights.isEmpty else {
            lastSummary = "Import the Flighty sample first, then this edits row 1 and re-imports."
            lastSummaryIsFailure = false
            refresh()
            return
        }
        flights[0].fields["note"] = .text("✎ user edited")
        mirror.collections[demo.collection] = flights
        mirrors[demo] = mirror
        // Re-import under fillEmptyOnly so the edited note survives the merge.
        runImport(.demo(demo), files: demo.files, policy: .fillEmptyOnly, busyButton: editButton)
    }

    private func runDemo(_ demo: ImportDemo, policy: ELVMergePolicy) {
        runImport(.demo(demo), files: demo.files, policy: policy, busyButton: sampleButton)
    }

    /// The WeRead sample: recognized against the loaded pack's file sources
    /// exactly like a picked file, then imported through `weread.notes`.
    private func importWeReadSample() {
        importTask?.cancel()
        setBusy(true, on: sampleButton)
        importTask = Task { [weak self] in
            await ExampleStore.shared.ready()
            guard let self, !Task.isCancelled else { return }
            setBusy(false, on: sampleButton)
            let target = ImportFileReader.target(
                fileName: WeReadNotesSample.fileName,
                data: Data(WeReadNotesSample.text.utf8),
                catalogSources: ExampleStore.shared.loadedPack.fileSources
            )
            runImport(target, files: [(WeReadNotesSample.fileName, WeReadNotesSample.text)], policy: .preferIncoming, busyButton: sampleButton)
        }
    }

    /// Parses off the main thread (a picked archive can be megabytes), then
    /// merges into the target's mirror and refreshes on the MainActor.
    /// Multiple files are shards of one list: each runs the same archive
    /// import path and the per-shard records concatenate in file (partN)
    /// order, the contract `ELVJSJSONReader.parseShards` applies to raw
    /// shard text.
    private func runImport(_ target: ImportTarget, files: [(fileName: String, text: String)], policy: ELVMergePolicy, busyButton: LMKButton) {
        importTask?.cancel()
        setBusy(true, on: busyButton)
        let source = switch target {
        case let .demo(demo): demo.source
        case let .catalog(source): source
        }
        importTask = Task { [weak self] in
            // Off the main actor; the framework logs each file's import
            // (source, format, row counts, bytes, duration).
            let outcome: Result<[ELVRecord], Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    try files.flatMap { file in
                        try ELVArchiveImporter.importRecords(source: source, fileName: file.fileName, data: Data(file.text.utf8))
                    }
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            setBusy(false, on: busyButton)
            apply(outcome: outcome, target: target, fileCount: files.count, policy: policy)
        }
    }

    private func apply(outcome: Result<[ELVRecord], Error>, target: ImportTarget, fileCount: Int, policy: ELVMergePolicy) {
        switch outcome {
        case let .success(records):
            switch target {
            case let .demo(demo):
                let merge = demo.merge(records, into: mirrors[demo], policy: policy)
                mirrors[demo] = merge.mirror
                lastSummary = demo.summary(imported: records.count, fileCount: fileCount, policy: policy, outcome: merge)
            case let .catalog(source):
                let index = catalogMirrors.firstIndex { $0.source.id == source.id }
                let merge = CatalogImport.merge(records, into: index.map { catalogMirrors[$0].mirror }, source: source, policy: policy)
                if let index {
                    catalogMirrors[index].mirror = merge.mirror
                } else {
                    catalogMirrors.append((source, merge.mirror))
                }
                lastSummary = CatalogImport.summary(source: source, imported: records.count, outcome: merge)
            }
            lastSummaryIsFailure = false
        case let .failure(error):
            // Typed copy only; a raw Swift error never reaches the UI. The
            // framework already logged the failure with its source, format,
            // and error.
            if let failure = error as? ELVArchiveImporter.Failure {
                lastSummary = FailureCopy.message(for: failure)
            } else {
                lastSummary = "The import failed."
            }
            lastSummaryIsFailure = true
        }
        refresh(announcing: true)
    }

    /// A picked or dropped file's read outcome: refused files say why;
    /// recognized ones import through their source.
    private func handleRead(_ outcome: ImportFileReader.Outcome, fileName: String) {
        let cap = ImportFileReader.maxImportBytesDescription
        let fileExtension = (fileName as NSString).pathExtension
        switch outcome {
        case .tooLarge:
            lastSummary = "\(fileName) is larger than \(cap), which is far beyond any personal-archive export. Pick a smaller file."
            lastSummaryIsFailure = true
            ParseLog.log(importSkipped: "larger than the \(cap) import cap", fileExtension: fileExtension)
            refresh(announcing: true)
        case .unreadable:
            lastSummary = "Could not read \(fileName)."
            lastSummaryIsFailure = true
            ParseLog.log(importSkipped: "file could not be read", fileExtension: fileExtension)
            refresh(announcing: true)
        case let .text(text, target):
            // Recognition already ran in the reader (stage ① over the
            // file); the source it picked owns the import.
            runImport(target, files: [(fileName, text)], policy: .preferIncoming, busyButton: pickButton)
        }
    }

    // MARK: - UI Updates

    /// The tapped control carries the spinner (and blocks its own taps);
    /// the others stay off until the import lands.
    private func setBusy(_ busy: Bool, on button: LMKButton) {
        for control in [pickButton, sampleButton, editButton] {
            if control === button {
                control.isLoading = busy
            } else {
                control.isEnabled = !busy
            }
        }
    }

    private func refresh(announcing: Bool = false) {
        visibleSections = ImportDemo.allCases.compactMap { demo in
            guard let records = mirrors[demo]?.collections[demo.collection], !records.isEmpty else { return nil }
            return .demo(demo, records)
        } + catalogMirrors.compactMap { entry in
            guard let records = entry.mirror.collections[CatalogImport.collection], !records.isEmpty else { return nil }
            return .catalog(entry.source, records)
        }
        let status: LMKStatus = lastSummaryIsFailure ? .error : .neutral
        if announcing {
            statusLabel.showOutcome(lastSummary, status: status)
        } else {
            statusLabel.show(lastSummary, status: status)
        }
        tableView.backgroundView = visibleSections.isEmpty ? emptyStateView : nil
        tableView.reloadData()
        tableView.setFittedHeaderView(tableHeader)
    }

    // MARK: - Key Commands

    /// iPhone only: iPad and Mac carry Import… in the menu bar (AppDelegate
    /// `buildMenu`), and registering it twice leaves UIKit to pick one.
    override var keyCommands: [UIKeyCommand]? {
        guard traitCollection.userInterfaceIdiom == .phone else { return super.keyCommands }
        return [UIKeyCommand(title: "Pick a File to Import", action: #selector(pickFile), input: "o", modifierFlags: .command)]
    }
}

// MARK: - UIDocumentPickerDelegate

extension ImportsViewController: UIDocumentPickerDelegate {
    func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        importTask?.cancel()
        setBusy(true, on: pickButton)
        let catalogSources = ExampleStore.shared.loadedPack.fileSources
        importTask = Task { [weak self] in
            let outcome = await ImportFileReader.read(at: url, catalogSources: catalogSources)
            guard let self, !Task.isCancelled else { return }
            setBusy(false, on: pickButton)
            handleRead(outcome, fileName: url.lastPathComponent)
        }
    }
}

// MARK: - UIDropInteractionDelegate

extension ImportsViewController: UIDropInteractionDelegate {
    func dropInteraction(_: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        session.items.count == 1 && session.hasItemsConforming(toTypeIdentifiers: ImportFileReader.importableTypes.map(\.identifier))
    }

    func dropInteraction(_: UIDropInteraction, sessionDidUpdate _: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    /// The dropped file is staged to a private copy (the provider deletes
    /// its own when the callback returns), read through the same reader and
    /// recognition as a picked file, then discarded.
    func dropInteraction(_: UIDropInteraction, performDrop session: UIDropSession) {
        guard let provider = session.items.first?.itemProvider, let typeIdentifier = ImportFileReader.importableTypeIdentifier(of: provider) else { return }
        importTask?.cancel()
        setBusy(true, on: pickButton)
        let catalogSources = ExampleStore.shared.loadedPack.fileSources
        importTask = Task { [weak self] in
            let outcome: ImportFileReader.Outcome
            let fileName: String
            if let staged = await ImportFileReader.stageDrop(from: provider, typeIdentifier: typeIdentifier) {
                outcome = await ImportFileReader.read(at: staged, catalogSources: catalogSources)
                fileName = staged.lastPathComponent
                ImportFileReader.discardStagedDrop(staged)
            } else {
                outcome = .unreadable
                fileName = provider.suggestedName ?? "The dropped file"
            }
            guard let self, !Task.isCancelled else { return }
            setBusy(false, on: pickButton)
            handleRead(outcome, fileName: fileName)
        }
    }
}

// MARK: - UITableViewDataSource

extension ImportsViewController: UITableViewDataSource {
    func numberOfSections(in _: UITableView) -> Int {
        visibleSections.count
    }

    func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        visibleSections.indices.contains(section) ? visibleSections[section].title : nil
    }

    func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        visibleSections.indices.contains(section) ? visibleSections[section].records.count : 0
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // Imported rows are read-only: the static pool, no highlight.
        let cell = tableView.dequeueReusableCell(withIdentifier: UITableView.staticRowReuseIdentifier, for: indexPath)
        guard visibleSections.indices.contains(indexPath.section) else { return cell }
        let section = visibleSections[indexPath.section]
        guard indexPath.row < section.records.count else { return cell }
        let record = section.records[indexPath.row]
        var content = cell.defaultContentConfiguration()
        switch section {
        case let .demo(demo, _):
            switch demo {
            case .flighty: configureFlightContent(&content, flight: record)
            case .twitter: configureTweetContent(&content, tweet: record)
            case .opml: configureFeedContent(&content, feed: record)
            }
        case .catalog:
            content.text = CatalogImport.rowTitle(record)
            content.secondaryText = CatalogImport.rowSecondary(record)
        }
        content.lmk_applyTextStyle()
        // Flight rows show the resolved time zones on a second line.
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.backgroundColor = LMKColor.backgroundSecondary
        cell.selectionStyle = .none
        return cell
    }

    private func configureFlightContent(_ content: inout UIListContentConfiguration, flight: ELVRecord) {
        let designator = flight.fields["designator"].map(ELVValueDisplay.string) ?? "?"
        let route = [flight.fields["from"], flight.fields["to"]].compactMap { $0.map(ELVValueDisplay.string) }.joined(separator: " → ")
        content.text = "\(designator)\(Separator.dot)\(route)"
        var parts = ["id: \(flight.externalId ?? "?")"]
        if let note = flight.fields["note"].map(ELVValueDisplay.string) { parts.append(note) }
        var secondary = parts.joined(separator: Separator.dot)
        // The airport.timeZone@1 resolution: local, offset-less CSV
        // timestamps get their IANA zones from the IATA codes.
        if case let .text(departureZone)? = flight.fields["departureTimeZone"],
           case let .text(arrivalZone)? = flight.fields["arrivalTimeZone"] {
            secondary += "\n\(departureZone) → \(arrivalZone)"
        }
        content.secondaryText = secondary
    }

    private func configureFeedContent(_ content: inout UIListContentConfiguration, feed: ELVRecord) {
        content.text = feed.displayTitle ?? feed.externalId ?? "?"
        var parts: [String] = []
        if let group = feed.fields["group"].map(ELVValueDisplay.string) { parts.append(group) }
        parts.append(feed.externalId ?? "?")
        content.secondaryText = parts.joined(separator: Separator.dot)
    }

    private func configureTweetContent(_ content: inout UIListContentConfiguration, tweet: ELVRecord) {
        content.text = tweet.fields["text"].map(ELVValueDisplay.string) ?? "?"
        var parts = ["id_str: \(tweet.externalId ?? "?")"]
        if let date = tweet.fields["date"].map(ELVValueDisplay.string) { parts.append(date) }
        if let likes = tweet.fields["likes"].map(ELVValueDisplay.string) { parts.append("\(likes) likes") }
        if let note = tweet.fields["note"].map(ELVValueDisplay.string) { parts.append(note) }
        content.secondaryText = parts.joined(separator: Separator.dot)
    }
}
