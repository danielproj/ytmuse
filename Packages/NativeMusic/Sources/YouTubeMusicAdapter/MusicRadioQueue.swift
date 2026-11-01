import AccountSession
import Foundation

/// The radio-queue (`next`) shapes behind the tuner. **No real capture of a `next` response exists on `main`.** The shapes here come from the
/// reference client's source and tests (Kaset, MIT, read-only): `next` is sent with `tunerSettingValue` and `isAudioOnly` /
/// `enablePersistentPlaylistPanel`, and a radio's queue filter is a `chipCloudChipRenderer` whose `navigationEndpoint` is a
/// `watchPlaylistEndpoint{playlistId, params}`. They are tested against documents built in that shape (labelled synthetic) and stay unverified
/// until a real signed capture is taken (W38). Nothing here sends a request.
public enum MusicRadioQueueParser {
    private static let maximumDepth = 48
    private static let maximumChips = 32

    /// Every radio-queue filter chip in a response. A chip whose endpoint is a browse or search endpoint (Home's mood chips, search filters) is
    /// not a radio filter; a chip's deselect command is not its selection.
    public static func parse(_ root: [String: Any]) -> MusicRadioQueue {
        var chips: [MusicRadioChip] = []
        func walk(_ value: Any, depth: Int) {
            guard depth <= maximumDepth, chips.count < maximumChips else { return }
            if let object = value as? [String: Any] {
                if let chip = object["chipCloudChipRenderer"] as? [String: Any], let parsed = read(chip) { chips.append(parsed) }
                for child in object.values { walk(child, depth: depth + 1) }
            } else if let array = value as? [Any] {
                for child in array { walk(child, depth: depth + 1) }
            }
        }
        walk(root, depth: 0)
        var seen = Set<String>()
        return MusicRadioQueue(chips: chips.filter { seen.insert($0.playlistID + "|" + $0.params).inserted })
    }

    private static func read(_ chip: [String: Any]) -> MusicRadioChip? {
        guard let endpoint = (chip["navigationEndpoint"] as? [String: Any])?["watchPlaylistEndpoint"] as? [String: Any],
              let list = valid(endpoint["playlistId"] as? String, #"^[A-Za-z0-9_-]{2,128}$"#),
              let params = valid(endpoint["params"] as? String, #"^[A-Za-z0-9%_=+/.-]{1,1024}$"#),
              let title = title(chip["text"]) else { return nil }
        return MusicRadioChip(title: title, isSelected: chip["isSelected"] as? Bool ?? false, playlistID: list, params: params)
    }
    private static func title(_ value: Any?) -> String? {
        guard let object = value as? [String: Any] else { return nil }
        let text = (object["simpleText"] as? String) ?? (object["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty, trimmed.utf8.count <= 128 else { return nil }
        return trimmed
    }
    private static func valid(_ value: String?, _ pattern: String) -> String? {
        guard let value, value.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return value
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
            body["tunerSettingValue"] = setting
        case .filter(let chip):
            body["playlistId"] = chip.playlistID
            body["params"] = chip.params
        }
        return body
    }
}
