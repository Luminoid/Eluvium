import EluviumCore
import LumiKitUI
import SnapKit
import UIKit

/// Screen ②: the installed pack. Every active source with its match rule,
/// fetch plan, and example count, plus the sources this binary skipped and
/// why. The paste box's answer to "why did my URL match this source."
final class SourcesViewController: UIViewController {
    // MARK: - Types

    private enum Section: Int, CaseIterable {
        case active
        case skipped

        var title: String {
            switch self {
            case .active: "Installed sources"
            case .skipped: "Skipped on this binary"
            }
        }
    }

    // MARK: - Properties

    /// nil until the store's background pack load lands (see `viewDidLoad`);
    /// the table simply has no sections before that.
    private var pack: ELVLoadedPack?
    private var loadTask: Task<Void, Never>?

    private lazy var navigationBar: LMKNavigationBar = {
        let bar = LMKNavigationBar()
        bar.title = "Sources"
        return bar
    }()

    private lazy var tableView: UITableView = {
        let table = LMKListTable.makeInsetGrouped(dataSource: self, delegate: self)
        table.registerStaticRows()
        return table
    }()

    private lazy var loadingView = LMKLoadingStateView()

    private lazy var emptyStateView: LMKEmptyStateView = {
        let view = LMKEmptyStateView()
        view.configure(LMKEmptyStateView.Content(message: "The loaded pack has no sources.", icon: .system("shippingbox")))
        return view
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LMKColor.backgroundPrimary
        view.addSubview(navigationBar)
        navigationBar.install(in: view)
        view.addSubview(tableView)
        tableView.snp.makeConstraints { make in
            make.top.equalTo(navigationBar.snp.bottom)
            make.leading.trailing.bottom.equalToSuperview()
        }
        tableView.backgroundView = loadingView
        loadingView.startLoading(message: "Loading the starter pack…")
        loadTask = Task { [weak self] in
            await ExampleStore.shared.ready()
            guard let self, !Task.isCancelled else { return }
            let pack = ExampleStore.shared.loadedPack
            self.pack = pack
            loadingView.stopLoading()
            if ExampleStore.shared.loadFailed {
                // A build-time bug surfaced at runtime: say so instead of
                // showing the empty fallback as an honest empty pack.
                emptyStateView.configure(LMKEmptyStateView.Content(
                    message: "The starter pack failed to load, so this build is running on the empty fallback. The log carries the pack error.",
                    icon: .system("exclamationmark.triangle")
                ))
                tableView.backgroundView = emptyStateView
            } else {
                tableView.backgroundView = pack.sources.isEmpty && pack.skipped.isEmpty ? emptyStateView : nil
            }
            tableView.reloadData()
        }
    }

    deinit {
        loadTask?.cancel()
    }
}

// MARK: - UITableViewDataSource

extension SourcesViewController: UITableViewDataSource {
    func numberOfSections(in _: UITableView) -> Int {
        pack == nil ? 0 : Section.allCases.count
    }

    func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let pack else { return nil }
        switch Section(rawValue: section) {
        case .active: return "\(Section.active.title) (\(pack.sources.count))"
        case .skipped: return pack.skipped.isEmpty ? nil : "\(Section.skipped.title) (\(pack.skipped.count))"
        case .none: return nil
        }
    }

    func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .active: pack?.sources.count ?? 0
        case .skipped: pack?.skipped.count ?? 0
        case .none: 0
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // Read-only rows (a context menu copies the id): the static pool.
        let cell = tableView.dequeueReusableCell(withIdentifier: UITableView.staticRowReuseIdentifier, for: indexPath)
        guard let row = row(at: indexPath) else { return cell }
        cell.lmk_applyListRow(row, backgroundColor: LMKColor.backgroundSecondary, pointer: nil)
        cell.selectionStyle = .none
        return cell
    }

    private func row(at indexPath: IndexPath) -> LMKListRowConfiguration? {
        guard let pack else { return nil }
        let rowStyle = LMKListRowConfiguration.Style(titleTextStyle: .bodyMedium)
        switch Section(rawValue: indexPath.section) {
        case .active:
            guard pack.sources.indices.contains(indexPath.row) else { return nil }
            let source = pack.sources[indexPath.row]
            // The id stays visible: it is the stable handle diagnostics and
            // skip reasons report.
            let subtitle = source.title == nil ? describe(source) : "\(source.id)\(Separator.dot)\(describe(source))"
            return LMKListRowConfiguration(title: source.title ?? source.id, subtitle: subtitle, trailing: .none, style: rowStyle)
        case .skipped:
            guard pack.skipped.indices.contains(indexPath.row) else { return nil }
            let skipped = pack.skipped[indexPath.row]
            var style = rowStyle
            style.titleColor = LMKColor.textSecondary
            return LMKListRowConfiguration(title: skipped.id, subtitle: skipped.reason, trailing: .none, style: style)
        case .none:
            return nil
        }
    }

    /// The source id a row names, for its copy action.
    private func sourceId(at indexPath: IndexPath) -> String? {
        guard let pack else { return nil }
        switch Section(rawValue: indexPath.section) {
        case .active: return pack.sources.indices.contains(indexPath.row) ? pack.sources[indexPath.row].id : nil
        case .skipped: return pack.skipped.indices.contains(indexPath.row) ? pack.skipped[indexPath.row].id : nil
        case .none: return nil
        }
    }

    private func describe(_ source: ELVSource) -> String {
        var parts = ["kind: \(source.kind)"]
        if let match = source.match {
            if !match.hosts.isEmpty { parts.append("host: \(match.hosts.joined(separator: ", "))") }
            if !match.brands.isEmpty { parts.append("brand: \(match.brands.joined(separator: ", "))") }
            if !match.paths.isEmpty { parts.append("path: \(match.paths.joined(separator: " | "))") }
            if match.file != nil { parts.append("file source") }
            if match.isCatchAll { parts.append("generic floor") }
        } else {
            parts.append("generic floor")
        }
        if let fetch = source.fetch {
            parts.append("fetch: \(fetch.mode)")
        }
        parts.append("examples: \(source.examples.count)")
        return parts.joined(separator: Separator.dot)
    }
}

// MARK: - UITableViewDelegate

extension SourcesViewController: UITableViewDelegate {
    /// Copy a source's id: the handle diagnostics, skip reasons, and
    /// `eluvium curate --ids` take.
    func tableView(_: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point _: CGPoint) -> UIContextMenuConfiguration? {
        guard let id = sourceId(at: indexPath) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [
                UIAction(title: "Copy ID", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = id
                },
            ])
        }
    }
}
