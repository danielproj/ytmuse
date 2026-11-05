import AccountSession
@testable import Features
import Foundation
import Testing

/// T20.4 — Read / write / moderation / invite actions enforce role, an explicit action and an outbox result; no arbitrary external comments are read.

/// A comments transport that records every request and answers as scripted. It performs no I/O. It is a labelled test writer: unlike the
/// application's own transports it says it CAN write (`writesUnresolved` is nil unless a test gives a reason), so the posting and moderation
/// rules of the surface stay exercised; `ReadOnlyComments` below is the transport that keeps the protocol's default.
actor ScriptedComments: CommentsTransport {
    enum Kind: Hashable { case open, page, replies }
    nonisolated let unresolved: String?
    nonisolated let writesUnresolved: String?
    private(set) var reads: [SocialSubject] = []
    private(set) var pageReads: [CommentsToken] = []
    private(set) var replyReads: [(token: CommentsToken, thread: String)] = []
    private(set) var posts: [(String, SocialSubject)] = []
    private(set) var moderations: [(ModerationOffer, String, SocialSubject)] = []
    var opening: CommentsOpening = .page(CommentsPage(comments: [], canPost: true))
    var readFailure: CommentsFailure?
    var pageAnswers: [String: Result<CommentsPage, CommentsFailure>] = [:]
    var replyAnswers: [String: Result<CommentsReplies, CommentsFailure>] = [:]
    var postAnswer: Result<SocialWriteAnswer, CommentsFailure> = .success(.confirmed)
    var moderateAnswer: Result<SocialWriteAnswer, CommentsFailure> = .success(.confirmed)
    /// A confirmed post does not add the text to what the next read returns (the list is only ever the source's).
    var holdPost = false
    private var held: CheckedContinuation<Void, Never>?
    private var holdKinds: Set<Kind> = []
    private var heldReads: [Kind: CheckedContinuation<Void, Never>] = [:]
    init(unresolved: String? = nil, writesUnresolved: String? = nil) { self.unresolved = unresolved; self.writesUnresolved = writesUnresolved }
    func set(page: CommentsPage) { opening = .page(page) }
    func set(opening: CommentsOpening) { self.opening = opening }
    func set(readFailure: CommentsFailure?) { self.readFailure = readFailure }
    func set(pageAnswer: Result<CommentsPage, CommentsFailure>, for token: String) { pageAnswers[token] = pageAnswer }
    func set(replyAnswer: Result<CommentsReplies, CommentsFailure>, for token: String) { replyAnswers[token] = replyAnswer }
    func set(postAnswer: Result<SocialWriteAnswer, CommentsFailure>) { self.postAnswer = postAnswer }
    func set(moderateAnswer: Result<SocialWriteAnswer, CommentsFailure>) { self.moderateAnswer = moderateAnswer }
    func hold() { holdPost = true }
    func release() { held?.resume(); held = nil }
    var isHeld: Bool { held != nil }
    /// The next read of this kind is answered only after `releaseRead`. Only that one read is held, so a regression that sends a second request
    /// fails its count instead of waiting forever.
    func holdRead(_ kind: Kind) { holdKinds.insert(kind) }
    func isReadHeld(_ kind: Kind) -> Bool { heldReads[kind] != nil }
    func releaseRead(_ kind: Kind) { heldReads.removeValue(forKey: kind)?.resume() }
    private func gate(_ kind: Kind) async {
        if holdKinds.remove(kind) != nil { await withCheckedContinuation { heldReads[kind] = $0 } }
    }
    func open(_ subject: SocialSubject) async throws -> CommentsOpening {
        reads.append(subject)
        let answer = opening, failure = readFailure
        await gate(.open)
        if let failure { throw failure }
        return answer
    }
    func page(_ token: CommentsToken, on subject: SocialSubject) async throws -> CommentsPage {
        pageReads.append(token)
        let answer = pageAnswers[token.rawValue] ?? .failure(.unreadable)
        await gate(.page)
        return try answer.get()
    }
    func replies(_ token: CommentsToken, of thread: SocialComment, on subject: SocialSubject) async throws -> CommentsReplies {
        replyReads.append((token, thread.id))
        let answer = replyAnswers[token.rawValue] ?? .failure(.unreadable)
        await gate(.replies)
        return try answer.get()
    }
    func post(_ text: String, on subject: SocialSubject) async throws -> SocialWriteAnswer {
        posts.append((text, subject))
        // Only the first post is held: a regression that lets a second one through then fails its assertion instead of waiting forever.
        if holdPost { holdPost = false; await withCheckedContinuation { held = $0 } }
        return try postAnswer.get()
    }
    func moderate(_ offer: ModerationOffer, comment: SocialComment, on subject: SocialSubject) async throws -> SocialWriteAnswer {
        moderations.append((offer, comment.id, subject)); return try moderateAnswer.get()
    }
    /// Reads of every kind, and the writes.
    func counts() -> (reads: Int, posts: Int, moderations: Int) { (reads.count + pageReads.count + replyReads.count, posts.count, moderations.count) }
}
/// A read-only transport that keeps the protocol's default `writesUnresolved`, as the application's own coordinator transport does. Every call is counted.
actor ReadOnlyComments: CommentsTransport {
    nonisolated var unresolved: String? { nil }
    private(set) var opens = 0, writes = 0
    func open(_ subject: SocialSubject) async throws -> CommentsOpening {
        opens += 1
        return .page(CommentsPage(header: nil, threads: [CommentThread(comment: SocialComment(id: "a", author: "Ann", text: "T", moderation: [ModerationOffer(id: "hide", title: "Hide", destructive: true)]))], canPost: true))
    }
    func page(_ token: CommentsToken, on subject: SocialSubject) async throws -> CommentsPage { throw CommentsFailure.unreadable }
    func replies(_ token: CommentsToken, of thread: SocialComment, on subject: SocialSubject) async throws -> CommentsReplies { throw CommentsFailure.unreadable }
    func post(_ text: String, on subject: SocialSubject) async throws -> SocialWriteAnswer { writes += 1; return .confirmed }
    func moderate(_ offer: ModerationOffer, comment: SocialComment, on subject: SocialSubject) async throws -> SocialWriteAnswer { writes += 1; return .confirmed }
}

let song = SocialSubject(kind: .song, id: "vid00000001", title: "A song")
let hide = ModerationOffer(id: "hide", title: "Hide", destructive: true)
let report = ModerationOffer(id: "report", title: "Report")
func comment(_ id: String, by author: String = "Someone", text: String = "Text", offers: [ModerationOffer] = []) -> SocialComment {
    SocialComment(id: id, author: author, text: text, moderation: offers)
}

@Suite struct SocialPolicyTests {
    @Test func everyActionThatChangesSomethingNeedsASignedInPerson() {
        for action in SocialActionKind.allCases where action != .readComments {
            #expect(SocialPolicy.permission(action, role: .signedOut) == .denied(.needsSignIn), "\(action)")
        }
    }
    @Test func readingCommentsNeedsNoAccount() {
        for role in [SocialRole.signedOut, .member, .collaborator, .owner] { #expect(SocialPolicy.permission(.readComments, role: role) == .allowed, "\(role)") }
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
    @Test func theApplicationsUnresolvedTransportAnswersNothingAndSaysWhy() async {
        let own = UnresolvedCommentsTransport()
        #expect(own.unresolved?.contains("Comments aren’t connected in this session") == true)
        #expect(own.writesUnresolved != nil)
        await #expect(throws: CommentsFailure.self) { _ = try await own.open(song) }
        await #expect(throws: CommentsFailure.self) { _ = try await own.page(CommentsToken("t"), on: song) }
        await #expect(throws: CommentsFailure.self) { _ = try await own.replies(CommentsToken("t"), of: comment("c"), on: song) }
        await #expect(throws: CommentsFailure.self) { _ = try await own.post("x", on: song) }
        await #expect(throws: CommentsFailure.self) { _ = try await own.moderate(hide, comment: comment("c"), on: song) }
    }
    @Test func signedOutReadingIsAllowedAndSendsTheRead() async {
        let transport = ScriptedComments()
        await transport.set(page: CommentsPage(comments: [comment("a")], canPost: false))
        let social = SocialSurface(transport: transport, signedIn: { .needsSignIn })
        #expect(social.songRole() == .signedOut && social.state(song) == .idle, "signed out is idle, not a sign-in wall")
        await social.loadComments(song)
        #expect(await transport.counts().reads == 1)
        #expect(social.list(song)?.comments.map(\.id) == ["a"])
    }
    @Test func commentsAreExactlyWhatTheSourceReturnedWithRepeatsDropped() async {
        let transport = ScriptedComments()
        await transport.set(page: CommentsPage(comments: [comment("a"), comment("b"), comment("a")], canPost: false))
        let social = SocialSurface(transport: transport)
        await social.loadComments(song)
        #expect(social.list(song)?.comments.map(\.id) == ["a", "b"])
        #expect(social.list(song)?.canPost == false)
    }
    @Test func aReadFailureIsAFailureNotAnEmptyList() async {
        let transport = ScriptedComments()
        await transport.set(readFailure: .offline)
        let social = SocialSurface(transport: transport)
        await social.loadComments(song)
        #expect(social.state(song) == .failed(.offline))
        #expect(social.list(song) == nil)
    }
    @Test func anEmptyPageIsAnAnswerOfItsOwnAndIsNotTheOtherStates() async {
        let social = SocialSurface(transport: ScriptedComments())
        await social.loadComments(song)
        #expect(social.list(song)?.comments.isEmpty == true)
        if case .loaded = social.state(song) {} else { Issue.record("an empty page is loaded, not \(social.state(song))") }
    }
}

/// C3: comments are read only when the person asks, one request per action, bounded, fenced and honest about what each answer is.
@Suite @MainActor struct CommentsExplicitReadingTests {
    private func token(_ value: String) -> CommentsToken { CommentsToken(value) }
    private func thread(_ id: String, replies: String? = nil, inline: [SocialComment] = []) -> CommentThread {
        CommentThread(comment: SocialComment(id: id, author: "Author " + id, text: "Text " + id, posted: "1 day ago", likeCountText: "3", replyCountText: replies == nil ? nil : "2"),
                      repliesToken: replies.map(CommentsToken.init), inlineReplies: inline)
    }
    private func header(selected: Int = 0) -> CommentsHeader {
        CommentsHeader(countText: "2,904 Comments", sorts: [CommentsSortOption(title: "Top", isSelected: selected == 0, token: token("sortTop")),
                                                           CommentsSortOption(title: "Newest", isSelected: selected == 1, token: token("sortNew"))])
    }
    private func first(next: String? = "more1", replies: String? = "rep1") -> CommentsPage {
        CommentsPage(header: header(), threads: [thread("t1", replies: replies), thread("t2")], next: next.map(CommentsToken.init), canPost: false)
    }
    private func rig(next: String? = "more1", signedIn: SearchPlayback = .available) async -> (SocialSurface, ScriptedComments) {
        let transport = ScriptedComments(writesUnresolved: "No write route.")
        await transport.set(page: first(next: next))
        await transport.set(pageAnswer: .success(CommentsPage(header: header(selected: 1), threads: [thread("n1"), thread("n2")], next: token("moreNew"))), for: "sortNew")
        await transport.set(pageAnswer: .success(CommentsPage(header: header(), threads: [thread("t1", replies: "rep1"), thread("t2")], next: token("more1"))), for: "sortTop")
        await transport.set(pageAnswer: .success(CommentsPage(threads: [thread("t3"), thread("t2")], next: token("more2"))), for: "more1")
        await transport.set(replyAnswer: .success(CommentsReplies(parentID: "t1", replies: [SocialComment(id: "t1.r1", author: "R", text: "reply", level: 1)], next: token("repMore"))), for: "rep1")
        await transport.set(replyAnswer: .success(CommentsReplies(parentID: "t1", replies: [SocialComment(id: "t1.r2", author: "R", text: "reply two", level: 1)])), for: "repMore")
        return (SocialSurface(transport: transport, signedIn: { signedIn }), transport)
    }

    @Test func nothingIsSentUntilTheExplicitAction() async {
        let (social, transport) = await rig()
        // Making the surface, asking for the state of a song, and an account change send nothing: there is no read to start by itself.
        #expect(social.state(song) == .idle && social.list(song) == nil)
        social.accountChanged()
        #expect(social.state(song) == .idle)
        // Acting on a song that was never opened sends nothing either.
        await social.loadMoreComments(song); await social.loadReplies(song, of: "t1")
        await social.selectSort(CommentsSortOption(title: "Top", isSelected: false, token: token("sortTop")), for: song)
        #expect(await transport.counts() == (0, 0, 0) && social.readCount == 0)
    }
    @Test func showCommentsIsOneExplicitRead() async {
        let (social, transport) = await rig()
        await social.loadComments(song)
        #expect(await transport.counts() == (1, 0, 0) && social.readCount == 1)
        let list = social.list(song)
        #expect(list?.header?.countText == "2,904 Comments" && list?.header?.sorts.map(\.title) == ["Top", "Newest"] && list?.pages == 1)
        #expect(list?.threads.map(\.id) == ["t1", "t2"])
        #expect(list?.threads.first?.comment.likeCountText == "3" && list?.threads.first?.comment.replyCountText == "2", "the printed counts, as printed")
    }
    @Test func aSongWithNoCommentsTabIsNotOfferedAndAMessageIsTheServicesOwn() async {
        let (social, transport) = await rig()
        await transport.set(opening: .notOffered)
        await social.loadComments(song)
        #expect(social.state(song) == .notOffered)
        let other = SocialSubject(kind: .song, id: "vid00000002", title: "Another")
        await transport.set(opening: .serviceMessage("Comments are turned off."))
        await social.loadComments(other)
        #expect(social.state(other) == .serviceMessage("Comments are turned off."))
        #expect(social.list(song) == nil && social.list(other) == nil, "neither is a list, and neither is \"no comments\"")
    }
    @Test func aServiceMessageIsOnlyEverWhatTheTransportSaid() async {
        let (social, transport) = await rig()
        await transport.set(opening: .page(CommentsPage(comments: [], canPost: false)))
        await social.loadComments(song)
        if case .serviceMessage = social.state(song) { Issue.record("an empty page must not become a service message") }
        if case .notOffered = social.state(song) { Issue.record("an empty page must not become \"not offered\"") }
    }
    @Test func aPlaylistIsNotOfferedAndNothingIsAsked() async {
        let (social, transport) = await rig()
        let playlist = SocialSubject(kind: .playlist, id: "PLfixture0000000000000000000000001", title: "Mix")
        #expect(social.state(playlist) == .notOffered)
        await social.loadComments(playlist); await social.loadMoreComments(playlist); await social.loadReplies(playlist, of: "t1")
        await social.selectSort(CommentsSortOption(title: "Top", isSelected: false, token: token("sortTop")), for: playlist)
        #expect(await transport.counts() == (0, 0, 0) && social.readCount == 0 && social.state(playlist) == .notOffered)
    }
    @Test func theSortOrdersAreTheServicesAndSwitchingIsOneRequestThatReplacesTheList() async {
        let (social, transport) = await rig()
        await social.loadComments(song)
        let newest = social.list(song)!.header!.sorts[1]
        await social.selectSort(newest, for: song)
        #expect(await transport.pageReads == [token("sortNew")] && social.readCount == 2)
        let list = social.list(song)!
        #expect(list.threads.map(\.id) == ["n1", "n2"] && list.header?.sorts.map(\.isSelected) == [false, true] && list.pages == 1 && !list.sorting)
        // The selected order is not asked for again, and a token the header never printed is not sent.
        await social.selectSort(list.header!.sorts[1], for: song)
        await social.selectSort(CommentsSortOption(title: "Forged", isSelected: false, token: token("forged")), for: song)
        #expect(await transport.pageReads.count == 1)
    }
    @Test func aSecondPressWhileASortIsLoadingSendsNothing() async {
        let (social, transport) = await rig()
        await social.loadComments(song)
        let sorts = social.list(song)!.header!.sorts
        await transport.holdRead(.page)
        let pending = Task { await social.selectSort(sorts[1], for: song) }
        while !(await transport.isReadHeld(.page)) { await Task.yield() }
        #expect(social.list(song)?.sorting == true)
        await social.selectSort(sorts[1], for: song); await social.loadMoreComments(song); await social.loadReplies(song, of: "t1"); await social.loadComments(song)
        #expect(await transport.counts() == (2, 0, 0), "the open and the one sort read are the only reads")
        await transport.releaseRead(.page); await pending.value
        #expect(social.list(song)?.threads.map(\.id) == ["n1", "n2"])
    }
    @Test func moreCommentsIsOneRequestPerPressAppendsOnceAndAFurtherPressWhileLoadingSendsNothing() async {
        let (social, transport) = await rig()
        await social.loadComments(song)
        await transport.holdRead(.page)
        let pending = Task { await social.loadMoreComments(song) }
        while !(await transport.isReadHeld(.page)) { await Task.yield() }
        await social.loadMoreComments(song)
        #expect(await transport.pageReads == [token("more1")], "one request, the second press was refused")
        await transport.releaseRead(.page); await pending.value
        let list = social.list(song)!
        #expect(list.threads.map(\.id) == ["t1", "t2", "t3"], "t2 came again and is shown once")
        #expect(list.pages == 2 && list.next == token("more2") && !list.loadingMore)
    }
    @Test func commentPagesStopAtTheBoundAndTheBoundIsStated() async {
        let (social, transport) = await rig()
        await social.loadComments(song)
        for index in 1..<SocialSurface.maximumCommentPages {
            await transport.set(pageAnswer: .success(CommentsPage(threads: [thread("p\(index)")], next: token("more\(index + 1)"))), for: "more\(index)")
        }
        for _ in 0..<(SocialSurface.maximumCommentPages + 3) { await social.loadMoreComments(song) }
        let list = social.list(song)!
        #expect(list.pages == SocialSurface.maximumCommentPages && list.next != nil && list.reachedPageBound)
        #expect(await transport.pageReads.count == SocialSurface.maximumCommentPages - 1, "10 pages are the first plus nine reads; nothing past that is sent")
        #expect(SocialSurface.maximumCommentPages == 10 && SocialSurface.maximumReplyPages == 5)
    }
    @Test func aSortSwitchStartsANewPageCount() async {
        let (social, _) = await rig()
        await social.loadComments(song)
        await social.loadMoreComments(song)
        #expect(social.list(song)?.pages == 2)
        await social.selectSort(social.list(song)!.header!.sorts[1], for: song)
        #expect(social.list(song)?.pages == 1, "the bound is per sort order")
    }
    @Test func repliesAreOneRequestPerThreadPressAndMoreRepliesFollowsTheTokenTheRepliesPublished() async {
        let (social, transport) = await rig()
        await social.loadComments(song)
        await social.loadReplies(song, of: "t2")
        #expect(await transport.replyReads.isEmpty, "a thread with no replies token has nothing to read")
        await social.loadReplies(song, of: "t1")
        let replyReads = await transport.replyReads
        #expect(replyReads.map(\.token) == [token("rep1")] && replyReads.map(\.thread) == ["t1"])
        var list = social.list(song)!
        #expect(list.shownReplies(of: list.threads[0]).map(\.id) == ["t1.r1"] && list.replies["t1"]?.next == token("repMore"))
        await social.loadReplies(song, of: "t1")
        #expect(await transport.replyReads.map(\.token) == [token("rep1"), token("repMore")])
        list = social.list(song)!
        #expect(list.shownReplies(of: list.threads[0]).map(\.id) == ["t1.r1", "t1.r2"] && list.replies["t1"]?.next == nil)
        await social.loadReplies(song, of: "t1")
        #expect(await transport.replyReads.count == 2, "no further page was published")
    }
    @Test func inlineRepliesAreShownWithoutARequest() async {
        let (social, transport) = await rig()
        let inline = [SocialComment(id: "t1.i1", author: "I", text: "inline", level: 1), SocialComment(id: "t1.i2", author: "I", text: "nested", level: 2)]
        await transport.set(page: CommentsPage(header: header(), threads: [thread("t1", inline: inline)], next: nil, canPost: false))
        await social.loadComments(song)
        let list = social.list(song)!
        let counts = await transport.counts()
        #expect(list.shownReplies(of: list.threads[0]).map(\.id) == ["t1.i1", "t1.i2"] && counts == (1, 0, 0))
    }
    @Test func replyPagesStopAtTheBound() async {
        let (social, transport) = await rig()
        for index in 1...(SocialSurface.maximumReplyPages + 2) {
            await transport.set(replyAnswer: .success(CommentsReplies(parentID: "t1", replies: [SocialComment(id: "t1.\(index)", author: "R", text: "r", level: 1)], next: token("rep\(index + 1)"))), for: "rep\(index)")
        }
        await social.loadComments(song)
        for _ in 0..<(SocialSurface.maximumReplyPages + 3) { await social.loadReplies(song, of: "t1") }
        let list = social.list(song)!
        #expect(list.replies["t1"]?.pages == SocialSurface.maximumReplyPages && list.reachedReplyBound(list.threads[0]))
        #expect(await transport.replyReads.count == SocialSurface.maximumReplyPages)
    }
    @Test func aReplyAnswerForAnotherThreadIsNotShown() async {
        let (social, transport) = await rig()
        await transport.set(replyAnswer: .success(CommentsReplies(parentID: "someoneElse", replies: [SocialComment(id: "x.r", author: "X", text: "x", level: 1)])), for: "rep1")
        await social.loadComments(song)
        await social.loadReplies(song, of: "t1")
        #expect(social.list(song)?.replies["t1"]?.replies.isEmpty == true && social.list(song)?.replies["t1"]?.failure == .unreadable)
    }
    @Test func aLateMoreAnswerFromBeforeASortSwitchIsDropped() async {
        let (social, transport) = await rig()
        await social.loadComments(song)
        await transport.holdRead(.page)
        let late = Task { await social.loadMoreComments(song) }
        while !(await transport.isReadHeld(.page)) { await Task.yield() }
        await social.selectSort(social.list(song)!.header!.sorts[1], for: song)
        #expect(social.list(song)?.threads.map(\.id) == ["n1", "n2"])
        await transport.releaseRead(.page); await late.value
        let list = social.list(song)!
        #expect(list.threads.map(\.id) == ["n1", "n2"] && list.pages == 1 && !list.loadingMore && list.next == token("moreNew"), "the old order's page did not join the new order")
    }
    @Test func aLateRepliesAnswerFromBeforeASortSwitchIsDropped() async {
        let (social, transport) = await rig()
        await social.loadComments(song)
        await transport.holdRead(.replies)
        let late = Task { await social.loadReplies(song, of: "t1") }
        while !(await transport.isReadHeld(.replies)) { await Task.yield() }
        await social.selectSort(social.list(song)!.header!.sorts[1], for: song)
        await transport.releaseRead(.replies); await late.value
        #expect(social.list(song)?.replies.isEmpty == true)
    }
    @Test func anAccountChangeDropsLateOpenMoreSortAndReplyAnswers() async {
        let (social, transport) = await rig()
        await transport.holdRead(.open)
        let opening = Task { await social.loadComments(song) }
        while !(await transport.isReadHeld(.open)) { await Task.yield() }
        social.accountChanged()
        await transport.releaseRead(.open); await opening.value
        #expect(social.state(song) == .idle, "the old account's answer did not appear")
        await social.loadComments(song)
        for kind in [ScriptedComments.Kind.page, .replies, .page] {
            await transport.holdRead(kind)
            let task = Task { switch kind { case .page: await social.loadMoreComments(song); default: await social.loadReplies(song, of: "t1") } }
            while !(await transport.isReadHeld(kind)) { await Task.yield() }
            social.accountChanged()
            await transport.releaseRead(kind); await task.value
            #expect(social.state(song) == .idle, "\(kind)")
            await social.loadComments(song)
        }
        let sorts = social.list(song)!.header!.sorts
        await transport.holdRead(.page)
        let sorting = Task { await social.selectSort(sorts[1], for: song) }
        while !(await transport.isReadHeld(.page)) { await Task.yield() }
        social.accountChanged()
        await transport.releaseRead(.page); await sorting.value
        #expect(social.state(song) == .idle)
    }
    @Test func aLateAnswerFromBeforeAnAccountChangeNeverJoinsTheNewAccountsList() async {
        let (social, transport) = await rig()
        await social.loadComments(song)
        await transport.holdRead(.page)
        let late = Task { await social.loadMoreComments(song) }
        while !(await transport.isReadHeld(.page)) { await Task.yield() }
        social.accountChanged()
        // The new account opens the very same song before the old account's page comes back.
        await social.loadComments(song)
        #expect(social.list(song)?.threads.map(\.id) == ["t1", "t2"] && social.list(song)?.pages == 1)
        await transport.releaseRead(.page); await late.value
        let list = social.list(song)!
        #expect(list.threads.map(\.id) == ["t1", "t2"] && list.pages == 1 && !list.loadingMore, "the old account's page was not appended to the new account's list")
    }
    @Test func aFailedSortKeepsTheOldOrderAndItsControlsAndSaysSo() async {
        let (social, transport) = await rig()
        await transport.set(pageAnswer: .failure(.offline), for: "sortNew")
        await social.loadComments(song)
        await social.selectSort(social.list(song)!.header!.sorts[1], for: song)
        var list = social.list(song)!
        #expect(list.sortFailure == .offline && !list.sorting && !list.needsReopen && list.threads.map(\.id) == ["t1", "t2"])
        await social.loadMoreComments(song)
        #expect(social.list(song)?.threads.map(\.id) == ["t1", "t2", "t3"], "the old order's pages still work after a failed switch")
        list = social.list(song)!
        #expect(list.sortFailure == .offline)
    }
    @Test func anOutOfDateAnswerAsksForTheCommentsToBeShownAgainWithoutSendingMore() async {
        let (social, transport) = await rig()
        await transport.set(pageAnswer: .failure(.outOfDate), for: "more1")
        await social.loadComments(song)
        await social.loadMoreComments(song)
        var list = social.list(song)!
        #expect(list.needsReopen && list.moreFailure == .outOfDate)
        let before = await transport.counts()
        await social.loadMoreComments(song); await social.loadReplies(song, of: "t1")
        await social.selectSort(list.header!.sorts[1], for: song)
        #expect(await transport.counts() == before, "a list that needs to be shown again sends nothing")
        await social.loadComments(song)
        list = social.list(song)!
        let opens = await transport.reads.count
        #expect(!list.needsReopen && list.moreFailure == nil && list.pages == 1 && opens == 2)
    }
    @Test func retryIsExplicitAndSendsOneRead() async {
        let (social, transport) = await rig()
        await transport.set(readFailure: .rateLimited)
        await social.loadComments(song)
        #expect(social.state(song) == .failed(.rateLimited) && social.readCount == 1)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await transport.reads.count == 1, "nothing retried by itself")
        await transport.set(readFailure: nil)
        await social.loadComments(song)
        #expect(await transport.reads.count == 2 && social.list(song) != nil)
    }
    @Test func aRenamedSongIsTheSameContext() async {
        let (social, transport) = await rig()
        await transport.holdRead(.open)
        let pending = Task { await social.loadComments(song) }
        while !(await transport.isReadHeld(.open)) { await Task.yield() }
        let renamed = SocialSubject(kind: .song, id: song.id, title: "The same song, retitled")
        #expect(social.state(renamed) == .loading)
        await social.loadComments(renamed)
        #expect(await transport.reads.count == 1, "one context per song: the retitled subject did not start a second open")
        await transport.releaseRead(.open); await pending.value
        #expect(social.list(renamed)?.threads.map(\.id) == ["t1", "t2"])
        #expect(song == renamed && song.hashValue == renamed.hashValue)
    }
    @Test func signedOutAndSignedInReadTheSameWay() async {
        for state in [SearchPlayback.needsSignIn, .available] {
            let (social, transport) = await rig(signedIn: state)
            await social.loadComments(song)
            await social.loadMoreComments(song)
            await social.loadReplies(song, of: "t1")
            #expect(await transport.counts() == (3, 0, 0), "\(state)")
        }
    }
}

@Suite @MainActor struct CommentWriteRefusalTests {
    @Test func whileWritesAreUnresolvedPostAndModerateAreRefusedInTheAppsWordsWithNoTransportCall() async {
        let transport = ReadOnlyComments()
        let social = SocialSurface(transport: transport)
        await social.loadComments(song)
        let loaded = social.list(song)
        #expect(loaded?.canPost == true && loaded?.comments.first?.moderation.isEmpty == false, "the page even offers both: the refusal is the app's, not the page's")
        #expect(social.writesUnresolved != nil)
        let post = await social.post("Hello", on: song)
        guard case .sourceUnresolved(let why) = post else { Issue.record("expected the app's own refusal, got \(post)"); return }
        #expect(why.contains("aren’t available from this app yet") && !why.contains("didn’t offer") && !why.contains("YouTube Music didn"))
        let comment = social.list(song)!.comments[0]
        guard case .sourceUnresolved = await social.moderate(comment.moderation[0], comment: comment, on: song, confirmation: social.confirmation(for: comment.moderation[0], comment: comment, on: song)) else { Issue.record("expected the app's own refusal"); return }
        #expect(await transport.writes == 0 && social.postCount == 0 && social.moderationCount == 0)
        #expect(social.outbox.entries.allSatisfy { !$0.wasSent } && social.outbox.entries.first?.result.message.contains("Nothing was sent") == true)
        #expect(await transport.opens == 1, "reading is unaffected")
    }
    @Test func signedOutIsRefusedTheSameWayAndSendsNothing() async {
        let transport = ReadOnlyComments()
        let social = SocialSurface(transport: transport, signedIn: { .needsSignIn })
        await social.loadComments(song)
        #expect(await social.post("Hello", on: song) == .sourceUnresolved(CommentsFailure.writesUnavailable.message))
        #expect(await transport.writes == 0)
    }
    @Test func aTransportThatSaysItCanWriteKeepsTheWriteRules() async {
        let transport = ScriptedComments()
        #expect(transport.writesUnresolved == nil)
        let social = SocialSurface(transport: transport)
        #expect(social.writesUnresolved == nil)
        await social.loadComments(song)
        #expect(await social.post("Hello", on: song) == .confirmed)
    }
    @Test func theDefaultReasonIsTheAppsAndNeverTheServices() {
        let reason = CommentsFailure.writesUnavailable.message
        #expect(reason.contains("Posting and moderating comments aren’t available from this app yet") && !reason.contains("didn’t offer"))
        #expect(UnresolvedCommentsTransport().writesUnresolved == reason)
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
        #expect(social.list(song)?.comments.isEmpty == true, "the source's answer did not include it, so it is not shown")
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
            let writesUnresolved: String? = nil
            func open(_ subject: SocialSubject) async throws -> CommentsOpening {
                .page(CommentsPage(comments: [SocialComment(id: "a", author: "A", text: "T", moderation: [ModerationOffer(id: "report", title: "Report")])], canPost: true))
            }
            func page(_ token: CommentsToken, on subject: SocialSubject) async throws -> CommentsPage { throw Mystery() }
            func replies(_ token: CommentsToken, of thread: SocialComment, on subject: SocialSubject) async throws -> CommentsReplies { throw Mystery() }
            func post(_ text: String, on subject: SocialSubject) async throws -> SocialWriteAnswer { throw Mystery() }
            func moderate(_ offer: ModerationOffer, comment: SocialComment, on subject: SocialSubject) async throws -> SocialWriteAnswer { throw Mystery() }
        }
        let social = SocialSurface(transport: Throwing())
        await social.loadComments(song)
        #expect(await social.post("Hello", on: song) == .unconfirmed)
        let a = social.list(song)!.comments[0]
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
        #expect(social.list(song) == nil && social.busy.isEmpty)
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
        let a = social.list(song)!.comments[0]
        #expect(await social.moderate(report, comment: a, on: song) == .confirmed)
        let sent = await transport.moderations
        #expect(sent.count == 1 && sent[0].0 == report && sent[0].1 == "a")
    }
    @Test func anActionOfferedOnAnotherCommentIsRefused() async {
        let (social, transport) = await rig()
        let pages = social.list(song)!.comments
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
        let a = social.list(song)!.comments[0]
        let forged = ModerationOffer(id: "report", title: "Report", destructive: true)
        #expect(await social.moderate(forged, comment: a, on: song) == .denied(.notAllowedOnThisComment))
        #expect(await transport.counts().moderations == 0)
    }
    @Test func aDestructiveActionNeedsTheConfirmationThatNamesItAndOneConfirmationIsOneRequest() async {
        let (social, transport) = await rig()
        let a = social.list(song)!.comments[0]
        #expect(await social.moderate(hide, comment: a, on: song) == .denied(.needsConfirmation))
        let question = try! #require(social.confirmation(for: hide, comment: a, on: song))
        #expect(question.author == "Ann" && question.commentID == "a" && question.offer == hide, "the question names the comment")
        #expect(await transport.counts().moderations == 0)
        #expect(await social.moderate(hide, comment: a, on: song, confirmation: question) == .confirmed)
        #expect(await transport.counts().moderations == 1 && social.moderationCount == 1)
    }
    @Test func aConfirmationForAnotherCommentOrAnotherOfferOrAChangedCommentIsNoAnswer() async {
        let (social, transport) = await rig()
        let comments = social.list(song)!.comments
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
        let comments = social.list(song)!.comments
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
        let a = social.list(song)!.comments[0]
        await transport.set(moderateAnswer: .success(.rejected(nil)))
        guard case .failed(_, true) = await social.moderate(report, comment: a, on: song) else { Issue.record("expected a sent refusal"); return }
        await transport.set(moderateAnswer: .success(.indeterminate))
        #expect(await social.moderate(report, comment: a, on: song) == .unconfirmed)
        #expect(await transport.counts().moderations == 2, "each press is one request; none repeats by itself")
    }
    @Test func anUnreadableReplyToASentModerationIsNotConfirmed() async {
        let (social, transport) = await rig()
        let a = social.list(song)!.comments[0]
        await transport.set(moderateAnswer: .failure(.unreadable))
        #expect(await social.moderate(report, comment: a, on: song) == .unconfirmed)
        #expect(await transport.counts().moderations == 1)
    }
    @Test func aConfirmedModerationReadsTheListAgain() async {
        let (social, transport) = await rig()
        let a = social.list(song)!.comments[0]
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
