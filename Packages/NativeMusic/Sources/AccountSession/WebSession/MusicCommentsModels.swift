import Foundation

/// What YouTube Music's own comments surface printed, as plain values. Every string is the service's own text, byte for byte: counts and
/// times are the PRINTED forms ("2,904 Comments", "4 weeks ago", "306"), never parsed into numbers or dates and never recomputed.
/// No URL-typed field exists: avatars and channel links are not modelled, so nothing here can be opened, fetched or forwarded.
///
/// Internal notes (not surfaced anywhere): built on the real anonymous captures in `Fixtures/MF-comments` (2026-11-05, client
/// `1.20261031.09.00`). The signed shapes (a posting offer, the author's own menu, moderation) have NOT been observed and are not modelled.

/// What a song's `next` response says about its Comments tab.
public enum MusicCommentsEntry: Sendable, Equatable {
    /// The tab publishes a continuation for the requested video: the token to send back to read the first page.
    case continuation(String)
    /// The tab prints a message instead of a continuation (for example the service's "Comments are turned off."), and the same
    /// response identified the requested video. A message in a response that does not identify the video is never returned as this case.
    case serviceMessage(String)
    /// The response is a valid watch-next page with no Comments tab.
    case notOffered
}

/// One entry of the sort menu (Top, Newest): its printed title, whether it is the selected one, and its own continuation.
public struct MusicCommentSortOption: Sendable, Equatable {
    public let title: String
    public let isSelected: Bool
    public let token: String
    public init(title: String, isSelected: Bool, token: String) { self.title = title; self.isSelected = isSelected; self.token = token }
}

/// What the page's comment box publishes about writing. Only what was observed is represented.
public enum MusicCommentsPosting: Sendable, Equatable {
    /// The box is a sign-in prompt (`prepareAccountEndpoint.signInEndpoint`): no write is offered to this session.
    case signInRequired
    /// The page published no usable box, or one this parser has no verified reading of. Nothing is offered. This is NOT "comments are off":
    /// the box carries a `disabledText` on every normal page, so that text is never read as a state.
    case notPublished
}

/// The header of a first page (and of a sort switch).
public struct MusicCommentsHeader: Sendable, Equatable {
    /// "2,904 Comments", as printed (the runs joined).
    public let countText: String?
    /// "2.9K", as printed.
    public let shortCountText: String?
    public let sortOptions: [MusicCommentSortOption]
    public let posting: MusicCommentsPosting
    public init(countText: String?, shortCountText: String?, sortOptions: [MusicCommentSortOption], posting: MusicCommentsPosting) {
        self.countText = countText; self.shortCountText = shortCountText; self.sortOptions = sortOptions; self.posting = posting
    }
}

public struct MusicComment: Sendable, Equatable {
    /// The service's comment id. A reply's id is `<thread id>.<reply id>`.
    public let id: String
    /// The id of the top-level comment this reply belongs to; nil for a top-level comment.
    public let parentID: String?
    /// 0 for a top-level comment; 1 and above for replies (a reply to a reply is level 2, and is listed under the same thread).
    public let replyLevel: Int
    public let authorName: String
    /// The author flags exactly as the service published them. `isCurrentUser` is the service's statement about THIS session; anonymously false.
    public let isVerified: Bool
    public let isCreator: Bool
    public let isArtist: Bool
    public let isCurrentUser: Bool
    /// The comment text, verbatim (bounded to 10,000 characters; a longer text is refused, not cut).
    public let text: String
    /// "4 weeks ago", as printed.
    public let publishedTime: String
    /// The printed like count without the viewer's own like ("306"); nil when the service printed none.
    public let likeCountText: String?
    /// The printed reply count of a top-level comment ("10"); nil when the service printed none.
    public let replyCountText: String?
    public init(id: String, parentID: String?, replyLevel: Int, authorName: String, isVerified: Bool, isCreator: Bool, isArtist: Bool, isCurrentUser: Bool,
                text: String, publishedTime: String, likeCountText: String?, replyCountText: String?) {
        self.id = id; self.parentID = parentID; self.replyLevel = replyLevel; self.authorName = authorName; self.isVerified = isVerified
        self.isCreator = isCreator; self.isArtist = isArtist; self.isCurrentUser = isCurrentUser; self.text = text; self.publishedTime = publishedTime
        self.likeCountText = likeCountText; self.replyCountText = replyCountText
    }
}

/// A top-level comment with what the service published about its replies: a continuation to read them, and any replies already inline.
public struct MusicCommentThread: Sendable, Equatable {
    public let comment: MusicComment
    public let repliesToken: String?
    public let inlineReplies: [MusicComment]
    public init(comment: MusicComment, repliesToken: String?, inlineReplies: [MusicComment]) {
        self.comment = comment; self.repliesToken = repliesToken; self.inlineReplies = inlineReplies
    }
}

public struct MusicCommentsPage: Sendable, Equatable {
    /// Present on a first page and on a sort switch; nil on a continuation page.
    public let header: MusicCommentsHeader?
    public let threads: [MusicCommentThread]
    /// The continuation of the next page; nil on the last page.
    public let nextToken: String?
    public init(header: MusicCommentsHeader?, threads: [MusicCommentThread], nextToken: String?) {
        self.header = header; self.threads = threads; self.nextToken = nextToken
    }
}

public struct MusicCommentsReplies: Sendable, Equatable {
    public let parentID: String
    /// Every reply of the page in the order the service listed them, a nested reply directly after the reply it hangs under.
    public let replies: [MusicComment]
    public let nextToken: String?
    public init(parentID: String, replies: [MusicComment], nextToken: String?) { self.parentID = parentID; self.replies = replies; self.nextToken = nextToken }
}

// MARK: Read requests and answers (C2)

/// One comments read. Every value is checked by `validate()` before anything is sent: a bad id or token is a policy error and nothing leaves.
///
/// A token is opaque and is only ever the service's own: a first-page continuation (followed inside `open`), a sort option's token, a
/// page's next token, or a thread's replies token. The coordinator additionally binds each token to the video, thread, list and account
/// scope that issued it (see `MusicSessionCoordinator.comments`), so a syntactically valid token from somewhere else is refused locally.
public enum MusicCommentsRequest: Sendable, Equatable {
    /// The song's `next` response, then (only when its Comments tab publishes one) the first page. At most 2 requests.
    case open(videoID: String)
    /// The next page, or a sort switch: one `next {continuation}` request.
    case page(token: String, videoID: String)
    /// The replies of one top-level comment, or their next page: one `next {continuation}` request. `parentID` is the thread's comment id.
    case replies(token: String, videoID: String, parentID: String)

    public var videoID: String {
        switch self {
        case .open(let videoID), .page(_, let videoID), .replies(_, let videoID, _): videoID
        }
    }
    /// The same shapes the adapter's parsers accept (`MusicBrowseParser.isVideoID`/`isToken`, the thread id pattern).
    public func validate() throws(MusicSessionError) {
        guard Self.matches(videoID, #"^[A-Za-z0-9_-]{11}$"#) else { throw .policy }
        switch self {
        case .open: break
        case .page(let token, _): guard Self.matches(token, Self.tokenPattern) else { throw .policy }
        case .replies(let token, _, let parentID):
            guard Self.matches(token, Self.tokenPattern), Self.matches(parentID, #"^[A-Za-z0-9_-]{1,128}$"#) else { throw .policy }
        }
    }
    static let tokenPattern = #"^[A-Za-z0-9%_=+/.-]{1,4096}$"#
    private static func matches(_ value: String, _ pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }
}

/// What one comments read answered.
public enum MusicCommentsAnswer: Sendable, Equatable {
    /// `entry` is what the Comments tab said. `firstPage` is present exactly when the tab published a continuation (the one extra request).
    /// `.notOffered` and `.serviceMessage` are never "no comments": the first means the tab is absent, the second prints the service's own message.
    case opened(entry: MusicCommentsEntry, firstPage: MusicCommentsPage?)
    case page(MusicCommentsPage)
    case replies(MusicCommentsReplies)
}
