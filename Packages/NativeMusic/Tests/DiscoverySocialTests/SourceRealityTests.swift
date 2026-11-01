import AccountSession
import CryptoKit
import Features
import Foundation
import Testing
@testable import YouTubeMusicAdapter

/// "Source reality first": what the real public captures on `main` do and do not carry. These tests read the pinned anonymous captures
/// (Fixtures/W10-real, W11-real, W12-kaset-real, W13-real; real YouTube Music responses with no account) and record, in code, which of this
/// node's features have a source surface. They are not live evidence for a signed account: a personalised response can carry more.
enum Captures {
    static let folders = ["W10-real", "W11-real", "W12-kaset-real", "W13-real"]
    static func files() throws -> [URL] {
        try folders.flatMap { folder in
            try FileManager.default.contentsOfDirectory(at: fixturesRoot().appendingPathComponent(folder), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" && $0.lastPathComponent != "manifest.json" }
        }.sorted { $0.path < $1.path }
    }
    static func object(_ url: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw MusicSessionError.unrecognised }
        return object
    }
    /// Every key at every depth. Keys are the response's structure; values are what people wrote, so a word in a description is not a feature.
    static func keys(_ value: Any, into set: inout Set<String>) {
        if let dictionary = value as? [String: Any] { for (key, child) in dictionary { set.insert(key); keys(child, into: &set) } }
        else if let array = value as? [Any] { for child in array { keys(child, into: &set) } }
    }
    static func allKeys() throws -> Set<String> {
        var set = Set<String>()
        for file in try files() { keys(try object(file), into: &set) }
        return set
    }
    /// Every string value stored under `key`, at any depth.
    static func values(of key: String, in value: Any, into result: inout [String]) {
        if let dictionary = value as? [String: Any] {
            for (name, child) in dictionary { if name == key, let text = child as? String { result.append(text) }; values(of: key, in: child, into: &result) }
        } else if let array = value as? [Any] { for child in array { values(of: key, in: child, into: &result) } }
    }
}

@Suite @MainActor struct SourceRealityTests {
    @Test func theCapturesWereActuallyRead() throws {
        let files = try Captures.files()
        #expect(files.count >= 14, "the sweep covers the real captures (\(files.count))")
        let keys = try Captures.allKeys()
        #expect(keys.count > 300, "and found a real response structure (\(keys.count) distinct keys)")
    }
    @Test func theSweepFindsWhatIsKnownToBeThere() throws {
        // Positive controls: the same sweep must see structure that is certainly in these responses, or the absences below mean nothing.
        let keys = try Captures.allKeys()
        for expected in ["watchPlaylistEndpoint", "watchEndpoint", "musicInlineBadgeRenderer", "likeStatus", "musicResponsiveListItemRenderer", "browseEndpoint"] {
            #expect(keys.contains(expected), "\(expected) is in the captures")
        }
    }
    @Test func noCaptureStructureNamesSamplesATunerARecapAchievementsCommentsOrModeration() throws {
        let keys = try Captures.allKeys()
        let words = ["sample", "tuner", "recap", "replay", "achievement", "award", "comment", "moderat", "diversity", "discoverymode", "radiobuilder", "radiosettings"]
        let hits = keys.filter { key in words.contains { key.lowercased().contains($0) } }
        #expect(hits.isEmpty, "structure that would name one of these features: \(hits.sorted())")
    }
    @Test func theBadgesTheCapturesDoCarryMarkAnEntryAsExplicitOrLiveNotAnAchievement() throws {
        var icons: [String] = []
        for file in try Captures.files() { Captures.values(of: "iconType", in: try Captures.object(file), into: &icons) }
        var badgeIcons = Set<String>()
        for file in try Captures.files() {
            // The icon inside a badge renderer.
            func walk(_ value: Any) {
                if let dictionary = value as? [String: Any] {
                    for (key, child) in dictionary {
                        if key == "musicInlineBadgeRenderer", let renderer = child as? [String: Any], let icon = (renderer["icon"] as? [String: Any])?["iconType"] as? String { badgeIcons.insert(icon) }
                        walk(child)
                    }
                } else if let array = value as? [Any] { array.forEach(walk) }
            }
            walk(try Captures.object(file))
        }
        #expect(!badgeIcons.isEmpty, "the capture does carry inline badges")
        #expect(badgeIcons == ["MUSIC_EXPLICIT_BADGE"], "inline badges here mark an explicit entry: \(badgeIcons)")
        #expect(!icons.isEmpty)
    }
    /// The radios a capture's pages present as radios, read straight from the raw JSON with no parser: a menu item the service marks with the `MIX`
    /// icon ("Start mix") whose endpoint is a watch endpoint, and a header's `startRadioButton`. playlistId → parameters.
    private func presentedRadios(_ root: Any) -> [String: String] {
        var found: [String: String] = [:]
        func walk(_ value: Any) {
            if let object = value as? [String: Any] {
                if let item = object["menuNavigationItemRenderer"] as? [String: Any], (item["icon"] as? [String: Any])?["iconType"] as? String == "MIX",
                   let endpoint = item["navigationEndpoint"] as? [String: Any], let watch = (endpoint["watchEndpoint"] ?? endpoint["watchPlaylistEndpoint"]) as? [String: Any],
                   let list = watch["playlistId"] as? String { found[list] = watch["params"] as? String ?? "" }
                if let button = (object["startRadioButton"] as? [String: Any])?["buttonRenderer"] as? [String: Any],
                   let endpoint = button["navigationEndpoint"] as? [String: Any], let watch = (endpoint["watchEndpoint"] ?? endpoint["watchPlaylistEndpoint"]) as? [String: Any], let list = watch["playlistId"] as? String {
                    found[list] = watch["params"] as? String ?? ""
                }
                object.values.forEach(walk)
            } else if let array = value as? [Any] { array.forEach(walk) }
        }
        walk(root)
        return found
    }
    private static let browseCaptures = ["browse-home", "browse-explore", "browse-artist", "browse-new_releases", "browse-charts", "browse-album", "browse-playlist"]
    private func seeds(from name: String) throws -> (seeds: [RadioSeed], oracle: [String: String], page: MusicBrowsePage) {
        let root = try Captures.object(fixturesRoot().appendingPathComponent("W11-real/\(name).json"))
        let page = try MusicBrowseParser.parse(root)
        let book = RadioSeedBook(limit: 500)
        book.note(page: page); book.note(items: page.shelves.flatMap(\.items))
        return (book.seeds, presentedRadios(root), page)
    }
    @Test func aSeedIsOnlyARadioThePageOrEntryPresentsAsOneAndKeepsTheEndpointsParameters() throws {
        var total = 0
        for name in Self.browseCaptures {
            let (seeds, oracle, _) = try seeds(from: name)
            total += seeds.count
            for seed in seeds {
                #expect(oracle[seed.id] != nil, "\(name): \(seed.id) (\(seed.title)) is not a radio the page presented")
                #expect(seed.params == oracle[seed.id], "\(name): \(seed.id) must carry the endpoint's own parameters, not \(seed.params ?? "nil")")
            }
            // No editorial, curated or shuffle playlist became a seed.
            for seed in seeds { #expect(!seed.id.hasPrefix("RDCLAK") && !seed.id.hasPrefix("RDAO") && !seed.id.hasPrefix("RDTMAK"), Comment(rawValue: "\(name): \(seed.id)")) }
        }
        #expect(total >= 25, "real radios were found: \(total)")
    }
    @Test func theSeedCensusOfTheSevenRealPagesIsPinned() throws {
        // Seeds per page with an unbounded book: every one is a presented radio with parameters. A parser change that adds or drops radios shows here.
        var counts: [String: Int] = [:]
        for name in Self.browseCaptures {
            let (seeds, _, _) = try seeds(from: name)
            counts[name] = seeds.count
            #expect(seeds.allSatisfy { $0.params == "wAEB" }, Comment(rawValue: name))
        }
        #expect(counts == ["browse-home": 30, "browse-explore": 45, "browse-artist": 76, "browse-new_releases": 46, "browse-charts": 42, "browse-album": 25, "browse-playlist": 16])
    }
    @Test func theCuratedPlaylistsOfARealPageAreNotRadios() throws {
        // new_releases and artist carry RDCLAK editorial playlists (play and shuffle endpoints only) next to real "Start mix" actions.
        for name in ["browse-new_releases", "browse-artist"] {
            let data = try String(contentsOf: fixturesRoot().appendingPathComponent("W11-real/\(name).json"), encoding: .utf8)
            #expect(data.contains("\"RDCLAK"), "\(name) does carry curated playlists, so the absence below means something")
            let (seeds, _, _) = try seeds(from: name)
            #expect(seeds.allSatisfy { !$0.id.hasPrefix("RDCLAK") }, Comment(rawValue: name))
        }
    }
    @Test func anArtistPageSeedKeepsItsOwnRadioActionAndParameters() throws {
        let (_, oracle, page) = try seeds(from: "browse-artist")
        let action = try #require(page.header?.actions.radioAction, "the artist page presents its own radio")
        #expect(oracle[action.playlistID] == action.params, "the page's radio action keeps its parameters")
        #expect(action.params?.isEmpty == false)
    }
    @Test func songRadiosStartFromTheTrackTheActionNamed() throws {
        let (seeds, _, _) = try seeds(from: "browse-album")
        let songs = seeds.filter { $0.kind == .song }
        #expect(!songs.isEmpty)
        for seed in songs { #expect(seed.videoID != nil && seed.id.hasPrefix("RDAMVM"), Comment(rawValue: seed.id)) }
    }
    @Test func theTunerControlsStayUnresolvedBecauseNoRadioQueueCaptureExistsAndFailWhenChipsOfTheReferenceShapeAppear() throws {
        // F1: no radio queue (`next`) capture exists, so tuning controls are UNRESOLVED. If a capture ever carries queue filter chips of the shape the reference
        // client uses (a chip whose endpoint is a watch-playlist endpoint with parameters), the application must be able to read them: this fails then, so
        // "unresolved" cannot go on being reported over a capture that shows them.
        for file in try Captures.files() {
            let queue = MusicRadioQueueParser.parse(try Captures.object(file))
            #expect(queue.chips.isEmpty, Comment(rawValue: "\(file.lastPathComponent) carries radio-queue chips \(queue.chips.map(\.title)): the tuner's unresolved state is now wrong and must read them"))
        }
        // Positive control: the same parser does read the shape when it is there.
        let synthetic: [String: Any] = ["contents": ["chipCloudChipRenderer": ["text": ["simpleText": "Popular"], "isSelected": true,
            "navigationEndpoint": ["watchPlaylistEndpoint": ["playlistId": "RDAMVMsyntheticvid", "params": "syntheticParams"]]]]]
        #expect(MusicRadioQueueParser.parse(synthetic).chips.map(\.title) == ["Popular"])
        // Home's mood chips are real chips in a real capture and are not radio filters.
        let home = try Captures.object(fixturesRoot().appendingPathComponent("W11-real/browse-home.json"))
        var chipRenderers = 0
        func count(_ value: Any) { if let o = value as? [String: Any] { if o["chipCloudChipRenderer"] != nil { chipRenderers += 1 }; o.values.forEach(count) } else if let a = value as? [Any] { a.forEach(count) } }
        count(home)
        #expect(chipRenderers > 0 && MusicRadioQueueParser.parse(home).chips.isEmpty, "Home's chips (\(chipRenderers)) are browse filters, not a radio's")
        // And no captured response is a radio queue at all.
        for file in try Captures.files() {
            var found = false
            func walk(_ v: Any) { if let o = v as? [String: Any] { if o["playlistPanelRenderer"] != nil || o["musicQueueRenderer"] != nil { found = true }; o.values.forEach(walk) } else if let a = v as? [Any] { a.forEach(walk) } }
            walk(try Captures.object(file))
            #expect(!found, Comment(rawValue: "\(file.lastPathComponent) is a radio queue capture now: read it and replace the unresolved state with what it shows"))
        }
        #expect(UnresolvedRadioControlsSource().unresolved != nil)
    }
    @Test func theQueueRequestAndChipShapesFollowTheReferenceClient() {
        let action = MusicRadioAction(playlistID: "RDAMVMsyntheticvid", videoID: "syntheticvid", params: "wAEB")
        let start = MusicRadioQueueParser.body(.start(action, tunerSetting: MusicRadioQueueRequest.normalTunerSetting))
        #expect(start["tunerSettingValue"] as? String == "AUTOMIX_SETTING_NORMAL" && start["isAudioOnly"] as? Bool == true && start["enablePersistentPlaylistPanel"] as? Bool == true)
        #expect(start["videoId"] as? String == "syntheticvid" && start["playlistId"] as? String == "RDAMVMsyntheticvid" && start["params"] as? String == "wAEB")
        let chip = MusicRadioChip(title: "Popular", isSelected: false, playlistID: "RDAMVMsyntheticvid", params: "chipParams")
        let filter = MusicRadioQueueParser.body(.filter(chip))
        #expect(filter["videoId"] == nil, "a filter re-makes the queue; it does not continue from a song")
        #expect(filter["params"] as? String == "chipParams" && filter["playlistId"] as? String == "RDAMVMsyntheticvid" && filter["tunerSettingValue"] == nil)
    }
    @Test func aChipWithABrowseOrSearchEndpointOrADeselectActionIsNotARadioFilter() {
        let doc: [String: Any] = ["a": ["chipCloudChipRenderer": ["text": ["simpleText": "Focus"], "navigationEndpoint": ["browseEndpoint": ["browseId": "FEmusic_home", "params": "x"]]]],
                                  "b": ["chipCloudChipRenderer": ["text": ["runs": [["text": "Songs"]]], "navigationEndpoint": ["searchEndpoint": ["query": "q", "params": "p"]]]],
                                  "c": ["chipCloudChipRenderer": ["text": ["simpleText": "Popular"], "isSelected": false,
                                        "navigationEndpoint": ["watchPlaylistEndpoint": ["playlistId": "RDAMVMsyntheticvid", "params": "sel"]],
                                        "onDeselectedCommand": ["watchPlaylistEndpoint": ["playlistId": "RDAMVMsyntheticvid", "params": "reset"]]]]]
        let queue = MusicRadioQueueParser.parse(doc)
        #expect(queue.chips.map(\.params) == ["sel"], "only the selection counts, and the deselect action is not a second chip")
        // A chip whose endpoint carries no parameters (or empty ones) selects nothing, so it is not offered as a filter.
        let bare: [String: Any] = ["x": ["chipCloudChipRenderer": ["text": ["simpleText": "Popular"], "navigationEndpoint": ["watchPlaylistEndpoint": ["playlistId": "RDAMVMsyntheticvid"]]]],
                                   "y": ["chipCloudChipRenderer": ["text": ["simpleText": "Popular"], "navigationEndpoint": ["watchPlaylistEndpoint": ["playlistId": "RDAMVMsyntheticvid", "params": ""]]]]]
        #expect(MusicRadioQueueParser.parse(bare).chips.isEmpty)
    }

    @Test func ratingsArePresentOnEntriesAsTheLikeControlAndAreTheLedgersToWrite() throws {
        let keys = try Captures.allKeys()
        #expect(keys.contains("likeStatus"))
        let album = try MusicBrowseParser.parse(try Captures.object(fixturesRoot().appendingPathComponent("W11-real/browse-album.json")))
        #expect(album.shelves.flatMap(\.items).contains { $0.controls?.like != nil }, "a track row publishes its rating control")
    }
    @Test func everyCaptureTheSweepReadsIsPinnedByAManifestHash() throws {
        var pinned = Set<String>()
        for folder in Captures.folders {
            let manifestURL = fixturesRoot().appendingPathComponent(folder + "/manifest.json")
            guard let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any], let files = manifest["files"] as? [[String: Any]] else {
                Issue.record("manifest unreadable: \(folder)"); continue
            }
            #expect(!files.isEmpty, Comment(rawValue: folder))
            for entry in files {
                guard let path = entry["path"] as? String, let hash = entry["sha256"] as? String else { Issue.record("manifest entry without path and hash in \(folder)"); continue }
                let data = try Data(contentsOf: fixturesRoot().appendingPathComponent(folder + "/" + path))
                #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == hash, Comment(rawValue: "\(folder)/\(path)"))
                pinned.insert(folder + "/" + path)
            }
        }
        let swept = Set(try Captures.files().map { $0.deletingLastPathComponent().lastPathComponent + "/" + $0.lastPathComponent })
        #expect(swept == pinned, Comment(rawValue: "every swept capture is pinned, and nothing pinned is skipped: \(swept.symmetricDifference(pinned))"))
    }
}
