import AccountSession
@testable import Features
import Foundation
import Testing

/// T20.4 — Read / write / moderation / invite actions enforce role, an explicit action and an outbox result; no arbitrary external comments are read.

/// A comments transport that records every request and answers as scripted. It performs no I/O.
actor ScriptedComments: CommentsTransport {
    nonisolated let unresolved: String?
    private(set) var reads: [SocialSubject] = []
    private(set) var posts: [(String, SocialSubject)] = []
    private(set) var moderations: [(ModerationOffer, String, SocialSubject)] = []
    var page = CommentsPage(comments: [], canPost: true)
    var readFailure: CommentsFailure?
    var postAnswer: Result<SocialWriteAnswer, CommentsFailure> = .success(.confirmed)
    var moderateAnswer: Result<SocialWriteAnswer, CommentsFailure> = .success(.confirmed)
    /// A confirmed post does not add the text to what the next read returns (the list is only ever the source's).
    var holdPost = false
    private var held: CheckedContinuation<Void, Never>?
    init(unresolved: String? = nil) { self.unresolved = unresolved }
    func set(page: CommentsPage) { self.page = page }
    func set(readFailure: CommentsFailure?) { self.readFailure = readFailure }
    func set(postAnswer: Result<SocialWriteAnswer, CommentsFailure>) { self.postAnswer = postAnswer }
    func set(moderateAnswer: Result<SocialWriteAnswer, CommentsFailure>) { self.moderateAnswer = moderateAnswer }
    func hold() { holdPost = true }
    func release() { held?.resume(); held = nil }
    var isHeld: Bool { held != nil }
    func read(_ subject: SocialSubject) async throws -> CommentsPage { reads.append(subject); if let readFailure { throw readFailure }; return page }
    func post(_ text: String, on subject: SocialSubject) async throws -> SocialWriteAnswer {
        posts.append((text, subject))
        // Only the first post is held: a regression that lets a second one through then fails its assertion instead of waiting forever.
        if holdPost { holdPost = false; await withCheckedContinuation { held = $0 } }
        return try postAnswer.get()
    }
    func moderate(_ offer: ModerationOffer, comment: SocialComment, on subject: SocialSubject) async throws -> SocialWriteAnswer {
        moderations.append((offer, comment.id, subject)); return try moderateAnswer.get()
    }
    func counts() -> (reads: Int, posts: Int, moderations: Int) { (reads.count, posts.count, moderations.count) }
}

let song = SocialSubject(kind: .song, id: "vid00000001", title: "A song")
let hide = ModerationOffer(id: "hide", title: "Hide", destructive: true)
let report = ModerationOffer(id: "report", title: "Report")
func comment(_ id: String, by author: String = "Someone", text: String = "Text", offers: [ModerationOffer] = []) -> SocialComment {
    SocialComment(id: id, author: author, text: text, moderation: offers)
}

@Suite struct SocialPolicyTests {
    @Test func everyActionNeedsASignedInPerson() {
        for action in SocialActionKind.allCases {
            #expect(SocialPolicy.permission(action, role: .signedOut) == .denied(.needsSignIn), "\(action)")
        }
    }
    @Test func commentingRatingAndModeratingAreOpenToAnySignedInRole() {
        for role in [SocialRole.member, .collaborator, .owner] {
            for action in [SocialActionKind.readComments, .postComment, .moderateComment, .rate] {
                #expect(SocialPolicy.permission(action, role: role).isAllowed, "\(action) \(role)")
            }
        }
    }
    @Test func onlyAPlaylistsOwnerMayInviteOrCloseContributions() {
        for action in [SocialActionKind.createInvite, .stopContributions] {
            #expect(SocialPolicy.permission(action, role: .owner) == .allowed)
            #expect(SocialPolicy.permission(action, role: .collaborator) == .denied(.notOwner))
            #expect(SocialPolicy.permission(action, role: .member) == .denied(.notOwner))
        }
    }
    @Test func theRoleComesOnlyFromWhatThePlaylistPublished() {
        #expect(SocialRole.of(.owner, signedIn: true) == .owner)
        #expect(SocialRole.of(.collaborator, signedIn: true) == .collaborator)
        #expect(SocialRole.of(.saved, signedIn: true) == .member && SocialRole.of(.viewer, signedIn: true) == .member)
        #expect(SocialRole.of(.owner, signedIn: false) == .signedOut, "being signed out beats any published right")
    }
    @Test func everyDenialHasItsOwnWords() {
        let all: [SocialDenial] = [.needsSignIn, .notOwner, .notAllowedOnThisComment, .needsConfirmation, .busy]
        #expect(Set(all.map(\.message)).count == all.count)
    }
}

@Suite @MainActor struct CommentsReadingTests {
    @Test func aSourceWithNoRouteIsNeverAskedAndSaysSo() async {
        let transport = ScriptedComments(unresolved: "No comments route.")
        let social = SocialSurface(transport: transport)
        await social.loadComments(song)
        #expect(social.state(song) == .unresolved("No comments route."))
        #expect(await transport.counts() == (0, 0, 0))
        #expect(social.readCount == 0)
    }
    @Test func theApplicationsOwnTransportAnswersNothingAndSaysWhy() async {
        let own = UnresolvedCommentsTransport()
        #expect(own.unresolved?.contains("Comments aren’t available yet") == true)
        await #expect(throws: CommentsFailure.self) { _ = try await own.read(song) }
        await #expect(throws: CommentsFailure.self) { _ = try await own.post("x", on: song) }
        await #expect(throws: CommentsFailure.self) { _ = try await own.moderate(hide, comment: comment("c"), on: song) }
    }
    @Test func signedOutIsNotReadAndIsItsOwnState() async {
        let transport = ScriptedComments()
        let social = SocialSurface(transport: transport, signedIn: { .needsSignIn })
        #expect(social.state(song) == .signInRequired)
        await social.loadComments(song)
        #expect(social.state(song) == .signInRequired && social.songRole() == .signedOut)
        #expect(await transport.counts().reads == 0)
    }
    @Test func commentsAreExactlyWhatTheSourceReturnedWithRepeatsDropped() async {
        let transport = ScriptedComments()
        await transport.set(page: CommentsPage(comments: [comment("a"), comment("b"), comment("a")], canPost: false))
        let social = SocialSurface(transport: transport)
        await social.loadComments(song)
        #expect(social.page(song)?.comments.map(\.id) == ["a", "b"])
        #expect(social.page(song)?.canPost == false)
    }
    @Test func aReadFailureIsAFailureNotAnEmptyList() async {
        let transport = ScriptedComments()
        await transport.set(readFailure: .offline)
        let social = SocialSurface(transport: transport)
        await social.loadComments(song)
        #expect(social.state(song) == .failed(.offline))
        #expect(social.page(song) == nil)
    }
    @Test func noCommentsIsAnAnswerOfItsOwn() async {
        let social = SocialSurface(transport: ScriptedComments())
        await social.loadComments(song)
        #expect(social.page(song)?.comments.isEmpty == true)
    }
}

@Suite @MainActor struct CommentPostingTests {
    private func rig(canPost: Bool = true, comments: [SocialComment] = [], playback: SearchPlayback = .available) async -> (SocialSurface, ScriptedComments) {
        let transport = ScriptedComments()
        await transport.set(page: CommentsPage(comments: comments, canPost: canPost))
        let social = SocialSurface(transport: transport, signedIn: { playback })
        await social.loadComments(song)
        return (social, transport)
    }
    @Test func aSourceWithNoRouteSendsNothingAndRecordsWhy() async {
        let transport = ScriptedComments(unresolved: "No route.")
        let social = SocialSurface(transport: transport)
        let result = await social.post("Hello", on: song)
        #expect(result == .sourceUnresolved("No route."))
        #expect(await transport.counts().posts == 0)
        #expect(social.outbox.entries.first?.result == .sourceUnresolved("No route.") && social.outbox.entries.first?.wasSent == false)
    }
    @Test func signedOutIsDeniedBeforeAnythingIsSent() async {
        let (social, transport) = await rig(playback: .needsSignIn)
        #expect(await social.post("Hello", on: song) == .denied(.needsSignIn))
        #expect(await transport.counts().posts == 0)
    }
    @Test func postingNeedsTheSourceToHaveOfferedItHere() async {
        let (social, transport) = await rig(canPost: false)
        let result = await social.post("Hello", on: song)
        guard case .denied(.notOffered) = result else { Issue.record("expected notOffered, got \(result)"); return }
        #expect(await transport.counts().posts == 0)
    }
    @Test func postingBeforeAnyReadHasNothingThatOfferedIt() async {
        let transport = ScriptedComments()
        let social = SocialSurface(transport: transport)
        guard case .denied(.notOffered) = await social.post("Hello", on: song) else { Issue.record("expected denied"); return }
        #expect(await transport.counts().posts == 0)
    }
    @Test func emptyAndOversizeTextIsNeverSent() async {
        let (social, transport) = await rig()
        guard case .denied(.invalid) = await social.post("   \n ", on: song) else { Issue.record("expected invalid"); return }
        guard case .denied(.invalid) = await social.post(String(repeating: "x", count: SocialSurface.maximumCommentCharacters + 1), on: song) else { Issue.record("expected invalid"); return }
        #expect(await transport.counts().posts == 0)
        #expect(await social.post(String(repeating: "x", count: SocialSurface.maximumCommentCharacters), on: song) == .confirmed)
    }
    @Test func oneExplicitPostIsOneRequestWithTheTrimmedTextAndOneOutboxEntry() async {
        let (social, transport) = await rig()
        #expect(await social.post("  Hello there \n", on: song) == .confirmed)
        let posts = await transport.posts
        #expect(posts.count == 1 && posts[0].0 == "Hello there" && posts[0].1 == song)
        #expect(social.postCount == 1 && social.outbox.entries.count == 1)
        #expect(social.outbox.entries[0].result == .confirmed && social.outbox.entries[0].action == .postComment)
    }
    @Test func aConfirmedPostIsShownByReadingAgainNeverByInsertingTheText() async {
        let (social, transport) = await rig()
        _ = await social.post("A brand new comment", on: song)
        #expect(await transport.counts().reads == 2, "the list was read again")
        #expect(social.page(song)?.comments.isEmpty == true, "the source's answer did not include it, so it is not shown")
    }
    @Test func aRefusalKeepsTheSourcesWordsAndSaysItWasSent() async {
        let (social, transport) = await rig()
        await transport.set(postAnswer: .success(.rejected("Comments are off for this song.")))
        let result = await social.post("Hello", on: song)
        #expect(result == .failed("Comments are off for this song.", sent: true))
        #expect(social.outbox.entries[0].wasSent)
        #expect(await transport.counts().reads == 1, "a refused post does not read again")
    }
    @Test func aRequestThatNeverLeftSaysNothingWasSent() async {
        let (social, transport) = await rig()
        await transport.set(postAnswer: .failure(.offline))
        let result = await social.post("Hello", on: song)
        guard case .failed(_, let sent) = result else { Issue.record("expected failed"); return }
        #expect(sent == false)
        #expect(social.outbox.entries[0].result.message.contains("Nothing was sent"))
    }
    @Test func anUnknownOutcomeIsUnconfirmedAndIsNeverRetriedByItself() async {
        let (social, transport) = await rig()
        await transport.set(postAnswer: .success(.indeterminate))
        #expect(await social.post("Hello", on: song) == .unconfirmed)
        #expect(await transport.counts().posts == 1, "one request, no automatic repeat")
        #expect(social.outbox.entries[0].wasSent)
        #expect(social.outbox.entries[0].result.message.contains("Check before doing it again"))
    }
    @Test func anUnreadableReplyToASentPostIsNotConfirmedAndNeverSaysNothingWasSent() async {
        let (social, transport) = await rig()
        await transport.set(postAnswer: .failure(.unreadable))
        let result = await social.post("Hello", on: song)
        #expect(result == .unconfirmed, "the request left and the answer could not be read")
        let words = social.outbox.entries[0].result.message
        #expect(!words.contains("Nothing was sent") && words.contains("Check before doing it again"), Comment(rawValue: words))
        #expect(social.outbox.entries[0].wasSent)
        #expect(await transport.counts().posts == 1, "and it is not sent again by itself")
    }
    @Test func eachFailureThatCanBeToldApartIsToldApart() async {
        let (social, transport) = await rig()
        for (failure, expected) in [(CommentsFailure.offline, false), (.needsSignIn, false), (.sessionEnded, false)] {
            await transport.set(postAnswer: .failure(failure))
            guard case .failed(_, let sent) = await social.post("Hello", on: song) else { Issue.record("\(failure) should be a failure"); return }
            #expect(sent == expected, "\(failure) never left")
        }
        await transport.set(postAnswer: .failure(.rateLimited))
        guard case .failed(_, true) = await social.post("Hello", on: song) else { Issue.record("a rate limit was the service's answer: it left"); return }
    }
    @Test func anErrorNobodyClassifiedIsNotReportedAsUnsent() async {
        struct Mystery: Error {}
        final class Throwing: CommentsTransport, @unchecked Sendable {
            let unresolved: String? = nil
            func read(_ subject: SocialSubject) async throws -> CommentsPage { CommentsPage(comments: [SocialComment(id: "a", author: "A", text: "T", moderation: [ModerationOffer(id: "report", title: "Report")])], canPost: true) }
            func post(_ text: String, on subject: SocialSubject) async throws -> SocialWriteAnswer { throw Mystery() }
            func moderate(_ offer: ModerationOffer, comment: SocialComment, on subject: SocialSubject) async throws -> SocialWriteAnswer { throw Mystery() }
        }
        let social = SocialSurface(transport: Throwing())
        await social.loadComments(song)
        #expect(await social.post("Hello", on: song) == .unconfirmed)
        let a = social.page(song)!.comments[0]
        #expect(await social.moderate(a.moderation[0], comment: a, on: song) == .unconfirmed)
    }
    @Test func aSecondPostWhileOneIsInFlightIsRefused() async {
        let (social, transport) = await rig()
        await transport.hold()
        let first = Task { await social.post("One", on: song) }
        while !(await transport.isHeld) { await Task.yield() }
        let second = await social.post("Two", on: song)
        #expect(second == .denied(.busy))
        await transport.release()
        #expect(await first.value == .confirmed)
        #expect(await transport.counts().posts == 1)
    }
    @Test func loadingAndAccountChangesNeverSendAnything() async {
        let (social, transport) = await rig(comments: [comment("a", offers: [hide])])
        await social.loadComments(song)
        social.accountChanged()
        await social.loadComments(song)
        let counts = await transport.counts()
        #expect(counts.posts == 0 && counts.moderations == 0)
        #expect(social.postCount == 0 && social.moderationCount == 0 && social.outbox.entries.isEmpty)
    }
    @Test func anAccountChangeDropsTheStateAndALateAnswerChangesNothing() async {
        let (social, transport) = await rig()
        await transport.hold()
        let pending = Task { await social.post("Hello", on: song) }
        while !(await transport.isHeld) { await Task.yield() }
        social.accountChanged()
        await transport.release()
        _ = await pending.value
        #expect(social.outbox.entries.isEmpty, "the old account's answer is not recorded for the new one")
        #expect(social.page(song) == nil && social.busy.isEmpty)
    }
    @Test func theOutboxIsBoundedAndNewestFirst() async {
        let (social, _) = await rig()
        for index in 0..<60 { _ = await social.post("Comment \(index)", on: song) }
        #expect(social.outbox.entries.count == 50)
        #expect(social.outbox.entries.first?.subject.isEmpty == false)
    }
}

@Suite @MainActor struct ModerationTests {
    private func rig(playback: SearchPlayback = .available) async -> (SocialSurface, ScriptedComments) {
        let transport = ScriptedComments()
        await transport.set(page: CommentsPage(comments: [comment("a", by: "Ann", offers: [hide, report]), comment("b", by: "Bob", offers: []), comment("c", by: "Cy", offers: [report])], canPost: true))
        let social = SocialSurface(transport: transport, signedIn: { playback })
        await social.loadComments(song)
        return (social, transport)
    }
    @Test func aSourceWithNoRouteSendsNothing() async {
        let transport = ScriptedComments(unresolved: "No route.")
        let social = SocialSurface(transport: transport)
        #expect(await social.moderate(report, comment: comment("a"), on: song) == .sourceUnresolved("No route."))
        #expect(await transport.counts().moderations == 0)
    }
    @Test func onlyAnActionTheSourceOfferedOnThatCommentIsSent() async {
        let (social, transport) = await rig()
        let a = social.page(song)!.comments[0]
        #expect(await social.moderate(report, comment: a, on: song) == .confirmed)
        let sent = await transport.moderations
        #expect(sent.count == 1 && sent[0].0 == report && sent[0].1 == "a")
    }
    @Test func anActionOfferedOnAnotherCommentIsRefused() async {
        let (social, transport) = await rig()
        let pages = social.page(song)!.comments
        #expect(await social.moderate(hide, comment: pages[2], on: song) == .denied(.notAllowedOnThisComment), "c offers only Report")
        #expect(await social.moderate(report, comment: pages[1], on: song) == .denied(.notAllowedOnThisComment), "b offers nothing")
        #expect(await transport.counts().moderations == 0)
    }
    @Test func aCommentTheCurrentPageDoesNotHoldIsRefused() async {
        let (social, transport) = await rig()
        #expect(await social.moderate(report, comment: comment("ghost", offers: [report]), on: song) == .denied(.notAllowedOnThisComment))
        #expect(await transport.counts().moderations == 0)
    }
    @Test func anOfferMadeUpByTheCallerIsRefusedEvenWithAMatchingId() async {
        let (social, transport) = await rig()
        let a = social.page(song)!.comments[0]
        let forged = ModerationOffer(id: "report", title: "Report", destructive: true)
        #expect(await social.moderate(forged, comment: a, on: song) == .denied(.notAllowedOnThisComment))
        #expect(await transport.counts().moderations == 0)
    }
    @Test func aDestructiveActionNeedsTheConfirmationThatNamesItAndOneConfirmationIsOneRequest() async {
        let (social, transport) = await rig()
        let a = social.page(song)!.comments[0]
        #expect(await social.moderate(hide, comment: a, on: song) == .denied(.needsConfirmation))
        let question = try! #require(social.confirmation(for: hide, comment: a, on: song))
        #expect(question.author == "Ann" && question.commentID == "a" && question.offer == hide, "the question names the comment")
        #expect(await transport.counts().moderations == 0)
        #expect(await social.moderate(hide, comment: a, on: song, confirmation: question) == .confirmed)
        #expect(await transport.counts().moderations == 1 && social.moderationCount == 1)
    }
    @Test func aConfirmationForAnotherCommentOrAnotherOfferOrAChangedCommentIsNoAnswer() async {
        let (social, transport) = await rig()
        let comments = social.page(song)!.comments
        let other = ModerationConfirmation(subject: song, offer: hide, commentID: "c", author: "Cy", text: "Text")
        #expect(await social.moderate(hide, comment: comments[0], on: song, confirmation: other) == .denied(.needsConfirmation), "the question was about Cy's comment")
        let question = try! #require(social.confirmation(for: hide, comment: comments[0], on: song))
        let reworded = ModerationConfirmation(subject: song, offer: hide, commentID: "a", author: "Ann", text: "Something she did not write")
        #expect(question != reworded)
        #expect(await social.moderate(hide, comment: comments[0], on: song, confirmation: reworded) == .denied(.needsConfirmation))
        #expect(await social.moderate(hide, comment: comments[0], on: SocialSubject(kind: .song, id: "other", title: "x"), confirmation: question) == .denied(.notAllowedOnThisComment))
        #expect(await transport.counts().moderations == 0)
    }
    @Test func aQuestionIsOnlyAskedAboutAnActionTheSourceOfferedOnThatComment() async {
        let (social, _) = await rig()
        let comments = social.page(song)!.comments
        #expect(social.confirmation(for: hide, comment: comments[2], on: song) == nil, "c offers only Report")
        #expect(social.confirmation(for: hide, comment: comments[1], on: song) == nil, "b offers nothing")
        #expect(social.confirmation(for: hide, comment: comment("ghost", offers: [hide]), on: song) == nil)
    }
    @Test func signedOutIsDenied() async {
        let (social, transport) = await rig(playback: .needsSignIn)
        #expect(await social.moderate(report, comment: comment("a", offers: [report]), on: song) == .denied(.needsSignIn))
        #expect(await transport.counts().moderations == 0)
    }
    @Test func aRefusalAndAnUnknownOutcomeAreRecordedAsSuch() async {
        let (social, transport) = await rig()
        let a = social.page(song)!.comments[0]
        await transport.set(moderateAnswer: .success(.rejected(nil)))
        guard case .failed(_, true) = await social.moderate(report, comment: a, on: song) else { Issue.record("expected a sent refusal"); return }
        await transport.set(moderateAnswer: .success(.indeterminate))
        #expect(await social.moderate(report, comment: a, on: song) == .unconfirmed)
        #expect(await transport.counts().moderations == 2, "each press is one request; none repeats by itself")
    }
    @Test func anUnreadableReplyToASentModerationIsNotConfirmed() async {
        let (social, transport) = await rig()
        let a = social.page(song)!.comments[0]
        await transport.set(moderateAnswer: .failure(.unreadable))
        #expect(await social.moderate(report, comment: a, on: song) == .unconfirmed)
        #expect(await transport.counts().moderations == 1)
    }
    @Test func aConfirmedModerationReadsTheListAgain() async {
        let (social, transport) = await rig()
        let a = social.page(song)!.comments[0]
        _ = await social.moderate(report, comment: a, on: song)
        #expect(await transport.counts().reads == 2)
    }
}

@Suite @MainActor struct InvitationTests {
    private let playlistID = "PLfixture0000000000000000000000001"
    private func session(owner: Bool, collaborator: Bool = false, viewer: Bool = false, playback: SearchPlayback = .available,
                         service: MiniPlaylistService? = nil) async -> (PlaylistEditSession, MiniPlaylistService) {
        let remote = service ?? MiniPlaylistService(playlistID: playlistID, owner: owner, collaborator: collaborator)
        let session = PlaylistEditSession(playlistID: playlistID, service: remote, signedIn: { playback })
        await session.load()
        return (session, remote)
    }
    @Test func theOwnerAsksOnceAndTheOutcomeIsRecorded() async {
        let (session, remote) = await session(owner: true)
        let social = SocialSurface(transport: ScriptedComments())
        let result = await social.createInvite(for: session, title: "Mine")
        #expect(result == .confirmed)
        #expect(await remote.received.count == 1)
        #expect(session.sentCount == 1)
        #expect(social.outbox.entries.first?.action == .createInvite && social.outbox.entries.first?.result == .confirmed)
        if case .invite(let url) = session.collaboration { #expect(url != nil) } else { Issue.record("expected an invite link") }
    }
    @Test func aCollaboratorIsDeniedAndNothingReachesTheService() async {
        let (session, remote) = await session(owner: false, collaborator: true)
        let social = SocialSurface(transport: ScriptedComments())
        #expect(await social.createInvite(for: session, title: "Shared") == .denied(.notOwner))
        #expect(await social.stopContributions(for: session, title: "Shared", confirmation: session.stopContributionsPrompt) == .denied(.notOwner))
        #expect(await remote.received.isEmpty && session.sentCount == 0)
        #expect(social.outbox.entries.map(\.wasSent) == [false, false])
    }
    @Test func aViewerIsDeniedAndNothingReachesTheService() async {
        let (session, remote) = await session(owner: false)
        let social = SocialSurface(transport: ScriptedComments())
        #expect(await social.createInvite(for: session, title: "Public") == .denied(.notOwner))
        #expect(await remote.received.isEmpty)
    }
    @Test func signedOutIsDeniedWhateverTheServiceOnceSaid() async {
        let (session, remote) = await session(owner: true)
        let social = SocialSurface(transport: ScriptedComments(), signedIn: { .sessionExpired })
        #expect(await social.createInvite(for: session, title: "Mine") == .denied(.needsSignIn))
        #expect(await remote.received.isEmpty)
    }
    @Test func stoppingContributionsNeedsTheConfirmationThatNamesThePlaylist() async {
        let (session, remote) = await session(owner: true)
        let social = SocialSurface(transport: ScriptedComments())
        #expect(await social.stopContributions(for: session, title: "Mine", confirmation: nil) == .denied(.needsConfirmation))
        let wrong = PlaylistPrompt(action: .stopContributions, playlistTitle: "Another", count: 1, names: ["Another"])
        #expect(await social.stopContributions(for: session, title: "Mine", confirmation: wrong) == .denied(.needsConfirmation))
        #expect(await remote.received.isEmpty)
        #expect(await social.stopContributions(for: session, title: "Mine", confirmation: session.stopContributionsPrompt) == .confirmed)
        #expect(await remote.received.count == 1 && session.collaboration == .closed)
    }
    @Test func aRefusalIsRecordedAsSentAndAFailedReadAsNotSent() async {
        let refusing = MiniPlaylistService(playlistID: playlistID, owner: true, collaborator: false)
        await refusing.set(outcome: .rejected(.service))
        let (session, _) = await session(owner: true, service: refusing)
        let social = SocialSurface(transport: ScriptedComments())
        guard case .failed(_, let sent) = await social.createInvite(for: session, title: "Mine") else { Issue.record("expected failed"); return }
        #expect(sent == true)
    }
    @Test func anUnknownOutcomeIsUnconfirmed() async {
        let unsure = MiniPlaylistService(playlistID: playlistID, owner: true, collaborator: false)
        await unsure.set(outcome: .indeterminate(.noAnswer))
        let (session, _) = await session(owner: true, service: unsure)
        let social = SocialSurface(transport: ScriptedComments())
        #expect(await social.createInvite(for: session, title: "Mine") == .unconfirmed)
        #expect(await unsure.received.count == 1)
    }
    @Test func collaborationResultsMapToTheOutboxHonestly() {
        let url = URL(string: "https://music.youtube.com/playlist?list=x")
        #expect(SocialSurface.result(of: .invite(url), sentBefore: 0, sentNow: 1, link: true) == .confirmed)
        guard case .failed(_, true) = SocialSurface.result(of: .invite(nil), sentBefore: 0, sentNow: 1, link: true) else { Issue.record("no usable link is a failure"); return }
        #expect(SocialSurface.result(of: .closed, sentBefore: 1, sentNow: 2, link: false) == .confirmed)
        #expect(SocialSurface.result(of: .unconfirmed, sentBefore: 0, sentNow: 1, link: true) == .unconfirmed)
        guard case .failed(_, false) = SocialSurface.result(of: .failed(.offline), sentBefore: 3, sentNow: 3, link: true) else { Issue.record("not sent"); return }
        guard case .failed(_, true) = SocialSurface.result(of: .failed(.refused), sentBefore: 3, sentNow: 4, link: true) else { Issue.record("sent"); return }
    }
}

@Suite @MainActor struct RatingResultTests {
    private let like = MusicItemControls.Like(videoID: "vid00000001", status: .indifferent, dislikeExposed: true)
    private func rig(_ answer: Result<MusicWriteOutcome, MusicSessionError>, playback: SearchPlayback = .available) -> (SocialSurface, LibraryWriteLedger) {
        let ledger = LibraryWriteLedger(writer: { _ in MusicWriteReply(outcome: try answer.get(), accountGeneration: 0) }, signedIn: { playback })
        return (SocialSurface(transport: ScriptedComments(), ledger: ledger), ledger)
    }
    @Test func noRatingActionMeansNoResult() {
        let (social, _) = rig(.success(.confirmed))
        #expect(social.ratingResult(videoID: "vid00000001") == nil)
    }
    @Test func theLedgersStatesBecomeTheOutcomeOfTheRatingAction() async {
        let (confirmed, c) = rig(.success(.confirmed)); await c.submit(.rate(like, to: .like))
        #expect(confirmed.ratingResult(videoID: like.videoID) == .confirmed)
        let (refused, r) = rig(.success(.rejected(.service))); await r.submit(.rate(like, to: .like))
        guard case .failed(_, true)? = refused.ratingResult(videoID: like.videoID) else { Issue.record("expected a sent refusal"); return }
        let (unsure, u) = rig(.success(.indeterminate(.noAnswer))); await u.submit(.rate(like, to: .like))
        #expect(unsure.ratingResult(videoID: like.videoID) == .unconfirmed)
        let (out, o) = rig(.success(.confirmed), playback: .needsSignIn); await o.submit(.rate(like, to: .like))
        #expect(out.ratingResult(videoID: like.videoID) == .denied(.needsSignIn))
        #expect(o.sentCount == 0, "a signed-out rating reaches no writer")
    }
}

@Suite @MainActor struct RatingActionTests {
    private let video = "vid00000001"
    private func control(_ ledger: LibraryWriteLedger) -> LibraryControl {
        let item = MusicCatalogItem(kind: .song, title: "A song", videoID: video, controls: MusicItemControls(like: .init(videoID: video, status: .indifferent, dislikeExposed: true)))
        return LibraryControls.make(item: item, source: nil, ledger: ledger).first { $0.kind == .like }!
    }
    private func press(_ social: SocialSurface, _ ledger: LibraryWriteLedger) async -> SocialOutboxEntry.Result {
        let pressed = control(ledger)
        return await social.rate(pressed, change: { await ledger.submit(pressed.intent) })
    }
    private final class Count: @unchecked Sendable { var writes = 0 }
    private func rig(_ outcome: MusicWriteOutcome, playback: SearchPlayback = .available) -> (SocialSurface, LibraryWriteLedger, Count) {
        let count = Count()
        let ledger = LibraryWriteLedger(writer: { _ in count.writes += 1; return MusicWriteReply(outcome: outcome, accountGeneration: 0) }, signedIn: { playback })
        return (SocialSurface(transport: ScriptedComments(), ledger: ledger, signedIn: { playback }), ledger, count)
    }
    @Test func aSignedOutPressIsDeniedBeforeAnyWriterIsAsked() async {
        let (social, ledger, count) = rig(.confirmed, playback: .needsSignIn)
        #expect(await press(social, ledger) == .denied(.needsSignIn))
        #expect(count.writes == 0 && ledger.sentCount == 0)
        #expect(social.outbox.entries.first?.action == .rate && social.outbox.entries.first?.wasSent == false)
    }
    @Test func aSignedOutPressNeverRunsTheButtonsChange() async {
        let (social, ledger, count) = rig(.confirmed, playback: .needsSignIn)
        final class Ran: @unchecked Sendable { var times = 0 }
        let ran = Ran()
        let pressed = control(ledger)
        _ = await social.rate(pressed, change: { ran.times += 1; await ledger.submit(pressed.intent) })
        #expect(ran.times == 0 && count.writes == 0, "the role check comes before the change, not after it")
    }
    @Test func aSignedInPressRunsTheButtonsChangeExactlyOnce() async {
        let (social, ledger, _) = rig(.confirmed)
        final class Ran: @unchecked Sendable { var times = 0 }
        let ran = Ran()
        let pressed = control(ledger)
        _ = await social.rate(pressed, change: { ran.times += 1; await ledger.submit(pressed.intent) })
        #expect(ran.times == 1)
    }
    @Test func aSignedInPressGoesThroughTheLedgerOnceAndTheOutboxHoldsItsOutcome() async {
        let (social, ledger, count) = rig(.confirmed)
        #expect(await press(social, ledger) == .confirmed)
        #expect(count.writes == 1)
        #expect(social.outbox.entries.first?.result == .confirmed && social.outbox.entries.first?.action == .rate)
    }
    @Test func aRefusedAndAnUnknownRatingAreRecordedAsSuch() async {
        let (refused, l1, _) = rig(.rejected(.service))
        guard case .failed(_, true) = await press(refused, l1) else { Issue.record("expected a sent refusal"); return }
        let (unsure, l2, _) = rig(.indeterminate(.noAnswer))
        #expect(await press(unsure, l2) == .unconfirmed)
    }
}

/// A small playlist service: a snapshot with the rights the test gives it, and the collaboration answers the real one gives.
actor MiniPlaylistService: PlaylistServing {
    let playlistID: String
    let owner: Bool, collaborator: Bool
    private(set) var received: [MusicPlaylistRequest] = []
    var outcome: MusicWriteOutcome = .confirmed
    init(playlistID: String, owner: Bool, collaborator: Bool) { self.playlistID = playlistID; self.owner = owner; self.collaborator = collaborator }
    func set(outcome: MusicWriteOutcome) { self.outcome = outcome }
    func read(playlistID: String) async throws -> PlaylistSnapshot {
        let editing = (owner || collaborator) ? MusicPlaylistEditing(canEditTracks: true, canEditDetails: owner, canDelete: owner, privacy: .unlisted) : nil
        return PlaylistSnapshot(playlistID: playlistID, title: "Fixture playlist", privacy: .unlisted, occurrences: [], editing: editing, isSaved: false)
    }
    func apply(_ request: MusicPlaylistRequest) async throws -> MusicPlaylistReply {
        received.append(request)
        let link = "https://music.youtube.com/playlist?list=\(playlistID)&jct=JOINTOKEN12345678"
        return MusicPlaylistReply(result: MusicPlaylistOutcome(outcome: outcome, inviteLink: outcome == .confirmed ? link : nil), accountGeneration: 0)
    }
    func listing() async throws -> [PlaylistListing] { [] }
}
