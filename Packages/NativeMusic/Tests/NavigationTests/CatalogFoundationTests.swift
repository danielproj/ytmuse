import Testing
import Foundation
import SwiftUI
import DesignSystem
@testable import AppShell

@MainActor struct CatalogFoundationTests {
    @Test func newLabelsAndActionFailuresHaveEnglishCatalogEntries() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Resources/Localizable.xcstrings"))) as? [String: Any])
        let strings = try #require(object["strings"] as? [String: Any])
        let required = ["Maximum scroll (pt): %@", "Content height (pt): %@", "Live scroll (pt): %@", "Stored scroll (pt): %@", "This link cannot be opened", "Panel", "Working…", "Untitled item", "Accounts", "Move up", "Move down", "Move to end of page", "Retry action", "Now Playing artwork", "Reset saved window state?", "Reset saved window state…", WindowNavigationAuthority.unavailableNotice, "Window history could not be saved. Try saving again.", "Window history could not be opened. Your current window was preserved."]
        #expect(!required.isEmpty)
        for key in required { #expect(strings[key] != nil, "Missing English key: \(key)") }
        // Converged with E01 (W09 integration): library, YouTube Music transport and Home.
        let converged = ["Your playlists", "No downloaded playlists", "No matching playlists", "No playlists in your library yet", "Show Library", "Showing the first page of your library.", "Your library could not be read", "Session expired", "Play %@", "YouTube Music playlist", "Open Your Library", "Your Music Account", "Sign In Again", "Cancel Sign-In", "Cancel authorization", "Your password is entered on Google’s page, never in YTMuse.", "YouTube Music could not start. Try Play again.", "Seeking and skipping are unavailable while an ad plays.", "Advertisement playing", "Ad", "Ad playing", "Starting YouTube Music…", "Buffering…", "Not playing", "Playing", "Paused", "Ended", "Stopped", "YouTube Music volume", "Loading, Pause", "%@ of %@", "Playing from YouTube Music", "Playlist", WebMusicQueueSummary.managedByYouTubeMusic]
        for key in converged { #expect(strings[key] != nil, "Missing English key: \(key)") }
        for action in [PlaybackUIAction.transport, .previous, .next, .seek, .volume, .mute, .selectQueue, .reorderQueue, .shuffle, .repeatMode, .sleepTimer] {
            #expect(strings[action.failure] != nil)
        }
        // Public component labels are localized keys, while metadata titles remain verbatim Strings.
        let label: LocalizedStringKey = "Accounts"
        _ = AccountSwitcher(label: label, action: {})
        _ = DownloadRow(title: "Björk — metadata", status: LocalizedStringKey("Pending"))
    }
}

/// Critic W09-integration finding 5: the user's real library is never labelled test data.
struct DevelopmentLabelSeparationTests {
    @Test func theSignedInLibraryIsNeverLabelledDevelopmentData() {
        #expect(!BrowserDestinationView.labelsDevelopmentData(development: true, destination: .library, signedInLibrary: true))
        #expect(BrowserDestinationView.labelsDevelopmentData(development: true, destination: .library, signedInLibrary: false))
        #expect(BrowserDestinationView.labelsDevelopmentData(development: true, destination: .explore, signedInLibrary: true))
        #expect(!BrowserDestinationView.labelsDevelopmentData(development: false, destination: .explore, signedInLibrary: false))
    }
}
