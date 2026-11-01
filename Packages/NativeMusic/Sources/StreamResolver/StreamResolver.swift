import Domain
import AccountSession
import Foundation

/// A player response is evidence about a boundary, never a media grant.
public enum MusicMediaBoundary: String, Sendable, Codable {
    case serviceDenied, challengeRequired, sourceGrantAndEventsMissing
}
public struct MusicPlayerObservation: Sendable, Codable {
    public let status: String
    public let boundary: MusicMediaBoundary
    public let directURLCount: Int
    public let cipherCount: Int
    public init(data: Data) throws {
        guard data.count <= 2_000_000, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["error"] == nil, let play = root["playabilityStatus"] as? [String: Any],
              let status = play["status"] as? String, ["OK", "LOGIN_REQUIRED", "UNPLAYABLE", "ERROR", "CONTENT_CHECK_REQUIRED", "AGE_CHECK_REQUIRED", "LIVE_STREAM_OFFLINE"].contains(status) else { throw MediaObservationError.unrecognized }
        self.status = status
        let stream = root["streamingData"] as? [String: Any]
        let formats = (stream?["formats"] as? [[String: Any]] ?? []) + (stream?["adaptiveFormats"] as? [[String: Any]] ?? [])
        directURLCount = formats.filter { $0["url"] != nil }.count
        cipherCount = formats.filter { $0["signatureCipher"] != nil || $0["cipher"] != nil }.count
        boundary = status != "OK" ? .serviceDenied : cipherCount > 0 ? .challengeRequired : .sourceGrantAndEventsMissing
    }
}
public enum MediaObservationError: Error { case unrecognized }
