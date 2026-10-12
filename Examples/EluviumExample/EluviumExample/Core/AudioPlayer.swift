import AVFoundation
import EluviumCore
import Foundation
import LumiKitCore
import LumiKitUI
import MediaPlayer
import UIKit

/// The app's one audio player (playback demo): a single `AVPlayer`
/// behind a tiny state surface, because one preview or episode plays at a
/// time and every screen shares the same bar. State changes broadcast
/// through `AppNotification.audioStateChanged` so any number of bars can
/// observe without fighting over a single callback slot. Lock screen and
/// Control Center mirror the same state through Now Playing + the remote
/// command center, which the declared background-audio mode requires.
///
/// `isPlaying` is the player's own `timeControlStatus` observed through KVO,
/// not a flag the transport methods toggle: interruptions, route loss,
/// stalls, and remote pauses all land in one place. A failed item (bad URL,
/// unsupported file, stall into failure) surfaces once through the shared
/// error handler and returns the bar to idle.
@MainActor
final class AudioPlayer {
    // MARK: - Types

    struct State: Equatable {
        var url: URL?
        var title: String?
        var isPlaying = false
        var currentSeconds: Double = 0
        var durationSeconds: Double?
        /// The playback speed, sticky across items until changed.
        var rate: Float = 1.0
        /// The embedded chapter under the playhead (ID3/M4A chapter marks
        /// read off the asset at play time), nil when the file carries none.
        var currentChapter: String?

        var fractionPlayed: Double {
            guard let durationSeconds, durationSeconds > 0 else { return 0 }
            return min(max(currentSeconds / durationSeconds, 0), 1)
        }
    }

    // MARK: - Properties

    static let shared = AudioPlayer()

    private(set) var state = State() {
        didSet {
            guard state != oldValue else { return }
            NotificationCenter.default.post(name: AppNotification.audioStateChanged, object: nil)
            // Now Playing interpolates elapsed time from the rate, so only
            // discontinuities re-publish: identity, play/pause, duration.
            // Seeks call `publishNowPlaying` themselves.
            if state.url != oldValue.url || state.title != oldValue.title
                || state.isPlaying != oldValue.isPlaying || state.durationSeconds != oldValue.durationSeconds
                || state.rate != oldValue.rate {
                publishNowPlaying()
            }
        }
    }

    /// Where a playback failure surfaces: the shared error handler on the
    /// top view controller. Injectable so the state-machine tests observe
    /// the message without a window.
    var failurePresenter: @MainActor (String) -> Void = { message in
        guard let presenter = UIViewController.lmk_topViewController() else { return }
        LMKErrorHandler.present(from: presenter, message: message, severity: .error)
    }

    /// `nonisolated(unsafe)` on the opaque token fields below: the
    /// nonisolated `deinit` tears them down, and Swift 6 only lets a deinit
    /// touch Sendable stored properties (`isolated deinit` needs the iOS
    /// 18.4 runtime; the target is 18.0). Every write happens on the
    /// MainActor, and deinit runs once nothing else can reach them. The
    /// player itself is a Sendable constant and needs no annotation.
    private let player = AVPlayer()
    /// The periodic observer's token, removed on reinstall and in deinit.
    private nonisolated(unsafe) var timeObserverToken: Any?
    private var timeControlObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    /// The current item's end and failed-to-end observers.
    private nonisolated(unsafe) var itemObservers: [NSObjectProtocol] = []
    /// Audio-session interruption and route-change observers.
    private nonisolated(unsafe) var sessionObservers: [NSObjectProtocol] = []
    /// Now Playing artwork for the current item; loaded off the record's
    /// image ref through the app's shared loader.
    private var artworkImage: UIImage?
    /// Embedded chapter marks (title, start seconds) for the current item.
    private var chapters: [(title: String, start: Double)] = []
    private var artworkTask: Task<Void, Never>?
    private var chapterTask: Task<Void, Never>?
    /// The latest audio-session request; each new one awaits it, so
    /// activations and deactivations reach the session in the order the
    /// player asked for them.
    private var sessionTask: Task<Void, Never>?
    /// Starts playback once the session is active (`startPlayback`).
    private var startTask: Task<Void, Never>?
    /// What the listener asked for last: play (true) or pause. A start
    /// waiting on session activation re-checks it, so a pause tapped in
    /// between wins.
    private var wantsPlayback = false
    /// Set once per item when its failure has been surfaced: the status KVO
    /// and the failed-to-end notification can both fire for one broken file.
    private var hasReportedFailure = false

    // MARK: - Constants

    /// The speed cycle, in tap order. `1.0` sits first so the cycle reads
    /// as "speed up, then back to normal".
    static let availableRates: [Float] = [1.0, 1.25, 1.5, 2.0, 0.8]
    /// Transport skip intervals (seconds), mirrored on the lock screen's
    /// skip commands.
    static let skipBackInterval: Double = 15
    static let skipForwardInterval: Double = 30
    /// The periodic tick that drives the scrubber and the chapter readout.
    static let tickInterval: Double = 0.5
    /// A small lead so a chapter reads as current the tick it starts.
    static let chapterLeadSeconds: Double = 0.25
    /// Seek and tick timescale: 600 divides evenly by every common rate.
    private static let timescale: CMTimeScale = 600

    // MARK: - Init

    /// `installsRemoteCommands` is false only in tests: the remote command
    /// center is process-global, and a second player must not steal the
    /// shared one's targets.
    init(installsRemoteCommands: Bool = true) {
        installTimeObserver()
        observePlayer()
        observeSession()
        if installsRemoteCommands {
            setupRemoteCommands()
        }
    }

    deinit {
        if let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
        }
        for observer in itemObservers + sessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        artworkTask?.cancel()
        chapterTask?.cancel()
        startTask?.cancel()
    }

    // MARK: - Setup

    /// One periodic observer for the player's lifetime; items come and go
    /// underneath it. Main queue, so `assumeIsolated` is sound.
    private func installTimeObserver() {
        if let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
        }
        let interval = CMTime(seconds: Self.tickInterval, preferredTimescale: Self.timescale)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.tick(currentSeconds: time.seconds)
            }
        }
    }

    private func observePlayer() {
        timeControlObservation = Self.observeTimeControl(of: player) { [weak self] isPlaying in
            // Hop only: KVO fires on AVFoundation's queue and the body is one
            // synchronous MainActor write; there is nothing to cancel.
            Task { @MainActor in self?.timeControlChanged(isPlaying: isPlaying) }
        }
    }

    /// Per-item surfaces: natural end, the stall-into-failure notification
    /// mid-play, and the item status flipping to `.failed` (bad URL,
    /// unsupported file), which fires before a single frame plays.
    private func observe(_ item: AVPlayerItem) {
        for observer in itemObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        let center = NotificationCenter.default
        itemObservers = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.finishedCurrentItem()
                }
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] notification in
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                MainActor.assumeIsolated {
                    self?.handlePlaybackFailure(error)
                }
            },
        ]
        itemStatusObservation = Self.observeFailure(of: item) { [weak self] error in
            // Hop only: KVO fires on AVFoundation's queue and the failure
            // handler is one synchronous MainActor call; nothing to cancel.
            Task { @MainActor in self?.handlePlaybackFailure(error) }
        }
    }

    /// A phone call or Siri pauses the session (`.began`); when it ends with
    /// `.shouldResume`, playback picks back up. Pulling out headphones
    /// (`.oldDeviceUnavailable`) pauses rather than blaring from the
    /// speaker. Both arrive on the main queue, so `assumeIsolated` holds.
    private func observeSession() {
        let center = NotificationCenter.default
        sessionObservers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
                let info = notification.userInfo
                let type = (info?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                let options = AVAudioSession.InterruptionOptions(rawValue: info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                MainActor.assumeIsolated {
                    self?.handleInterruption(type, options: options)
                }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
                let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                MainActor.assumeIsolated {
                    self?.handleRouteChange(reason)
                }
            },
        ]
    }

    /// Lock-screen / headphone transport. Handlers arrive on arbitrary
    /// queues, so each hops to the MainActor and answers optimistically.
    /// Every hop below is fire-and-forget by design: one synchronous
    /// MainActor call with nothing to await or cancel.
    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            // Hop only (see above).
            Task { @MainActor in
                guard let self, !self.state.isPlaying else { return }
                self.togglePause()
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            // Hop only (see above).
            Task { @MainActor in
                guard let self, self.state.isPlaying else { return }
                self.togglePause()
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            // Hop only (see above).
            Task { @MainActor in
                self?.togglePause()
            }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime
            // Hop only (see above).
            Task { @MainActor in
                guard let self, let duration = self.state.durationSeconds, duration > 0 else { return }
                self.seek(toFraction: seconds / duration)
            }
            return .success
        }
        // The skip commands are what CarPlay and headphone buttons send;
        // without targets they render disabled and taps do nothing.
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipBackInterval)]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            // Hop only (see above).
            Task { @MainActor in
                self?.skip(-Self.skipBackInterval)
            }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipForwardInterval)]
        center.skipForwardCommand.addTarget { [weak self] _ in
            // Hop only (see above).
            Task { @MainActor in
                self?.skip(Self.skipForwardInterval)
            }
            return .success
        }
        center.changePlaybackRateCommand.supportedPlaybackRates = Self.availableRates.map { NSNumber(value: $0) }
        center.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            let rate = event.playbackRate
            // Hop only (see above).
            Task { @MainActor in
                guard let self, Self.availableRates.contains(rate) else { return }
                self.setRate(rate)
            }
            return .success
        }
    }

    // MARK: - Actions

    /// Plays a record's audio, with its title and artwork riding along to
    /// the bar and the lock screen; a record without audio is a no-op.
    func play(item record: ELVRecord) {
        guard let url = RecordBrowsing.audioURL(of: record) else { return }
        play(url: url, title: record.displayTitle, artwork: RecordBrowsing.imageRef(of: record))
    }

    /// Starts `url`, or toggles pause when it is already the current item.
    /// `artwork` feeds the lock screen; the chosen speed sticks across items.
    func play(url: URL, title: String?, artwork: ELVMediaRef? = nil) {
        guard url != state.url else {
            togglePause()
            return
        }
        let item = AVPlayerItem(url: url)
        observe(item)
        player.replaceCurrentItem(with: item)
        artworkTask?.cancel()
        chapterTask?.cancel()
        artworkImage = nil
        chapters = []
        hasReportedFailure = false
        // Optimistic `isPlaying` so the bar flips this turn; the player's
        // timeControlStatus reconciles it through KVO.
        state = State(url: url, title: title, isPlaying: true, rate: state.rate)
        player.defaultRate = state.rate
        startPlayback()
        if let artwork {
            artworkTask = Task { [weak self] in
                let image = await RecordImageLoader.image(for: artwork)
                guard let self, !Task.isCancelled, state.url == url else { return }
                artworkImage = image
                publishNowPlaying()
            }
        }
        // ID3/M4A chapter marks. A fresh asset for the read: AVAsset is not
        // Sendable, so the player's own item never crosses the executor hop
        // (metadata loads from cache once the item is buffering anyway).
        chapterTask = Task { [weak self] in
            let marks = await Self.loadChapters(fromURL: url)
            guard let self, !Task.isCancelled, state.url == url else { return }
            chapters = marks
        }
    }

    /// Cycles the playback speed through `availableRates`; the choice
    /// applies immediately when playing and sticks for the next item.
    func cycleRate() {
        let rates = Self.availableRates
        let index = rates.firstIndex(of: state.rate).map { ($0 + 1) % rates.count } ?? 0
        setRate(rates[index])
    }

    /// Relative seek for the transport skips (negative goes back).
    func skip(_ seconds: Double) {
        guard state.url != nil else { return }
        var target = max(state.currentSeconds + seconds, 0)
        if let duration = state.durationSeconds { target = min(target, duration) }
        player.seek(to: CMTime(seconds: target, preferredTimescale: Self.timescale))
        state.currentSeconds = target
        publishNowPlaying()
    }

    func togglePause() {
        guard state.url != nil else { return }
        if state.isPlaying {
            wantsPlayback = false
            startTask?.cancel()
            player.pause()
            // Read the player's status now so the bar flips this turn; the
            // KVO hop reconciles anything the player decides afterwards.
            timeControlChanged(isPlaying: player.timeControlStatus != .paused)
        } else {
            // Resuming an item parked at its end would be an audible no-op:
            // rewind first so play means play.
            if let duration = state.durationSeconds, state.currentSeconds >= duration {
                player.seek(to: .zero)
                state.currentSeconds = 0
            }
            // Optimistic, like a fresh play: the start waits on the session.
            timeControlChanged(isPlaying: true)
            startPlayback()
        }
    }

    func seek(toFraction fraction: Double) {
        guard let duration = state.durationSeconds, duration > 0 else { return }
        let clamped = min(max(fraction, 0), 1)
        player.seek(to: CMTime(seconds: duration * clamped, preferredTimescale: Self.timescale))
        state.currentSeconds = duration * clamped
        publishNowPlaying()
    }

    /// Returns the surface to idle (the bar collapses) and tells the user
    /// once per item; the chosen speed sticks. Internal so the app tests
    /// drive the state machine without a broken file.
    func handlePlaybackFailure(_ error: (any Error)?) {
        guard let url = state.url, !hasReportedFailure else { return }
        hasReportedFailure = true
        // The host is public-safe; the error attaches (domain and code in
        // the public text, the description in private detail).
        LMKLogger.error("Playback failed for an episode on \(url.host ?? "-")", error: error, category: .error)
        let title = state.title
        unloadCurrentItem()
        failurePresenter(title.map { "Couldn't play \($0)." } ?? "Couldn't play that audio.")
    }

    // MARK: - Helpers

    /// Applies a speed immediately when playing and keeps it for the next
    /// item (the rate button and the lock screen's rate command share it).
    private func setRate(_ rate: Float) {
        player.defaultRate = rate
        if state.isPlaying { player.rate = rate }
        state.rate = rate
    }

    private func timeControlChanged(isPlaying: Bool) {
        guard state.url != nil else { return }
        state.isPlaying = isPlaying
    }

    private func tick(currentSeconds: Double) {
        guard state.url != nil, currentSeconds.isFinite else { return }
        var next = state
        next.currentSeconds = max(currentSeconds, 0)
        if next.durationSeconds == nil, let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0 {
            next.durationSeconds = duration
        }
        next.currentChapter = chapters.last(where: { $0.start <= next.currentSeconds + Self.chapterLeadSeconds })?.title
        state = next
    }

    private func finishedCurrentItem() {
        wantsPlayback = false
        var next = state
        next.isPlaying = false
        if let duration = next.durationSeconds { next.currentSeconds = duration }
        state = next
        // Hand the audio back (other apps' playback resumes); a replay
        // activates the session again before it starts.
        requestSession(active: false)
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType?, options: AVAudioSession.InterruptionOptions) {
        guard state.url != nil else { return }
        switch type {
        case .began:
            player.pause()
        case .ended:
            // The interruption deactivated the session; resuming activates
            // it again before playing.
            if options.contains(.shouldResume), wantsPlayback { startPlayback() }
        default:
            break
        }
    }

    private func handleRouteChange(_ reason: AVAudioSession.RouteChangeReason?) {
        guard reason == .oldDeviceUnavailable, state.url != nil else { return }
        // A pulled headphone is a pause the listener didn't type: nothing
        // resumes it behind their back.
        wantsPlayback = false
        startTask?.cancel()
        player.pause()
    }

    /// Drops the current item and its observers and resets the state; the
    /// chosen speed survives.
    private func unloadCurrentItem() {
        wantsPlayback = false
        startTask?.cancel()
        artworkTask?.cancel()
        chapterTask?.cancel()
        itemStatusObservation = nil
        for observer in itemObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        itemObservers = []
        player.replaceCurrentItem(with: nil)
        artworkImage = nil
        chapters = []
        state = State(rate: state.rate)
        requestSession(active: false)
    }

    /// Activates the session, then plays the current item, unless the
    /// listener paused or the item changed while activation ran.
    private func startPlayback() {
        wantsPlayback = true
        let url = state.url
        let activation = requestSession(active: true)
        startTask?.cancel()
        startTask = Task { [weak self] in
            await activation.value
            guard let self, !Task.isCancelled, wantsPlayback, state.url == url else { return }
            player.play()
        }
    }

    /// Queues one session change behind the previous one: both run on the
    /// `AudioSessionController` actor (off the MainActor), and each awaits
    /// its predecessor, so they land in request order.
    @discardableResult
    private func requestSession(active: Bool) -> Task<Void, Never> {
        let previous = sessionTask
        let task = Task {
            await previous?.value
            if active {
                await AudioSessionController.shared.activate()
            } else {
                await AudioSessionController.shared.deactivate()
            }
        }
        sessionTask = task
        return task
    }

    /// Embedded chapter marks via `AVAsset` timed metadata (`@concurrent`:
    /// metadata loading must not ride the MainActor). Files without
    /// chapters return an empty list — the common case.
    @concurrent
    private static func loadChapters(fromURL url: URL) async -> [(title: String, start: Double)] {
        let asset = AVURLAsset(url: url)
        guard let locales = try? await asset.load(.availableChapterLocales), let locale = locales.first else { return [] }
        guard let groups = try? await asset.loadChapterMetadataGroups(withTitleLocale: locale, containingItemsWithCommonKeys: []) else { return [] }
        var marks: [(title: String, start: Double)] = []
        for group in groups {
            let start = group.timeRange.start.seconds
            guard start.isFinite,
                  let titleItem = group.items.first(where: { $0.commonKey == .commonKeyTitle }),
                  let title = try? await titleItem.load(.stringValue), !title.isEmpty else { continue }
            marks.append((title: title, start: max(start, 0)))
        }
        return marks.sorted { $0.start < $1.start }
    }

    /// Formed off the MainActor so the change handler doesn't inherit its
    /// isolation: KVO fires on AVFoundation's queue, and an isolated closure
    /// would trap on the executor check there. Reports the item's failure
    /// reason once its status flips to `.failed`.
    private nonisolated static func observeFailure(of item: AVPlayerItem, onFailure: @escaping @Sendable ((any Error)?) -> Void) -> NSKeyValueObservation {
        item.observe(\.status, options: [.new]) { item, _ in
            guard item.status == .failed else { return }
            onFailure(item.error)
        }
    }

    /// Same severing as `observeFailure`, for the player's transport state.
    /// `waitingToPlayAtSpecifiedRate` (buffering) still counts as playing.
    private nonisolated static func observeTimeControl(of player: AVPlayer, onChange: @escaping @Sendable (Bool) -> Void) -> NSKeyValueObservation {
        player.observe(\.timeControlStatus, options: [.new]) { player, _ in
            onChange(player.timeControlStatus != .paused)
        }
    }

    /// Publishes the lock-screen / Control Center readout: title, elapsed,
    /// duration, rate. Runs on discontinuities, not ticks — the system
    /// interpolates elapsed time from the published rate.
    private func publishNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard state.url != nil else {
            center.nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: state.title ?? "Playing",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.currentSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: state.isPlaying ? Double(state.rate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(state.rate),
        ]
        if let duration = state.durationSeconds {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let artwork = artworkImage {
            info[MPMediaItemPropertyArtwork] = Self.makeArtwork(from: artwork)
        }
        center.nowPlayingInfo = info
    }

    /// Builds the Now Playing artwork off this class's MainActor context:
    /// MediaPlayer invokes the request handler on its own accessQueue, and a
    /// closure formed in MainActor-isolated code inherits that isolation and
    /// traps (`_dispatch_assert_queue_fail`) when the runtime checks the
    /// executor. The `nonisolated static` wrapper severs the inheritance.
    private nonisolated static func makeArtwork(from image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}

/// The one serial home for `AVAudioSession` calls. Activation and
/// deactivation are synchronous XPC (tens of ms), so they run on this
/// actor, off the MainActor; `AudioPlayer` chains its requests so they also
/// arrive in order.
actor AudioSessionController {
    static let shared = AudioSessionController()

    /// Spoken-audio playback, then active. Repeated calls are cheap and
    /// needed: an interruption deactivates the session behind the app's back.
    func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio)
        } catch {
            LMKLogger.error("Audio session category failed", error: error, category: .error)
        }
        do {
            try session.setActive(true)
        } catch {
            LMKLogger.error("Audio session activation failed", error: error, category: .error)
        }
    }

    /// Releases the session so other apps' audio resumes.
    func deactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            LMKLogger.error("Audio session deactivation failed", error: error, category: .error)
        }
    }
}
