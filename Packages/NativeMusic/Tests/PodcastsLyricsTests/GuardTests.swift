import Foundation
import Testing

private func packageRoot() -> URL {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { root.deleteLastPathComponent() }
    return root
}
private func swiftFiles(under folder: URL) throws -> [(name: String, text: String)] {
    guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
    var result: [(String, String)] = []
    for case let url as URL in walker where url.pathExtension == "swift" {
        result.append((url.path.replacingOccurrences(of: packageRoot().path + "/", with: ""), try String(contentsOf: url, encoding: .utf8)))
    }
    return result
}
private func codeLines(_ text: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter {
        let t = $0.trimmingCharacters(in: .whitespaces); return !t.hasPrefix("//") && !t.hasPrefix("///") && !t.hasPrefix("*")
    }
}
private func sources(_ folders: String...) throws -> [(name: String, text: String)] {
    var all: [(String, String)] = []
    for folder in folders { all += try swiftFiles(under: packageRoot().appendingPathComponent("Sources/" + folder)) }
    return all
}

/// The W18 rules as tests over the sources: what the podcast and lyrics code is and is not allowed to do.
@Suite struct PodcastsLyricsGuardTests {
    @Test func theSweptPopulationIsNotEmpty() throws {
        let files = try sources("Features/Podcasts", "Features/Lyrics")
        #expect(files.count >= 6 && files.allSatisfy { !$0.text.isEmpty })
        #expect(try sources("YouTubeMusicAdapter").contains { $0.name.hasSuffix("MusicLyricsParser.swift") })
    }
    @Test func noExternalLyricsProviderIsNamedOrReachedAnywhere() throws {
        let providers = ["musixmatch.com", "genius.com", "lrclib", "lyrics.ovh", "azlyrics", "lyricfind", "api.musixmatch", "megalobiz", "syair", "lyricsify"]
        for (name, text) in try sources("Features/Podcasts", "Features/Lyrics", "YouTubeMusicAdapter", "AppShell") {
            let lowered = text.lowercased()
            for provider in providers { #expect(!lowered.contains(provider), Comment(rawValue: "\(name) names \(provider)")) }
        }
        // The lyrics code makes no request of its own: it has no URL and no URLSession.
        for (name, text) in try sources("Features/Lyrics") + (try sources("YouTubeMusicAdapter").filter { $0.name.hasSuffix("MusicLyricsParser.swift") }) {
            let code = codeLines(text).joined(separator: "\n")
            #expect(!code.contains("URLSession") && !code.contains("URLRequest") && !code.contains("http://") && !code.contains("https://"), Comment(rawValue: name))
        }
    }
    @Test func nothingInTheLyricsPathEditsOrFabricatesTheText() throws {
        for (name, text) in try sources("Features/Lyrics") + (try sources("YouTubeMusicAdapter").filter { $0.name.hasSuffix("MusicLyricsParser.swift") }) {
            for line in codeLines(text) {
                #expect(!line.contains(".trimmingCharacters") || line.contains("isEmpty"), Comment(rawValue: "\(name): the text is only measured for emptiness, never trimmed: \(line)"))
                #expect(!line.contains("replacingOccurrences") && !line.contains(".lowercased()") && !line.contains(".uppercased()") && !line.contains("capitalized"), Comment(rawValue: "\(name): \(line)"))
            }
        }
        // Timing is read from the source's cue ranges only: no line is given a start time anywhere else.
        let makers = try sources("Features", "AppShell", "YouTubeMusicAdapter").filter { $0.text.contains("MusicTimedLyricLine(") }.map(\.name).sorted()
        #expect(makers == ["Sources/Features/Lyrics/LyricsFollowing.swift"].filter { _ in false } + ["Sources/YouTubeMusicAdapter/MusicLyricsParser.swift"])
    }
    @Test func theLyricsViewShowsTheTextVerbatimAndTheSourceFooter() throws {
        let view = try #require(try sources("Features/Lyrics").first { $0.name.hasSuffix("LyricsView.swift") }).text
        #expect(view.contains("Text(verbatim: text)") && view.contains("Text(verbatim: footer)") && view.contains("lyricsSource"))
        #expect(view.contains("accessibilityReduceMotion") && view.contains("lyricsReturn") && view.contains("onScrollPhaseChange"))
    }
    @Test func episodeProgressNeverLeavesThisMac() throws {
        for (name, text) in try sources("Features/Podcasts") {
            let code = codeLines(text).joined(separator: "\n")
            #expect(!code.contains("URLSession") && !code.contains("URLRequest") && !code.contains("feedbackToken") && !code.contains("videoPlaybackPositionFeedbackToken"), Comment(rawValue: name))
            #expect(!code.contains("MusicWriteRequest") && !code.contains(".write("), Comment(rawValue: name))
        }
        // The one write this node adds is named in the ledger's intent and the wire, and nowhere else.
        // The REQUEST (`MusicWriteRequest.episodeLater(videoID:saved:)`) is built by the ledger's intent and read by the wire, and by nothing else.
        let namers = try sources("Features", "AppShell", "YouTubeMusicAdapter", "AccountSession").filter { file in
            codeLines(file.text).contains { $0.contains("request: .episodeLater(") || $0.contains("case .episodeLater(let video, let saved)") || $0.contains("case episodeLater(videoID: String, saved: Bool)") }
        }.map(\.name).sorted()
        #expect(namers == ["Sources/AccountSession/WebSession/MusicLibraryModels.swift", "Sources/Features/Library/LibraryWriteLedger.swift", "Sources/YouTubeMusicAdapter/SignedMusic.swift"], Comment(rawValue: "\(namers)"))
    }
    @Test func noEpisodeSurfaceDrawsADownloadControl() throws {
        for (name, text) in try sources("Features/Podcasts") {
            let code = codeLines(text).joined(separator: "\n")
            #expect(!code.contains("DownloadScheduler") && !code.contains("DownloadAction") && !code.contains("addLocalFile") && !code.contains("Button(\"Download"), Comment(rawValue: name))
            #expect(!code.contains("offlineVideoEndpoint") && !code.contains("getDownloadActionCommand"), Comment(rawValue: name))
        }
        let views = try #require(try sources("Features/Podcasts").first { $0.name.hasSuffix("PodcastViews.swift") }).text
        #expect(views.contains("DownloadCapabilityNote"), "the episode page states why there is no download")
    }
    @Test func theAdvertisingRulesHoldForTheNewCommands() throws {
        let scripts = try #require(try sources("Playback/WebMusic").first { $0.name.hasSuffix("WebMusicScripts.swift") }).text
        let start = try #require(scripts.range(of: "static let rate = "))
        let body = String(scripts[start.lowerBound...].prefix(900))
        #expect(body.contains("ytmuseAdShowing()") && body.contains("return \"ad\""))
        // The model never changes the speed or seeks during an ad.
        let model = try #require(try sources("Features/Podcasts").first { $0.name.hasSuffix("PodcastPlaybackModel.swift") }).text
        #expect(model.contains("!reading.advertisement") && model.contains("!player.reading.advertisement"))
    }
    @Test func theProgressBeatNeverWritesAndOnlyObservesWhilePlaying() throws {
        let composition = try #require(try sources("AppShell").first { $0.name.hasSuffix("PodcastsComposition.swift") }).text
        #expect(composition.contains("reading.playing, local.current != nil"))
        let start = try #require(composition.range(of: "let beat = Task"))
        let beat = String(composition[start.lowerBound...])
        #expect(!codeLines(beat).contains { $0.contains(".write(") || $0.contains("URLSession") || $0.contains("awaitedMusic") })
    }
    @Test func theNewRoutesAreReadsAndNavigationOnly() throws {
        let hub = try #require(try sources("AppShell").first { $0.name.hasSuffix("CatalogComposition.swift") }).text
        #expect(hub.contains("case .episode: return route.identifier.hasPrefix(\"MPED\")"))
    }
}
