import Foundation

/// The single published radio chip operation supported by the player: update the autoplay
/// section, deduplicating against the local queue. Endpoint kind is always watchEndpoint,
/// even without a video. No caller can supply another operation or arbitrary command object.
public struct MusicQueueFilterCommand: Equatable, Sendable {
    public let playlistID: String
    public let params: String
    public let playerParams: String?

    public init?(playlistID: String, params: String, playerParams: String? = nil) {
        func idByte(_ b: UInt8) -> Bool {
            (48...57).contains(b) || (65...90).contains(b) || (97...122).contains(b) || b == 45 || b == 95
        }
        func opaque(_ s: String) -> Bool {
            (1...1024).contains(s.utf8.count) && s.utf8.allSatisfy { idByte($0) || [37, 61, 43, 47, 46].contains($0) }
        }
        guard (2...128).contains(playlistID.utf8.count), playlistID.utf8.allSatisfy(idByte),
              opaque(params), playerParams.map(opaque) ?? true else { return nil }
        self.playlistID = playlistID; self.params = params; self.playerParams = playerParams
    }
}
