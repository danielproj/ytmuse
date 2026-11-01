import Testing
import AppKit
import SwiftUI
import Foundation
import DesignSystem
import Domain
import AccountSession
@testable import AppShell

/// T52-F1. Two things the audit suites rely on when they run side by side in one process.
///
/// 1. `settleUntilReported` waits for tags that report late and still leaves a tag that never renders missing.
/// 2. `LocalAccountBootstrap.shutdown()` shuts down THAT bootstrap only. It used to be reached through one process-wide static closure
///    (`PlaybackApplicationDelegate.shutdown`) that held whichever bootstrap installed it last, so a test finishing its render released the player
///    another test was still rendering, and the bar's tint, the mini-player's timeline and the other suites' tags vanished mid-run.

private struct LateReporter: View {
    let delay: Int
    @State private var shown = false
    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            Text("early").audit("early", group: "root", kind: .element)
            if shown { Text("late").audit("late", group: "root", kind: .element) }
        }
        .frame(width: 200, height: 120, alignment: .topLeading)
        .task { try? await Task.sleep(for: .milliseconds(delay)); shown = true }
    }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["YTMUSE_NATIVE_DESIGN_TEST"] == "1"))
@MainActor struct SettleHelperTests {
    private func host(delay: Int) -> AuditHost {
        AuditHost(LateReporter(delay: delay), size: AuditSize(name: "tiny", width: 200, height: 120), scheme: .light, title: false)
    }
    private func missing(_ host: AuditHost, _ required: [String]) -> [String] {
        host.violations(expecting: required).filter { $0.rule == .missing }.map(\.detail)
    }
    @Test func aTagThatReportsLateIsWaitedFor() async {
        let host = host(delay: 500); defer { host.close() }
        let complete = await host.settleUntilReported(["early", "late"])
        #expect(complete)
        #expect(missing(host, ["early", "late"]).isEmpty, "late was reported inside the bound")
    }
    @Test func theWaitIsBounded() async {
        let host = host(delay: 5000); defer { host.close() }
        let start = ContinuousClock.now
        let complete = await host.settleUntilReported(["early", "late"], milliseconds: 400)
        let elapsed = ContinuousClock.now - start
        #expect(!complete)
        #expect(elapsed < .seconds(3), "the bound is a bound (\(elapsed))")
        #expect(missing(host, ["early", "late"]) == ["late was not reported"], "a tag that is not there in time is still a failure")
    }
    @Test func aTagThatNeverRendersStaysMissing() async {
        let host = host(delay: 0); defer { host.close() }
        let complete = await host.settleUntilReported(["early", "never"], milliseconds: 600)
        #expect(!complete)
        #expect(missing(host, ["early", "never"]) == ["never was not reported"])
    }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["YTMUSE_NATIVE_DESIGN_TEST"] == "1"))
@MainActor struct ShutdownIsolationTests {
    @Test func shuttingOneBootstrapDownLeavesTheOtherPlaying() async throws {
        let first = LocalAccountBootstrap(); await first.load()
        let second = LocalAccountBootstrap(); await second.load()   // installed last: the static closure would now reach THIS one
        first.playback.music = await SyntheticPlayback.player(.playing)
        second.playback.music = await SyntheticPlayback.player(.playing)
        try #require(first.playback.music != nil && second.playback.music != nil)
        await first.shutdown()
        #expect(first.playback.music == nil, "the bootstrap that shut down released its own player")
        #expect(second.playback.music != nil, "and the one still in use kept its player")
        await second.shutdown()
        #expect(second.playback.music == nil)
        await first.isolatedStorage?.destroy()
        await second.isolatedStorage?.destroy()
    }

    /// R2 (T52-F1 critic): the app's quit reaches the bootstrap's own shutdown. This runs the closure the app installs (`makeShutdownClosure()`),
    /// for ONE bootstrap, without the process-wide static: a closure that forwards nothing leaves the session unsaved and the player alive.
    @Test func theClosureTheAppInstallsRunsThisBootstrapsQuitAndNoOtherBootstrapsQuit() async throws {
        let first = LocalAccountBootstrap(); await first.load()
        let second = LocalAccountBootstrap(); await second.load()
        let firstStore = RecordingResumeStore(), secondStore = RecordingResumeStore()
        first.playback.resumeStore = firstStore; second.playback.resumeStore = secondStore
        first.playback.music = await SyntheticPlayback.player(.playing)
        second.playback.music = await SyntheticPlayback.player(.playing)
        // The session is saved under the account the player is bound to: give the first bootstrap one (as the lifecycle rig does).
        let id = UUID()
        let context = try AccountContext(accountID: id, channelID: ID("UCsyntheticShutdown"), region: "US")
        let account = try Account(id: id, serviceIdentity: ServiceID("UCsyntheticShutdown"), context: context, displayName: "Synthetic Listener", credential: try CredentialReference("synthetic-ref"))
        try await first.playback.authority.restorePaused(LocalIdentity(account: account, state: .connected), context: RequestContext(account: context, accountGeneration: 4, requestGeneration: 0))
        let firstAccount = try #require(await first.playback.authority.activeAccountID())
        let ran = Ran()
        first.shutdownAfter = { await ran.mark("first") }
        second.shutdownAfter = { await ran.mark("second") }
        let closure = first.makeShutdownClosure()
        await closure()
        #expect(await firstStore.saved.map(\.1) == [firstAccount.uuidString], "the session was saved for this bootstrap before the player was dropped")
        #expect(await firstStore.saved.first?.0.playlistID == "PLsynthetic")
        #expect(first.playback.music == nil, "its player was released")
        #expect(await ran.names == ["first"], "its own cleanup ran, and only its own")
        #expect(second.playback.music != nil, "the other bootstrap's player is untouched")
        #expect(await secondStore.saved.isEmpty, "and nothing was saved for it")
        await second.shutdown()
        await first.isolatedStorage?.destroy()
        await second.isolatedStorage?.destroy()
    }
}

private actor Ran {
    private(set) var names: [String] = []
    func mark(_ name: String) { names.append(name) }
}
private actor RecordingResumeStore: MusicResumeStoring {
    private(set) var saved: [(MusicResumeRecord, String)] = []
    func save(_ record: MusicResumeRecord, account: String) { saved.append((record, account)) }
    func load(account: String) -> MusicResumeRecord? { saved.last { $0.1 == account }?.0 }
    func clear(account: String) {}
}
