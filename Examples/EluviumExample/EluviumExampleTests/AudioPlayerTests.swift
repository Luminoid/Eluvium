import EluviumCore
import Foundation
import Testing
@testable import EluviumExample

/// The player's state machine around a record and a failure, driven without
/// real playback: a private instance that installs no remote commands, and
/// the failure handler called the way the item observers would.
@Suite("Audio player")
@MainActor
struct AudioPlayerTests {
    @Test
    func `A playback failure resets the bar and surfaces one message per item`() throws {
        let player = AudioPlayer(installsRemoteCommands: false)
        var messages: [String] = []
        player.failurePresenter = { messages.append($0) }
        let url = try #require(URL(string: "file:///nonexistent/episode.mp3"))

        player.play(url: url, title: "Episode 1")
        #expect(player.state.url == url)
        #expect(player.state.title == "Episode 1")

        player.handlePlaybackFailure(CocoaError(.fileReadCorruptFile))
        // Idle again: the bar collapses on a nil URL.
        #expect(player.state.url == nil)
        #expect(!player.state.isPlaying)
        #expect(player.state.currentSeconds == 0)
        #expect(messages == ["Couldn't play Episode 1."])

        // The status KVO and the failed-to-end notification can both fire
        // for one broken file: only the first reaches the user.
        player.handlePlaybackFailure(nil)
        #expect(messages.count == 1)

        // Idle players ignore failures outright.
        player.handlePlaybackFailure(nil)
        #expect(messages.count == 1)
    }

    @Test
    func `A pause before the session finishes activating wins over the queued start`() async throws {
        let player = AudioPlayer(installsRemoteCommands: false)
        player.failurePresenter = { _ in }
        let url = try #require(URL(string: "file:///nonexistent/episode.mp3"))
        player.play(url: url, title: "Episode 1")
        // Optimistic: the bar flips to playing this turn.
        #expect(player.state.isPlaying)
        // Paused before activation lands: the start must not override it.
        player.togglePause()
        #expect(!player.state.isPlaying)
        await AudioSessionController.shared.activate()
        await Task.yield()
        #expect(!player.state.isPlaying)
        player.handlePlaybackFailure(nil)
    }

    @Test
    func `Playing a record reads its audio, title, and keeps the chosen speed; a record without audio is a no-op`() throws {
        let player = AudioPlayer(installsRemoteCommands: false)
        player.failurePresenter = { _ in }
        player.cycleRate()
        let rate = player.state.rate
        #expect(rate != 1.0)

        var silent = ELVRecord(sourceId: "s", kind: "movie")
        silent.fields["title"] = .text("No audio")
        player.play(item: silent)
        #expect(player.state.url == nil)

        let audioURL = try #require(URL(string: "file:///nonexistent/preview.m4a"))
        var track = ELVRecord(sourceId: "s", kind: "track")
        track.fields["title"] = .text("Preview")
        track.fields["audio"] = .media(ELVMediaRef(url: audioURL, kind: ELVMediaRef.audio))
        player.play(item: track)
        #expect(player.state.url == audioURL)
        #expect(player.state.title == "Preview")
        #expect(player.state.rate == rate)

        // A failure keeps the speed the listener chose.
        player.handlePlaybackFailure(CocoaError(.fileReadUnknown))
        #expect(player.state.rate == rate)
    }
}
