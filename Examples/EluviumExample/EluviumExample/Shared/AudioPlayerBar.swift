import EluviumCore
import LumiKitUI
import SnapKit
import UIKit

/// The shared playback bar: play/pause, the playing title, and an
/// `LMKSlider` scrubber whose readout doubles as the time display and the
/// VoiceOver value (timecodes, not fractions). Screens pin one between
/// their content and the safe area; it collapses to zero height until
/// something plays and observes `AppNotification.audioStateChanged`, so
/// every bar mirrors the one shared `AudioPlayer`. It opens and closes
/// with a short slide and fade (instant under Reduce Motion).
final class AudioPlayerBar: UIView {
    // MARK: - Properties

    /// While the user drags, state ticks must not yank the thumb back.
    private var isScrubbing = false

    /// Active while nothing plays: a hidden bar must not reserve its height
    /// in the screens that pin it between table and safe area. The outer
    /// breathing margin rides inside the bar for the same reason.
    private var collapseConstraint: Constraint?
    private var isCollapsed = false

    private lazy var card: LMKCardView = {
        let card = LMKCardView()
        card.style.surface.contentInsets = .lmk_symmetric(vertical: LMKSpacing.small, horizontal: LMKSpacing.large)
        return card
    }()

    private lazy var playButton: LMKButton = {
        let button = LMKButton(systemImage: "play.fill", style: .iconOnly(.primary), target: self, action: #selector(playPauseTapped))
        button.accessibilityLabel = "Play"
        return button
    }()

    private lazy var titleLabel: UILabel = {
        let label = UILabel.lmk_make(.caption, color: LMKColor.textPrimary, numberOfLines: 1)
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    /// The embedded chapter under the playhead; collapses when absent.
    private lazy var chapterLabel: UILabel = {
        let label = UILabel.lmk_make(.caption, color: LMKColor.textSecondary, numberOfLines: 1)
        label.lineBreakMode = .byTruncatingTail
        label.isHidden = true
        return label
    }()

    private lazy var skipBackButton: LMKButton = {
        let button = LMKButton(systemImage: "gobackward.15", style: .iconOnly(.primary), target: self, action: #selector(skipBackTapped))
        button.accessibilityLabel = "Skip back 15 seconds"
        return button
    }()

    private lazy var skipForwardButton: LMKButton = {
        let button = LMKButton(systemImage: "goforward.30", style: .iconOnly(.primary), target: self, action: #selector(skipForwardTapped))
        button.accessibilityLabel = "Skip forward 30 seconds"
        return button
    }()

    /// The speed readout is text ("1.25×"), so this is the ghost style, not
    /// an icon button: the number is the whole point of the control.
    private lazy var rateButton: LMKButton = {
        let button = LMKButton(title: Self.rateText(1.0), style: .ghost(.primary), target: self, action: #selector(rateTapped))
        button.accessibilityLabel = "Playback speed"
        return button
    }()

    private lazy var slider: LMKSlider = {
        let slider = LMKSlider()
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.accessibilityLabel = "Playback position"
        // The formatter drives both the visible readout and the VoiceOver
        // value, so adjustments announce timecodes instead of fractions.
        slider.valueFormatter = { value in
            let state = AudioPlayer.shared.state
            guard let duration = state.durationSeconds else {
                return ELVValueDisplay.duration(state.currentSeconds)
            }
            return "\(ELVValueDisplay.duration(Double(value) * duration)) / \(ELVValueDisplay.duration(duration))"
        }
        slider.onValueChange = { [weak self] value in
            // VoiceOver increments and keyboard adjustments arrive as value
            // changes with no touch phase: commit those immediately. Touch
            // scrubs keep committing on touch-up only.
            guard let self, !isScrubbing else { return }
            AudioPlayer.shared.seek(toFraction: Double(value))
        }
        slider.addTarget(self, action: #selector(scrubBegan), for: .touchDown)
        slider.addTarget(self, action: #selector(scrubEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return slider
    }()

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        setupLayout()
        setCollapsed(true, animated: false)
        NotificationCenter.default.addObserver(self, selector: #selector(stateChanged), name: AppNotification.audioStateChanged, object: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupLayout() {
        addSubview(card)
        card.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            // Below required so the zero-height collapse wins cleanly; the
            // bar is hidden whenever collapsed, so the overflow never draws.
            make.bottom.equalToSuperview().inset(LMKSpacing.small).priority(.high)
        }
        snp.makeConstraints { make in
            collapseConstraint = make.height.equalTo(0).constraint
        }

        let textStack = UIStackView(arrangedSubviews: [titleLabel, chapterLabel])
        textStack.axis = .vertical
        textStack.spacing = LMKSpacing.xxs

        let controlsRow = UIStackView(arrangedSubviews: [skipBackButton, playButton, skipForwardButton, textStack, rateButton])
        controlsRow.axis = .horizontal
        controlsRow.alignment = .center
        controlsRow.spacing = LMKSpacing.small
        // The transport buttons sit flush: their 44pt touch boxes already
        // carry visual padding around the glyphs, so extra spacing between
        // them just spreads the cluster.
        controlsRow.setCustomSpacing(0, after: skipBackButton)
        controlsRow.setCustomSpacing(0, after: playButton)

        // The scrubber (progress + timestamp readout) rides its own second
        // line, full card width, under the transport row.
        let column = UIStackView(arrangedSubviews: [controlsRow, slider])
        column.axis = .vertical
        column.spacing = LMKSpacing.xxs
        card.contentView.addSubview(column)
        column.snp.makeConstraints { $0.edges.equalToSuperview() }
        // Height comes from the theme's 44pt button floor; the transport
        // glyphs also get a 44pt-wide box, so they sit flush without their
        // touch areas overlapping.
        for control in [skipBackButton, playButton, skipForwardButton] {
            control.snp.makeConstraints { $0.width.greaterThanOrEqualTo(LMKLayout.minimumTouchTarget) }
        }
        for control in [skipBackButton, playButton, skipForwardButton, rateButton] {
            control.setContentHuggingPriority(.required, for: .horizontal)
        }
        slider.snp.makeConstraints { $0.height.greaterThanOrEqualTo(LMKLayout.minimumTouchTarget) }
    }

    // MARK: - Actions

    @objc private func playPauseTapped() {
        AudioPlayer.shared.togglePause()
    }

    @objc private func skipBackTapped() {
        AudioPlayer.shared.skip(-AudioPlayer.skipBackInterval)
    }

    @objc private func skipForwardTapped() {
        AudioPlayer.shared.skip(AudioPlayer.skipForwardInterval)
    }

    @objc private func rateTapped() {
        AudioPlayer.shared.cycleRate()
    }

    @objc private func scrubBegan() {
        isScrubbing = true
    }

    @objc private func scrubEnded() {
        isScrubbing = false
        AudioPlayer.shared.seek(toFraction: Double(slider.value))
    }

    // MARK: - UI Updates

    @objc private func stateChanged() {
        let state = AudioPlayer.shared.state
        setCollapsed(state.url == nil, animated: true)
        titleLabel.lmk_setText(state.title ?? "Playing")
        playButton.setSymbol(state.isPlaying ? "pause.fill" : "play.fill")
        playButton.accessibilityLabel = state.isPlaying ? "Pause" : "Play"
        chapterLabel.lmk_setText(state.currentChapter)
        chapterLabel.isHidden = state.currentChapter == nil
        rateButton.title = Self.rateText(state.rate)
        rateButton.accessibilityLabel = "Playback speed, \(String(format: "%g", state.rate)) times"
        guard !isScrubbing else { return }
        slider.setValue(Float(state.fractionPlayed), animated: false)
    }

    /// Opens or closes the bar. Animated through `LMKAnimation` when the
    /// bar is on screen (the host's layout animates with it, so the content
    /// above slides instead of jumping); instant under Reduce Motion,
    /// off screen, and at setup.
    private func setCollapsed(_ collapsed: Bool, animated: Bool) {
        guard collapsed != isCollapsed else { return }
        isCollapsed = collapsed
        guard animated, LMKAnimation.shouldAnimate, window != nil, let host = superview else {
            isHidden = collapsed
            alpha = 1
            toggleCollapseConstraint(collapsed)
            return
        }
        if !collapsed {
            isHidden = false
            alpha = 0
        }
        toggleCollapseConstraint(collapsed)
        LMKAnimation.animateListUpdate(animations: { [weak self] in
            self?.alpha = collapsed ? 0 : 1
            host.layoutIfNeeded()
        }, completion: { [weak self] in
            // A newer change may have reopened the bar mid-animation.
            guard let self, isCollapsed else { return }
            isHidden = true
            alpha = 1
        })
    }

    private func toggleCollapseConstraint(_ collapsed: Bool) {
        if collapsed {
            collapseConstraint?.activate()
        } else {
            collapseConstraint?.deactivate()
        }
    }

    // MARK: - Helpers

    /// %g drops trailing zeros: 1×, 1.25×, 2×.
    private static func rateText(_ rate: Float) -> String {
        String(format: "%g×", rate)
    }
}
