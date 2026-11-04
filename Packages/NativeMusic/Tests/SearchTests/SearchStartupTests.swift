import AccountSession
import Foundation
import Testing
@testable import AppShell
@testable import Features

/// Uses only the ordinary composition's isolated stores and an in-memory reader.
/// The design shortcut intentionally does not create a service coordinator.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["YTMUSE_UI_TEST_ISOLATED"] == "1" && ProcessInfo.processInfo.environment["YTMUSE_NATIVE_DESIGN_TEST"] != "1" && ProcessInfo.processInfo.environment["YTMUSE_UI_DEVELOPMENT_DATA"] != "1"))
@MainActor struct SearchStartupTests {
    actor Reader: MusicSessionReading {
        let adapterVersion = "isolated-search-startup"
        private(set) var queries: [String] = []
        func accountMenu(session: MusicCookieSession) async throws -> MusicSignedResult<MusicAccountIdentity> { throw MusicSessionError.policy }
        func likedPlaylists(session: MusicCookieSession) async throws -> MusicSignedResult<MusicLibraryPlaylists> { throw MusicSessionError.policy }
        func avatar(_ url: URL) async throws -> Data { throw MusicSessionError.policy }
        func search(query: String, session: MusicCookieSession?) async throws -> MusicSignedResult<MusicSearchResponse> {
            queries.append(query)
            return MusicSignedResult(value: MusicSearchResponse(top: nil,
                items: [MusicSearchItem(kind: .song, title: "Startup result", subtitle: nil, videoID: "raceSong001")],
                suggestion: nil, skippedRows: 0), rotation: [])
        }
    }

    @Test func aSearchModelCreatedBeforeAccountLoadingStillReachesTheReader() async throws {
        let reader = Reader()
        let bootstrap = LocalAccountBootstrap(musicReader: reader)
        #expect(bootstrap.music == nil)
        let model = bootstrap.makeSearchModel()
        model.query = "startup query"
        for _ in 0..<200 {
            if case .loaded = model.remoteStatus { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        #expect(await reader.queries == ["startup query"])
        #expect(model.results.contains { $0.title == "Startup result" })
        #expect(bootstrap.music != nil)
        await bootstrap.shutdown()
        await bootstrap.isolatedStorage?.destroy()
    }
}
