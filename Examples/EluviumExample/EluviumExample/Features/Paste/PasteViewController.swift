import EluviumCore
import LumiKitUI
import SnapKit
import UIKit

/// Screen ①: one paste box over the whole pipeline. As text lands, the
/// pack's offline preview names the record (label, source, what a run would
/// add) with no network; Resolve then runs recognize → fetch → extract →
/// assemble with the share text riding along, and shows the record as a
/// field table with provenance and typed failure states.
///
/// Built on LumiKit's scroll stack, whose readable-width pinning reads the
/// scroll view's own guide, so the page holds still during the iOS 26
/// interactive swipe back.
final class PasteViewController: LMKScrollStackViewController {
    // MARK: - Properties

    private var runTask: Task<Void, Never>?
    /// Waits out the pack load, then previews the box's current text.
    private var previewTask: Task<Void, Never>?

    private lazy var inputField: LMKTextView = {
        let field = LMKTextView()
        field.placeholder = "Paste a link, or share text with one in it (Wikipedia, PokéAPI, an IMDb title, a Maps place, or any URL)"
        field.textView.autocorrectionType = .no
        field.textView.autocapitalizationType = .none
        field.textView.keyboardType = .URL
        field.onTextChange = { [weak self] _ in
            self?.schedulePreview()
        }
        return field
    }()

    /// The offline preview line under the box: silent, since it updates on
    /// every keystroke.
    private let previewLine = LMKStatusLabel()

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
        previewTask?.cancel()
    }

    // MARK: - Setup

    override func setupStackContent() {
        stackView.addArrangedSubview(inputField)
        stackView.addArrangedSubview(previewLine)
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
        guard let input = InputParser.input(in: inputField.text ?? "", policy: ExampleStore.shared.pastePolicy) else {
            recordPanel.status.showOutcome("That doesn't look like a link yet.", status: .warning)
            return
        }
        runTask?.cancel()
        // A failed resolve must not leave the previous record's browse
        // affordances live: clear the panel before running.
        recordPanel.clear()
        setBusy(true)
        runTask = ResolveFlow.run(.paste(input), status: recordPanel.status, onRecord: { [weak self] record in
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

    /// Previews the box's text once the starter pack is in (an instant
    /// return after the first load), so a paste in the first second after
    /// launch still gets its line.
    private func schedulePreview() {
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            await ExampleStore.shared.ready()
            guard let self, !Task.isCancelled else { return }
            let text = inputField.text ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                previewLine.clear()
                return
            }
            guard let input = InputParser.input(in: text, policy: ExampleStore.shared.pastePolicy) else {
                previewLine.show("Not a link yet.", status: .neutral)
                return
            }
            previewLine.show(PreviewCopy.line(for: ExampleStore.shared.preview(input)), status: .neutral)
        }
    }

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

/// The Paste screen's preview line: the record's name, the source that
/// recognized the link, and what Resolve would still add.
enum PreviewCopy {
    static func line(for preview: ELVPreview) -> String {
        var parts: [String] = []
        if let name = preview.record.displayTitle, !name.isEmpty {
            parts.append(name)
        }
        switch (preview.sourceId, preview.provisionalSourceId) {
        case let (source?, provisional?): parts.append("\(provisional), via \(source)")
        case let (source?, nil): parts.append(source)
        case (nil, _): parts.append("no source matched")
        }
        let steps = steps(for: preview.pending)
        parts.append(steps.isEmpty ? "complete offline" : "Resolve will \(ListFormatter.localizedString(byJoining: steps))")
        return "Preview: " + parts.joined(separator: Separator.dot)
    }

    private static func steps(for pending: ELVPreviewPending) -> [String] {
        var steps: [String] = []
        if pending.contains(.redirect) { steps.append("follow the short link") }
        if pending.contains(.fetch) { steps.append("fetch the page") }
        if pending.contains(.floor) { steps.append("read the page") }
        if pending.contains(.platformLookup) { steps.append("look the place up") }
        return steps
    }
}
