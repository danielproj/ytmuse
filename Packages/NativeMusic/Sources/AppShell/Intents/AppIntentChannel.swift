import AccountSession
import Domain
import Features
import Foundation
import OutputRoutes
import Playback
import SystemIntegration

// W24 (MAC03, ARCH03, ARCH09). The app's side of the intent command channel.
//
// This is the only place an App Intent meets the app, and it holds no logic of its own that a window click does not also run: playback goes
// through `PlaybackModel.remote(_:)` (the media keys' entry: capabilities, ad refusal, Play here, Now Playing) and `playMusic` (the search and
// library Play), rating and saving through the same `remote(.setLike/.setSave)` -> W12 ledger path, Show Queue through the shell. Nothing here
// opens a network request of its own; entity candidates are read from models the windows already filled.

/// What the channel needs from the running app. The production conformer is `LocalAccountBootstrap`; tests supply their own over real models.
@MainActor protocol IntentAppSurface: AnyObject {
    var playback: PlaybackModel { get }
    /// Bringing the app's own windows forward. The production conformer is the shell; a test records the calls and opens nothing.
    func showPlayerWindow()
    func showQueuePanel()
    /// Has a window run the search; false when none could (the intent then says so).
    func performSearch(_ text: String) async -> Bool
    /// The live session's account and generation, or nil when nobody is connected.
    func liveScope() async -> IntentScope?
    func awaitStartup() async
    /// Whether playing is possible for this account right now (signed in, session live).
    var playbackReadiness: SearchPlayback { get }
    /// Library collections' loaded rows (never triggers a read).
    func loadedRows(_ kind: MusicLibraryKind) -> [MusicCatalogItem]
    /// Radios the service presented for entries the person has met while browsing (never triggers a read).
    func meetSeeds() -> [RadioSeed]
}

@MainActor final class AppIntentChannel: IntentCommandChannel {
    private unowned let surface: any IntentAppSurface
    private var playback: PlaybackModel { surface.playback }
    init(surface: any IntentAppSurface) { self.surface = surface }

    func awaitReady() async { await surface.awaitStartup() }
    func currentScope() async -> IntentScope? {
        guard let scope = await surface.liveScope() else { return nil }
        if case .available = surface.playbackReadiness { return scope }
        return nil
    }

    // MARK: Candidates (existing models and caches only)

    func candidates(kind: IntentMediaKind?, matching text: String?, limit: Int) async -> [IntentMedia] {
        guard let scope = await currentScope() else { return [] }
        var found: [IntentMedia] = []
        func add(_ media: IntentMedia?) { if let media, kind == nil || kind == media.kind { found.append(media) } }
        let sources: [(MusicLibraryKind, IntentMediaKind)] = [(.songs, .song), (.likedSongs, .song), (.albums, .album), (.artists, .artist), (.following, .artist), (.playlists, .playlist)]
        for (library, mediaKind) in sources where kind == nil || kind == mediaKind {
            for item in surface.loadedRows(library) { add(Self.media(from: item, kind: mediaKind, scope: scope)) }
        }
        if kind == nil || kind == .mix {
            for seed in surface.meetSeeds() { add(Self.media(from: seed, scope: scope)) }
        }
        var unique: [IntentMedia] = [], seen = Set<String>()
        for media in found where seen.insert(media.identity).inserted { unique.append(media) }
        if let text, !text.isEmpty {
            let wanted = IntentResolver.fold(text)
            unique = unique.filter { IntentResolver.fold($0.title).contains(wanted) || IntentResolver.fold($0.subtitle ?? "").contains(wanted) }
        }
        return Array(unique.prefix(max(1, limit)))
    }
    /// A playable entity from a catalog row, or nil when the row published nothing to start (private media, an artist with no radio, a title only).
    static func media(from item: MusicCatalogItem, kind: IntentMediaKind, scope: IntentScope) -> IntentMedia? {
        let artist = item.links.first { $0.kind == .artist }?.title ?? item.details.first
        switch kind {
        case .song:
            guard item.kind == .song || item.kind == .video, let target = CatalogActionPlan.target(for: item) else { return nil }
            return IntentMedia(scope: scope, kind: .song, title: item.title, subtitle: artist, target: IntentMediaTarget(videoID: target.videoID ?? item.videoID, playlistID: target.playlistID, params: target.params))
        case .album, .playlist:
            guard item.kind == (kind == .album ? .album : .playlist), let target = CatalogActionPlan.target(for: item) else { return nil }
            return IntentMedia(scope: scope, kind: kind, title: item.title, subtitle: item.details.first, target: IntentMediaTarget(playlistID: target.playlistID, browseID: item.browseID, params: target.params))
        case .artist:
            guard item.kind == .artist, let radio = item.radio else { return nil }
            return IntentMedia(scope: scope, kind: .artist, title: item.title, subtitle: nil, target: IntentMediaTarget(videoID: radio.videoID, playlistID: radio.playlistID, browseID: item.browseID, params: radio.params))
        case .mix:
            return nil
        }
    }
    static func media(from seed: RadioSeed, scope: IntentScope) -> IntentMedia? {
        IntentMedia(scope: scope, kind: .mix, title: seed.title, subtitle: seed.subtitle, target: IntentMediaTarget(videoID: seed.videoID, playlistID: seed.id, params: seed.params))
    }

    // MARK: Commands

    /// Each command meets exactly the gates the window's own control meets. The live YouTube Music session is required only by what starts YouTube
    /// Music or carries an entity of an account: owned and local media, the transport, the windows, Search (anonymous when signed out, as in the
    /// window) and the sleep timer work with no session, as the media keys do.
    func perform(_ command: IntentCommand) async -> IntentOutcome {
        switch command {
        case .resume: return dispatch(.play, done: String(localized: "Playing."))
        case .pause: return dispatch(.pause, done: String(localized: "Paused."))
        case .toggle: return dispatch(.toggle, done: String(localized: "Done."))
        case .next: return dispatch(.next, done: String(localized: "Skipping to the next item."))
        case .previous: return dispatch(.previous, done: String(localized: "Going back."))
        case .seek(let position):
            guard position.isFinite, position >= 0 else { return .refused(.unavailable(String(localized: "Choose a position within the item."))) }
            return dispatch(.seek(position), done: String(localized: "Seeking."))
        case .play(let media):
            // The start permit FIRST, then the scope: a permit captured after the scope was read could be minted for an account that took over in between,
            // and would let the old account's item start under the new account's player. Captured first, an account barrier anywhere after it rejects the start.
            let request = playback.authority.requestOwnedStart()
            guard let scope = await currentScope() else { return .refused(.signedOut) }
            return await play(media, scope: scope, request: request)
        case .playSearch(let query):
            let request = playback.authority.requestOwnedStart()   // before the scope is read, as for `play`
            guard let scope = await currentScope() else { return .refused(.signedOut) }
            // Only an item that can actually be started takes part, so a spoken name never lands on something that would then refuse.
            let playable = await candidates(kind: nil, matching: nil, limit: 500).filter { $0.target.playlistID != nil }
            // This invocation's own fence (DATA03): the session it started in must still be the live one after the awaits above. Nothing is shared with
            // other intents, so a concurrent intent can neither widen nor shorten it.
            guard await currentScope() == scope else { return .refused(.staleIdentity) }
            switch IntentResolver.resolve(query, among: playable) {
            case .none: return .refused(.notFound)
            case .many(let options): return .refused(.ambiguous(options))
            case .one(let media): return await play(media, scope: scope, request: request)
            }
        case .search(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.utf8.count <= 512 else { return .refused(.unavailable(String(localized: "Say what to search for."))) }
            guard await surface.performSearch(trimmed) else {
                return .refused(.failed(String(localized: "These words were not searched: no YTMuse window could take them, or a newer search replaced them. Open YTMuse and try again.")))
            }
            return .done(String(localized: "Searching."))
        case .rate(let rating, let media):
            var scope: IntentScope?
            if media != nil { guard let live = await currentScope() else { return .refused(.signedOut) }; scope = live }
            return rate(rating, of: media, scope: scope)
        case .save(let media):
            var scope: IntentScope?
            if media != nil { guard let live = await currentScope() else { return .refused(.signedOut) }; scope = live }
            return save(of: media, scope: scope)
        case .showQueue: surface.showQueuePanel(); return .done(String(localized: "Showing the queue."))
        case .showPlayer: surface.showPlayerWindow(); return .done(String(localized: "Showing the player."))
        case .sleepTimer(let timer): return await sleepTimer(timer)
        }
    }

    /// One transport command through the same admission the media keys use. The reason a command is off is the window's own sentence.
    private func dispatch(_ command: RemoteTransportCommand, done: String) -> IntentOutcome {
        let engine: OutputEngineKind = playback.music != nil ? .youTubeMusic : .localMedia
        let startsSound = [.play, .toggle, .next, .previous].contains(command.kind)
        let promptHeld = startsSound && playback.outputs?.lossPending(for: engine) == true
        switch playback.remote(command) {
        case .success:
            if promptHeld { return needsPlayHere() }
            return .done(done)
        case .noActionableItem: return .refused(.nothingPlaying)
        case .refused:
            let reason = playback.remoteReason(command.kind) ?? String(localized: "That isn’t available right now.")
            return .refused(reason == RemoteCommandReason.advertisement ? .advertisement : .unavailable(reason))
        }
    }
    /// A route was lost: the app asks "Play here?" in its own window and nothing sounds until it is answered. The intent says so.
    private func needsPlayHere() -> IntentOutcome {
        surface.showPlayerWindow()
        return .refused(.needsConfirmation(String(localized: "Your audio output changed. Confirm “Play here” in YTMuse to start playback.")))
    }

    private func play(_ media: IntentMedia, scope: IntentScope, request: OwnedStartRequest) async -> IntentOutcome {
        if let refusal = IntentResolver.admit(media, current: scope) { return .refused(refusal) }
        guard let playlistID = media.target.playlistID else { return .refused(.unavailable(String(localized: "YouTube Music gave this item nothing to play."))) }
        let held = playback.outputs?.lossPending(for: .youTubeMusic) == true
        // `request` was captured at the very start of the command (before the scope was read), exactly as a click captures it: an account barrier after it rejects the start.
        let outcome = await playback.playMusic(playlistID: playlistID, title: media.title, videoID: media.target.videoID, params: media.target.params, request: request)
        switch outcome {
        case .started: return held ? needsPlayHere() : .done(String(localized: "Playing \(media.title)."))
        case .stale: return .refused(.staleIdentity)
        // `playMusic` answers `.busy` both for a start already in progress and for a start the Play here prompt is holding.
        case .busy: return held ? needsPlayHere() : .refused(.failed(String(localized: "YTMuse is already starting something. Try again in a moment.")))
        case .failed: return .refused(.failed(playback.error ?? String(localized: "YouTube Music could not start. Try Play again.")))
        }
    }

    /// Like, dislike and Save act on the song that is playing, through the W12 ledger, never on an arbitrary entity: the control exists only for a
    /// song whose page was read and published it.
    private func isPlayingSong(_ media: IntentMedia?, scope: IntentScope?) -> IntentRefusal? {
        guard let media else { return nil }
        if let refusal = IntentResolver.admit(media, current: scope) { return refusal }
        guard media.kind == .song, let playing = playback.music?.snapshot.videoID, media.target.videoID == playing else {
            return .unavailable(String(localized: "YTMuse can like or save only the song that is playing."))
        }
        return nil
    }
    private func rate(_ rating: IntentRating, of media: IntentMedia?, scope: IntentScope?) -> IntentOutcome {
        if let refusal = isPlayingSong(media, scope: scope) { return .refused(refusal) }
        switch rating {
        case .like: return dispatch(.setLike(true), done: String(localized: "Asked YouTube Music to like this song."))
        case .dislike: return dispatch(.setDislike(true), done: String(localized: "Asked YouTube Music to dislike this song."))
        case .none:
            let active = playback.remoteCapabilities().active
            if active.contains(.like) { return dispatch(.setLike(false), done: String(localized: "Asked YouTube Music to remove the like.")) }
            if active.contains(.dislike) { return dispatch(.setDislike(false), done: String(localized: "Asked YouTube Music to remove the dislike.")) }
            return playback.remoteCapabilities().hasItem ? .done(String(localized: "This song has no rating to remove.")) : .refused(.nothingPlaying)
        }
    }
    private func save(of media: IntentMedia?, scope: IntentScope?) -> IntentOutcome {
        if let refusal = isPlayingSong(media, scope: scope) { return .refused(refusal) }
        return dispatch(.setSave(true), done: String(localized: "Asked YouTube Music to save this song to your library."))
    }

    /// The window's own sleep timer: the hidden YouTube Music player's (fade over its page volume, then pause) or the native session's (owned audio
    /// and downloads). Both are set through the same owner calls the window's menus make.
    private func sleepTimer(_ timer: IntentSleepTimer) async -> IntentOutcome {
        if let player = playback.music, !player.isClosed { return await musicSleepTimer(timer) }
        guard playback.session != nil else {
            return .refused(.unavailable(String(localized: "Nothing is playing, so there is no timer to set.")))
        }
        let held = playback.outputs?.lossPending(for: .localMedia) == true
        switch timer {
        case .off:
            await playback.act(action: .sleepTimer) { try await $0.setTimer(nil) }
            return playback.failedAction == .sleepTimer ? .refused(.failed(playback.error ?? PlaybackUIAction.sleepTimer.failure)) : .done(String(localized: "Sleep timer off."))
        case .endOfItem, .minutes:
            let value: SleepTimer
            if case .minutes(let minutes) = timer { value = [5, 15, 30, 60].contains(minutes) ? .minutes(minutes) : .custom(Double(minutes) * 60) } else { value = .endOfItem }
            await playback.nativeEnableTimer { await self.playback.act(action: .sleepTimer) { try await $0.setTimer(value) } }
            if held { return needsPlayHere() }
            if playback.failedAction == .sleepTimer { return .refused(.failed(playback.error ?? PlaybackUIAction.sleepTimer.failure)) }
            if case .minutes(let minutes) = timer { return .done(String(localized: "Sleep timer set for \(minutes) minutes.")) }
            return .done(String(localized: "Sleep timer set for the end of this item."))
        }
    }
    /// YouTube Music: the player fades its page's volume over 5 seconds at expiry (never during an advertisement) and pauses. End of item pauses at the
    /// boundary the page reports.
    private func musicSleepTimer(_ timer: IntentSleepTimer) async -> IntentOutcome {
        let value: SleepTimer?
        switch timer {
        case .off: value = nil
        case .endOfItem: value = .endOfItem
        case .minutes(let minutes): value = [5, 15, 30, 60].contains(minutes) ? .minutes(minutes) : .custom(Double(minutes) * 60)
        }
        switch await playback.setMusicSleepTimer(value) {
        case .refused(let reason): return .refused(.unavailable(reason.message))
        case .cleared: return .done(String(localized: "Sleep timer off."))
        case .set:
            if case .minutes(let minutes) = timer { return .done(String(localized: "Sleep timer set for \(minutes) minutes.")) }
            return .done(String(localized: "Sleep timer set for the end of this item."))
        }
    }
}

extension LocalAccountBootstrap: IntentAppSurface {
    func liveScope() async -> IntentScope? {
        await load()
        guard let scope = await playback.authority.activeScope() else { return nil }
        return IntentScope(accountID: scope.account, generation: scope.generation)
    }
    func awaitStartup() async { await load() }
    func showPlayerWindow() { shell.showMainWindow() }
    func showQueuePanel() { shell.showQueue() }
    func performSearch(_ text: String) async -> Bool { await shell.performSearch(text) }
    var playbackReadiness: SearchPlayback { searchPlayback }
    func loadedRows(_ kind: MusicLibraryKind) -> [MusicCatalogItem] { library.models[kind]?.entries.map(\.item) ?? [] }
    func meetSeeds() -> [RadioSeed] { discovery.tuner.seeds }

    /// Makes the running app answer App Intents (called once, by the production composition root).
    func installIntents(hub: IntentHub = .shared) { hub.install(AppIntentChannel(surface: self)) }
}
