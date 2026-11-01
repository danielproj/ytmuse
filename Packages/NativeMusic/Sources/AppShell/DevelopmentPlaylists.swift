#if DEBUG
import AccountSession
import Features
import Foundation

/// Debug-only, labelled development playlists for the isolated UI tests of playlist editing, behind the same service seam the live
/// account uses. It exists only when `YTMUSE_UI_DEVELOPMENT_DATA=1`, `YTMUSE_UI_DEVELOPMENT_PLAYLISTS=1` and QA isolation are all set, the
/// screens label it "Development data · Not YouTube Music", and no Release build contains it. It is not a capture of the service, it
/// performs no network request, and it changes nothing anywhere but its own memory: it only answers like a service would, including
/// when a collaborator changes a playlist, a reply is lost, or a change is refused.
enum DevelopmentPlaylists {
    static var enabled: Bool { isEnabled(ProcessInfo.processInfo.environment) }
    static func isEnabled(_ environment: [String: String]) -> Bool {
        DevelopmentSearch.isEnabled(environment) && environment["YTMUSE_UI_DEVELOPMENT_PLAYLISTS"] == "1"
    }
    static let shared = DevelopmentPlaylistService()
    /// The invite link's join token the development service honours, for the playlist `joinable`.
    static let joinToken = "DEVJOINTOKEN0001"
    static let joinable = "PLdevjoinable00001"
    static let mix = "PLdevmix000000001", undoFails = "PLdevundofails0001", lostReply = "PLdevlostreply001", busy = "PLdevbusy00000001", shared_ = "PLdevshared000001", publicList = "PLdevpublic000001"
}

actor DevelopmentPlaylistService: PlaylistServing {
    struct Row: Equatable { var setVideoID: String; var videoID: String; var title: String }
    enum Role { case owner, collaborator, viewer }
    enum Rule { case none, refuseAdds, loseFirstAddReply, collaboratorMovesFirst(title: String) }
    struct Entry { var title: String; var details = ""; var privacy: MusicPlaylistPrivacy = .private; var role: Role; var rows: [Row]; var rule: Rule = .none; var reads = 0; var lostOnce = false }
    private var lists: [String: Entry] = [:]
    private var order: [String] = []
    private var counter = 100

    init() {
        func rows(_ names: [(String, String)]) -> [Row] { names.enumerated().map { Row(setVideoID: "DEV\($0.offset)", videoID: $0.element.0, title: $0.element.1) } }
        let songs: [(String, String)] = [("devsong0001", "Café del Mar"), ("devsong0001", "Café del Mar"), ("devsong0002", "Noche Cálida"), ("devsong0003", "Zeta Song"),
                                          ("devsong0004", "Late Song"), ("devsong0005", "Last Song"), ("devsong0006", "Quiet Song")]
        var seeded: [String: Entry] = [:], seededOrder: [String] = []
        func add(_ id: String, _ entry: Entry) { seeded[id] = entry; seededOrder.append(id) }
        add(DevelopmentPlaylists.mix, Entry(title: "Dev Mix", role: .owner, rows: rows(songs)))
        add(DevelopmentPlaylists.undoFails, Entry(title: "Undo Fails Mix", role: .owner, rows: rows(songs.suffix(5).map { ($0.0, $0.1) }), rule: .refuseAdds))
        add(DevelopmentPlaylists.lostReply, Entry(title: "Lost Reply Mix", role: .owner, rows: rows(Array(songs.prefix(3))), rule: .loseFirstAddReply))
        add(DevelopmentPlaylists.busy, Entry(title: "Busy Mix", role: .owner,
                                             rows: rows([("devbusy0001", "Busy Song 1"), ("devbusy0002", "Busy Song 2"), ("devbusy0003", "Busy Song 3"), ("devbusy0004", "Busy Song 4")]),
                                             rule: .collaboratorMovesFirst(title: "Busy Song 2")))
        add(DevelopmentPlaylists.shared_, Entry(title: "Shared Mix", privacy: .public, role: .collaborator, rows: rows(Array(songs.prefix(3)))))
        add(DevelopmentPlaylists.publicList, Entry(title: "Public Picks", privacy: .public, role: .viewer, rows: rows(Array(songs.prefix(3)))))
        // A collaborative playlist the person can join by invite link; it is not in their library until they do.
        seeded[DevelopmentPlaylists.joinable] = Entry(title: "Joinable Mix", privacy: .public, role: .viewer, rows: rows(Array(songs.prefix(2))))
        lists = seeded; order = seededOrder
    }
    private func add(_ id: String, _ entry: Entry) { lists[id] = entry; order.append(id) }

    // MARK: Pages (what the catalog and library readers show)

    private func item(_ row: Row, in id: String, editable: Bool) -> MusicCatalogItem {
        MusicCatalogItem(kind: .song, title: row.title, details: ["Development Artist"], videoID: row.videoID, contextPlaylistID: id, occurrenceID: row.setVideoID,
                         controls: editable ? MusicItemControls(playlistRemoval: MusicPlaylistRowRemoval(playlistID: id, videoID: row.videoID, setVideoID: row.setVideoID)) : nil)
    }
    private func editing(_ entry: Entry) -> MusicPlaylistEditing? {
        switch entry.role {
        case .owner: MusicPlaylistEditing(canEditTracks: true, canEditDetails: true, canDelete: true, privacy: entry.privacy)
        case .collaborator: MusicPlaylistEditing(canEditTracks: true, canEditDetails: false, canDelete: false, privacy: entry.privacy)
        case .viewer: nil
        }
    }
    func page(for browseID: String) -> MusicBrowsePage? {
        let id = MusicPlaylistRequest.playlistID(fromBrowseID: browseID)
        guard let entry = lists[id] else { return nil }
        let items = entry.rows.map { item($0, in: id, editable: entry.role != .viewer) }
        var accounting = MusicParseAccounting()
        accounting.sections = 1; accounting.shelves = 1; accounting.items = items.count; accounting.classified = items.count
        let header = MusicPageHeader(title: entry.title, subtitle: ["Playlist"], secondSubtitle: ["\(items.count) songs"], byline: "Development Owner",
                                     description: entry.details.isEmpty ? [] : [MusicTextRun(text: entry.details)], actions: MusicPageActions(play: id), editing: editing(entry))
        return MusicBrowsePage(header: header, shelves: [MusicShelf(key: "list:" + id, title: nil, layout: .list, items: items)], accounting: accounting)
    }
    func libraryPage() -> MusicBrowsePage {
        let items = order.compactMap { id -> MusicCatalogItem? in
            guard let entry = lists[id] else { return nil }
            return MusicCatalogItem(kind: .playlist, title: entry.title, details: ["Playlist", "\(entry.rows.count) songs"], serviceLabel: "Playlist", browseID: "VL" + id, playlistID: id)
        }
        var accounting = MusicParseAccounting()
        accounting.sections = 1; accounting.shelves = 1; accounting.items = items.count; accounting.classified = items.count
        return MusicBrowsePage(shelves: [MusicShelf(key: "grid:playlists", title: nil, layout: .grid, items: items)], accounting: accounting)
    }

    // MARK: PlaylistServing

    func read(playlistID: String) async throws -> PlaylistSnapshot {
        guard var entry = lists[playlistID] else { throw MusicSessionError.unrecognised }
        entry.reads += 1
        // A collaborator moves a song to the end just before the person's change reads the playlist (the second read of this playlist).
        if case .collaboratorMovesFirst(let title) = entry.rule, entry.reads == 2, let index = entry.rows.firstIndex(where: { $0.title == title }) {
            entry.rows.append(entry.rows.remove(at: index))
        }
        lists[playlistID] = entry
        let occurrences = entry.rows.map { PlaylistOccurrence(setVideoID: $0.setVideoID, videoID: $0.videoID, title: $0.title, subtitle: "Development Artist", removable: entry.role != .viewer) }
        // The service's own suggestions for an editable playlist: nothing is added from them unless the person presses Add.
        let suggestions = entry.role == .viewer ? [] : [
            MusicCatalogItem(kind: .song, title: "Suggested Song", details: ["Development Artist"], videoID: "devsugg0001"),
            MusicCatalogItem(kind: .song, title: "Noche Cálida", details: ["Development Artist"], videoID: "devsong0002")]
        return PlaylistSnapshot(playlistID: playlistID, title: entry.title, details: entry.details, privacy: entry.role == .viewer ? nil : entry.privacy, occurrences: occurrences,
                                editing: editing(entry), isSaved: entry.role == .viewer ? false : nil, isComplete: true, suggestions: suggestions)
    }
    func listing() async throws -> [PlaylistListing] { order.compactMap { id in lists[id].map { PlaylistListing(playlistID: id, title: $0.title) } } }

    func apply(_ request: MusicPlaylistRequest) async throws -> MusicPlaylistReply {
        try await Task.sleep(for: .milliseconds(1200))
        func reply(_ outcome: MusicWriteOutcome, id: String? = nil, added: [MusicPlaylistAddedOccurrence] = []) -> MusicPlaylistReply {
            MusicPlaylistReply(result: MusicPlaylistOutcome(outcome: outcome, createdPlaylistID: id, added: added), accountGeneration: 0)
        }
        switch request {
        case .create(let title, let description, let privacy, _):
            counter += 1
            let id = "PLdevcreated\(String(format: "%06d", counter))"
            add(id, Entry(title: title, details: description ?? "", privacy: privacy, role: .owner, rows: []))
            return reply(.confirmed, id: id)
        case .delete(let id):
            lists[id] = nil; order.removeAll { $0 == id }
            return reply(.confirmed)
        case .edit(let id, let actions):
            if actions.count == 1, case .joinCollaboration(let token)? = actions.first {
                guard var viewer = lists[id], viewer.role == .viewer, id == DevelopmentPlaylists.joinable, token == DevelopmentPlaylists.joinToken else { return reply(.rejected(.service)) }
                viewer.role = .collaborator; lists[id] = viewer; if !order.contains(id) { order.append(id) }
                return reply(.confirmed)
            }
            guard var entry = lists[id], entry.role != .viewer else { return reply(.rejected(.service)) }
            let adds = actions.contains { if case .add = $0 { true } else { false } }
            if adds, case .refuseAdds = entry.rule { return reply(.rejected(.service)) }
            // Collaboration requests are single actions. Joining turns a viewer into a collaborator (and lists the playlist); the others are the owner's.
            if let only = actions.first, actions.count == 1 {
                switch only {
                case .createInviteLink:
                    guard entry.role == .owner else { return reply(.rejected(.service)) }
                    var link = URLComponents()
                    link.scheme = "https"; link.host = "music.youtube.com"; link.path = "/playlist"
                    link.queryItems = [URLQueryItem(name: "list", value: id), URLQueryItem(name: "jct", value: DevelopmentPlaylists.joinToken)]
                    return MusicPlaylistReply(result: MusicPlaylistOutcome(outcome: .confirmed, inviteLink: link.string), accountGeneration: 0)
                case .closeToContributions:
                    guard entry.role == .owner else { return reply(.rejected(.service)) }
                    return reply(.confirmed)
                case .joinCollaboration: return reply(.rejected(.service))
                default: break
                }
            }
            var rows = entry.rows, added: [MusicPlaylistAddedOccurrence] = []
            for action in actions {
                switch action {
                case .add(let video, let mode):
                    // The service's own rule (ytmusicapi/Kaset): without DEDUPE_OPTION_SKIP a song already there refuses the whole add.
                    if mode == .skipExisting, rows.contains(where: { $0.videoID == video }) { return reply(.rejected(.service)) }
                    counter += 1
                    let set = "NEW\(counter)"
                    rows.append(Row(setVideoID: set, videoID: video, title: Self.title(for: video, in: lists))); added.append(.init(videoID: video, setVideoID: set))
                case .remove(let video, let set):
                    guard let index = rows.firstIndex(where: { $0.setVideoID == set }), rows[index].videoID == video else { return reply(.rejected(.service)) }
                    rows.remove(at: index)
                case .moveBefore(let set, let successor):
                    guard let from = rows.firstIndex(where: { $0.setVideoID == set }) else { return reply(.rejected(.service)) }
                    let row = rows.remove(at: from)
                    if let successor, let to = rows.firstIndex(where: { $0.setVideoID == successor }) { rows.insert(row, at: to) } else { rows.append(row) }
                case .rename(let title):
                    if title == "Refuse" { return reply(.rejected(.service)) }
                    entry.title = title
                case .describe(let text): entry.details = text
                case .setPrivacy(let privacy): entry.privacy = privacy
                case .createInviteLink, .closeToContributions, .joinCollaboration: return reply(.rejected(.service))
                }
            }
            entry.rows = rows
            let loseReply: Bool = { if adds, case .loseFirstAddReply = entry.rule, !entry.lostOnce { return true } else { return false } }()
            if loseReply { entry.lostOnce = true }
            lists[id] = entry
            return reply(loseReply ? .indeterminate(.noAnswer) : .confirmed, added: added)
        }
    }
    private static func title(for video: String, in lists: [String: Entry]) -> String {
        if video == "devsugg0001" { return "Suggested Song" }
        for entry in lists.values { if let row = entry.rows.first(where: { $0.videoID == video }) { return row.title } }
        return "Added Song"
    }
}
#endif
