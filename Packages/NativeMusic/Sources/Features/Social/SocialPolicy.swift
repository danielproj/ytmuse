import AccountSession
import Foundation

/// How the signed-in person relates to the thing a social action is about. Derived only from what the service published for it
/// (a playlist's editing rights, a comment's own moderation offer); never assumed from a name or an id.
public enum SocialRole: String, Sendable, Equatable {
    case signedOut
    /// Signed in, with no special standing on this item.
    case member
    /// May add to a shared playlist.
    case collaborator
    /// Owns the playlist (the service offered deletion).
    case owner
    public static func of(_ playlistRole: MusicPlaylistRole, signedIn: Bool) -> SocialRole {
        guard signedIn else { return .signedOut }
        switch playlistRole { case .owner: return .owner; case .collaborator: return .collaborator; case .saved, .viewer: return .member }
    }
}

public enum SocialActionKind: String, Sendable, Equatable, CaseIterable {
    case readComments, postComment, moderateComment, rate, createInvite, stopContributions
    public var title: String {
        switch self {
        case .readComments: String(localized: "Read comments")
        case .postComment: String(localized: "Post a comment")
        case .moderateComment: String(localized: "Moderate a comment")
        case .rate: String(localized: "Rate")
        case .createInvite: String(localized: "Create an invite link")
        case .stopContributions: String(localized: "Stop contributions")
        }
    }
}
public enum SocialDenial: Sendable, Equatable {
    case needsSignIn, notOwner, notOffered(String), notAllowedOnThisComment, needsConfirmation, invalid(String), busy
    public var message: String {
        switch self {
        case .needsSignIn: String(localized: "Sign in to YouTube Music to do this.")
        case .notOwner: String(localized: "Only the playlist’s owner can do this.")
        case .notOffered(let why): why
        case .notAllowedOnThisComment: String(localized: "YouTube Music didn’t offer this action on this comment.")
        case .needsConfirmation: String(localized: "This needs your confirmation first.")
        case .invalid(let why): why
        case .busy: String(localized: "Another request for this is still in progress.")
        }
    }
}
public enum SocialPermission: Sendable, Equatable {
    case allowed
    case denied(SocialDenial)
    public var isAllowed: Bool { self == .allowed }
}

/// The role rules, in one place. A denied action is never sent; the reason is shown where the action would be.
public enum SocialPolicy {
    public static func permission(_ action: SocialActionKind, role: SocialRole) -> SocialPermission {
        switch action {
        case .readComments, .postComment, .moderateComment, .rate:
            return role == .signedOut ? .denied(.needsSignIn) : .allowed
        case .createInvite, .stopContributions:
            switch role {
            case .signedOut: return .denied(.needsSignIn)
            case .owner: return .allowed
            case .member, .collaborator: return .denied(.notOwner)
            }
        }
    }
}
