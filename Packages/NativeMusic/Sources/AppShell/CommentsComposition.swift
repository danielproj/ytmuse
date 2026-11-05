import AccountSession
import Features
import Foundation

/// Comments, read through the account coordinator and nothing else.
///
/// The coordinator already does everything a read needs: it signs the request when an account is active and goes anonymous otherwise, drops an
/// answer that belongs to another account, and refuses a continuation token that was not issued for this song, list and account. This type only
/// turns its answers into the screen's values and its errors into the screen's failures. It resolves the coordinator **for every request**
/// (`awaitedMusic()` inside the reader), never once at start-up: a nil coordinator captured while the account store was still opening would
/// leave comments unreadable for the whole run.
///
/// It reads. It has no write: `post` and `moderate` throw before anything is sent, `writesUnresolved` stays at its default (non-nil) so the
/// surface refuses them first, and no posting or moderation shape has ever been observed. Nothing here loads an avatar or opens a link.
struct CoordinatorCommentsTransport: CommentsTransport {
    typealias Reader = @Sendable (MusicCommentsRequest) async throws -> MusicBrowseReply<MusicCommentsAnswer>
    private let reader: Reader
    init(reader: @escaping Reader) { self.reader = reader }
    var unresolved: String? { nil }

    func open(_ subject: SocialSubject) async throws -> CommentsOpening {
        guard subject.kind == .song else { throw CommentsFailure.unreadable }
        switch try await read(.open(videoID: subject.id)) {
        case .opened(let entry, let firstPage):
            switch entry {
            case .continuation:
                // The reader returns the first page exactly when the tab published a continuation. Anything else is not an answer to use.
                guard let firstPage else { throw CommentsFailure.unreadable }
                return .page(Self.page(firstPage))
            case .serviceMessage(let message): return .serviceMessage(message)
            case .notOffered: return .notOffered
            }
        case .page, .replies: throw CommentsFailure.unreadable
        }
    }
    func page(_ token: CommentsToken, on subject: SocialSubject) async throws -> CommentsPage {
        guard subject.kind == .song else { throw CommentsFailure.unreadable }
        guard case .page(let page) = try await read(.page(token: token.rawValue, videoID: subject.id)) else { throw CommentsFailure.unreadable }
        return Self.page(page)
    }
    func replies(_ token: CommentsToken, of thread: SocialComment, on subject: SocialSubject) async throws -> CommentsReplies {
        guard subject.kind == .song else { throw CommentsFailure.unreadable }
        guard case .replies(let replies) = try await read(.replies(token: token.rawValue, videoID: subject.id, parentID: thread.id)) else { throw CommentsFailure.unreadable }
        return CommentsReplies(parentID: replies.parentID, replies: replies.replies.map(Self.comment), next: replies.nextToken.map(CommentsToken.init))
    }
    func post(_ text: String, on subject: SocialSubject) async throws -> SocialWriteAnswer { throw CommentsFailure.writesUnavailable }
    func moderate(_ offer: ModerationOffer, comment: SocialComment, on subject: SocialSubject) async throws -> SocialWriteAnswer { throw CommentsFailure.writesUnavailable }

    private func read(_ request: MusicCommentsRequest) async throws -> MusicCommentsAnswer {
        do { return try await reader(request).value }
        catch let error as MusicSessionError { throw Self.failure(error) }
    }
    /// What each session error means on this screen. A signed token whose session ended, and a list the coordinator replaced, both mean "show it again".
    static func failure(_ error: MusicSessionError) -> CommentsFailure {
        switch error {
        case .network, .timedOut: .offline
        case .rateLimited: .rateLimited
        case .stale, .signedOut: .outOfDate
        default: .unreadable
        }
    }
    static func page(_ page: MusicCommentsPage) -> CommentsPage {
        CommentsPage(header: page.header.map { header in
            CommentsHeader(countText: header.countText,
                           sorts: header.sortOptions.map { CommentsSortOption(title: $0.title, isSelected: $0.isSelected, token: CommentsToken($0.token)) })
        }, threads: page.threads.map { thread in
            CommentThread(comment: comment(thread.comment), repliesToken: thread.repliesToken.map(CommentsToken.init), inlineReplies: thread.inlineReplies.map(comment))
        }, next: page.nextToken.map(CommentsToken.init), canPost: false)
    }
    static func comment(_ comment: MusicComment) -> SocialComment {
        SocialComment(id: comment.id, author: comment.authorName, text: comment.text, posted: comment.publishedTime, moderation: [],
                      likeCountText: comment.likeCountText, replyCountText: comment.replyCountText, isVerified: comment.isVerified,
                      isCreator: comment.isCreator, isArtist: comment.isArtist, isCurrentUser: comment.isCurrentUser, level: comment.replyLevel)
    }
}

extension LocalAccountBootstrap {
    /// The comments transport for a launch: the coordinator read transport in a normal launch, and the unresolved one in isolated automation, which
    /// never acquires credentials or reaches a reader. (The Debug development data replaces either.)
    static func commentsTransport(isolated: Bool, reader: @escaping CoordinatorCommentsTransport.Reader) -> any CommentsTransport {
        isolated ? UnresolvedCommentsTransport() : CoordinatorCommentsTransport(reader: reader)
    }
    /// The live reader, resolving the coordinator on every request.
    func commentsTransport(isolated: Bool) -> any CommentsTransport {
        Self.commentsTransport(isolated: isolated) { [weak self] request in
            guard let self else { throw MusicSessionError.stale }
            return try await self.awaitedMusic().comments(request)
        }
    }
}
