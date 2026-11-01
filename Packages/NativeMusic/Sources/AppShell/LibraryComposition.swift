import AccountSession
import Domain
import Features
import Foundation

extension LocalAccountBootstrap {
    /// The Library and History screens' shared state. Reads are the real signed `browse` for the active account through the account
    /// coordinator (same scope fence, allowlist and caps as every other read); writes are the explicit single-item changes the
    /// person asks for, through one ledger. Under the Debug development flags the labelled development data answers instead, and
    /// a UI-automation launch without it never reaches the network.
    func makeLibrarySurface() -> LibrarySurface {
        let reader: LibraryCollectionModel.Reader
        let continuer: LibraryCollectionModel.Continuer
        let writer: LibraryWriteLedger.Writer
        var store: any LocalHistoryStoring = historyStore
        var accountKey: @MainActor () -> String? = { [unowned self] in model.active?.accountID.uuidString }
        var signedIn: @MainActor () -> SearchPlayback = { [unowned self] in searchPlayback }
        var development = false
        let pacer = ContinuationPacer()
        #if DEBUG
        if DevelopmentLibrary.enabled {
            development = true
            reader = DevelopmentLibrary.reader; continuer = DevelopmentLibrary.continuer; writer = DevelopmentLibrary.writer
            store = DevelopmentLocalHistory(); accountKey = { DevelopmentLibrary.accountKey }; signedIn = { .available }
        } else if Self.automationIsolated(ProcessInfo.processInfo.environment) {
            reader = { _ in throw MusicSessionError.policy }; continuer = { _ in throw MusicSessionError.policy }; writer = { _ in throw MusicSessionError.policy }
        } else {
            (reader, continuer, writer) = liveLibraryTransports(pacer: pacer)
        }
        #else
        (reader, continuer, writer) = liveLibraryTransports(pacer: pacer)
        #endif
        let scope: @MainActor () -> String = { [unowned self] in searchScopeToken }
        let check: LibraryWriteLedger.Reader
        if development { check = { @Sendable _ in nil } } else { check = liveLibraryCheck() }
        let ledger = LibraryWriteLedger(writer: writer, reader: check, accountScope: scope, signedIn: signedIn)
        var models: [MusicLibraryKind: LibraryCollectionModel] = [:]
        for kind in MusicLibraryKind.allCases {
            models[kind] = LibraryCollectionModel(source: LibrarySource(kind: kind), reader: reader, continuer: continuer, accountScope: scope,
                                                  onItems: { [weak ledger] items in for item in items { ledger?.observe(item: item) } })
        }
        let remote = LibraryCollectionModel(source: .history, reader: reader, continuer: continuer, accountScope: scope)
        let history = HistoryModel(remote: remote, store: store, policy: listeningPolicy, accountKey: accountKey)
        let surface = LibrarySurface(models: models, history: history, ledger: ledger, performer: searchPerformer, playback: signedIn, accountScope: scope, development: development)
        surface.uploads = makeUploadsSurface(library: surface, reader: reader, continuer: continuer, writer: writer, scope: scope, signedIn: signedIn,
                                             accountKey: accountKey, development: development)
        catalog.pageObserver = { [weak ledger] page in
            if let controls = page.header?.actions.controls { ledger?.observe(controls: controls) }
            for item in page.shelves.flatMap(\.items) { ledger?.observe(item: item) }
        }
        return surface
    }
    /// Real playback progress becomes local plays. Wired once, to the application's single playback owner.
    func connectListeningHistory(_ surface: LibrarySurface) {
        playback.listening = { [weak surface, weak self] snapshot in
            self?.discoveryObserves(snapshot)
            guard let history = surface?.history else { return }
            history.observe(ListeningObservation(
                videoID: snapshot.videoID, title: snapshot.title, artist: snapshot.artist, position: snapshot.position, duration: snapshot.duration,
                playing: snapshot.phase == .playing, buffering: snapshot.phase == .buffering, ended: snapshot.phase == .ended,
                content: snapshot.isAd ? .advertisement : (self?.isPreviewing(snapshot.videoID) == true ? .preview : .track), monotonic: ProcessInfo.processInfo.systemUptime, wall: Date()))
        }
    }
    private func liveLibraryTransports(pacer: ContinuationPacer) -> (LibraryCollectionModel.Reader, LibraryCollectionModel.Continuer, LibraryWriteLedger.Writer) {
        let reader: LibraryCollectionModel.Reader = { [weak self] source in
            guard let self else { throw MusicSessionError.stale }
            return try await self.awaitedMusic().library(id: source.browseID)
        }
        let continuer: LibraryCollectionModel.Continuer = { [weak self] token in
            guard let self else { throw MusicSessionError.stale }
            try await pacer.wait(scope: await self.searchScopeToken)
            return try await self.awaitedMusic().libraryContinuation(token: token)
        }
        let writer: LibraryWriteLedger.Writer = { [weak self] request in
            guard let self else { throw MusicSessionError.stale }
            return try await self.awaitedMusic().write(request)
        }
        return (reader, continuer, writer)
    }
    /// The read that settles an unconfirmed change (SYNC05): the artist's or the playlist's own page says whether it is followed or
    /// saved. A like and a saved song have no page of their own to read, so those say nothing and the check reports it cannot tell.
    private func liveLibraryCheck() -> LibraryWriteLedger.Reader {
        { [weak self] key in
            guard let self else { return nil }
            switch key {
            case .following(let channel):
                guard let reply = try? await self.awaitedMusic().browse(id: channel), reply.mode == .signedIn,
                      let value = reply.value.header?.actions.controls.follow?.isFollowing else { return nil }
                return .following(value)
            case .playlistSaved(let list):
                guard let reply = try? await self.awaitedMusic().browse(id: "VL" + list), reply.mode == .signedIn,
                      let value = reply.value.header?.actions.controls.save?.isSaved else { return nil }
                return .saved(value)
            case .episodeLater(let video):
                // The episode's own page says whether it is in "Episodes for Later".
                guard let reply = try? await self.awaitedMusic().episode(id: "MPED" + video), reply.mode == .signedIn, reply.value.videoID == video,
                      let later = reply.value.later else { return nil }
                return .saved(later.isSaved)
            case .rating, .songSaved: return nil
            }
        }
    }
}
