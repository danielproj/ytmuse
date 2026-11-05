import Foundation

/// What a social action is about: one item of the service, named by its own id. A transport is given this and nothing else — never a URL,
/// never a page address — so there is no way to ask it to read an arbitrary external site.
///
/// Two subjects are the same subject when they name the same item: the title is only what is printed for it. (A comments context is one per
/// item; a title that changed between two renders must not become a second, independent context that invalidates the first.)
public struct SocialSubject: Hashable, Sendable {
    public enum Kind: String, Sendable { case song, playlist }
    public let kind: Kind
    public let id: String
    public let title: String
    public init(kind: Kind, id: String, title: String) { self.kind = kind; self.id = id; self.title = title }
    public static func == (left: SocialSubject, right: SocialSubject) -> Bool { left.kind == right.kind && left.id == right.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(kind); hasher.combine(id) }
    public var description: String {
        switch kind {
        case .song: String(localized: "“\(title)”")
        case .playlist: String(localized: "the playlist “\(title)”")
        }
    }
}
/// One action the source offered on one comment. The application defines none: the list is exactly what the source supplied.
public struct ModerationOffer: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    /// Removes or hides something; asks for a confirmation that names the comment.
    public let destructive: Bool
    public init(id: String, title: String, destructive: Bool = false) { self.id = id; self.title = title; self.destructive = destructive }
}
public struct SocialComment: Identifiable, Equatable, Sendable {
    public let id: String
    public let author: String
    public let text: String
    /// When it was posted, as the source printed it.
    public let posted: String?
    /// What the source offered the signed-in person to do with this comment (empty: nothing).
    public let moderation: [ModerationOffer]
    /// The like count and, on a top-level comment, the reply count, as the source printed them ("306", "10"); never parsed, never recomputed.
    public let likeCountText: String?
    public let replyCountText: String?
    /// The author flags exactly as the source published them.
    public let isVerified: Bool, isCreator: Bool, isArtist: Bool, isCurrentUser: Bool
    /// 0 for a top-level comment, 1 and above for replies.
    public let level: Int
    public init(id: String, author: String, text: String, posted: String? = nil, moderation: [ModerationOffer] = [], likeCountText: String? = nil,
                replyCountText: String? = nil, isVerified: Bool = false, isCreator: Bool = false, isArtist: Bool = false, isCurrentUser: Bool = false, level: Int = 0) {
        self.id = id; self.author = author; self.text = text; self.posted = posted; self.moderation = moderation
        self.likeCountText = likeCountText; self.replyCountText = replyCountText
        self.isVerified = isVerified; self.isCreator = isCreator; self.isArtist = isArtist; self.isCurrentUser = isCurrentUser; self.level = level
    }
}

/// A continuation the SOURCE issued: a page of comments, one of its sort orders, or the replies of one thread. It is opaque here — nothing in the
/// application builds, reads, edits or shows one — and a transport accepts a token and nothing else (never a URL or a bare string) as the address
/// of a read. The coordinator behind the transport additionally refuses a token that was not issued for this song, thread, list and account.
public struct CommentsToken: Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}
/// One entry of the sort menu as the source printed it: its title, whether it is the selected one, and the token that switches to it.
public struct CommentsSortOption: Equatable, Sendable {
    public let title: String
    public let isSelected: Bool
    public let token: CommentsToken
    public init(title: String, isSelected: Bool, token: CommentsToken) { self.title = title; self.isSelected = isSelected; self.token = token }
}
public struct CommentsHeader: Equatable, Sendable {
    /// "2,904 Comments", as the source printed it.
    public let countText: String?
    public let sorts: [CommentsSortOption]
    public init(countText: String?, sorts: [CommentsSortOption]) { self.countText = countText; self.sorts = sorts }
}
/// A top-level comment with what the source published about its replies: replies already inline, and a token that reads them.
public struct CommentThread: Identifiable, Equatable, Sendable {
    public let comment: SocialComment
    public let repliesToken: CommentsToken?
    public let inlineReplies: [SocialComment]
    public var id: String { comment.id }
    public init(comment: SocialComment, repliesToken: CommentsToken? = nil, inlineReplies: [SocialComment] = []) {
        self.comment = comment; self.repliesToken = repliesToken; self.inlineReplies = inlineReplies
    }
}
/// One page of the source's comments: the first page (with its header), the page after, or a sort switch (with its header).
public struct CommentsPage: Equatable, Sendable {
    public let header: CommentsHeader?
    public let threads: [CommentThread]
    /// The token of the next page; nil on the last page.
    public let next: CommentsToken?
    /// The source offered this person a way to post here (never true for a source whose writes are unresolved).
    public let canPost: Bool
    public var comments: [SocialComment] { threads.map(\.comment) }
    public init(header: CommentsHeader? = nil, threads: [CommentThread], next: CommentsToken? = nil, canPost: Bool = false) {
        self.header = header; self.threads = threads; self.next = next; self.canPost = canPost
    }
    /// A page of plain top-level comments with no replies and no further page.
    public init(comments: [SocialComment], canPost: Bool) {
        self.init(header: nil, threads: comments.map { CommentThread(comment: $0) }, next: nil, canPost: canPost)
    }
}
public struct CommentsReplies: Equatable, Sendable {
    /// The id of the top-level comment these answer.
    public let parentID: String
    public let replies: [SocialComment]
    public let next: CommentsToken?
    public init(parentID: String, replies: [SocialComment], next: CommentsToken? = nil) { self.parentID = parentID; self.replies = replies; self.next = next }
}
/// What opening a song's comments answered.
public enum CommentsOpening: Equatable, Sendable {
    case page(CommentsPage)
    /// The song has no comments tab. This is not "no comments".
    case notOffered
    /// The comments tab printed a message of its own instead of comments ("Comments are turned off."), carried verbatim.
    case serviceMessage(String)
}

public enum CommentsFailure: Error, Equatable, Sendable {
    case offline, needsSignIn, sessionEnded, unreadable, rateLimited
    /// The list this read belonged to was replaced (another open or sort, a changed account, or the app forgot it). Nothing is wrong with the
    /// service: the comments are shown again from the start.
    case outOfDate
    /// This app has no route to post or moderate comments, so nothing was sent.
    case writesUnavailable
    public var message: String {
        switch self {
        case .offline: String(localized: "You’re offline, so nothing was sent or loaded.")
        case .needsSignIn: String(localized: "Sign in to YouTube Music to do this.")
        case .sessionEnded: String(localized: "Your YouTube Music session ended. Sign in again.")
        case .unreadable: String(localized: "YouTube Music’s answer couldn’t be read, so nothing is shown.")
        case .rateLimited: String(localized: "YouTube Music is asking for a pause. Nothing was changed.")
        case .outOfDate: String(localized: "This list of comments is out of date. Show the comments again.")
        case .writesUnavailable: String(localized: "Posting and moderating comments aren’t available from this app yet.")
        }
    }
}
public enum SocialWriteAnswer: Equatable, Sendable {
    case confirmed
    /// The source answered and refused (its own words when it gave some).
    case rejected(String?)
    /// The request left and the outcome is unknown.
    case indeterminate
}
/// Where comments come from, and where their posting and moderation would go. Reading needs no account. The application composes a coordinator-backed
/// transport that READS (`CommentsComposition`) and says, through `writesUnresolved`, that it has no verified route to write: no captured signed
/// response shows what a post or a moderation looks like, so none is assumed.
public protocol CommentsTransport: Sendable {
    /// nil: a read route exists. Otherwise why there is none, shown where comments would be.
    var unresolved: String? { get }
    /// nil: a verified write route exists. Otherwise why posting and moderating are unavailable. The default is "unresolved", so a transport has
    /// to say it can write; the surface refuses every post and moderation without calling the transport while this is non-nil.
    var writesUnresolved: String? { get }
    /// Opens a song's comments: at most the two reads the source needs (its Comments tab, then the first page).
    func open(_ subject: SocialSubject) async throws -> CommentsOpening
    /// One read of the page or sort order a token the source issued names.
    func page(_ token: CommentsToken, on subject: SocialSubject) async throws -> CommentsPage
    /// One read of the replies of `thread` (a top-level comment of this subject), or of their next page.
    func replies(_ token: CommentsToken, of thread: SocialComment, on subject: SocialSubject) async throws -> CommentsReplies
    func post(_ text: String, on subject: SocialSubject) async throws -> SocialWriteAnswer
    func moderate(_ offer: ModerationOffer, comment: SocialComment, on subject: SocialSubject) async throws -> SocialWriteAnswer
}
public extension CommentsTransport {
    var writesUnresolved: String? { CommentsFailure.writesUnavailable.message }
}
/// The transport of isolated automation and of any session with no connection: nothing is read, posted or moderated, and the screens say so.
public struct UnresolvedCommentsTransport: CommentsTransport {
    public init() {}
    public var unresolved: String? {
        String(localized: "Comments aren’t connected in this session, so nothing is read, posted or moderated.")
    }
    public func open(_ subject: SocialSubject) async throws -> CommentsOpening { throw CommentsFailure.unreadable }
    public func page(_ token: CommentsToken, on subject: SocialSubject) async throws -> CommentsPage { throw CommentsFailure.unreadable }
    public func replies(_ token: CommentsToken, of thread: SocialComment, on subject: SocialSubject) async throws -> CommentsReplies { throw CommentsFailure.unreadable }
    public func post(_ text: String, on subject: SocialSubject) async throws -> SocialWriteAnswer { throw CommentsFailure.writesUnavailable }
    public func moderate(_ offer: ModerationOffer, comment: SocialComment, on subject: SocialSubject) async throws -> SocialWriteAnswer { throw CommentsFailure.writesUnavailable }
}
