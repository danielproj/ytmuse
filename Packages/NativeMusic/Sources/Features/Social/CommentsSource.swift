import Foundation

/// What a social action is about: one item of the service, named by its own id. A transport is given this and nothing else — never a URL,
/// never a page address — so there is no way to ask it to read an arbitrary external site.
public struct SocialSubject: Hashable, Sendable {
    public enum Kind: String, Sendable { case song, playlist }
    public let kind: Kind
    public let id: String
    public let title: String
    public init(kind: Kind, id: String, title: String) { self.kind = kind; self.id = id; self.title = title }
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
    public init(id: String, author: String, text: String, posted: String? = nil, moderation: [ModerationOffer] = []) {
        self.id = id; self.author = author; self.text = text; self.posted = posted; self.moderation = moderation
    }
}
public struct CommentsPage: Equatable, Sendable {
    public let comments: [SocialComment]
    /// The source offered this person a way to post here.
    public let canPost: Bool
    public init(comments: [SocialComment], canPost: Bool) { self.comments = comments; self.canPost = canPost }
}
public enum CommentsFailure: Error, Equatable, Sendable {
    case offline, needsSignIn, sessionEnded, unreadable, rateLimited
    public var message: String {
        switch self {
        case .offline: String(localized: "You’re offline, so nothing was sent or loaded.")
        case .needsSignIn: String(localized: "Sign in to YouTube Music to do this.")
        case .sessionEnded: String(localized: "Your YouTube Music session ended. Sign in again.")
        case .unreadable: String(localized: "YouTube Music’s answer couldn’t be read, so nothing is shown.")
        case .rateLimited: String(localized: "YouTube Music is asking for a pause. Nothing was changed.")
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
/// Where comments and their moderation come from. The application composes `UnresolvedCommentsTransport` until a route is verified
/// (W38): no captured YouTube Music response carries comments, so no shape or request is assumed.
public protocol CommentsTransport: Sendable {
    /// nil: a route exists. Otherwise why there is none, shown where comments would be.
    var unresolved: String? { get }
    func read(_ subject: SocialSubject) async throws -> CommentsPage
    func post(_ text: String, on subject: SocialSubject) async throws -> SocialWriteAnswer
    func moderate(_ offer: ModerationOffer, comment: SocialComment, on subject: SocialSubject) async throws -> SocialWriteAnswer
}
public struct UnresolvedCommentsTransport: CommentsTransport {
    public init() {}
    public var unresolved: String? {
        String(localized: "Comments aren’t available yet. None of the YouTube Music responses this app can read carries them, so there is nothing to read, post or moderate.")
    }
    public func read(_ subject: SocialSubject) async throws -> CommentsPage { throw CommentsFailure.unreadable }
    public func post(_ text: String, on subject: SocialSubject) async throws -> SocialWriteAnswer { throw CommentsFailure.unreadable }
    public func moderate(_ offer: ModerationOffer, comment: SocialComment, on subject: SocialSubject) async throws -> SocialWriteAnswer { throw CommentsFailure.unreadable }
}
