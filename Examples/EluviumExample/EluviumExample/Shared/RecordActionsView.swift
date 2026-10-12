import EluviumCore
import LumiKitUI
import SnapKit
import UIKit

/// The record-level action row under a presented card, shared by every
/// record-presenting screen (Paste, the examples browser, the pushed record
/// page): "Load episodes" when the record carries a feed pointer (the
/// podcast chain), "Play" when the record itself carries a playable audio
/// URL (a track preview). The episodes resolve runs in here so the three
/// screens cannot drift; hosts supply the status label and the navigation.
final class RecordActionsView: UIView {
    // MARK: - Properties

    /// The resolved feed, handed back for the host to push its item browser.
    var onEpisodes: ((ELVRecord) -> Void)?
    /// The host's status line, for the episodes resolve's failure copy.
    weak var statusLabel: LMKStatusLabel?

    private var record: ELVRecord?
    private var episodesTask: Task<Void, Never>?

    private lazy var episodesButton = LMKButton(title: "Load episodes", style: .outlined(.primary), target: self, action: #selector(episodesTapped))

    private lazy var playButton = LMKButton(title: "Play", style: .outlined(.primary), target: self, action: #selector(playTapped))

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        let stack = UIStackView(arrangedSubviews: [episodesButton, playButton])
        stack.axis = .vertical
        stack.spacing = LMKSpacing.small
        addSubview(stack)
        stack.snp.makeConstraints { $0.edges.equalToSuperview() }
        configure(with: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        episodesTask?.cancel()
    }

    // MARK: - Actions

    /// The podcast chain: the show record carries its RSS `feedUrl`;
    /// resolving it is an ordinary feed resolve whose items are the show's
    /// full episode list.
    @objc private func episodesTapped() {
        guard let record, let feedURL = RecordBrowsing.feedURL(of: record), let statusLabel else { return }
        episodesTask?.cancel()
        episodesButton.isLoading = true
        episodesTask = ResolveFlow.run(.url(feedURL, example: nil), status: statusLabel, showsStages: false, onRecord: { [weak self] feed in
            self?.onEpisodes?(feed)
        }, completion: { [weak self] _ in
            self?.episodesButton.isLoading = false
        })
    }

    @objc private func playTapped() {
        guard let record else { return }
        AudioPlayer.shared.play(item: record)
    }

    // MARK: - UI Updates

    /// Shows the affordances the record supports; `nil` hides the whole view
    /// and cancels an in-flight episodes resolve, so a failed or replaced
    /// resolve can never leave the previous record's actions live.
    func configure(with record: ELVRecord?) {
        self.record = record
        episodesTask?.cancel()
        episodesButton.isLoading = false
        episodesButton.isHidden = record.map { RecordBrowsing.feedURL(of: $0) == nil } ?? true
        playButton.isHidden = record.map { RecordBrowsing.audioURL(of: $0) == nil } ?? true
        isHidden = episodesButton.isHidden && playButton.isHidden
    }
}
