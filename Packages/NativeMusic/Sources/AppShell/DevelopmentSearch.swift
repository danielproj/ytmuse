#if DEBUG
import AccountSession
import Features
import Foundation

/// Debug-only, labelled development data for the isolated UI tests: a small synthetic
/// catalog behind the same `RemoteSearch` seam the service uses. It exists only when
/// `YTMUSE_UI_DEVELOPMENT_DATA=1` is set on an isolated launch, the Search view labels
/// it "Development data · Not YouTube Music", and no Release build contains it.
enum DevelopmentSearch {
    /// Both the flag and QA isolation are required: the catalog can never stand in for the service on a launch
    /// that has the person's real store, account or session.
    static var enabled: Bool { isEnabled(ProcessInfo.processInfo.environment) }
    static func isEnabled(_ environment: [String: String]) -> Bool {
        environment["YTMUSE_UI_DEVELOPMENT_DATA"] == "1" && IsolatedQAStorage.requested(environment)
    }
    /// Library playlists the development local source offers.
    static let library: [MusicLibraryPlaylist] = [
        .init(id: "PLdevelopmentCafe", title: "Café Mix (development)", countText: "12 songs", itemCount: 12),
        .init(id: "PLdevelopmentFocus", title: "Évening Focus (development)", countText: "30 songs", itemCount: 30),
    ]
    @MainActor static func librarySource() -> LibraryPlaylistSearchSource { LibraryPlaylistSearchSource { library } }

    private static let catalog: [MusicSearchItem] = [
        .init(kind: .song, title: "Café del Mar", details: ["Development Artist", "Development Album", "3:45"], videoID: "devsong0001"),
        .init(kind: .song, title: "Noche Cálida", details: ["Development Artist", "Development Album", "4:02"], explicit: true, videoID: "devsong0002"),
        .init(kind: .video, title: "Café del Mar (Development Video)", details: ["Development Artist", "1.2M views", "3:50"], videoID: "devvideo001"),
        .init(kind: .album, title: "Development Album", details: ["Development Artist", "2019"], serviceLabel: "Album", browseID: "MPREbdevelopment1", playlistID: "OLAK5uydevelopment1"),
        .init(kind: .artist, title: "Development Artist", details: [], browseID: "UCdevelopmentartist00000000"),
        .init(kind: .playlist, title: "Café Collection (development)", details: ["Development", "50 songs"], browseID: "VLPLdevelopmentpl1", playlistID: "PLdevelopmentpl1"),
        .init(kind: .podcast, title: "Cafe Talk (development)", details: ["Development Host"], browseID: "MPSPPLdevelopmentshow", playlistID: "PLdevelopmentshow"),
        .init(kind: .episode, title: "Brewing music (development)", details: ["Oct 5, 2025", "Cafe Talk"], videoID: "devepisode01"),
        .init(kind: .album, title: "Sin Camino", details: ["Development Artist", "2021"], serviceLabel: "Single", browseID: "MPREbdevelopment2"),
    ]
    @Sendable static func remote(_ query: String) async throws -> MusicSearchReply {
        let parsed = FoldedQuery(query)
        let matches = catalog.filter { parsed.match($0.title) != nil }
        let suggestion = parsed.match("café del mar") == nil && SearchText.fold(query).hasPrefix("cafe del m") ? MusicSearchSuggestion(text: "Café del Mar", appliedByService: false) : nil
        guard !matches.isEmpty || suggestion != nil else {
            return MusicSearchReply(response: MusicSearchResponse(top: nil, items: [], suggestion: nil, skippedRows: 0, serviceReportedNoResults: true), mode: .anonymous, accountGeneration: 0)
        }
        return MusicSearchReply(response: MusicSearchResponse(top: matches.first, items: Array(matches.dropFirst()), suggestion: suggestion, skippedRows: 0), mode: .anonymous, accountGeneration: 0)
    }
}
#endif
