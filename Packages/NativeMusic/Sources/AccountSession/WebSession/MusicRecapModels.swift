import Foundation

/// The one route the signed Recap read uses: the `browse` handler `FEmusic_listening_review`. PROVENANCE: the id was taken from a third-party
/// client (YouTube.js `Music.getRecap()`, MIT), NOT from a first-party navigation entry: the signed account's menu and guide published no Recap
/// entry and no such handler. It is confirmed to be a real handler by its own self-identification in an anonymous capture (`browse_id`,
/// `GetBrowseListeningReviewPage_rid`, `logged_in=0`) and by an HTTP 400 control for an invented id; the parent then dispatched the known id through
/// the official page navigator for one signed capture (R1, 2026-11-05). Dispatching a known id is not discovery from a first-party navigation entry,
/// and nothing here says the service offers Recap to any account. Nothing else is requested and no other id, URL or client is ever built from this.
public enum MusicRecapRoute {
    /// The `browseId` of the Recap handler.
    public static let browseID = "FEmusic_listening_review"
    /// Upper bound on the response body. The only answer ever captured is a few kilobytes; anything larger is not a message envelope.
    public static let maximumResponseBytes = 1_000_000
    /// Bounds on a service message, in UTF-8 bytes. An over-long text is refused (unreadable), never truncated into a different message.
    public static let maximumHeadlineBytes = 1_000
}

/// A message the service sent in place of a Recap. Its words are the service's own, read as text at run time; this application writes none of them.
/// What the message MEANS is not established by any capture: it may be an upstream fault as well as a statement about the account, so it is never
/// reported as "no Recap", "unsupported account" or "empty".
public struct MusicRecapServiceMessage: Sendable, Equatable {
    /// The message's primary text (`messageRenderer.text`), runs joined as printed.
    public let headline: String
    /// A secondary line. Always nil for now: the captured secondary text sits under keys the export redacted, so it is withheld until evidenced.
    /// Kept so a later, evidenced reader does not change the model.
    public let detail: String?
    public init(headline: String, detail: String? = nil) { self.headline = headline; self.detail = detail }
}

/// What one Recap read can honestly say. A successful Recap summary is deliberately NOT a case: no signed successful payload has been captured,
/// so an answer carrying anything but the recognised message envelope is `MusicSessionError.unrecognised`, never a guess.
public enum MusicRecapReading: Sendable, Equatable {
    /// The service answered for the signed-out state (`logged_in` = 0). The pure parser reports it so anonymous captures read; the signed adapter
    /// read turns it into `MusicSessionError.signedOut` (an unauthenticated signed read ends the session like every other signed read).
    case needsSignIn
    /// The service answered with a message of its own instead of Recap contents.
    case serviceMessage(MusicRecapServiceMessage)
}
