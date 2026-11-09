import AccountSession
import Foundation

/// The rating of the song a `next` (watch) response is about, read from the player overlay's like button
/// (`playerOverlays.playerOverlayRenderer.actions[].likeButtonRenderer`): the same renderer a row's menu carries, so it yields the same
/// `MusicItemControls.Like`. The queue rows of a `next` response carry no rating (real captures `R1-real`, `R2-real`), so this is the only
/// place a song that was never shown on a page gets one.
///
/// Real anonymous captures (`MF-comments`, `R1-real`, `R2-real`, `W18-real`) show three shapes, all handled here:
/// - an overlay whose like button names the requested song: its state (anonymous answers read `INDIFFERENT` and carry sign-in prompts
///   where a signed answer carries the endpoints; the state, the target and `likesAllowed` are where both put them);
/// - an overlay with no like button at all (`next-khnokW3Mw24.json`, while the German capture of the same song carries one), and no
///   overlay at all (`next-Qx7Lm2Zk9Vw.json`, a nonsense id): the service published no rating this time, which is `nil`, never "not liked";
/// - anything that is not a watch-next answer for the requested song: `.unrecognised`, never a rating.
public enum MusicWatchRatingParser {
    public static func parse(_ root: [String: Any], videoID: String) throws(MusicSessionError) -> MusicItemControls.Like? {
        guard root["error"] == nil,
              (root["contents"] as? [String: Any])?["singleColumnMusicWatchNextResultsRenderer"] != nil else { throw .unrecognised }
        // The answer must say it is about the song asked for: a rating is never moved from one song to another.
        if let current = ((root["currentVideoEndpoint"] as? [String: Any])?["watchEndpoint"] as? [String: Any])?["videoId"] as? String,
           current != videoID { throw .unrecognised }
        guard let overlay = (root["playerOverlays"] as? [String: Any])?["playerOverlayRenderer"] as? [String: Any] else { return nil }
        var found: MusicItemControls.Like?
        for action in overlay["actions"] as? [[String: Any]] ?? [] {
            guard let like = action["likeButtonRenderer"] as? [String: Any] else { continue }
            guard found == nil,
                  let target = (like["target"] as? [String: Any])?["videoId"] as? String, target == videoID,
                  let status = (like["likeStatus"] as? String).flatMap(MusicLikeStatus.init(rawValue:)) else { throw .unrecognised }
            // A song whose likes are switched off publishes the button without offering it: no rating control, as on a row.
            guard like["likesAllowed"] as? Bool == true else { return nil }
            found = .init(videoID: videoID, status: status, dislikeExposed: like["dislikeNavigationEndpoint"] != nil)
        }
        return found
    }
}
