import AppKit
import Foundation
import Playback

// W21 (ARCH03, PLAY01). The status item, its popover, the mini-player and full-screen Now Playing are views over the one playback owner. They read
// `ShellTransportState` and send commands through `ShellCommanding`; nothing in a shell surface talks to a player, a page or a session directly.

struct ShellTransportState: Equatable {
    enum Source: Equatable { case none, youTubeMusic, owned }
    var source: Source = .none
    var title = ""
    var artist: String?
    var hasItem = false
    /// The person wants it playing (the play button shows Pause).
    var isPlaying = false
    var isLoading = false
    /// A YouTube Music advertisement is playing: shown as "Ad", never skipped, covered or sought (Playback addendum).
    var isAd = false
    var canSkip = false
    var canSeek = false
    var isLive = false
    var hasPicture = false
    var volume = 1.0
    /// The sleep timer of whichever engine plays (PLAY17), nil without one.
    var sleepTimer: SleepTimerDisplay?
    /// Next and Previous: only for an item that can be skipped. An advertisement is never skipped, so both are off during one.
    var skipEnabled: Bool { hasItem && canSkip }
    static let idle = ShellTransportState()
    /// "Title - Artist", for the status item's tooltip. Nothing when nothing is playing.
    var tooltip: String? {
        guard hasItem else { return nil }
        let name = isAd ? String(localized: "Advertisement") : title
        return [name, isAd ? nil : artist].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " - ")
    }
    /// One honest line under the title.
    var statusLine: String {
        if isAd { return String(localized: "Ad playing") }
        if !hasItem { return String(localized: "Nothing playing") }
        if isLoading { return String(localized: "Loading…") }
        return artist ?? (isPlaying ? String(localized: "Playing") : String(localized: "Paused"))
    }
}

extension PlaybackModel {
    /// What the shell surfaces draw. Reads only the coarse snapshot (never the position clock), so a position tick never rebuilds a shell surface.
    var shellState: ShellTransportState {
        if let player = music, WebMusicQueueSummary.isActive(player) {
            let s = player.snapshot
            return ShellTransportState(source: .youTubeMusic, title: s.title ?? s.playlistTitle ?? "YouTube Music", artist: s.artist, hasItem: true, isPlaying: s.intent,
                                       isLoading: s.phase == .loading || s.phase == .buffering, isAd: s.isAd, canSkip: s.canSkip, canSeek: s.canSeek, isLive: s.isLive,
                                       hasPicture: s.hasPicture, volume: s.volume, sleepTimer: sleepTimerDisplay)
        }
        if session != nil, let snapshot = state, snapshot.playback.state != .idle {
            return ShellTransportState(source: .owned, title: currentTitle, artist: nil, hasItem: snapshot.queue.current != nil, isPlaying: snapshot.playback.intent == .play,
                                       isLoading: snapshot.playback.state == .buffering || snapshot.playback.state == .resolving, isAd: false, canSkip: true,
                                       canSeek: snapshot.media?.userSeekable == true, isLive: false, hasPicture: nativeVideo.hasPicture, volume: requestedGain,
                                       sleepTimer: sleepTimerDisplay)
        }
        return .idle
    }
    // The shell's transport commands are the media keys' commands (`remote`): admission is synchronous, an ad refuses skip and seek, and the
    // two engines are told apart in one place.
    func shellTogglePlayPause() { _ = remote(.toggle) }
    func shellNext() { _ = remote(.next) }
    func shellPrevious() { _ = remote(.previous) }
    func shellSetVolume(_ level: Double) {
        guard level.isFinite else { return }
        if let player = music, !player.isClosed { Task { await player.setVolume(min(1, max(0, level))) } }
        else if session != nil { changeGain(min(max(level, gainRange.lowerBound), gainRange.upperBound)) }
    }
}

/// The one command layer the shell surfaces call (ARCH03). `ShellCoordinator` is its production conformer; tests record calls.
@MainActor protocol ShellCommanding: AnyObject {
    var transport: ShellTransportState { get }
    func togglePlayPause()
    func next()
    func previous()
    func setVolume(_ level: Double)
    func showMainWindow()
    func showMiniPlayer()
    func showNowPlayingFullScreen()
    func showQueue()
    func openSettings()
    func quit()
}

enum ShellMenuCommand: String, Equatable, CaseIterable { case playPause, next, previous, showWindow, miniPlayer, settings, quit }
enum StatusMenuEntry: Equatable {
    case item(command: ShellMenuCommand, title: String, enabled: Bool)
    case separator
}
/// The status item's context menu as data: Play/Pause, Next, Previous, then Show YTMuse, Mini-player, Settings and Quit (WIN01, addendum).
/// During an advertisement Next and Previous are off, because nothing skips an ad.
enum StatusMenuModel {
    static func entries(for state: ShellTransportState) -> [StatusMenuEntry] {
        [.item(command: .playPause, title: state.isPlaying ? String(localized: "Pause") : String(localized: "Play"), enabled: state.hasItem),
         .item(command: .next, title: String(localized: "Next"), enabled: state.skipEnabled),
         .item(command: .previous, title: String(localized: "Previous"), enabled: state.skipEnabled),
         .separator,
         .item(command: .showWindow, title: String(localized: "Show YTMuse"), enabled: true),
         .item(command: .miniPlayer, title: String(localized: "Mini-player"), enabled: true),
         .item(command: .settings, title: String(localized: "Settings…"), enabled: true),
         .separator,
         .item(command: .quit, title: String(localized: "Quit YTMuse"), enabled: true)]
    }
    @MainActor static func perform(_ command: ShellMenuCommand, on shell: any ShellCommanding) {
        switch command {
        case .playPause: shell.togglePlayPause()
        case .next: shell.next()
        case .previous: shell.previous()
        case .showWindow: shell.showMainWindow()
        case .miniPlayer: shell.showMiniPlayer()
        case .settings: shell.openSettings()
        case .quit: shell.quit()
        }
    }
}
