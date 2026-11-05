#if DEBUG
import Testing
import Foundation
import AccountSession
import Features
@testable import AppShell

/// W20: how the application composes Samples, the tuner, Recap, badges and the social surface. Isolated storage only; nothing here
/// plays, signs in or reaches a network.
@Suite(.serialized) @MainActor struct DiscoveryCompositionTests {
    private func withBootstrap(_ environment: [String: String], _ body: (LocalAccountBootstrap) async throws -> Void) async throws {
        let bootstrap = LocalAccountBootstrap(environment: environment)
        let storage = try #require(bootstrap.isolatedStorage)
        do { try await body(bootstrap) } catch { await storage.destroy(); throw error }
        await storage.destroy()
    }
    private let live = ["YTMUSE_UI_TEST_ISOLATED": "1"]
    private let development = ["YTMUSE_UI_TEST_ISOLATED": "1", "YTMUSE_UI_DEVELOPMENT_DATA": "1", "YTMUSE_UI_DEVELOPMENT_LIBRARY": "1", "YTMUSE_UI_DEVELOPMENT_DISCOVERY": "1"]

    @Test func theApplicationsOwnSourcesAreUnresolvedAndSayWhyNothingIsSimulated() async throws {
        try await withBootstrap(live) { bootstrap in
            let discovery = bootstrap.discovery
            #expect(!discovery.development)
            guard case .unresolved(let reason) = discovery.samples.state else { Issue.record("Samples must be unresolved, not \(discovery.samples.state)"); return }
            #expect(reason.contains("Samples aren’t available yet"))
            guard case .unresolved = discovery.summaries.recap, case .unresolved = discovery.summaries.badges else { Issue.record("Recap and badges must be unresolved"); return }
            #expect(discovery.tuner.capability == .noRadio && discovery.tuner.seeds.isEmpty)
            let social = bootstrap.social
            guard case .unresolved = social.state(SocialSubject(kind: .song, id: "vid00000001", title: "x")) else { Issue.record("comments must be unresolved"); return }
            #expect(!social.development && bootstrap.discoveryReadout == nil)
        }
    }
    @Test func theSocialRoleCheckAgreesWithTheLibraryAboutBeingSignedIn() async throws {
        try await withBootstrap(live) { bootstrap in
            #expect(bootstrap.social.isSignedIn == false, "no account: signed out, so every social action is denied")
            #expect(bootstrap.social.songRole() == .signedOut)
        }
        var library = live
        library["YTMUSE_UI_DEVELOPMENT_DATA"] = "1"; library["YTMUSE_UI_DEVELOPMENT_LIBRARY"] = "1"
        try await withBootstrap(library) { bootstrap in
            #expect(bootstrap.social.isSignedIn, "the labelled development library is signed in, as its playlists and invitations are")
            #expect(!bootstrap.social.development, "and comments stay unresolved without the discovery flag")
            guard case .unresolved = bootstrap.social.state(SocialSubject(kind: .song, id: "vid00000001", title: "x")) else { Issue.record("comments must stay unresolved"); return }
        }
    }
    @Test func nothingStartsWhenTheSurfacesAreMadeOrLoaded() async throws {
        try await withBootstrap(live) { bootstrap in
            let discovery = bootstrap.discovery
            await discovery.samples.load(); await discovery.summaries.loadRecap(); await discovery.summaries.loadBadges()
            #expect(discovery.arbiter.active == nil)
            #expect(discovery.samples.readCount == 0 && discovery.summaries.readCount == 0, "an unresolved source is never read")
            #expect(bootstrap.playback.music == nil, "no hidden player was created")
        }
    }
    @Test func theDevelopmentSourcesAppearOnlyWithAllTheFlags() async throws {
        for missing in ["YTMUSE_UI_DEVELOPMENT_DATA", "YTMUSE_UI_DEVELOPMENT_LIBRARY", "YTMUSE_UI_DEVELOPMENT_DISCOVERY"] {
            var environment = development; environment[missing] = nil
            try await withBootstrap(environment) { bootstrap in
                #expect(!bootstrap.discovery.development, "without \(missing)")
                guard case .unresolved = bootstrap.discovery.samples.state else { Issue.record("expected unresolved without \(missing)"); return }
            }
        }
    }
    @Test func theDevelopmentSurfaceIsLabelledAndPreviewsHandOffThroughTheScriptedSessionOnly() async throws {
        try await withBootstrap(development) { bootstrap in
            let discovery = bootstrap.discovery
            #expect(discovery.development)
            await discovery.samples.load()
            #expect(discovery.samples.clips.count == 2)
            await discovery.samples.preview("devclip00001")
            #expect(bootstrap.discoveryReadout?().contains("preview=devclip00001") == true)
            await discovery.samples.preview("devclip00002")
            #expect(bootstrap.discoveryReadout?().contains("preview=devclip00002") == true && bootstrap.discoveryReadout?().contains("overlap=0") == true)
            await discovery.samples.play("devclip00002")
            #expect(bootstrap.discoveryReadout?().contains("preview=none") == true && bootstrap.discoveryReadout?().contains("handoffs=1") == true)
            #expect(bootstrap.playback.music == nil, "the scripted player is not the hidden player")
        }
    }
    @Test func pinnedConditionsKeepDevelopmentPreviewsFromStartingByThemselves() async throws {
        var environment = development; environment["YTMUSE_UI_PREVIEW_CONDITIONS"] = "lowpower"
        try await withBootstrap(environment) { bootstrap in
            let discovery = bootstrap.discovery
            await discovery.samples.load()
            await discovery.samples.focus("devclip00001")
            #expect(discovery.arbiter.active == nil && discovery.arbiter.autoplayRefusal == .lowPowerMode)
            await discovery.samples.preview("devclip00001")
            #expect(discovery.arbiter.active == "devclip00001")
        }
    }
    @Test func theDevelopmentRadioSeedsStartRadiosThroughTheScriptedSessionAndSuppliedControlsAppear() async throws {
        try await withBootstrap(development) { bootstrap in
            let tuner = bootstrap.discovery.tuner
            #expect(tuner.seeds.count == 2)
            await tuner.start(tuner.seeds[0])
            #expect(tuner.context != nil && tuner.controls.map(\.id) == ["devmix"])
            await tuner.choose(option: "devdiscover", in: "devmix", suppliedBy: tuner.controlsIdentity)
            #expect(tuner.context?.choices == ["devmix": "devdiscover"])
        }
    }
    @Test func aScopeChangeClearsTheDiscoveryAndSocialState() async throws {
        try await withBootstrap(development) { bootstrap in
            let discovery = bootstrap.discovery
            await discovery.samples.load()
            await discovery.samples.preview("devclip00001")
            discovery.accountChanged(); bootstrap.social.accountChanged()
            await discovery.arbiter.stop(.requested)
            #expect(discovery.samples.state == .idle && discovery.arbiter.active == nil && discovery.tuner.seeds.isEmpty)
        }
    }

    // MARK: Comments (C3)

    private final class ReaderCalls: @unchecked Sendable {
        private let lock = NSLock(); private var requests: [MusicCommentsRequest] = []
        func add(_ request: MusicCommentsRequest) { lock.withLock { requests.append(request) } }
        var all: [MusicCommentsRequest] { lock.withLock { requests } }
    }
    @Test func isolatedAutomationKeepsCommentsUnresolvedAndAProductionLaunchComposesTheCoordinatorReadTransport() async throws {
        let calls = ReaderCalls()
        let reader: CoordinatorCommentsTransport.Reader = { request in calls.add(request); throw MusicSessionError.policy }
        let isolated = LocalAccountBootstrap.commentsTransport(isolated: true, reader: reader)
        #expect(isolated is UnresolvedCommentsTransport && isolated.unresolved != nil)
        let production = LocalAccountBootstrap.commentsTransport(isolated: false, reader: reader)
        #expect(production is CoordinatorCommentsTransport && production.unresolved == nil)
        #expect(production.writesUnresolved != nil, "reading is composed; writing is not")
        #expect(calls.all.isEmpty, "composing a transport reads nothing")
        let surface = SocialSurface(transport: isolated)
        await surface.loadComments(SocialSubject(kind: .song, id: "vid00000001", title: "x"))
        #expect(calls.all.isEmpty && surface.readCount == 0, "isolated automation never reaches a reader")
    }
    @Test func theProductionTransportResolvesTheCoordinatorForEveryRequestAndSendsExactlyOneReaderCallPerAction() async throws {
        let calls = ReaderCalls()
        let video = "vid00000001"
        let transport = LocalAccountBootstrap.commentsTransport(isolated: false) { request in
            calls.add(request)
            switch request {
            case .open: return MusicBrowseReply(value: .opened(entry: .notOffered, firstPage: nil), mode: .anonymous, accountGeneration: 0)
            case .page: return MusicBrowseReply(value: .page(MusicCommentsPage(header: nil, threads: [], nextToken: nil)), mode: .anonymous, accountGeneration: 0)
            case .replies(_, _, let parent): return MusicBrowseReply(value: .replies(MusicCommentsReplies(parentID: parent, replies: [], nextToken: nil)), mode: .anonymous, accountGeneration: 0)
            }
        }
        let subject = SocialSubject(kind: .song, id: video, title: "x")
        #expect(try await transport.open(subject) == .notOffered)
        _ = try await transport.page(CommentsToken("tok"), on: subject)
        _ = try await transport.replies(CommentsToken("rep"), of: SocialComment(id: "thread1", author: "a", text: "t"), on: subject)
        #expect(calls.all == [.open(videoID: video), .page(token: "tok", videoID: video), .replies(token: "rep", videoID: video, parentID: "thread1")])
        // A playlist is never read.
        let playlist = SocialSubject(kind: .playlist, id: "PLfixture0000000000000000000000001", title: "Mix")
        await #expect(throws: CommentsFailure.self) { _ = try await transport.open(playlist) }
        #expect(calls.all.count == 3)
        // Posting and moderation throw before any read.
        await #expect(throws: CommentsFailure.writesUnavailable) { _ = try await transport.post("hi", on: subject) }
        #expect(calls.all.count == 3)
    }
    @Test func theProductionTransportMapsTheCoordinatorsAnswersAndErrorsHonestly() async throws {
        let video = "vid00000001"
        func transport(_ body: @escaping @Sendable (MusicCommentsRequest) throws -> MusicCommentsAnswer) -> any CommentsTransport {
            LocalAccountBootstrap.commentsTransport(isolated: false) { MusicBrowseReply(value: try body($0), mode: .signedIn, accountGeneration: 3) }
        }
        let subject = SocialSubject(kind: .song, id: video, title: "x")
        let comment = MusicComment(id: "t1", parentID: nil, replyLevel: 0, authorName: "Ann", isVerified: true, isCreator: false, isArtist: true, isCurrentUser: false,
                                   text: "Hello", publishedTime: "4 weeks ago", likeCountText: "306", replyCountText: "10")
        let reply = MusicComment(id: "t1.r1", parentID: "t1", replyLevel: 1, authorName: "Bob", isVerified: false, isCreator: false, isArtist: false, isCurrentUser: true,
                                 text: "Hi", publishedTime: "1 day ago", likeCountText: nil, replyCountText: nil)
        let header = MusicCommentsHeader(countText: "2,904 Comments", shortCountText: "2.9K",
                                         sortOptions: [MusicCommentSortOption(title: "Top", isSelected: true, token: "sortTok1"), MusicCommentSortOption(title: "Newest", isSelected: false, token: "sortTok2")], posting: .signInRequired)
        let page = MusicCommentsPage(header: header, threads: [MusicCommentThread(comment: comment, repliesToken: "repTok", inlineReplies: [reply])], nextToken: "nextTok")
        let opened = transport { _ in .opened(entry: .continuation("entry"), firstPage: page) }
        guard case .page(let mapped) = try await opened.open(subject) else { Issue.record("expected a page"); return }
        #expect(mapped.header?.countText == "2,904 Comments" && mapped.header?.sorts.map(\.title) == ["Top", "Newest"] && mapped.header?.sorts.map(\.isSelected) == [true, false])
        #expect(mapped.header?.sorts.map(\.token.rawValue) == ["sortTok1", "sortTok2"] && mapped.next == CommentsToken("nextTok"))
        #expect(mapped.canPost == false, "a sign-in prompt box is never a composer")
        let thread = try #require(mapped.threads.first)
        #expect(thread.comment == SocialComment(id: "t1", author: "Ann", text: "Hello", posted: "4 weeks ago", likeCountText: "306", replyCountText: "10", isVerified: true, isArtist: true))
        #expect(thread.repliesToken == CommentsToken("repTok") && thread.inlineReplies == [SocialComment(id: "t1.r1", author: "Bob", text: "Hi", posted: "1 day ago", isCurrentUser: true, level: 1)])
        // A message is the service's own; an absent tab is not offered; a continuation with no first page is not an answer.
        #expect(try await transport { _ in .opened(entry: .serviceMessage("Comments are turned off."), firstPage: nil) }.open(subject) == .serviceMessage("Comments are turned off."))
        #expect(try await transport { _ in .opened(entry: .notOffered, firstPage: nil) }.open(subject) == .notOffered)
        await #expect(throws: CommentsFailure.unreadable) { _ = try await transport { _ in .opened(entry: .continuation("e"), firstPage: nil) }.open(subject) }
        // The wrong kind of answer for a request is unreadable, never guessed at.
        await #expect(throws: CommentsFailure.unreadable) { _ = try await transport { _ in .page(page) }.open(subject) }
        await #expect(throws: CommentsFailure.unreadable) { _ = try await transport { _ in .opened(entry: .notOffered, firstPage: nil) }.page(CommentsToken("t"), on: subject) }
        // Errors: the coordinator's fences become "show again", never a service error and never an empty list.
        for (error, expected) in [(MusicSessionError.stale, CommentsFailure.outOfDate), (.signedOut, .outOfDate), (.network, .offline), (.timedOut, .offline),
                                  (.rateLimited, .rateLimited), (.unrecognised, .unreadable), (.oversized, .unreadable), (.policy, .unreadable), (.server, .unreadable)] {
            await #expect(throws: expected, Comment(rawValue: "\(error)")) { _ = try await transport { _ in throw error }.open(subject) }
        }
    }
    @Test func theDevelopmentFlagComposesTheLabelledScriptedCommentsThatCanReadAndWrite() async throws {
        try await withBootstrap(development) { bootstrap in
            let social = bootstrap.social
            #expect(social.development && social.writesUnresolved == nil && social.isSignedIn)
            let subject = SocialSubject(kind: .song, id: "vid00000001", title: "x")
            #expect(social.state(subject) == .idle, "composing it read nothing")
            await social.loadComments(subject)
            let list = try #require(social.list(subject))
            #expect(list.threads.count == 2 && list.header?.sorts.count == 2 && list.next != nil && list.canPost)
            await social.loadMoreComments(subject); await social.loadReplies(subject, of: "devc1")
            #expect(social.list(subject)?.threads.count == 3 && social.list(subject)?.replies["devc1"]?.replies.count == 1)
        }
    }
}
#endif
