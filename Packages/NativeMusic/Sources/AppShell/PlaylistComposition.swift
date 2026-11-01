import AccountSession
import Domain
import Features
import Foundation

extension LocalAccountBootstrap {
    /// The playlist editing surface. Reads are the real signed `browse` for the active account through the account coordinator (same
    /// scope fence, allowlist and caps as every other read; an anonymous answer is refused, because an anonymous page publishes no edit
    /// affordance and must never read as "not editable"); changes are the explicit single actions the person asks for, through the
    /// editing session. Under the Debug development flag the labelled development playlists answer instead, and a UI-automation launch
    /// without it never reaches the network.
    func makePlaylistSurface() -> PlaylistSurface {
        let service: any PlaylistServing
        var signedIn: @MainActor () -> SearchPlayback = { [unowned self] in searchPlayback }
        var development = false
        #if DEBUG
        if DevelopmentPlaylists.enabled {
            development = true
            service = DevelopmentPlaylists.shared; signedIn = { .available }
        } else if Self.automationIsolated(ProcessInfo.processInfo.environment) {
            service = ClosurePlaylistService(read: { _ in throw MusicSessionError.policy }, apply: { _ in throw MusicSessionError.policy }, listing: { throw MusicSessionError.policy })
        } else {
            service = livePlaylistService()
        }
        #else
        service = livePlaylistService()
        #endif
        let scope: @MainActor () -> String = { [unowned self] in searchScopeToken }
        let creator = PlaylistCreator(service: service, accountScope: scope, signedIn: signedIn)
        creator.startingVisibility = { [unowned self] in MusicPlaylistPrivacy(rawValue: settings.text("newPlaylistVisibility").uppercased()) ?? PlaylistCreator.defaultPrivacy }
        let joiner = PlaylistJoiner(service: service, accountScope: scope, signedIn: signedIn)
        return PlaylistSurface(creator: creator, joiner: joiner, makeSession: { id in PlaylistEditSession(playlistID: id, service: service, accountScope: scope, signedIn: signedIn) },
                               performer: searchPerformer, playback: signedIn, development: development, choices: { try await service.listing() })
    }

    private func livePlaylistService() -> ClosurePlaylistService {
        let pacer = ContinuationPacer()
        let source = PlaylistPageSource(
            page: { [weak self] id in
                guard let self else { throw MusicSessionError.stale }
                let reply = try await self.awaitedMusic().browse(id: id)
                guard reply.mode == .signedIn else { throw MusicSessionError.signedOut }
                return reply.value
            },
            continuation: { [weak self] token in
                guard let self else { throw MusicSessionError.stale }
                try await pacer.wait(scope: await self.searchScopeToken)
                let reply = try await self.awaitedMusic().continuation(token: token)
                guard reply.mode == .signedIn else { throw MusicSessionError.signedOut }
                return reply.value
            })
        return ClosurePlaylistService(
            read: { id in try await PlaylistSnapshotReader.read(playlistID: id, source: source) },
            apply: { [weak self] request in
                guard let self else { throw MusicSessionError.stale }
                return try await self.awaitedMusic().editPlaylist(request)
            },
            listing: { [weak self] in
                guard let self else { throw MusicSessionError.stale }
                return try await Self.readListing(self, pacer: pacer)
            },
            suggestions: { token in try await PlaylistSnapshotReader.readSuggestions(token: token, source: source) })
    }
    /// The person's whole playlist list (a read), page by page. A list that could not be read to its end is an error, never a shorter list:
    /// "absent from the list" is evidence only when the list is complete.
    private static func readListing(_ bootstrap: LocalAccountBootstrap, pacer: ContinuationPacer) async throws -> [PlaylistListing] {
        var result: [PlaylistListing] = [], seen = Set<String>(), tokens = Set<String>()
        func take(_ items: [MusicCatalogItem]) {
            for item in items where item.kind == .playlist {
                guard let browse = item.browseID else { continue }
                let id = MusicPlaylistRequest.playlistID(fromBrowseID: browse)
                if seen.insert(id).inserted { result.append(PlaylistListing(playlistID: id, title: item.title)) }
            }
        }
        let first = try await bootstrap.awaitedMusic().library(id: MusicLibraryKind.playlists.browseID)
        guard first.mode == .signedIn else { throw MusicSessionError.signedOut }
        take(first.value.shelves.flatMap(\.items))
        var next = first.value.continuation ?? first.value.shelves.compactMap(\.continuation).first
        var pages = 1
        while let token = next {
            guard tokens.insert(token).inserted, pages < 40 else { throw MusicSessionError.unrecognised }
            pages += 1
            try await pacer.wait(scope: await bootstrap.searchScopeToken)
            let more = try await bootstrap.awaitedMusic().libraryContinuation(token: token)
            guard more.mode == .signedIn else { throw MusicSessionError.signedOut }
            take(more.value.items + more.value.shelves.flatMap(\.items))
            next = more.value.continuation ?? more.value.shelves.compactMap(\.continuation).first
        }
        return result
    }
}
