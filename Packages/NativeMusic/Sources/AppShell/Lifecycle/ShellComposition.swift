import AppKit
import DesignSystem
import Features
import Foundation
import Playback
import SwiftUI

/// W21: wires the shell to the app's surfaces. The shell itself knows nothing of the catalog, the library or the lyrics; the composition supplies
/// them as closures, and installs the launch, reopen and termination hooks the delegate runs.
extension LocalAccountBootstrap {
    func installShell() {
        installOutputs()
        installUpdates()
        let shell = shell
        shell.likeControlProvider = { [weak self] videoID in self?.playingSongControls(videoID).first { $0.kind == .like } }
        shell.libraryControlsProvider = { [weak self] videoID in self?.playingSongControls(videoID) ?? [] }
        shell.ratingGapProvider = { [weak self] videoID in
            switch self?.nowPlayingRatings.gap(for: videoID) {
            case .reading?: .reading
            case .notOffered?: .notOffered
            case .signedOut?: .signedOut
            case .failed?: .readFailed
            case nil: nil
            }
        }
        shell.likePress = { [weak self] control in
            guard let self else { return }
            await LibraryControlPress.press(control, ledger: self.library.ledger, social: self.social)
            // The service now holds what was asked for (or the change is still settling): the playing song's rating follows it.
            if case .rating(let video) = control.key, let write = self.library.ledger.write(control.key), !write.state.isFailed,
               case .rating(let status)? = write.displayed {
                self.nowPlayingRatings.settle(video, to: status)
            }
        }
        shell.ratingHeld = { [weak self] control in
            guard let self, case .rating(let video) = control.key, let write = self.library.ledger.write(control.key), !write.state.isFailed else { return false }
            return self.library.ledger.rating(video, service: .indifferent) == .dislike
        }
        shell.artworkContextProvider = { [weak self] in self.map { ShellArtworkContext(pipeline: $0.artwork, request: $0.artworkRequest, authority: $0.artworkAuthority) } ?? ShellArtworkContext() }
        shell.queuePanelProvider = { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(ShellQueuePanel(playback: self.playback, shell: self.shell))
        }
        shell.lyricsPanelProvider = { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            let podcasts = self.podcasts
            let playback = self.playback
            let videoID: String? = {
                guard let player = playback.music, !player.isClosed else { return nil }
                let state = player.snapshot
                guard !state.isAd, state.phase != .idle, let id = state.videoID else { return nil }
                return podcasts.playback.current?.videoID == id ? nil : id
            }()
            return AnyView(LyricsPanelView(model: podcasts.lyrics, follow: podcasts.follow, videoID: videoID, position: { playback.music?.timeline.position ?? 0 }))
        }
        PlaybackApplicationDelegate.didFinishLaunching = { shell.start() }
        PlaybackApplicationDelegate.willTerminate = { shell.stop() }
        PlaybackApplicationDelegate.reopen = { shell.showMainWindow() }
    }
}

/// The queue panel of the shell's surfaces: YouTube Music's own queue statement while it plays; otherwise a way to the window's queue.
struct ShellQueuePanel: View {
    let playback: PlaybackModel
    let shell: ShellCoordinator
    var body: some View {
        if let player = playback.music, WebMusicQueueSummary.isActive(player) {
            ScrollView { WebMusicQueueView(player: player) }
        } else {
            VStack(spacing: MusicSpace.xs) {
                Text("The queue is shown in the main window.").font(.callout)
                Button("Show Queue in Window") { shell.showQueue() }.musicAction(.secondary)
            }.padding(MusicSpace.md).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension LocalAccountBootstrap {
    /// Like, Dislike and Save for the song that is playing: what its row published when it was shown on a page, with the rating replaced by the
    /// one read for the playing song itself (`NowPlayingRatings`), which is newer and exists for songs no page showed.
    func playingSongControls(_ videoID: String) -> [LibraryControl] {
        let ledger = library.ledger
        var controls = catalog.song(videoID).map { LibraryControls.make(item: $0, source: nil, ledger: ledger) } ?? []
        if let like = nowPlayingRatings.like(for: videoID) {
            controls.removeAll { $0.kind == .like || $0.kind == .dislike }
            controls.insert(contentsOf: LibraryControls.rating(like, ledger: ledger), at: 0)
        }
        return controls.filter { [.like, .dislike, .save].contains($0.kind) }
    }
}
