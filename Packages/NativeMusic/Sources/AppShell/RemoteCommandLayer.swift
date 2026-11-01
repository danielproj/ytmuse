import Features
import Foundation
import Playback
import SystemIntegration

// W23 (ARCH03, MAC01, MAC02). The remote-command layer of the one playback owner.
//
// Media keys, AirPods, Control Center and the Lock Screen widget are not a second control path. `PlaybackModel.remote(_:)` is the one entry for all of
// them, and the shell's buttons use it too. Both the enable flag the system is given for each command and the answer to a command that arrives come
// from `remoteCapabilities()`, computed from the live state each time, so a command is never offered and then refused, and a command that is
// off in the window is off on the keys as well.

/// The library control a remote like, dislike or save would press, or the sentence saying why there is none.
enum RemoteLibraryControlState: Equatable {
    case available(LibraryControl)
    case unavailable(String)
}
/// The W12 library ledger as the remote layer sees it. The shell is the production conformer.
@MainActor protocol RemoteLibraryControlling: AnyObject {
    func remoteLibraryControl(_ kind: RemoteCommandKind) -> RemoteLibraryControlState
    /// Presses the control through the ledger. Called only for a physical button or Control Center: a person's own action.
    func remoteLibraryPress(_ control: LibraryControl) async
}

/// A podcast episode the player is on, as the remote layer needs it.
struct RemoteEpisode: Equatable {
    let videoID: String
    let show: String?
    let back: Int
    let forward: Int
}
/// The W18 podcast controls as the remote layer sees them.
@MainActor protocol RemoteEpisodeControlling: AnyObject {
    func remoteEpisode(for videoID: String) -> RemoteEpisode?
    func remoteJump(forward: Bool) async -> Bool
    func remoteSetRate(_ rate: Double, for episode: RemoteEpisode) async -> Bool
}
extension PodcastPlaybackModel: RemoteEpisodeControlling {
    func remoteEpisode(for videoID: String) -> RemoteEpisode? {
        guard let current, current.videoID == videoID else { return nil }
        return RemoteEpisode(videoID: videoID, show: current.show, back: skip.back, forward: skip.forward)
    }
    func remoteJump(forward: Bool) async -> Bool { forward ? await skipForward() : await skipBack() }
    func remoteSetRate(_ rate: Double, for episode: RemoteEpisode) async -> Bool {
        guard let show = episode.show else { return false }
        return await setRate(rate, forShow: show)
    }
}

/// The sentences that say why a remote command is off.
enum RemoteCommandReason {
    static var advertisement: String { String(localized: "An advertisement is playing. It cannot be skipped or sought.") }
    static var restored: String { String(localized: "This item is waiting where you left it. Press Play first.") }
    static var noQueue: String { String(localized: "YouTube Music has no next or previous item here.") }
    static var notSeekable: String { String(localized: "This item cannot be sought right now.") }
    static var liveWindow: String { String(localized: "This live stream offers no earlier part to seek to.") }
    static var notEpisode: String { String(localized: "Jumps and speed are for podcast episodes.") }
    static var episodeUnknownShow: String { String(localized: "This episode’s show is not known, so its speed cannot be changed.") }
    static var noLibrary: String { String(localized: "Library changes are not available here.") }
    static var ownedMedia: String { String(localized: "This is your own audio or a local file, not a YouTube Music song, so it has no like or save.") }
    static var noDislike: String { String(localized: "YouTube Music does not offer Dislike for this song.") }
    static var noSave: String { String(localized: "YouTube Music did not offer Save to Library for this song. Open the song once to read its page.") }
}

extension PlaybackModel {
    /// What the system's commands should offer, and what a command that arrives is held to. Pure over the live state.
    func remoteCapabilities() -> RemoteCapabilities {
        if music == nil, session != nil { return nativeRemoteCapabilities() }
        guard let player = music, !player.isClosed, player.snapshot.phase != .idle else { return .none }
        let s = player.snapshot
        var enabled: Set<RemoteCommandKind> = [.play, .pause, .toggle]
        var reasons: [RemoteCommandKind: String] = [:]
        var capabilities = RemoteCapabilities(hasItem: true)
        // Skipping and seeking are the UI's own conditions (`WebMusicSnapshot.canSkip` / `canSeek`): an ad, a restored item and a missing
        // playlist turn them off in the transport bar, and they are off here for the same reason.
        if s.canSkip { enabled.formUnion([.next, .previous]) }
        else { let why = s.isAd ? RemoteCommandReason.advertisement : s.restored ? RemoteCommandReason.restored : RemoteCommandReason.noQueue; reasons[.next] = why; reasons[.previous] = why }
        if s.canSeek { enabled.insert(.seek) }
        else { reasons[.seek] = s.isAd ? RemoteCommandReason.advertisement : s.restored ? RemoteCommandReason.restored : s.isLive ? RemoteCommandReason.liveWindow : RemoteCommandReason.notSeekable }
        // Podcast episodes: the W18 jumps and speed, through the podcast model, only for the episode that is playing.
        if let id = s.videoID, let episode = episodes?.remoteEpisode(for: id) {
            capabilities.skipBack = episode.back; capabilities.skipForward = episode.forward
            if s.canSeek { enabled.formUnion([.skipBackward, .skipForward]) }
            else { let why = s.isAd ? RemoteCommandReason.advertisement : s.restored ? RemoteCommandReason.restored : RemoteCommandReason.notSeekable; reasons[.skipBackward] = why; reasons[.skipForward] = why }
            if s.isAd { reasons[.changeRate] = RemoteCommandReason.advertisement }
            else if episode.show == nil { reasons[.changeRate] = RemoteCommandReason.episodeUnknownShow }
            else if !s.canSeek { reasons[.changeRate] = s.restored ? RemoteCommandReason.restored : RemoteCommandReason.notSeekable }
            else { enabled.insert(.changeRate); capabilities.rates = PodcastRate.steps }
        } else {
            for kind in [RemoteCommandKind.skipBackward, .skipForward, .changeRate] { reasons[kind] = RemoteCommandReason.notEpisode }
        }
        // Like, dislike and save: only where the library ledger has a real write path for this song, and never during an ad.
        for kind in [RemoteCommandKind.like, .dislike, .save] {
            if s.isAd { reasons[kind] = RemoteCommandReason.advertisement; continue }
            guard let library = remoteLibrary else { reasons[kind] = RemoteCommandReason.noLibrary; continue }
            switch library.remoteLibraryControl(kind) {
            case .available(let control): enabled.insert(kind); if control.isOn { capabilities.active.insert(kind) }
            case .unavailable(let why): reasons[kind] = why
            }
        }
        capabilities.enabled = enabled; capabilities.reasons = reasons
        return capabilities
    }
    private func nativeRemoteCapabilities() -> RemoteCapabilities {
        var enabled: Set<RemoteCommandKind> = [.play, .pause, .toggle, .next, .previous]
        var reasons: [RemoteCommandKind: String] = [:]
        if timeline.snapshot?.media?.userSeekable == true { enabled.insert(.seek) } else { reasons[.seek] = RemoteCommandReason.notSeekable }
        for kind in [RemoteCommandKind.skipBackward, .skipForward, .changeRate] { reasons[kind] = RemoteCommandReason.notEpisode }
        for kind in [RemoteCommandKind.like, .dislike, .save] { reasons[kind] = RemoteCommandReason.ownedMedia }
        return RemoteCapabilities(hasItem: true, enabled: enabled, reasons: reasons)
    }
    /// Re-tells the system which commands are on and which buttons show as on (a ledger change made anywhere, in any window, changes the Like button).
    func refreshRemoteCapabilities() { if nowPlaying.isActive { nowPlaying.setCapabilities(remoteCapabilities()) } }
    /// Why a command is off right now, for any surface that wants to say so. Nil when it is on, or nothing is loaded.
    func remoteReason(_ kind: RemoteCommandKind) -> String? {
        let capabilities = remoteCapabilities()
        return capabilities.hasItem && !capabilities.enabled.contains(kind) ? capabilities.reasons[kind] : nil
    }
}
