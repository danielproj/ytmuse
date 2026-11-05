import AccountSession
import AppKit
import Features
import Foundation
import Persistence
import SystemIntegration
import Playback
import Domain

/// Search actions land on the one application playback session: the same
/// `playMusic` the Library's Play uses, with the permit captured at the action.
@MainActor final class AppSearchPerformer: SearchActionPerformer {
    private let playback: PlaybackModel
    private let pasteboard: NSPasteboard
    /// Where Share… on an item or page opens its sheet: the shell's facility (the system sheet in a normal launch, a recording stand-in under isolation).
    private let sharing: (@MainActor () -> any SharingPresenting)?
    init(playback: PlaybackModel, pasteboard: NSPasteboard = .general, sharing: (@MainActor () -> any SharingPresenting)? = nil) {
        self.playback = playback; self.pasteboard = pasteboard; self.sharing = sharing
    }
    func share(link: URL) -> Bool {
        // Only a canonical Music link is ever handed to the sheet, whatever the caller built.
        guard let sharing, case .success(.item(let item)) = LinkPolicy.parse(link), CanonicalLink.url(for: item) == link else { return false }
        return sharing().present(link)
    }
    func play(playlistID: String, title: String) async -> SearchPlayOutcome {
        let request = playback.authority.requestOwnedStart()
        return await playback.playMusic(playlistID: playlistID, title: title, request: request)
    }
    func play(playlistID: String, title: String, videoID: String?, params: String?) async -> SearchPlayOutcome {
        let request = playback.authority.requestOwnedStart()
        return await playback.playMusic(playlistID: playlistID, title: title, videoID: videoID, params: params, request: request)
    }
    func play(playlistID: String, title: String, videoID: String?, params: String?, intent: MusicPlaybackIntent) async -> SearchPlayOutcome {
        let request = playback.authority.requestOwnedStart()
        return await playback.playMusic(playlistID: playlistID, title: title, videoID: videoID, params: params, intent: intent, request: request)
    }
    var supportsRadioQueueUpdates: Bool { true }
    // A scope is issued only for the existing owner. No start permit or player creation.
    private var radioScope: (id: UUID, player: WebMusicPlayer, scope: WebMusicRadioQueueScope, starts: Int, epoch: UInt64)?
    func captureRadioQueueScope(playlistID: String) -> UUID? {
        guard !playback.starting, playback.session == nil, let player = playback.music,
              let scope = player.captureRadioQueueScope(playlistID: playlistID) else { return nil }
        let id = UUID()
        radioScope = (id, player, scope, playback.playRequestCount, playback.authority.currentRadioControlEpoch())
        return id
    }
    func radioQueueScopeIsCurrent(_ id: UUID) -> Bool {
        guard let saved = radioScope, saved.id == id, !playback.starting,
              playback.session == nil, playback.music === saved.player,
              playback.playRequestCount == saved.starts, playback.authority.currentRadioControlEpoch() == saved.epoch else { return false }
        return saved.player.radioQueueScopeIsCurrent(saved.scope)
    }
    func applyRadioFilter(_ command: MusicQueueFilterCommand, scope id: UUID) async -> SearchPlayOutcome {
        guard radioQueueScopeIsCurrent(id), let saved = radioScope else { return .stale }
        let applied = await saved.player.applyRadioFilter(command, scope: saved.scope) { [weak self] in
            self?.radioQueueScopeIsCurrent(id) == true
        }
        guard radioQueueScopeIsCurrent(id) else { return .stale }
        return applied ? .started : .failed
    }
    func playRadioFilter(_ command: MusicQueueFilterCommand, title: String) async -> SearchPlayOutcome { .failed }
    func copy(link: URL) {
        pasteboard.clearContents()
        pasteboard.setString(link.absoluteString, forType: .string)
    }
    func copy(text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

extension LocalAccountBootstrap {
    /// A token that changes whenever the active account, or whether its session is live, changes.
    var searchScopeToken: String {
        "\(model.active?.accountID.uuidString ?? "none")|\(model.activeConnected)|\(model.activeExpired)"
    }
    var searchPlayback: SearchPlayback {
        if model.usesMusicSession && model.activeConnected { return .available }
        return model.activeExpired ? .sessionExpired : .needsSignIn
    }
    /// One search model per window. The service request is the real Music `search`: signed
    /// for the active account, anonymous otherwise. Under the Debug development-data flag
    /// the labelled development catalog answers instead, never a stand-in for the service.
    /// One recents bucket per account (or "none" before sign-in), in the app preferences store (a throwaway plist under isolation).
    var searchRecentsKey: String { model.active?.accountID.uuidString ?? "none" }
    func makeSearchModel() -> SearchModel {
        let performer = searchPerformer
        let recents = SearchRecents(defaults: AppPreferences.store, scope: { [unowned self] in searchRecentsKey })
        #if DEBUG
        if DevelopmentSearch.enabled {
            let model = SearchModel(sources: [DevelopmentSearch.librarySource()], remote: DevelopmentSearch.remote, performer: performer,
                                    accountScope: { [unowned self] in searchScopeToken }, playback: { [unowned self] in searchPlayback }, recents: recents)
            return model
        }
        #endif
        let library = LibraryPlaylistSearchSource { [unowned self] in
            if case .signedIn(let proof) = model.proof { return proof.library.playlists }
            return []
        }
        return SearchModel(sources: [library], remote: searchRemote, performer: performer,
                           accountScope: { [unowned self] in searchScopeToken }, playback: { [unowned self] in searchPlayback }, recents: recents)
    }
}
