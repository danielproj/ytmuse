import AccountSession
import CryptoKit
import Domain
import Features
import Foundation
import Testing
@testable import YouTubeMusicAdapter

// MARK: Fixtures (W13: synthetic-from-real-renderers, and the real captures they are made from)

func fixturesRoot() -> URL {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    return root.appendingPathComponent("Fixtures")
}
func w13Data(_ name: String) throws -> Data { try Data(contentsOf: fixturesRoot().appendingPathComponent("W13/" + name)) }
func w13(_ name: String) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: try w13Data(name)) as? [String: Any] else { throw MusicSessionError.unrecognised }
    return object
}
func w13Real(_ name: String) throws -> Data { try Data(contentsOf: fixturesRoot().appendingPathComponent("W13-real/" + name)) }
func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func playlistPage(_ name: String) throws -> MusicBrowsePage { try MusicBrowseParser.parse(try w13(name)) }

// MARK: A scripted signed service: nothing here reaches a network

actor ScriptedSigned: SignedMusicTransport {
    private(set) var requests: [URLRequest] = []
    var body: Data
    var status: Int
    var type: String?
    var failure: (any Error)?
    init(body: Data = Data("{}".utf8), status: Int = 200, type: String? = "application/json; charset=UTF-8", failure: (any Error)? = nil) {
        self.body = body; self.status = status; self.type = type; self.failure = failure
    }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> SignedMusicWireResponse {
        try SignedMusicPolicy.validate(request, maximumBytes: maximumBytes)
        requests.append(request)
        if let failure { throw failure }
        return .init(status: status, body: body, contentType: type)
    }
    func captured() -> [URLRequest] { requests }
}
struct FixedNow: WallClock { func now() -> Date { Date(timeIntervalSince1970: 1_700_000_000) } }
func testSession() throws -> MusicCookieSession {
    func cookie(_ name: String, _ value: String) -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: value, .domain: ".youtube.com", .path: "/", .expires: Date(timeIntervalSince1970: 1_700_000_000 + 86_400)])!
    }
    return try MusicCookieSession(accountID: UUID(), cookies: [cookie("SAPISID", "SYNTHETIC-SAPISID-VALUE"), cookie("SID", "SYNTHETIC-SID-VALUE")], now: Date(timeIntervalSince1970: 1_700_000_000))
}
func signedClient(_ transport: ScriptedSigned) -> SignedMusicClient { SignedMusicClient(transport: transport, clock: FixedNow()) { "1.20261028.01.00" } }
func requestBody(_ request: URLRequest) throws -> [String: Any] {
    guard let data = request.httpBody, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MusicSessionError.unrecognised }
    return object
}

// MARK: Deterministic randomness (property tests are seeded, never random between runs)

struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: A fake remote playlist (the service's behaviour, in memory)

/// The service as the editing session sees it: ordered occurrences with ids of the service's own making, paged reads whose cursors
/// expire when the playlist changes, atomic edits, and faults a test can inject. It is the oracle of the property tests, and it
/// answers like the service does (a lost reply is `indeterminate`), never by throwing after it applied something.
actor FakePlaylistRemote: PlaylistServing {
    struct Row: Equatable { var setVideoID: String; var videoID: String; var title: String }
    enum Fault {
        /// Applied, but the reply never arrives.
        case lostReplyAfterApplying
        /// The request is lost on the way: not applied, and no reply.
        case lostReplyBeforeApplying
        /// Only the first `count` actions are applied, then the reply is lost.
        case partialThenLost(count: Int)
        /// The service answers with something the app cannot read, after applying.
        case unreadableAfterApplying
        case refuse
        case offline
        /// The call is cancelled while in flight, after the service applied it: the app cannot know.
        case cancelledAfterApplying
    }
    let playlistID: String
    var rows: [Row]
    var title = "Fixture playlist"
    var details = ""
    var privacy: MusicPlaylistPrivacy? = .private
    var editing: MusicPlaylistEditing? = MusicPlaylistEditing(canEditTracks: true, canEditDetails: true, canDelete: true, privacy: .private)
    var pageSize = 4
    var counter = 5000
    var version = 0
    /// Every request the service was given (a measurement: a test asserts what was sent, not what was meant).
    private(set) var received: [MusicPlaylistRequest] = []
    private(set) var readCalls = 0
    var faults: [Fault] = []
    var failReads = 0
    var failListing = false
    /// Runs after a read returns and before the next call: simulates a change made elsewhere (a collaborator, another device).
    var afterRead: [@Sendable (isolated FakePlaylistRemote) -> Void] = []
    /// Runs while a paged read is between pages.
    var betweenPages: (@Sendable (isolated FakePlaylistRemote, Int) -> Void)?
    var listed: [PlaylistListing] = []
    private(set) var deleted = false
    /// The service's suggested songs (read through the page's section-list token, never members) and whether reading them fails.
    var suggested: [MusicCatalogItem] = []
    var failSuggestions = false
    private(set) var suggestionReads = 0
    /// What a collaboration request answers: the join token the invite link carries.
    static let joinToken = "JOINTOKEN12345678"
    private(set) var contributionsClosed = false
    func setSuggested(_ items: [MusicCatalogItem]) { suggested = items }
    func setFailSuggestions(_ value: Bool) { failSuggestions = value }
    private var holdReadNumber: Int?
    private var heldRead: CheckedContinuation<Void, Never>?
    var isReadHeld: Bool { heldRead != nil }
    /// Holds the n-th read (counting the first load as 1) after it has been taken, until `releaseRead`.
    func holdRead(number n: Int) { holdReadNumber = n }
    func releaseRead() { heldRead?.resume(); heldRead = nil }
    private var holdNext = false
    private var held: CheckedContinuation<Void, Never>?
    var isHeld: Bool { held != nil }
    func holdNextApply() { holdNext = true }
    func release() { held?.resume(); held = nil }

    init(playlistID: String = "PLfixture0000000000000000000000001", rows: [Row]) { self.playlistID = playlistID; self.rows = rows }
    static func rows(_ videos: [String]) -> [Row] { videos.enumerated().map { Row(setVideoID: "S\($0.offset)", videoID: $0.element, title: "Song " + $0.element) } }
    static func video(_ n: Int) -> String { "vid" + String(format: "%08d", n) }

    struct State: Equatable {
        var rows: [Row]; var ids: [String]; var title: String; var details: String; var privacy: MusicPlaylistPrivacy?
        var requests: [MusicPlaylistRequest]; var deleted: Bool
        func count(of video: String) -> Int { rows.filter { $0.videoID == video }.count }
        /// The edit actions of the last request that carried any.
        var lastActions: [MusicPlaylistEditAction] { for request in requests.reversed() { if case .edit(_, let actions) = request { return actions } }; return [] }
    }
    /// Everything a test asserts about the service, read in one hop so expectations stay synchronous.
    func state() -> State { State(rows: rows, ids: ids(), title: title, details: details, privacy: privacy, requests: received, deleted: deleted) }
    func setFaults(_ list: [Fault]) { faults = list }
    func failNextReads(_ count: Int) { failReads = count }
    func setAfterRead(_ hooks: [@Sendable (isolated FakePlaylistRemote) -> Void]) { afterRead = hooks }
    func setBetweenPages(_ hook: (@Sendable (isolated FakePlaylistRemote, Int) -> Void)?) { betweenPages = hook }
    func setEditing(_ value: MusicPlaylistEditing?) { editing = value }
    func setPageSize(_ n: Int) { pageSize = n }
    func setListed(_ items: [PlaylistListing]) { listed = items }
    func setFailListing(_ value: Bool) { failListing = value }
    func ids() -> [String] { rows.map(\.setVideoID) }
    func order() -> [String] { rows.map { "\($0.setVideoID)=\($0.videoID)" } }
    func requests() -> [MusicPlaylistRequest] { received }

    // Remote changes made "elsewhere" (not by the session under test)
    func remoteMove(_ id: String, before successor: String?) {
        guard let from = rows.firstIndex(where: { $0.setVideoID == id }) else { return }
        let row = rows.remove(at: from)
        if let successor, let to = rows.firstIndex(where: { $0.setVideoID == successor }) { rows.insert(row, at: to) } else { rows.append(row) }
        version += 1
    }
    func remoteRemove(_ id: String) { rows.removeAll { $0.setVideoID == id }; version += 1 }
    func remoteAdd(_ video: String) -> String { counter += 1; let id = "R\(counter)"; rows.append(Row(setVideoID: id, videoID: video, title: "Song " + video)); version += 1; return id }
    func remoteRename(_ new: String) { title = new; version += 1 }
    func remoteSetPrivacy(_ new: MusicPlaylistPrivacy) { privacy = new; version += 1 }

    // MARK: Reads (paged, through the real snapshot reader)

    nonisolated func readSuggestions(token: String) async throws -> [MusicCatalogItem] { try await suggestionsAnswer(token) }
    private func suggestionsAnswer(_ token: String) throws -> [MusicCatalogItem] {
        suggestionReads += 1
        if failSuggestions { throw MusicSessionError.unrecognised }
        guard token == "sug-token" else { throw MusicSessionError.unrecognised }
        return suggested
    }
    nonisolated func read(playlistID: String) async throws -> PlaylistSnapshot {
        let source = PlaylistPageSource(page: { _ in try await self.firstPage() }, continuation: { try await self.nextPage($0) })
        let snapshot = try await PlaylistSnapshotReader.read(playlistID: playlistID, source: source)
        await self.finishedRead()
        return snapshot
    }
    private func finishedRead() async {
        readCalls += 1
        if holdReadNumber == readCalls { holdReadNumber = nil; await withCheckedContinuation { heldRead = $0 } }
        guard !afterRead.isEmpty else { return }
        let hook = afterRead.removeFirst()
        hook(self)
    }
    private func item(_ row: Row) -> MusicCatalogItem {
        MusicCatalogItem(kind: .song, title: row.title, details: ["Artist"], videoID: row.videoID, occurrenceID: row.setVideoID,
                         controls: editing?.canEditTracks == true
                            ? MusicItemControls(playlistRemoval: MusicPlaylistRowRemoval(playlistID: playlistID, videoID: row.videoID, setVideoID: row.setVideoID)) : nil)
    }
    private func firstPage() throws -> MusicBrowsePage {
        if failReads > 0 { failReads -= 1; throw MusicSessionError.network }
        let slice = Array(rows.prefix(pageSize))
        let more = rows.count > pageSize ? "cur-\(version)-\(pageSize)" : nil
        // Like the service, an editable playlist page also carries the section list's own token: it reloads the SUGGESTIONS, not the tracks.
        let sectionToken = editing?.canEditTracks == true ? "sug-token" : nil
        var header = MusicPageHeader(title: title, description: details.isEmpty ? [] : [MusicTextRun(text: details)], editing: editing.map { var e = $0; e.privacy = privacy; return e })
        header.actions = MusicPageActions()
        return MusicBrowsePage(header: header, shelves: [MusicShelf(key: "list:playlist", title: nil, layout: .list, items: slice.map(item), continuation: more)], continuation: sectionToken)
    }
    private func nextPage(_ token: String) throws -> MusicContinuationPage {
        if failReads > 0 { failReads -= 1; throw MusicSessionError.network }
        let parts = token.split(separator: "-")
        guard parts.count == 3, parts[0] == "cur", let issued = Int(parts[1]), let offset = Int(parts[2]) else { throw MusicSessionError.unrecognised }
        betweenPages?(self, offset)
        // A cursor issued before the playlist changed is no longer honoured, as the service does for a stale continuation.
        guard issued == version else { throw MusicSessionError.unrecognised }
        let slice = Array(rows.dropFirst(offset).prefix(pageSize))
        let next = offset + pageSize < rows.count ? "cur-\(version)-\(offset + pageSize)" : nil
        return MusicContinuationPage(items: slice.map(item), shelves: [], continuation: next)
    }

    // MARK: Writes

    func apply(_ request: MusicPlaylistRequest) async throws -> MusicPlaylistReply {
        received.append(request)
        if holdNext { holdNext = false; await withCheckedContinuation { held = $0 } }
        let fault = faults.isEmpty ? nil : faults.removeFirst()
        func reply(_ outcome: MusicWriteOutcome, id: String? = nil, added: [MusicPlaylistAddedOccurrence] = []) -> MusicPlaylistReply {
            MusicPlaylistReply(result: MusicPlaylistOutcome(outcome: outcome, createdPlaylistID: id, added: added), accountGeneration: 0)
        }
        switch fault {
        case .offline?: throw MusicSessionError.network
        case .refuse?: return reply(.rejected(.service))
        case .lostReplyBeforeApplying?: return reply(.indeterminate(.noAnswer))
        default: break
        }
        switch request {
        case .create(let title, _, let privacy, let videos):
            let id = "PLcreated\(String(format: "%026d", listed.count + 1))"
            listed.append(PlaylistListing(playlistID: id, title: title))
            _ = (privacy, videos)
            if case .lostReplyAfterApplying? = fault { return reply(.indeterminate(.noAnswer)) }
            return reply(.confirmed, id: id)
        case .delete:
            deleted = true
            listed.removeAll { $0.playlistID == playlistID }
            if case .lostReplyAfterApplying? = fault { return reply(.indeterminate(.noAnswer)) }
            return reply(.confirmed)
        case .edit(_, let actions) where actions.count == 1 && actions[0].isCollaborationAction:
            switch actions[0] {
            case .createInviteLink:
                guard editing?.canDelete == true else { return reply(.rejected(.service)) }
                if case .lostReplyAfterApplying? = fault { return reply(.indeterminate(.noAnswer)) }
                return MusicPlaylistReply(result: MusicPlaylistOutcome(outcome: .confirmed, inviteLink: "https://music.youtube.com/playlist?list=\(playlistID)&jct=\(Self.joinToken)"), accountGeneration: 0)
            case .closeToContributions:
                guard editing?.canDelete == true else { return reply(.rejected(.service)) }
                contributionsClosed = true
                if case .lostReplyAfterApplying? = fault { return reply(.indeterminate(.noAnswer)) }
                return reply(.confirmed)
            case .joinCollaboration(let token):
                guard editing == nil, token == Self.joinToken else { return reply(.rejected(.service)) }
                editing = MusicPlaylistEditing(canEditTracks: true, canEditDetails: false, canDelete: false, privacy: nil)
                version += 1
                if case .lostReplyAfterApplying? = fault { return reply(.indeterminate(.noAnswer)) }
                return reply(.confirmed)
            default: return reply(.rejected(.service))
            }
        case .edit(_, let actions):
            var limit = actions.count
            if case .partialThenLost(let count)? = fault { limit = min(count, actions.count) }
            guard let added = applyAtomically(Array(actions.prefix(limit))) else { return reply(.rejected(.service)) }
            switch fault {
            case .cancelledAfterApplying?: throw CancellationError()
            case .lostReplyAfterApplying?, .partialThenLost?: return reply(.indeterminate(.noAnswer))
            case .unreadableAfterApplying?: return reply(.indeterminate(.unrecognisedAnswer))
            default: return reply(.confirmed, added: added)
            }
        }
    }
    /// All actions or none. nil: the service refuses (an occurrence it does not have, a mismatched video).
    private func applyAtomically(_ actions: [MusicPlaylistEditAction]) -> [MusicPlaylistAddedOccurrence]? {
        var rows = self.rows, title = self.title, details = self.details, privacy = self.privacy
        var added: [MusicPlaylistAddedOccurrence] = [], counter = self.counter
        for action in actions {
            switch action {
            case .add(let video, let mode):
                // The service's rule (ytmusicapi add_playlist_items, Kaset): the duplicate check is on unless DEDUPE_OPTION_SKIP is sent
                // (`.keepDuplicates`); a song already there then refuses the WHOLE add and nothing is added.
                if mode == .skipExisting, rows.contains(where: { $0.videoID == video }) { return nil }
                counter += 1
                let id = "A\(counter)"
                rows.append(Row(setVideoID: id, videoID: video, title: "Song " + video)); added.append(.init(videoID: video, setVideoID: id))
            case .remove(let video, let set):
                guard let index = rows.firstIndex(where: { $0.setVideoID == set }), rows[index].videoID == video else { return nil }
                rows.remove(at: index)
            case .moveBefore(let set, let successor):
                guard let from = rows.firstIndex(where: { $0.setVideoID == set }) else { return nil }
                if let successor, !rows.contains(where: { $0.setVideoID == successor }) { return nil }
                let row = rows.remove(at: from)
                if let successor, let to = rows.firstIndex(where: { $0.setVideoID == successor }) { rows.insert(row, at: to) } else { rows.append(row) }
            case .rename(let new): title = new
            case .describe(let text): details = text
            case .setPrivacy(let value): privacy = value
            case .createInviteLink, .closeToContributions, .joinCollaboration: return nil
            }
        }
        if rows != self.rows || title != self.title || details != self.details || privacy != self.privacy { version += 1 }
        self.rows = rows; self.title = title; self.details = details; self.privacy = privacy; self.counter = counter
        return added
    }

    nonisolated func listing() async throws -> [PlaylistListing] { try await listedForCheck() }
    private func listedForCheck() throws -> [PlaylistListing] {
        if failListing { throw MusicSessionError.network }
        return listed
    }
}

@MainActor func settle(_ rounds: Int = 40) async { for _ in 0..<rounds { await Task.yield() } }

/// An editing session over a fake remote, loaded.
@MainActor func loadedSession(_ remote: FakePlaylistRemote, scope: @escaping @MainActor () -> String = { "scope-1" }) async -> PlaylistEditSession {
    let session = PlaylistEditSession(playlistID: remote.playlistID, service: remote, accountScope: scope)
    await session.load()
    return session
}

extension MusicPlaylistEditAction {
    var isCollaborationAction: Bool {
        switch self { case .createInviteLink, .closeToContributions, .joinCollaboration: true; default: false }
    }
}
