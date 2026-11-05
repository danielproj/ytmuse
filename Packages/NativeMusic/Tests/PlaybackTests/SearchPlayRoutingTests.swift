import AppKit
import Foundation
import Testing
import Domain
import AccountSession
import Features
@testable import Playback
@testable import AppShell

private func identity() throws -> (LocalIdentity, RequestContext) {
    let id = UUID()
    let context = try AccountContext(accountID: id, channelID: ID("UCsyntheticSearch"), region: "US")
    let account = try Account(id: id, serviceIdentity: ServiceID("UCsyntheticSearch"), context: context, displayName: "Synthetic Listener", credential: try CredentialReference("synthetic-ref"))
    return (LocalIdentity(account: account, state: .connected), RequestContext(account: context, accountGeneration: 4, requestGeneration: 0))
}
private func listID(_ url: URL?) -> String? {
    url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == "list" }?.value
}

/// Search's Play goes through the shared command layer to the one hidden player: the same
/// `playMusic` the Library uses, behind the account permit, never at launch or on typing.
@Suite @MainActor struct SearchPlayRoutingTests {
    private func rig(restore: Bool = true) async throws -> (AppPlaybackAuthority, PlaybackModel, PageLog, AppSearchPerformer, NSPasteboard, RequestContext) {
        let log = PageLog()
        let owner = AppPlaybackAuthority(makeMusicPage: { delegate in let page = FakeMusicPage(delegate: delegate); log.pages.append(page); return page })
        await owner.configureMusic { _ in FakeCookieSource() }
        let (who, context) = try identity()
        if restore { try await owner.restorePaused(who, context: context) }
        let model = PlaybackModel(authority: owner)
        let board = NSPasteboard(name: NSPasteboard.Name("local.native-music.test-" + UUID().uuidString))
        return (owner, model, log, AppSearchPerformer(playback: model, pasteboard: board), board, context)
    }
    private func result(_ kind: MusicSearchKind, _ target: SearchTarget, _ title: String = "Synthetic") -> SearchResult {
        SearchResult(kind: kind, title: title, subtitle: nil, badges: [.service], target: target, fromService: true)
    }
    @Test func playOnEachKindLoadsItsPlaylistInTheHiddenPlayerAfterAnExplicitAction() async throws {
        let (_, model, log, performer, _, _) = try await rig()
        #expect(log.pages.isEmpty, "restoring an account starts nothing")
        let search = SearchModel(performer: performer, playback: { .available })
        _ = search
        let cases: [(SearchResult, String)] = [
            (result(.song, SearchTarget(videoID: "aaaaaaaaaa1")), "RDAMVMaaaaaaaaaa1"),
            (result(.video, SearchTarget(videoID: "bbbbbbbbbb1")), "RDAMVMbbbbbbbbbb1"),
            (result(.album, SearchTarget(browseID: "MPREb_x", playlistID: "OLAK5uy_syntheticAlbum01")), "OLAK5uy_syntheticAlbum01"),
            (result(.playlist, SearchTarget(browseID: "VLPLsynthetic", playlistID: "PLsynthetic")), "PLsynthetic"),
            (result(.podcast, SearchTarget(browseID: "MPSPx", playlistID: "PLshow")), "PLshow"),
        ]
        for (item, expected) in cases {
            let playlist = try #require(SearchActionPlan.playlist(for: item))
            #expect(playlist == expected)
            let outcome = await performer.play(playlistID: playlist, title: item.title)
            #expect(outcome == .started)
        }
        let page = try #require(log.pages.first)
        #expect(log.pages.count == 1, "one hidden player for the one application session")
        #expect(listID(page.loads.first) == "RDAMVMaaaaaaaaaa1", "the first start is a full load of the song's radio seed")
        #expect(model.music != nil)
    }
    @Test func theSearchModelsReturnReachesThePlayerThroughTheSharedPath() async throws {
        let (_, _, log, performer, _, _) = try await rig()
        let search = SearchModel(performer: performer, playback: { .available })
        let item = result(.song, SearchTarget(videoID: "aaaaaaaaaa1"), "Seed song")
        await search.perform(.play, on: item)
        #expect(listID(log.pages.first?.loads.first) == "RDAMVMaaaaaaaaaa1")
        #expect(search.feedback[item.id] == .started)
    }
    @Test func aPermitCapturedByTheActionIsRefusedAfterAnAccountBarrier() async throws {
        let (owner, _, log, performer, _, context) = try await rig()
        let early = owner.requestOwnedStart()
        try await owner.detach(previous: context, barrier: RequestContext(account: nil, accountGeneration: 5, requestGeneration: 0))
        let model = PlaybackModel(authority: owner)
        let outcome = await model.playMusic(playlistID: "PLsynthetic", title: "x", request: early)
        #expect(outcome == .stale && log.pages.isEmpty)
        _ = performer
    }
    @Test func withNoConnectedAccountPlayFailsAtTheItemAndStartsNothing() async throws {
        let (_, model, log, performer, _, _) = try await rig(restore: false)
        let search = SearchModel(performer: performer, playback: { .available })
        let item = result(.song, SearchTarget(videoID: "aaaaaaaaaa1"))
        await search.perform(.play, on: item)
        #expect(log.pages.isEmpty && model.music == nil)
        #expect(search.feedback[item.id] == .failed(String(localized: "Your account changed before this started. Try Play again.")), "an authority with no connected account is reported at the item, not swallowed")
    }
    @Test func scopedControlUsesExistingOwnerAndAccountReplacementRefusesIt() async throws {
        let (owner, model, log, performer, _, context) = try await rig()
        _ = await performer.play(playlistID: "PLsynthetic", title: "Outgoing")
        let page = try #require(log.pages.first); page.commitLast()
        page.send(lifecycleState(playing: false, playlist: "PLsynthetic"))
        await model.music?.pause()
        func queue(_ id: String) -> [String: Any] {
            // The page's queue message leads with the playing item, marked current (the Nov 4 read-back contract); an unmarked list is rejected.
            ["type": "queue", "doc": 1, "load": 1, "videoId": lifecycleVideo,
             "items": "[{\"i\":\"" + lifecycleVideo + "\",\"t\":\"Now\",\"c\":true},{\"i\":\"" + id + "\",\"t\":\"Upcoming\"}]", "more": 0]
        }
        page.send(queue("bbbbbbbbbb1"))
        let scope = try #require(performer.captureRadioQueueScope(playlistID: "PLsynthetic"))
        let command = try #require(MusicQueueFilterCommand(playlistID: "RDATmZvkhnokW3Mw24", params: "opaque%3D", playerParams: "0gcJCW0At9Zurpe2"))
        let starts = model.playRequestCount, player = model.music, state = model.state, loads = page.loads.count
        let task = Task { await performer.applyRadioFilter(command, scope: scope) }
        for _ in 0..<100 where !page.commands.contains(where: { $0.body == WebMusicScripts.updateRadioQueue }) {
            try? await Task.sleep(for: .milliseconds(2))
        }
        await Task.yield(); await Task.yield()
        page.send(queue("cccccccccc1"))
        #expect(await task.value == .started)
        #expect(model.playRequestCount == starts && model.music === player && model.session == nil)
        #expect(model.state == nil && state == nil && page.loads.count == loads && model.music?.snapshot.intent == false)
        let sent = try #require(page.commands.last { $0.body == WebMusicScripts.updateRadioQueue })
        #expect(sent.arguments["params"] as? String == command.params && sent.arguments["playerParams"] as? String == command.playerParams)
        try await owner.detach(previous: context, barrier: RequestContext(account: nil, accountGeneration: 5, requestGeneration: 0))
        let count = page.commands.count
        #expect(await performer.applyRadioFilter(command, scope: scope) == .stale)
        #expect(page.commands.count == count)
    }
    @Test func aLocalMediaOwnerOrPendingNewStartRefusesCachedRadioControls() async throws {
        let (_, model, log, performer, _, _) = try await rig()
        _ = await performer.play(playlistID: "PLsynthetic", title: "Radio")
        let page = try #require(log.pages.first); page.commitLast()
        page.send(lifecycleState(playlist: "PLsynthetic"))
        page.send(["type": "queue", "doc": 1, "load": 1, "videoId": lifecycleVideo, "items": "[]", "more": 0])
        let scope = try #require(performer.captureRadioQueueScope(playlistID: "PLsynthetic"))
        let command = try #require(MusicQueueFilterCommand(playlistID: "RDfetch", params: "p"))
        let count = page.commands.count, starts = model.playRequestCount
        model.starting = true
        #expect(await performer.applyRadioFilter(command, scope: scope) == .stale)
        model.starting = false
        let local = try await ownedSession(wall: ManualWall(), clock: ManualMonotonic())
        model.session = local
        #expect(await performer.applyRadioFilter(command, scope: scope) == .stale)
        #expect(model.playRequestCount == starts && page.commands.count == count)
        await local.close()
    }
    @Test func copyLinkWritesToTheSuppliedPasteboardOnly() async throws {
        let (_, _, _, performer, board, _) = try await rig()
        performer.copy(link: URL(string: "https://music.youtube.com/watch?v=aaaaaaaaaa1")!)
        #expect(board.string(forType: .string) == "https://music.youtube.com/watch?v=aaaaaaaaaa1")
        board.releaseGlobally()
    }
}
