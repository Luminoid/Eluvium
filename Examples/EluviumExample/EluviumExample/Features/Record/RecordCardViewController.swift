import EluviumCore
import EluviumNet
import LumiKitUI
import SnapKit
import UIKit

/// A pushed record page: the drill-through target for list entries and
/// feed posts (tap an Oscars entry, land on its IMDb record). Resolves a
/// URL through the store funnel and carries the same browse affordances as
/// the Paste screen: tappable collections and the shared record actions
/// (episodes, play). A spinner covers the page while the resolve runs; a
/// resolve that produces no record ends in the typed failure copy with a
/// retry instead of an empty scroll view.
final class RecordCardViewController: LMKScrollStackViewController {
    // MARK: - Properties

    private let url: URL
    /// Set when the page runs a corpus example (the examples browser's
    /// page mode): the resolve logs with the expectation verdict and unmet
    /// expectations surface on the status line, exactly like the panel.
    private let example: ELVExample?
    private var runTask: Task<Void, Never>?

    private lazy var bar: LMKNavigationBar = {
        let bar = LMKNavigationBar()
        bar.title = "Record"
        bar.showsBackButton = true
        return bar
    }()

    override var navigationBar: LMKNavigationBar? { bar }

    /// Status line, record card, and record actions: the shared panel.
    private lazy var recordPanel: RecordPanelView = {
        let panel = RecordPanelView()
        panel.onBrowse = { [weak self] record, name in
            self?.pushItems(of: record, collection: name)
        }
        panel.onEpisodes = { [weak self] feed in
            self?.pushItems(of: feed, collection: "items")
        }
        return panel
    }()

    private lazy var loadingView = LMKLoadingStateView()

    private lazy var emptyStateView: LMKEmptyStateView = {
        let view = LMKEmptyStateView()
        view.isHidden = true
        return view
    }()

    // MARK: - Init

    init(url: URL, example: ELVExample? = nil) {
        self.url = url
        self.example = example
        super.init(style: RecordPageStyle.scrollStack())
        hidesBottomBarWhenPushed = true
    }

    isolated deinit {
        runTask?.cancel()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        // Both placeholders cover the page area: the spinner while the
        // resolve runs, the failure copy when it produces no record.
        view.addSubview(loadingView)
        view.addSubview(emptyStateView)
        loadingView.snp.makeConstraints { $0.edges.equalTo(scrollView) }
        emptyStateView.snp.makeConstraints { $0.edges.equalTo(scrollView) }
        resolve()
    }

    // MARK: - Setup

    override func setupStackContent() {
        stackView.addArrangedSubview(recordPanel)
    }

    // MARK: - Actions

    private func resolve() {
        runTask?.cancel()
        recordPanel.clear()
        emptyStateView.isHidden = true
        loadingView.isHidden = false
        loadingView.startLoading(message: "Resolving \(url.host ?? "the page")…")
        runTask = ResolveFlow.run(.url(url, example: example), status: recordPanel.status, showsStages: false, onRecord: { [weak self] record in
            guard let self else { return }
            // The corpus's declared expectations, via the same check the
            // log line records; a plain resolve just clears the status.
            if let example, case let unmet = example.unmetExpectations(for: record), !unmet.isEmpty {
                recordPanel.status.showOutcome("Expectations unmet: \(unmet.joined(separator: "; ")).", status: .warning)
            } else {
                recordPanel.status.clear()
            }
            show(record)
        }, completion: { [weak self] result in
            guard let self else { return }
            loadingView.stopLoading()
            loadingView.isHidden = true
            switch result {
            case .record:
                break
            case .unrecognized:
                showEmptyState(FailureCopy.unrecognized(host: url.host))
            case let .failed(failure, _):
                showEmptyState(FailureCopy.message(for: failure))
            }
        })
    }

    // MARK: - UI Updates

    private func show(_ record: ELVRecord) {
        bar.title = record.displayTitle ?? record.kind
        recordPanel.present(record)
    }

    /// The failure copy takes the page (the status line would only repeat
    /// it), with a retry since most resolve failures are transient.
    private func showEmptyState(_ message: String) {
        recordPanel.status.clear()
        let retry = LMKEmptyStateView.Action(title: "Try again", icon: "arrow.clockwise") { [weak self] in
            self?.resolve()
        }
        emptyStateView.configure(LMKEmptyStateView.Content(message: message, icon: .system("exclamationmark.triangle"), primaryAction: retry))
        emptyStateView.isHidden = false
    }
}
