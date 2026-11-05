import Foundation

/// Which part of the queue a published radio chip replaces. YouTube Music has published both: the R1 capture (2026-11-03) carried
/// `AUTOPLAY` (fetched songs are added after the queue), and by 2026-11-05 every chip carried `QUEUE` (the songs after the current one are
/// replaced, which is what the official page does when a chip is clicked). Only these two values are known; any other is unrecognised.
public enum MusicQueueUpdateSection: String, Equatable, Sendable, CaseIterable {
    case autoplay = "QUEUE_UPDATE_SECTION_AUTOPLAY"
    case queue = "QUEUE_UPDATE_SECTION_QUEUE"
}

/// The single published radio chip operation supported by the player: update the section the chip
/// names, deduplicating against the local queue. Endpoint kind is always watchEndpoint,
/// even without a video. No caller can supply another operation or arbitrary command object.
public struct MusicQueueFilterCommand: Equatable, Sendable {
    public let playlistID: String
    public let params: String
    public let playerParams: String?
    /// The section the chip itself published, sent back unchanged.
    public let section: MusicQueueUpdateSection

    public init?(playlistID: String, params: String, playerParams: String? = nil, section: MusicQueueUpdateSection = .autoplay) {
        func idByte(_ b: UInt8) -> Bool {
            (48...57).contains(b) || (65...90).contains(b) || (97...122).contains(b) || b == 45 || b == 95
        }
        func opaque(_ s: String) -> Bool {
            (1...1024).contains(s.utf8.count) && s.utf8.allSatisfy { idByte($0) || [37, 61, 43, 47, 46].contains($0) }
        }
        guard (2...128).contains(playlistID.utf8.count), playlistID.utf8.allSatisfy(idByte),
              opaque(params), playerParams.map(opaque) ?? true else { return nil }
        self.playlistID = playlistID; self.params = params; self.playerParams = playerParams; self.section = section
    }
}
