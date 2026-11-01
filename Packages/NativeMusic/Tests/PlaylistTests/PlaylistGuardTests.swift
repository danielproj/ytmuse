import AccountSession
import Foundation
import Testing
@testable import Features

private func packageRoot() -> URL {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { root.deleteLastPathComponent() }          // Tests/PlaylistTests/<file> -> package root
    return root
}
private func swiftFiles(under folder: URL) throws -> [(name: String, text: String)] {
    guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
    var result: [(String, String)] = []
    for case let url as URL in walker where url.pathExtension == "swift" {
        result.append((url.path.replacingOccurrences(of: packageRoot().path + "/", with: ""), try String(contentsOf: url, encoding: .utf8)))
    }
    return result.sorted { $0.0 < $1.0 }
}
private func codeLines(_ text: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///") && !trimmed.hasPrefix("*")
    }
}

/// The addendum's safety rules for playlist editing, as tests. W12's `LibraryGuardTests` already refuses any live transport in any test
/// target (this target included); these pin who may send a playlist change and from where.
@Suite struct PlaylistGuardTests {
    @Test func theWriteCoverageIsNotVacuous() throws {
        let sources = try swiftFiles(under: packageRoot().appendingPathComponent("Sources"))
        #expect(sources.count > 80)
        #expect(sources.contains { $0.name.hasSuffix("Features/Playlists/PlaylistEditSession.swift") })
        let tests = try swiftFiles(under: packageRoot().appendingPathComponent("Tests"))
        #expect(tests.contains { $0.name.hasSuffix("PlaylistTests/PlaylistGuardTests.swift") }, "the scan covers this target too")
    }
    @Test func onlyTheComposedServiceReachesTheCoordinatorsPlaylistWriteAndItIsOneCallSite() throws {
        let sources = try swiftFiles(under: packageRoot().appendingPathComponent("Sources"))
        var callers: [String] = []
        for (name, text) in sources { for line in codeLines(text) where line.contains(".editPlaylist(") && (line.contains("awaitedMusic") || line.contains("coordinator") || line.contains("music.")) { callers.append(name) } }
        #expect(callers == ["Sources/AppShell/PlaylistComposition.swift"])
        let composition = try #require(sources.first { $0.name.hasSuffix("AppShell/PlaylistComposition.swift") })
        #expect(codeLines(composition.text).filter { $0.contains("awaitedMusic().editPlaylist(") }.count == 1)
    }
    @Test func onlyTheEditingSessionAndTheCreatorEverApplyARequest() throws {
        let sources = try swiftFiles(under: packageRoot().appendingPathComponent("Sources"))
        var appliers: Set<String> = []
        for (name, text) in sources where codeLines(text).contains(where: { $0.contains("service.apply(") || $0.contains("try await service.apply") }) { appliers.insert(name) }
        #expect(appliers == ["Sources/Features/Playlists/PlaylistCreator.swift", "Sources/Features/Playlists/PlaylistEditSession.swift", "Sources/Features/Playlists/PlaylistJoiner.swift"])
        // Reading, loading, refreshing and checking never apply: the only `apply` calls sit in `dispatch`, `deletePlaylist` and `create`.
        let session = try #require(sources.first { $0.name.hasSuffix("PlaylistEditSession.swift") }).text
        let lines = session.components(separatedBy: "\n")
        var function = ""
        var inside: [String: Int] = [:]
        for line in lines {
            if let range = line.range(of: #"func ([A-Za-z]+)"#, options: .regularExpression) { function = String(line[range].dropFirst(5)) }
            if line.contains("service.apply(") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { inside[function, default: 0] += 1 }
        }
        #expect(inside == ["dispatch": 1, "deletePlaylist": 1, "sendCollaboration": 1], Comment(rawValue: "\(inside)"))
    }
    @Test func theViewsSubmitOnlyFromAnExplicitGestureNeverFromALoopATimerOrAnAppearance() throws {
        let views = try swiftFiles(under: packageRoot().appendingPathComponent("Sources/Features/Playlists")).filter { $0.name.hasSuffix("View.swift") || $0.name.hasSuffix("Entries.swift") }
        #expect(views.count >= 3)
        for (name, text) in views {
            for line in codeLines(text) where line.contains("session.submit(") || line.contains("session.resolve(") || line.contains("session.undoLast(") || line.contains("creator.create(") || line.contains("session.deletePlaylist(") || line.contains("session.retry(")
                || line.contains("joiner.join(") || line.contains("session.stopContributions(") || line.contains("session.createInviteLink(") || line.contains("session.confirmAdd(") || line.contains("session.retryCollaboration(") {
                #expect(!(line.contains("for ") || line.contains("forEach") || line.contains("Timer") || line.contains("sleep") || line.contains(".onAppear") || line.contains(".task")),
                        Comment(rawValue: "\(name): \(line)"))
            }
        }
    }
    @Test func neverARemovalByVideoIdAndNoWholePlaylistReplacement() throws {
        let sources = try swiftFiles(under: packageRoot().appendingPathComponent("Sources"))
        // The ONE named exception (W18): "Episodes for Later" is the service's own list of single episodes. An episode page publishes no occurrence id,
        // and its own remove names the episode, so a person's remove-from-later is a removal by video id. Only the episode parser (which recognises the
        // published endpoint) and the one `episodeLater` wire case may name the action; the playlist editor and the playlist wire never.
        let episodeLater: Set<String> = ["Sources/YouTubeMusicAdapter/MusicEpisodeParser.swift", "Sources/YouTubeMusicAdapter/SignedMusic.swift"]
        for (name, text) in sources where !name.contains("Development") {
            if !episodeLater.contains(name) { #expect(!text.contains("ACTION_REMOVE_VIDEO_BY_VIDEO_ID"), Comment(rawValue: name)) }
            #expect(!text.contains("ACTION_SET_PLAYLIST_ORDER") && !text.contains("ACTION_REPLACE"), Comment(rawValue: name))
        }
        let signed = try #require(sources.first { $0.name.hasSuffix("YouTubeMusicAdapter/SignedMusic.swift") }).text
        #expect(signed.components(separatedBy: "ACTION_REMOVE_VIDEO_BY_VIDEO_ID").count - 1 == 1, "exactly one use in the signed client")
        let wireCase = try #require(signed.range(of: "case .episodeLater(let video, let saved):"))
        #expect(signed[wireCase.upperBound...].prefix(600).contains("ACTION_REMOVE_VIDEO_BY_VIDEO_ID"), "and it is inside the episodeLater case")
        // The parser file is exempt too, so it is held to a count and a place (rework 1): exactly one use, inside the function that recognises the
        // published endpoint, and no constant there can carry the action into the playlist code.
        let parser = try #require(sources.first { $0.name.hasSuffix("YouTubeMusicAdapter/MusicEpisodeParser.swift") }).text
        #expect(parser.components(separatedBy: "ACTION_REMOVE_VIDEO_BY_VIDEO_ID").count - 1 == 1, "exactly one use in the episode parser")
        let side = try #require(parser.range(of: "private static func side("))
        let end = try #require(parser[side.upperBound...].range(of: "\n    }\n"))
        #expect(parser[side.upperBound..<end.lowerBound].contains("ACTION_REMOVE_VIDEO_BY_VIDEO_ID"), "inside side(_:videoID:), the recognition of the published endpoint")
        #expect(!parser.split(separator: "\n").contains { $0.contains("static let") && $0.contains("ACTION_") }, "no constant holds an action name")
        // Nothing in the playlist code reaches into the episode parser, and only the signed client uses its list constant.
        for (name, text) in sources where !name.contains("Development") && name != "Sources/YouTubeMusicAdapter/MusicEpisodeParser.swift" {
            if text.contains("MusicEpisodeParser.") { #expect(["Sources/YouTubeMusicAdapter/SignedMusic.swift", "Sources/YouTubeMusicAdapter/PublicMusic.swift"].contains(name), Comment(rawValue: "\(name) uses the episode parser")) }
        }
        let playlistWire = try #require(sources.first { $0.name.hasSuffix("SignedPlaylistWrites.swift") }).text
        #expect(!playlistWire.contains("MusicEpisodeParser") && !playlistWire.contains("laterPlaylistID"))
        // The only remove the app builds names the occurrence.
        let wire = try #require(sources.first { $0.name.hasSuffix("SignedPlaylistWrites.swift") }).text
        #expect(wire.contains("\"setVideoId\": occurrence"))
    }
    @Test func theThreePlaylistPathsAreNamedOnlyByTheTransportPolicyAndTheWireCode() throws {
        let sources = try swiftFiles(under: packageRoot().appendingPathComponent("Sources"))
        for (name, text) in sources where text.contains("playlistWritePaths") || text.contains("browse/edit_playlist") || text.contains("playlist/create") || text.contains("playlist/delete") {
            #expect(["Sources/YouTubeMusicAdapter/SignedMusic.swift", "Sources/YouTubeMusicAdapter/SignedPlaylistWrites.swift", "Sources/AccountSession/WebSession/MusicPlaylistModels.swift"].contains(name)
                    || name.hasSuffix("Playlists/PlaylistModel.swift"), Comment(rawValue: name))
        }
    }
    @Test func theEditButtonIsOfferedOnlyFromTheServicesOwnEditableHeader() throws {
        let entries = try #require(try swiftFiles(under: packageRoot().appendingPathComponent("Sources/Features/Playlists")).first { $0.name.hasSuffix("PlaylistEntries.swift") }).text
        #expect(entries.contains("header.editing?.canEditTracks == true"))
        #expect(entries.contains("surface.isSignedIn") && entries.contains("MusicPlaylistRequest.isEditablePlaylistID"))
        let editor = try #require(try swiftFiles(under: packageRoot().appendingPathComponent("Sources/Features/Playlists")).first { $0.name.hasSuffix("PlaylistEditorView.swift") }).text
        // Every destructive control sits behind a confirmation dialog or is a single, named, undoable removal.
        #expect(editor.contains(".confirmationDialog(") && editor.contains("Delete Playlist"))
        #expect(!editor.contains("Button(\"Delete Playlist…\", role: .destructive) { Task"), "the delete control opens a confirmation, it does not send")
    }
    @Test func everyDropHandlerGoesThroughTheStagingEntryPointAndTheValueIsChecked() throws {
        // The behaviour (nothing is sent until the confirmation) is tested on the session in PlaylistSessionTests; this pins that the views
        // reach it only through `stageDrop`, so a new drop handler cannot bypass it by calling a submitting method.
        let sources = try swiftFiles(under: packageRoot().appendingPathComponent("Sources/Features/Playlists"))
        var found = 0
        for (name, text) in sources {
            let lines = codeLines(text)
            for (index, line) in lines.enumerated() where line.contains(".dropDestination(") {
                found += 1
                let body = lines[index..<min(lines.count, index + 12)].joined(separator: "\n")
                #expect(body.contains("stageDrop(") || body.contains("PlaylistDraggedSong.additions("), Comment(rawValue: "\(name): \(body)"))
                #expect(!body.contains("addSongs(") && !body.contains(".submit(") && !body.contains("confirmAdd(") && !body.contains(".apply("), Comment(rawValue: "\(name): \(body)"))
            }
        }
        #expect(found >= 2, "the editor's list and the playlist drop target")
        // Dragged values are checked: only this app's song format with a real video id is accepted.
        #expect(PlaylistDraggedSong(videoID: "short", title: "x") == nil)
        #expect(PlaylistDraggedSong(videoID: "dQw4w9WgXcQ", title: "") == nil)
        let song = try #require(PlaylistDraggedSong(videoID: "dQw4w9WgXcQ", title: "A"))
        #expect(PlaylistDraggedSong.additions(from: [song, song]).count == 2)
        let forged = try JSONDecoder().decode(PlaylistDraggedSong.self, from: Data(#"{"format":"other","videoID":"dQw4w9WgXcQ","title":"x"}"#.utf8))
        #expect(!forged.isValid && PlaylistDraggedSong.additions(from: [forged]).isEmpty)
        #expect(PlaylistDraggedSong.additions(from: Array(repeating: song, count: 80)).count == MusicPlaylistRequest.maximumActions)
    }
    @Test func readingNeverSendsAnything() async throws {
        let remote = FakePlaylistRemote(rows: FakePlaylistRemote.rows((0..<6).map(FakePlaylistRemote.video)))
        let session = await MainActor.run { PlaylistEditSession(playlistID: remote.playlistID, service: remote) }
        await session.load(); await session.refresh()
        let (sent, pending) = await MainActor.run { (session.sentCount, session.operations.count) }
        let state = await remote.state()
        #expect(sent == 0 && pending == 0)
        #expect(state.requests.isEmpty)
    }
    @Test func developmentPlaylistsExistOnlyInsideDebugAndOnlyWithBothFlagsAndIsolation() throws {
        let sources = try swiftFiles(under: packageRoot().appendingPathComponent("Sources"))
        let file = try #require(sources.first { $0.name.hasSuffix("AppShell/DevelopmentPlaylists.swift") })
        #expect(file.text.hasPrefix("#if DEBUG") && file.text.hasSuffix("#endif\n"))
        #expect(file.text.contains("DevelopmentSearch.isEnabled(environment) && environment[\"YTMUSE_UI_DEVELOPMENT_PLAYLISTS\"] == \"1\""))
        #expect(!file.text.contains("URLSession") && !file.text.contains("https://"), "the development data performs no network request")
        for (name, text) in sources where name != file.name && text.contains("DevelopmentPlaylists") {
            var depth = 0
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#if DEBUG") { depth += 1 } else if trimmed.hasPrefix("#endif") { depth -= 1 }
                if trimmed.contains("DevelopmentPlaylists") && !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///") { #expect(depth > 0, "unguarded in \(name): \(trimmed)") }
            }
        }
    }
    @Test func playlistUserStringsAreInTheStringCatalog() throws {
        let catalogURL = packageRoot().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Localizable.xcstrings")
        let strings = try #require((try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])?["strings"] as? [String: Any])
        let localized = try NSRegularExpression(pattern: #"String\(localized: "((?:[^"\\]|\\.)*)"\)"#)
        let literal = try NSRegularExpression(pattern: #"(?:Text|Label|Button|Picker|TextField|Section|confirmationDialog|ProgressView)\("((?:[^"\\]|\\.)*)""#)
        var checked = 0
        for (name, text) in try swiftFiles(under: packageRoot().appendingPathComponent("Sources/Features/Playlists")) {
            for regex in [localized, literal] {
                for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    guard let range = Range(match.range(at: 1), in: text) else { continue }
                    var key = String(text[range])
                    guard key.range(of: #"[A-Za-z]{2}"#, options: .regularExpression) != nil else { continue }
                    key = key.replacingOccurrences(of: #"\\\((?:[^()]|\([^()]*\))*\)"#, with: "%@", options: .regularExpression)
                    checked += 1
                    #expect(Self.candidates(key).contains { strings[$0] != nil }, Comment(rawValue: "\(name): missing \(key)"))
                }
            }
        }
        #expect(checked >= 80)
    }
    /// Every spelling a key can have in the catalog: each `%@` placeholder may be a count (`%lld`) instead.
    private static func candidates(_ key: String) -> [String] {
        let parts = key.components(separatedBy: "%@")
        guard parts.count > 1, parts.count <= 6 else { return [key] }
        return (0..<(1 << (parts.count - 1))).map { mask in
            var text = parts[0]
            for index in 1..<parts.count { text += ((mask >> (index - 1)) & 1 == 1 ? "%lld" : "%@") + parts[index] }
            return text
        }
    }
    @Test func theThirdPartyNoticeNamesTheCopiedFixtures() throws {
        let notices = try String(contentsOf: packageRoot().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("THIRD_PARTY_NOTICES.md"), encoding: .utf8)
        #expect(notices.contains("Fixtures/W13-real/kaset-playlist_detail.json") && notices.contains("4c59ff259d853f1cc328597f5adccf2a291c2fa7"))
    }
}
