import AccountSession
import Foundation

/// Queue metadata only. Shape grounded in the anonymous R1 public radio capture.
/// Read the queue's own chip array in publisher order; never traverse arbitrary response objects.
public enum MusicRadioQueueParser {
    public static func parse(_ root: [String: Any]) throws -> MusicRadioQueue {
        guard let contents = root["contents"] as? [String: Any],
              let single = contents["singleColumnMusicWatchNextResultsRenderer"] as? [String: Any],
              let tabbed = single["tabbedRenderer"] as? [String: Any],
              let results = tabbed["watchNextTabbedResultsRenderer"] as? [String: Any],
              let tabs = results["tabs"] as? [[String: Any]], !tabs.isEmpty, tabs.count <= 8 else { throw MusicSessionError.unrecognised }
        var queue: [String: Any]?
        for tab in tabs {
            if let renderer = tab["tabRenderer"] as? [String: Any],
               let content = renderer["content"] as? [String: Any],
               let candidate = content["musicQueueRenderer"] as? [String: Any] {
                guard queue == nil else { throw MusicSessionError.unrecognised }
                queue = candidate
            }
        }
        guard let queue, let content = queue["content"] as? [String: Any],
              let panel = content["playlistPanelRenderer"] as? [String: Any],
              let rows = panel["contents"] as? [[String: Any]], !rows.isEmpty, rows.count <= 500 else { throw MusicSessionError.unrecognised }
        // The real W18 song queue has no subheader; that is a readable queue with no filters.
        guard let headerValue = queue["subHeaderChipCloud"] else { return MusicRadioQueue(chips: []) }
        guard let header = headerValue as? [String: Any], let cloud = header["chipCloudRenderer"] as? [String: Any],
              let entries = cloud["chips"] as? [[String: Any]], entries.count <= 32 else { throw MusicSessionError.unrecognised }
        var chips: [MusicRadioChip] = []
        var seen = Set<String>()
        for entry in entries {
            guard let chip = entry["chipCloudChipRenderer"] as? [String: Any],
                  let navigation = chip["navigationEndpoint"] as? [String: Any],
                  let command = navigation["queueUpdateCommand"] as? [String: Any],
                  command["queueUpdateSection"] as? String == "QUEUE_UPDATE_SECTION_AUTOPLAY",
                  command["dedupeAgainstLocalQueue"] as? Bool == true,
                  command["syncMode"] as? String == "QUEUE_UPDATE_SYNC_MODE_DEDUPE_AGAINST_LOCAL",
                  Set(command.keys) == ["queueUpdateSection", "fetchContentsCommand", "dedupeAgainstLocalQueue", "syncMode"],
                  let fetch = command["fetchContentsCommand"] as? [String: Any],
                  Set(fetch.keys).isSubset(of: ["watchEndpoint", "clickTrackingParams"]),
                  Set(navigation.keys).isSubset(of: ["queueUpdateCommand", "clickTrackingParams"]),
                  let endpoint = fetch["watchEndpoint"] as? [String: Any],
                  let list = endpoint["playlistId"] as? String,
                  let params = endpoint["params"] as? String,
                  let selected = chip["isSelected"] as? Bool,
                  let text = chip["text"] as? [String: Any],
                  let runs = text["runs"] as? [[String: Any]], !runs.isEmpty, runs.count <= 16 else { throw MusicSessionError.unrecognised }
            let parts = try runs.map { run -> String in
                guard let value = run["text"] as? String, value.utf8.count <= 128 else { throw MusicSessionError.unrecognised }
                return value
            }
            let title = parts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard valid(list, #"^[A-Za-z0-9_-]{2,128}$"#), valid(params, #"^[A-Za-z0-9%_=+/.-]{1,1024}$"#),
                  !title.isEmpty, title.utf8.count <= 128, seen.insert(list + "|" + params).inserted else { throw MusicSessionError.unrecognised }
            var playerParams: String?
            if let value = endpoint["playerParams"] {
                guard let text = value as? String, valid(text, #"^[A-Za-z0-9%_=+/.-]{1,1024}$"#) else { throw MusicSessionError.unrecognised }
                playerParams = text
            }
            // Unknown functional fields must not be silently discarded. Logging context has no playback semantics.
            guard Set(endpoint.keys).isSubset(of: ["playlistId", "params", "playerParams", "loggingContext"]) else { throw MusicSessionError.unrecognised }
            chips.append(MusicRadioChip(title: title, isSelected: selected, playlistID: list, params: params, playerParams: playerParams))
        }
        return MusicRadioQueue(chips: chips)
    }
    private static func valid(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex
    }
    /// Only the published action/choice is forwarded. No guessed tuner setting or derived playlist.
    public static func queueBody(_ action: MusicRadioAction) throws -> [String: Any] {
        guard valid(action.playlistID, #"^[A-Za-z0-9_-]{2,128}$"#),
              action.params.map({ valid($0, #"^[A-Za-z0-9%_=+/.-]{1,1024}$"#) }) ?? true,
              action.playerParams.map({ valid($0, #"^[A-Za-z0-9%_=+/.-]{1,1024}$"#) }) ?? true,
              action.videoID.map(MusicBrowseParser.isVideoID) ?? true else { throw MusicSessionError.policy }
        var body: [String: Any] = ["playlistId": action.playlistID, "isAudioOnly": true, "enablePersistentPlaylistPanel": true]
        if let params = action.params { body["params"] = params }
        if let playerParams = action.playerParams { body["playerParams"] = playerParams }
        if let video = action.videoID { body["videoId"] = video }
        return body
    }

    /// The JSON body of a queue request, in the reference client's shape. A filter selection carries the chip's playlist and parameters and
    /// no track (the queue is re-made, not continued from one song).
    public static func body(_ request: MusicRadioQueueRequest) -> [String: Any] {
        var body: [String: Any] = ["isAudioOnly": true, "enablePersistentPlaylistPanel": true]
        switch request {
        case .start(let action, let setting):
            body["playlistId"] = action.playlistID
            if let video = action.videoID { body["videoId"] = video }
            if let params = action.params { body["params"] = params }
            if let playerParams = action.playerParams { body["playerParams"] = playerParams }
            body["tunerSettingValue"] = setting
        case .filter(let chip):
            body["playlistId"] = chip.playlistID
            body["params"] = chip.params
            if let playerParams = chip.playerParams { body["playerParams"] = playerParams }
        }
        return body
    }
}
