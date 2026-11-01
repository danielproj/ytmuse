import AccountSession
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// A song carried by a drag from a search result, an album or artist page, or a library row. It is a value copied out of the row (the
/// video id and the name the confirmation shows); dropping it on a playlist only *stages* an add, which then goes through the same
/// confirmed path as every other add (naming confirmation for several songs, Keep duplicates / Skip existing). Nothing is sent by a drop.
public struct PlaylistDraggedSong: Codable, Transferable, Equatable, Sendable {
    /// Marks the payload as this app's: JSON from anywhere else does not decode into a song.
    public let format: String
    public let videoID: String
    public let title: String
    public static let currentFormat = "ytmuse.song.v1"
    public init?(videoID: String?, title: String) {
        guard let videoID, MusicPlaylistRequest.isVideoID(videoID), !title.isEmpty, title.count <= 512 else { return nil }
        self.format = Self.currentFormat; self.videoID = videoID; self.title = title
    }
    /// Valid only if it is this app's format with a real video id: a drop of anything else is ignored.
    public var isValid: Bool { format == Self.currentFormat && MusicPlaylistRequest.isVideoID(videoID) && !title.isEmpty && title.count <= 512 }
    public var addition: PlaylistAddition { PlaylistAddition(videoID: videoID, title: title) }
    public static var transferRepresentation: some TransferRepresentation { CodableRepresentation(contentType: .json) }
    /// The valid songs among the dropped values, in order, at most 50.
    public static func additions(from dropped: [PlaylistDraggedSong]) -> [PlaylistAddition] {
        Array(dropped.filter(\.isValid).map(\.addition).prefix(MusicPlaylistRequest.maximumActions))
    }
}

public extension View {
    /// Makes a song row draggable as a song to add to a playlist. Rows that are not songs (or carry no video id) are not draggable.
    @ViewBuilder func songDraggable(videoID: String?, title: String, kind: MusicEntityKind) -> some View {
        if kind == .song || kind == .video, let song = PlaylistDraggedSong(videoID: videoID, title: title) { draggable(song) } else { self }
    }
}
