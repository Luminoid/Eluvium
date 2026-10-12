import EluviumCore
import LumiKitUI
import SnapKit
import UIKit

/// Screen ①: one paste box over the whole pipeline. Recognize → fetch →
/// extract → assemble, then the record as a field table with provenance and
/// typed failure states. The framework's parity is demonstrated by hand here.
///
/// Built on LumiKit's scroll stack, whose readable-width pinning reads the
/// scroll view's own guide, so the page holds still during the iOS 26
/// interactive swipe back.
final class PasteViewController: LMKScrollStackViewController {
    // MARK: - Properties

    private var runTask: Task<Void, Never>?

    private lazy var inputField: LMKTextView = {
        let field = LMKTextView()
        field.placeholder = "Paste a link (Wikipedia, PokéAPI, a Six Flags ride, an IMDb title, or any URL)"
        field.textView.autocorrectionType = .no
        field.textView.autocapitalizationType = .none
        field.textView.keyboardType = .URL
        return field
    }()

    private lazy var resolveButton = LMKButton(title: "Resolve", style: .filled(.primary), target: self, action: #selector(resolveTapped))

    private lazy var examplesButton = LMKButton(title: "Try an example…", style: .ghost(.primary), target: self, action: #selector(examplesTapped))

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

    private lazy var bar: LMKNavigationBar = {
        let bar = LMKNavigationBar()
        bar.title = "Paste"
        return bar
    }()

    override var navigationBar: LMKNavigationBar? { bar }

    // MARK: - Init

    init() {
        super.init(style: RecordPageStyle.scrollStack(keyboardDismissMode: .onDrag))
    }

    isolated deinit {
        runTask?.cancel()
    }

    // MARK: - Setup

    override func setupStackContent() {
        stackView.addArrangedSubview(inputField)
        stackView.addArrangedSubview(resolveButton)
        stackView.addArrangedSubview(examplesButton)
        stackView.addArrangedSubview(recordPanel)
    }

    // MARK: - Actions

    @objc private func examplesTapped() {
        navigationController?.pushViewController(ExamplesViewController(), animated: LMKAnimation.shouldAnimate)
    }

    @objc private func resolveTapped() {
        view.endEditing(true)
        let raw = (inputField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = InputParser.firstURL(in: raw) else {
            recordPanel.status.showOutcome("That doesn't look like a URL yet.", status: .warning)
            return
        }
        runTask?.cancel()
        // A failed resolve must not leave the previous record's browse
        // affordances live: clear the panel before running.
        recordPanel.clear()
        setBusy(true)
        runTask = ResolveFlow.run(.url(url, example: nil), status: recordPanel.status, onRecord: { [weak self] record in
            guard let self else { return }
            recordPanel.status.clear()
            recordPanel.present(record)
        }, completion: { [weak self] _ in
            self?.setBusy(false)
        })
    }

    /// The menu bar's Resolve (⌘↩) on iPad and Mac, routed here while this
    /// screen is in front (`MainTabBarController.target(forAction:)`).
    @objc func resolveFromMenu(_: Any?) {
        resolveTapped()
    }

    // MARK: - UI Updates

    private func setBusy(_ busy: Bool) {
        // LMKButton's loading state is the design system's busy affordance:
        // activity indicator plus blocked interaction in one flag.
        resolveButton.isLoading = busy
    }

    // MARK: - Key Commands

    /// iPhone only: iPad and Mac carry Resolve in the menu bar (AppDelegate
    /// `buildMenu`), and registering it twice leaves UIKit to pick one.
    override var keyCommands: [UIKeyCommand]? {
        guard traitCollection.userInterfaceIdiom == .phone else { return super.keyCommands }
        return [UIKeyCommand(title: "Resolve", action: #selector(resolveTapped), input: "\r", modifierFlags: .command)]
    }
}

/// The scroll-stack style both record pages (Paste, the pushed record page)
/// share: medium spacing, vertical breathing room, and the readable measure
/// list headers use (`lmk_readableWidthGuide`: safe-area based, 16pt sides,
/// capped on wide screens), so a record page and a list line up.
@MainActor
enum RecordPageStyle {
    static func scrollStack(keyboardDismissMode: UIScrollView.KeyboardDismissMode = .none) -> LMKScrollStackViewController.Style {
        LMKScrollStackViewController.Style(
            stackSpacing: LMKSpacing.medium,
            contentInsets: NSDirectionalEdgeInsets(top: LMKSpacing.large, leading: 0, bottom: LMKSpacing.large, trailing: 0),
            widthMode: .capped(maxWidth: LMKLayout.readableContentMaxWidth, horizontalInset: LMKSpacing.large),
            keyboardDismissMode: keyboardDismissMode,
            alwaysBounceVertical: true,
            // Under the translucent tab bar, not above it, so content
            // scrolls behind the bar; the scroll view's automatic insets keep
            // the last row clear.
            bottomAnchor: .superview
        )
    }
}
