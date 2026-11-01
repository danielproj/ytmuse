import AppKit
import Foundation
import Testing
@testable import AccountSession
@testable import Features

/// SS1: the attempt store can only be removed once its web view is deallocated.
@Suite @MainActor struct SignInReleaseTests {
    @Test func theSheetHostNeverKeepsTheSignInWebViewAlive() {
        var view: NSView? = NSView()
        let host = WebContentHost(view: view!)
        #expect(host.content.view === view)
        view = nil
        #expect(host.content.view == nil, "SwiftUI may keep the host value; it must not keep the web view")
    }
    /// T1: behaviour, not wall-clock speed. The injected sleep records each wait and
    /// releases the view on a chosen poll, so the result is identical under any load.
    @Test func awaitingReleaseReturnsOnThePollTheViewIsGone() async {
        var released = false, sleeps: [Duration] = []
        let result = await WebMusicSignIn.awaitRelease(limit: .seconds(3), step: .milliseconds(50), sleep: { step in
            sleeps.append(step)
            if sleeps.count == 3 { released = true }
        }) { released }
        #expect(result && sleeps.count == 3, "returns on the first poll after release, without waiting out the bound")
        #expect(sleeps.allSatisfy { $0 == .milliseconds(50) })
    }
    @Test func awaitingReleaseIsBoundedWhenTheViewNeverGoes() async {
        var sleeps = 0
        let result = await WebMusicSignIn.awaitRelease(limit: .seconds(3), step: .milliseconds(50), sleep: { _ in sleeps += 1 }) { false }
        #expect(!result && sleeps == 60, "exactly limit / step waits, then it gives up")
    }
    @Test func anAlreadyReleasedViewNeverWaits() async {
        var sleeps = 0
        let result = await WebMusicSignIn.awaitRelease(limit: .seconds(3), sleep: { _ in sleeps += 1 }) { true }
        #expect(result && sleeps == 0)
    }
}
