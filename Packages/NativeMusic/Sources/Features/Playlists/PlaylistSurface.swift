import AccountSession
import Foundation
import Observation
import SwiftUI

/// The playlist editing state the screens share: one editing session per playlist (so the sheet reopens on the same state), the
/// creator, and the one place that hands out links. Created by the shell; the environment carries it to the catalog and library pages.
@MainActor @Observable public final class PlaylistSurface {
    public let creator: PlaylistCreator
    public let joiner: PlaylistJoiner
    /// The labelled development data answers instead of the service (Debug, isolated UI runs only).
    public let development: Bool
    /// Invalidates direct chooser presentations even when switching between two signed-in accounts.
    public private(set) var accountGeneration: UInt64 = 0
    @ObservationIgnored private let makeSession: @MainActor (String) -> PlaylistEditSession
    @ObservationIgnored private var sessions: [String: PlaylistEditSession] = [:]
    @ObservationIgnored public weak var performer: (any SearchActionPerformer)?
    @ObservationIgnored private let playbackState: @MainActor () -> SearchPlayback
    @ObservationIgnored private let choices: @Sendable () async throws -> [PlaylistListing]

    public init(creator: PlaylistCreator, joiner: PlaylistJoiner, makeSession: @escaping @MainActor (String) -> PlaylistEditSession, performer: (any SearchActionPerformer)?,
                playback: @escaping @MainActor () -> SearchPlayback, development: Bool = false, choices: @escaping @Sendable () async throws -> [PlaylistListing] = { [] }) {
        self.creator = creator; self.joiner = joiner; self.makeSession = makeSession; self.performer = performer; playbackState = playback; self.development = development; self.choices = choices
    }
    /// The person's own playlists (ids and titles), read for the Add to Playlist chooser. A read; it changes nothing.
    public func playlistChoices() async throws -> [PlaylistListing] { try await choices() }
    public var playback: SearchPlayback { playbackState() }
    /// Editing is offered only to a signed-in account, and only on a playlist the service's own page marks as editable.
    public var isSignedIn: Bool { playback == .available }
    public func session(for playlistID: String) -> PlaylistEditSession {
        let id = MusicPlaylistRequest.playlistID(fromBrowseID: playlistID)
        if let existing = sessions[id] { return existing }
        let made = makeSession(id)
        sessions[id] = made
        return made
    }
    /// Copies the canonical link to the clipboard. Only an explicit Copy Link press reaches this.
    @discardableResult public func copyLink(playlistID: String) -> Bool {
        guard let url = PlaylistSharing.canonicalURL(playlistID: playlistID), let performer else { return false }
        performer.copy(link: url)
        return true
    }
    /// Copies a validated link (an invite link). Only an explicit press reaches this.
    @discardableResult public func copy(link: URL) -> Bool {
        guard let performer else { return false }
        performer.copy(link: link); return true
    }
    public func accountChanged() {
        accountGeneration &+= 1
        for session in sessions.values { session.accountChanged() }
        sessions = [:]; creator.accountChanged(); joiner.accountChanged()
    }
}

private struct PlaylistSurfaceKey: EnvironmentKey { static let defaultValue: PlaylistSurface? = nil }
public extension EnvironmentValues {
    /// The shell's playlist editing surface, for catalog pages and the Library.
    var playlistSurface: PlaylistSurface? {
        get { self[PlaylistSurfaceKey.self] }
        set { self[PlaylistSurfaceKey.self] = newValue }
    }
}
