import AccountSession
import Domain
import CryptoKit
import Features
import Foundation
import Testing
@testable import YouTubeMusicAdapter

/// "Source reality first": what the real public captures on `main` do and do not carry. These tests read the pinned anonymous captures
/// (Fixtures/W10-real, W11-real, W12-kaset-real, W13-real; real YouTube Music responses with no account) and record, in code, which of this
/// node's features have a source surface. They are not live evidence for a signed account: a personalised response can carry more.
///
/// MORE-FEATURES C1 (2026-11-05): the absence sweeps now run over `superset` (the four folders above plus `addedFolders`), because the first
/// version swept keys only and only those four folders, so it stayed green while W18-real, R1-real and R2-real already carried a Comments
/// tab (a VALUE, a tab title) and Fixtures/MF-comments carries the whole comment structure. Tab titles are now swept at value level too.
enum Captures {
    static let folders = ["W10-real", "W11-real", "W12-kaset-real", "W13-real"]
    /// Folders swept by the absence tests in addition to `folders`. Each is pinned by a manifest and proven to be read by a positive control.
    static let addedFolders = ["W18-real", "R1-real", "R2-real", "MF-comments"]
    static func files(in folders: [String]) throws -> [URL] {
        try folders.flatMap { folder in
            try FileManager.default.contentsOfDirectory(at: fixturesRoot().appendingPathComponent(folder), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" && $0.lastPathComponent != "manifest.json" }
        }.sorted { $0.path < $1.path }
    }
    static func superset() throws -> [URL] { try files(in: folders + addedFolders) }
    static func keys(in files: [URL]) throws -> Set<String> {
        var set = Set<String>()
        for file in files { keys(try object(file), into: &set) }
        return set
    }
    /// The title of every tab of every watch-next response in `files` (a feature published as a tab title is a VALUE, which a key sweep never sees).
    static func watchNextTabTitles(in files: [URL]) throws -> Set<String> {
        var titles = Set<String>()
        for file in files {
            let tabs = ((((try object(file)["contents"] as? [String: Any])?["singleColumnMusicWatchNextResultsRenderer"] as? [String: Any])?["tabbedRenderer"] as? [String: Any])?["watchNextTabbedResultsRenderer"] as? [String: Any])?["tabs"] as? [[String: Any]] ?? []
            for tab in tabs { if let title = (tab["tabRenderer"] as? [String: Any])?["title"] as? String { titles.insert(title) } }
        }
        return titles
    }
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
    /// Every word of the original absence test is still swept; the sweep now covers the superset of folders. The two words that name the
    /// comment surface (`comment`, `moderat`) moved to the tests below because Fixtures/MF-comments genuinely carries that structure.
    @Test func noCaptureStructureNamesSamplesATunerARecapOrAchievements() throws {
        let keys = try Captures.keys(in: try Captures.superset())
        let words = ["sample", "tuner", "recap", "replay", "achievement", "award", "diversity", "discoverymode", "radiobuilder", "radiosettings"]
        let hits = keys.filter { key in words.contains { key.lowercased().contains($0) } }
        #expect(hits.isEmpty, "structure that would name one of these features: \(hits.sorted())")
    }
    @Test func noCaptureOutsideTheCommentFixturesNamesCommentsOrModerationInItsStructure() throws {
        // The folders that are not the comment fixtures: the old four plus W18-real, R1-real and R2-real. Their Comments tab is a value, not a key.
        let keys = try Captures.keys(in: try Captures.files(in: Captures.folders + ["W18-real", "R1-real", "R2-real"]))
        let hits = keys.filter { key in ["comment", "moderat"].contains { key.lowercased().contains($0) } }
        #expect(hits.isEmpty, "structure that would name comments or moderation outside Fixtures/MF-comments: \(hits.sorted())")
        #expect(keys.contains("musicQueueRenderer"), "the sweep read the watch-next responses that publish the Comments tab")
    }
    @Test func theCommentFixturesCarryTheCommentStructureAndNoModerationOffer() throws {
        let files = try Captures.files(in: ["MF-comments"])
        let keys = try Captures.keys(in: files)
        for expected in ["commentThreadRenderer", "commentViewModel", "commentEntityPayload", "commentsHeaderRenderer", "commentRepliesRenderer", "continuationItemRenderer"] {
            #expect(keys.contains(expected), "\(expected) is in the comment captures")
        }
        // The only structure naming moderation is a per-thread flag. Its value in every capture is false: not an offer, not a state.
        let moderation = keys.filter { $0.lowercased().contains("moderat") }
        #expect(moderation == ["isModeratedElqComment"], "moderation structure in the comment captures: \(moderation.sorted())")
        var flags: [String] = []
        for file in files { Captures.values(of: "isModeratedElqComment", in: try Captures.object(file), into: &flags) }
        func booleans(_ value: Any, into result: inout [Bool]) {
            if let dictionary = value as? [String: Any] { for (key, child) in dictionary { if key == "isModeratedElqComment", let flag = child as? Bool { result.append(flag) }; booleans(child, into: &result) } }
            else if let array = value as? [Any] { for child in array { booleans(child, into: &result) } }
        }
        var flagValues: [Bool] = []
        for file in files { booleans(try Captures.object(file), into: &flagValues) }
        #expect(flags.isEmpty && flagValues.count >= 70 && flagValues.allSatisfy { !$0 }, "the flag is a boolean and false on all \(flagValues.count) comments")
    }
    @Test func theCommentsTabIsPublishedByTheRealWatchNextCapturesThatCarryIt() throws {
        // The Comments tab is a VALUE (a tab title) in W18-real, R1-real and R2-real, which is how the old key sweep missed it.
        for path in ["W18-real/next-song.json", "R1-real/next-radio.json", "R2-real/next-radio-artist.json"] {
            let root = try Captures.object(fixturesRoot().appendingPathComponent(path))
            let tabs = ((((root["contents"] as? [String: Any])?["singleColumnMusicWatchNextResultsRenderer"] as? [String: Any])?["tabbedRenderer"] as? [String: Any])?["watchNextTabbedResultsRenderer"] as? [String: Any])?["tabs"] as? [[String: Any]] ?? []
            let comments = tabs.compactMap { $0["tabRenderer"] as? [String: Any] }.first { $0["title"] as? String == "Comments" }
            let list = try #require((comments?["content"] as? [String: Any])?["sectionListRenderer"] as? [String: Any], Comment(rawValue: path))
            #expect((list["continuations"] as? [[String: Any]])?.first?["reloadContinuationData"] != nil, Comment(rawValue: path))
        }
    }
    @Test func theWatchNextTabTitlesTheCapturesCarryArePinnedSoANewTabCannotHide() throws {
        // Value-level census over every swept capture. A new tab ("Samples", "Recap", "Badges") fails here, whatever its keys are called.
        let titles = try Captures.watchNextTabTitles(in: try Captures.superset())
        #expect(titles == ["Up next", "Lyrics", "Comments", "Related", "Nächster Titel", "Songtext", "Kommentare", "Ähnliche Titel"], "watch-next tab titles: \(titles.sorted())")
    }
    @Test func everyAddedFolderIsReallyReadByTheSweepAndPinnedByItsManifest() throws {
        // Positive control per folder: the sweep sees a key that certainly lives in that folder's responses.
        let certain = ["W18-real": "singleColumnMusicWatchNextResultsRenderer", "R1-real": "chipCloudRenderer", "R2-real": "chipCloudRenderer", "MF-comments": "commentEntityPayload"]
        #expect(Set(certain.keys) == Set(Captures.addedFolders))
        for folder in Captures.addedFolders {
            let files = try Captures.files(in: [folder])
            #expect(!files.isEmpty, Comment(rawValue: folder))
            #expect(try Captures.keys(in: files).contains(try #require(certain[folder])), Comment(rawValue: "\(folder) is swept, so its absences mean something"))
            let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixturesRoot().appendingPathComponent(folder + "/manifest.json"))) as? [String: Any])
            // Two manifest forms exist: a `files` list, and the single-capture form with the file's own `sha256` at the top.
            var pinned: [String: String] = [:]
            if let entries = manifest["files"] as? [[String: Any]] {
                for entry in entries { if let path = entry["path"] as? String, let hash = entry["sha256"] as? String { pinned[path] = hash } }
            } else if let hash = manifest["sha256"] as? String, files.count == 1 { pinned[files[0].lastPathComponent] = hash }
            #expect(Set(pinned.keys) == Set(files.map(\.lastPathComponent)), Comment(rawValue: "every swept file of \(folder) is pinned, and nothing pinned is skipped"))
            for file in files {
                let digest = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
                #expect(pinned[file.lastPathComponent] == digest, Comment(rawValue: "\(folder)/\(file.lastPathComponent)"))
            }
        }
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
    @Test func radioFiltersUseTheRealQueueShapeAndPreserveEveryPublishedChoice() throws {
        let data = try Data(contentsOf: fixturesRoot().appendingPathComponent("R1-real/next-radio.json"))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let manifestData = try Data(contentsOf: fixturesRoot().appendingPathComponent("R1-real/manifest.json"))
        let manifest = try #require(try JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(hash == "e00e9e6f0d22296a973b4b9094f00e2d0252c6a953e007eaf3776cc5d0ae97aa")
        #expect(hash == manifest["sha256"] as? String && manifest["mode"] as? String == "real-public-anonymous-capture")
        let queue = try MusicRadioQueueParser.parse(root)
        #expect(queue.chips.map(\.title) == ["All", "Popular", "Discover", "Deep cuts", "Party", "2010s", "Workout", "2000s", "Electronic", "Pop", "Alternative", "Glitch house", "Gothic Funk"])
        #expect(queue.chips.count == 13 && queue.chips[0].isSelected)
        #expect(queue.chips.dropFirst().allSatisfy { !$0.isSelected })
        #expect(queue.chips.filter { $0.playerParams != nil }.map(\.title) == ["Workout", "Gothic Funk"])
        for chip in queue.chips where chip.playerParams == nil {
            let body = try MusicRadioQueueParser.queueBody(MusicRadioAction(playlistID: chip.playlistID, params: chip.params))
            #expect(body["playlistId"] as? String == chip.playlistID && body["params"] as? String == chip.params)
            #expect(body["videoId"] == nil && body["tunerSettingValue"] == nil)
        }
    }
    /// R2-real (2026-11-05): YouTube Music moved every chip to the QUEUE section. The R1 parser accepted AUTOPLAY only, so it rejected the whole
    /// cloud and the live app said "Radio filters couldn't load" for every radio. Both captures must read, and each chip keeps its own section.
    @Test func radioFiltersReadTheQueueSectionCaptureAndKeepEachChipsSection() async throws {
        let data = try Data(contentsOf: fixturesRoot().appendingPathComponent("R2-real/next-radio-artist.json"))
        let manifestData = try Data(contentsOf: fixturesRoot().appendingPathComponent("R2-real/manifest.json"))
        let manifest = try #require(try JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(hash == "c165dd2d7f8f5d3e3bfcb992328ba9aebc1d3c507e74e68ea71ab33a7a4a4141")
        #expect(hash == manifest["sha256"] as? String && manifest["mode"] as? String == "real-public-anonymous-capture")
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let queue = try MusicRadioQueueParser.parse(root)
        #expect(queue.chips.map(\.title) == ["All", "Popular", "Discover", "Deep cuts", "Pump-up", "Pop", "1980s", "Rock", "Alternative", "1970s", "Gothic Funk", "Beat rock", "Rock noir"])
        #expect(queue.chips.allSatisfy { $0.section == .queue })
        #expect(queue.chips[0].isSelected && queue.chips.dropFirst().allSatisfy { !$0.isSelected })
        #expect(queue.chips.filter { $0.playerParams != nil }.map(\.title) == ["Discover"])
        let r1 = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixturesRoot().appendingPathComponent("R1-real/next-radio.json"))) as? [String: Any])
        #expect(try MusicRadioQueueParser.parse(r1).chips.allSatisfy { $0.section == .autoplay }, "the earlier capture still reads, as AUTOPLAY")
        // The tuner turns each chip into the command the page receives, carrying that chip's section.
        let controls = try await QueueRadioControlsSource { _ in queue }.controls(for: RadioContext(seed: RadioSeed(id: "RDEMyqld5TvlRMTjOZ3qRzO16w", kind: .artist, title: "Japan"), playlistID: "RDEMyqld5TvlRMTjOZ3qRzO16w", params: "wAEB", choices: [:]))
        #expect(controls.first?.options.allSatisfy { $0.queueCommand?.section == MusicQueueUpdateSection.queue } == true)
    }
    @Test func anUnknownQueueSectionFailsTheWholeRead() throws {
        var text = try String(contentsOf: fixturesRoot().appendingPathComponent("R2-real/next-radio-artist.json"), encoding: .utf8)
        let range = try #require(text.range(of: "\"QUEUE_UPDATE_SECTION_QUEUE\""))
        text.replaceSubrange(range, with: "\"QUEUE_UPDATE_SECTION_SOMETHING_ELSE\"")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(throws: MusicSessionError.unrecognised) { try MusicRadioQueueParser.parse(root) }
    }
    @Test func validNoFilterQueueIsDifferentFromMalformedOrUnrelatedBody() throws {
        let data = try Data(contentsOf: fixturesRoot().appendingPathComponent("W18-real/next-song.json"))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(try MusicRadioQueueParser.parse(root).chips.isEmpty)
        #expect(throws: MusicSessionError.unrecognised) { try MusicRadioQueueParser.parse([:]) }
        let home = try Captures.object(fixturesRoot().appendingPathComponent("W11-real/browse-home.json"))
        #expect(throws: MusicSessionError.unrecognised) { try MusicRadioQueueParser.parse(home) }
    }
    @Test func malformedRecognisedChipFailsTheWholeRead() throws {
        let data = try Data(contentsOf: fixturesRoot().appendingPathComponent("R1-real/next-radio.json"))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let path = ["contents", "singleColumnMusicWatchNextResultsRenderer", "tabbedRenderer", "watchNextTabbedResultsRenderer", "tabs"]
        func replacingChips(_ value: Any, path: ArraySlice<String>, transform: ([[String: Any]]) throws -> [[String: Any]]) throws -> Any {
            guard let key = path.first else {
                return try transform(try #require(value as? [[String: Any]]))
            }
            if key == "0" {
                var array = try #require(value as? [Any])
                array[0] = try replacingChips(array[0], path: path.dropFirst(), transform: transform)
                return array
            }
            var object = try #require(value as? [String: Any])
            object[key] = try replacingChips(try #require(object[key]), path: path.dropFirst(), transform: transform)
            return object
        }
        let chipPath = path + ["0", "tabRenderer", "content", "musicQueueRenderer", "subHeaderChipCloud", "chipCloudRenderer", "chips"]
        func corrupt(_ value: Any, key: String, replacement: Any) -> Any {
            if var object = value as? [String: Any] {
                if key == "playerParams", object["playlistId"] != nil, object["params"] != nil { object[key] = replacement }
                for k in Array(object.keys) { object[k] = k == key ? replacement : corrupt(object[k]!, key: key, replacement: replacement) }
                return object
            }
            if let array = value as? [Any] { return array.map { corrupt($0, key: key, replacement: replacement) } }
            return value
        }
        for (key, value) in [("params", "" as Any), ("params", "p\n" as Any), ("watchEndpoint", "wrong" as Any), ("isSelected", "wrong" as Any), ("text", [:] as Any), ("queueUpdateSection", "unknown" as Any), ("syncMode", "unknown" as Any), ("dedupeAgainstLocalQueue", false as Any), ("playerParams", String(repeating: "x", count: 1025) as Any)] {
            let replacement = try replacingChips(root, path: chipPath[...]) { chips in
                #expect(chips.count == 13)
                var mutated = chips
                mutated[0] = try #require(corrupt(chips[0], key: key, replacement: value) as? [String: Any])
                let siblings = Array(mutated.dropFirst())
                #expect(NSDictionary(dictionary: ["chips": siblings]).isEqual(to: ["chips": Array(chips.dropFirst())]))
                // Prove the other twelve chips still parse when substituted into the real queue.
                let good = try #require(try replacingChips(root, path: chipPath[...]) { _ in siblings } as? [String: Any])
                #expect(try MusicRadioQueueParser.parse(good).chips.count == 12)
                return mutated
            }
            let bad = try #require(replacement as? [String: Any])
            #expect(throws: MusicSessionError.unrecognised) { try MusicRadioQueueParser.parse(bad) }
        }
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

@MainActor private final class QueueFilterRecorder: SearchActionPerformer {
    var supportsRadioQueueUpdates: Bool { true }
    let scope = UUID()
    var current = true
    func captureRadioQueueScope(playlistID: String) -> UUID? { scope }
    func radioQueueScopeIsCurrent(_ scope: UUID) -> Bool { current && scope == self.scope }
    func applyRadioFilter(_ command: MusicQueueFilterCommand, scope: UUID) async -> SearchPlayOutcome {
        guard scope == self.scope else { return .stale }
        filters.append(command)
        if let apply { return await apply() }
        return .started
    }
    var apply: (@MainActor () async -> SearchPlayOutcome)?
    var filters: [MusicQueueFilterCommand] = []
    func play(playlistID: String, title: String) async -> SearchPlayOutcome { .started }
    func playRadioFilter(_ command: MusicQueueFilterCommand, title: String) async -> SearchPlayOutcome { filters.append(command); return .started }
    func copy(link: URL) {}
}
@Suite @MainActor struct PublishedQueueFilterRoutingTests {
    @Test func retainedRenderedActionsCannotBindToNewAccountOrSameSeedControls() async throws {
        for replaceAccount in [false, true] {
            let book = RadioSeedBook()
            let item = MusicCatalogItem(kind: .song, title: "Seed", videoID: "aaaaaaaaaa1", radio: MusicRadioAction(playlistID: "RDseed"))
            book.note(items: [item])
            let recorder = QueueFilterRecorder()
            let source = QueueRadioControlsSource { _ in MusicRadioQueue(chips: [
                MusicRadioChip(title: "Workout", isSelected: false, playlistID: "RDfetch", params: "p", playerParams: "extra")]) }
            let tuner = TunerModel(seedBook: book, performer: recorder, source: source)
            let seed = try #require(book.seeds.first)
            await tuner.start(seed)
            let identityA = tuner.controlsIdentity
            let optionA = try #require(tuner.controls.first?.options.first)
            // This is the identity captured while rendering A, before even the setter is invoked.
            let delayedAction = { await tuner.choose(option: optionA.id, in: "queue-filter", suppliedBy: identityA) }
            if replaceAccount { tuner.accountChanged(); book.note(items: [item]) }
            await tuner.start(seed)
            let identityB = tuner.controlsIdentity
            #expect(identityA != identityB && tuner.controls.first?.options.first?.id == optionA.id)
            await delayedAction()
            #expect(recorder.filters.isEmpty && !tuner.busy && tuner.context?.choices.isEmpty == true)
            await tuner.choose(option: optionA.id, in: "queue-filter", suppliedBy: identityB)
            #expect(recorder.filters.count == 1 && tuner.startCount == 2)
        }
    }
    @Test func unconfirmedPerformerReturnsModelToIdleWithoutRestartOrSelection() async throws {
        let book = RadioSeedBook()
        book.note(items: [MusicCatalogItem(kind: .song, title: "Seed", videoID: "aaaaaaaaaa1", radio: MusicRadioAction(playlistID: "RDseed"))])
        let recorder = QueueFilterRecorder()
        let source = QueueRadioControlsSource { _ in MusicRadioQueue(chips: [
            MusicRadioChip(title: "Workout", isSelected: false, playlistID: "RDfetch", params: "p")]) }
        let tuner = TunerModel(seedBook: book, performer: recorder, source: source)
        await tuner.start(try #require(book.seeds.first))
        let before = tuner.context
        recorder.apply = {
            try? await Task.sleep(for: .milliseconds(40))
            return .failed // Whole-operation timeout from the player boundary.
        }
        let identity = tuner.controlsIdentity
        let task = Task { await tuner.choose(option: "RDfetch|p", in: "queue-filter", suppliedBy: identity) }
        for _ in 0..<10 { await Task.yield() }
        #expect(tuner.busy)
        await task.value
        #expect(!tuner.busy && tuner.failure == .filterUnconfirmed && tuner.context == before && tuner.startCount == 1)
    }
    @Test func everyRealChipReachesTheCompletePerformerWithExactOpaqueFields() async throws {
        let data = try Data(contentsOf: fixturesRoot().appendingPathComponent("R1-real/next-radio.json"))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let queue = try MusicRadioQueueParser.parse(root)
        let book = RadioSeedBook()
        book.note(items: [MusicCatalogItem(kind: .song, title: "Seed", videoID: "aaaaaaaaaa1", radio: MusicRadioAction(playlistID: "RDseed"))])
        let recorder = QueueFilterRecorder()
        let reads = RadioReadRecorder()
        let tuner = TunerModel(seedBook: book, performer: recorder, source: QueueRadioControlsSource { context in
            await reads.note(context.queueReadAction)
            return queue
        })
        await tuner.start(try #require(book.seeds.first))
        for chip in queue.chips {
            let option = try #require(tuner.controls.first?.options.first { $0.title == chip.title })
            #expect(tuner.canApply(option))
            await tuner.choose(option: option.id, in: "queue-filter", suppliedBy: tuner.controlsIdentity)
            let sent = try #require(recorder.filters.last)
            #expect(sent.playlistID == chip.playlistID && sent.params == chip.params && sent.playerParams == chip.playerParams)
            let context = try #require(tuner.context)
            #expect(context.playlistID == "RDseed" && context.params == nil)
            let action = context.queueReadAction
            #expect(await reads.last == action, "the post-choice source read uses the selected fetch endpoint")
            #expect(action.playlistID == chip.playlistID && action.params == chip.params && action.playerParams == chip.playerParams && action.videoID == nil)
            let body = try MusicRadioQueueParser.queueBody(action)
            #expect(body["playlistId"] as? String == chip.playlistID && body["params"] as? String == chip.params)
            #expect(body["playerParams"] as? String == chip.playerParams && body["videoId"] == nil)
        }
        #expect(tuner.startCount == 1, "autoplay controls never count as new radio starts")
        let staleOption = try #require(tuner.controls.first?.options.first)
        recorder.current = false
        #expect(!tuner.canApply(staleOption))
        await tuner.choose(option: staleOption.id, in: "queue-filter", suppliedBy: tuner.controlsIdentity)
        #expect(recorder.filters.count == 13)
        for bad in ["", "p\n", String(repeating: "p", count: 1025)] {
            #expect(throws: MusicSessionError.policy) {
                try MusicRadioQueueParser.queueBody(MusicRadioAction(playlistID: "RDseed", params: "p", playerParams: bad))
            }
        }
        #expect(recorder.filters.filter { $0.playerParams != nil }.count == 2)
        #expect(recorder.filters.filter { $0.playerParams != nil }.allSatisfy { $0.playerParams == "0gcJCW0At9Zurpe2" })
    }
}

private actor RadioReadRecorder {
    var last: MusicRadioAction?
    func note(_ action: MusicRadioAction) { last = action }
}
