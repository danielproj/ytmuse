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
        shell.likeControlProvider = { [weak self] videoID in
            guard let self, let item = self.catalog.song(videoID) else { return nil }
            return LibraryControls.make(item: item, source: nil, ledger: self.library.ledger).first { $0.kind == .like }
        }
        shell.libraryControlsProvider = { [weak self] videoID in
            guard let self, let item = self.catalog.song(videoID) else { return [] }
            return LibraryControls.make(item: item, source: nil, ledger: self.library.ledger).filter { [.like, .dislike, .save].contains($0.kind) }
        }
        shell.likePress = { [weak self] control in
            guard let self else { return }
            await LibraryControlPress.press(control, ledger: self.library.ledger, social: self.social)
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
                Button("Show Queue in Window") { shell.showQueue() }.musicButtons()
            }.padding(MusicSpace.md).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
