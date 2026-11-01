import AppIntents
import Foundation
import Testing
import SystemIntegration
import WidgetShared
@testable import Playback
@testable import AppShell

private func requiresAudioPlaybackIntent<T: AudioPlaybackIntent>(_ type: T.Type) {}

/// T25.2 (MAC06, ARCH03): a widget button carries the (account, session) it was drawn under; the app refuses it unless that is still the live one, and otherwise the
/// command goes through W24's channel and the media keys' own admission. Nothing is queued, so there is no stale command to replay.
@Suite @MainActor struct WidgetCommandTests {
    private let account = WidgetFixtures.account
    private func stamp(_ scope: IntentScope) -> WidgetCommandStamp { WidgetCommandStamp(WidgetScope(account: scope.accountID, generation: scope.generation)) }

    // MARK: The rule

    @Test func theGateAdmitsOnlyTheSameAccountInTheSameSession() {
        let live = WidgetScope(account: account, generation: 5)
        #expect(WidgetCommandGate.verdict(for: WidgetCommandStamp(live), live: live) == .admit)
        #expect(WidgetCommandGate.verdict(for: WidgetCommandStamp(live), live: nil) == .refuse(.signedOut), "nobody is signed in")
        #expect(WidgetCommandGate.verdict(for: WidgetCommandStamp(live), live: WidgetScope(account: UUID(), generation: 5)) == .refuse(.otherAccount), "another account is live")
        #expect(WidgetCommandGate.verdict(for: WidgetCommandStamp(live), live: WidgetScope(account: account, generation: 6)) == .refuse(.earlierSession), "a later session of the same account")
        #expect(WidgetCommandGate.verdict(for: WidgetCommandStamp(live), live: WidgetScope(account: account, generation: 4)) == .refuse(.earlierSession), "an earlier one: the stamp must be equal, not just ordered")
    }
    @Test func noRefusalNamesAnAccountATokenOrAGeneration() {
        let token = WidgetScope.token(for: account)
        let all: [WidgetCommandRefusal] = [.appUnavailable, .signedOut, .otherAccount, .earlierSession, .refused("An advertisement is playing.")]
        for refusal in all {
            #expect(!refusal.message.isEmpty && !refusal.message.contains(token) && !refusal.message.contains(account.uuidString) && !refusal.message.contains("5"))
        }
        #expect(WidgetCommandRefusal.otherAccount.message == WidgetCommandRefusal.earlierSession.message, "one sentence: the refusal does not say which")
    }

    // MARK: The intent

    @Test func theButtonIntentIsAnAudioPlaybackIntentTheSystemRunsInTheAppAndIsNotOfferedAnywhere() {
        requiresAudioPlaybackIntent(WidgetTransportIntent.self)
        #expect(WidgetTransportIntent.isDiscoverable == false, "not in Shortcuts, not to Siri")
        #expect(WidgetTransportIntent.openAppWhenRun == false, "a button never brings the app forward")
    }
    @Test func theIntentHandsItsStampToTheReceiverAndRelaysTheAppsAnswer() async throws {
        let receiver = WidgetCommandReceiver()
        var seen: [(WidgetCommandKind, WidgetCommandStamp)] = []
        receiver.install { kind, stamp in seen.append((kind, stamp)); return .success("Done.") }
        let scope = WidgetScope(account: account, generation: 12)
        for kind in WidgetCommandKind.allCases {
            try await WidgetCommandReceiver.$current.withValue(receiver) { _ = try await WidgetTransportIntent(command: kind, scope: scope).perform() }
        }
        #expect(seen.map(\.0) == [.playPause, .next, .previous] && seen.allSatisfy { $0.1 == WidgetCommandStamp(scope) })
        receiver.install { _, _ in .failure(.earlierSession) }
        await #expect(throws: WidgetCommandRefusal.earlierSession) {
            try await WidgetCommandReceiver.$current.withValue(receiver) { _ = try await WidgetTransportIntent(command: .next, scope: scope).perform() }
        }
    }
    @Test func inAProcessWithNoAppHandlerTheButtonDoesNothingAndStartsNothing() async {
        // This is what the extension process would do if the system ran the intent there: there is no player, session or fallback to start.
        let receiver = WidgetCommandReceiver()
        #expect(!receiver.isInstalled)
        await #expect(throws: WidgetCommandRefusal.appUnavailable) {
            try await WidgetCommandReceiver.$current.withValue(receiver) { _ = try await WidgetTransportIntent(command: .playPause, scope: WidgetScope(account: account, generation: 1)).perform() }
        }
        await #expect(throws: WidgetCommandRefusal.earlierSession, "a negative session number is not a session") {
            var intent = WidgetTransportIntent(); intent.command = .next; intent.accountToken = "x"; intent.generation = -1
            try await WidgetCommandReceiver.$current.withValue(receiver) { _ = try await intent.perform() }
        }
    }

    // MARK: The app's side, over the real playback owner

    private func rig() async throws -> (IntentRig, FakeMusicPage, WidgetCommandBridge) {
        let rig = try await IntentRig.make()
        let (_, page) = try await rig.rig.play(state: lifecycleState(playing: false))
        try await Task.sleep(for: .milliseconds(150))   // let the page's own start-up messages arrive, so a later count measures only what a command sent
        return (rig, page, WidgetCommandBridge(surface: rig.surface, hub: rig.hub))
    }
    @Test func aCurrentStampRunsTheMediaKeysOwnCommandsThroughW24sChannel() async throws {
        let (rig, page, bridge) = try await rig()
        let live = stamp(rig.scope)
        func transport() -> [String] { page.bodies.filter { $0 == WebMusicScripts.play || $0 == WebMusicScripts.pause } }
        let sent = transport().count
        guard case .success = await bridge.handle(.playPause, stamp: live) else { Issue.record("play/pause with a current stamp must run"); return }
        await rig.rig.wait { transport().count > sent }
        guard case .success = await bridge.handle(.playPause, stamp: live) else { Issue.record("a second play/pause must run"); return }
        await rig.rig.wait { transport().count > sent + 1 }
        let pair = Array(transport().suffix(2))
        #expect(transport().count == sent + 2 && pair.count == 2 && pair[0] != pair[1], "the button is the player's own play/pause TOGGLE: two presses send play and pause, not the same one twice")
        let next = await bridge.handle(.next, stamp: live)
        guard case .success = next else { Issue.record("next: \(next)"); return }
        await rig.rig.wait { page.bodies.contains(WebMusicScripts.skip) }
        #expect(page.bodies.contains(WebMusicScripts.skip), "Next reached the player's own skip")
        let before = page.bodies.count
        let previous = await bridge.handle(.previous, stamp: live)
        guard case .success = previous else { Issue.record("previous: \(previous)"); return }
        await rig.rig.wait { page.bodies.count > before }
        #expect(page.bodies.count > before)
        #expect(rig.donations.donations.isEmpty, "a widget button is not a user action in the window, so it donates nothing")
    }
    @Test func aStaleStampIsRefusedAndNothingReachesThePlayer() async throws {
        let (rig, page, bridge) = try await rig()
        let before = page.bodies.count
        let cases: [(String, WidgetCommandStamp, WidgetCommandRefusal)] = [
            ("another account", stamp(rig.otherScope), .otherAccount),
            ("an earlier session", stamp(rig.earlierSession), .earlierSession),
            ("a later session", stamp(rig.laterSession), .earlierSession),
            ("an earlier launch of the app (same account, same session number, another nonce)", WidgetCommandStamp(accountToken: stamp(rig.scope).accountToken, generation: rig.scope.generation, launch: "0123456789abcdef0123456789abcdef"), .earlierSession),
        ]
        for (name, stale, expected) in cases {
            for kind in WidgetCommandKind.allCases {
                guard case .failure(let refusal) = await bridge.handle(kind, stamp: stale) else { Issue.record("\(name) \(kind) must be refused"); continue }
                #expect(refusal == expected, "\(name) \(kind)")
            }
        }
        try await Task.sleep(for: .milliseconds(40))
        #expect(page.bodies.count == before, "no stale command reached the page")
    }
    @Test func withNobodySignedInTheButtonIsRefusedAsSignedOut() async throws {
        let (rig, page, bridge) = try await rig()
        let live = stamp(rig.scope)
        rig.surface.scope = nil
        let before = page.bodies.count
        guard case .failure(let refusal) = await bridge.handle(.playPause, stamp: live) else { Issue.record("must be refused"); return }
        #expect(refusal == .signedOut)
        #expect(page.bodies.count == before)
    }
    @Test func anAccountSwitchWhileTheCommandIsWaitingForTheChannelIsCaughtByTheSecondCheck() async throws {
        let (rig, page, bridge) = try await rig()
        let live = stamp(rig.scope)
        let other = rig.otherScope
        // The first scope read still says the old account; the account changes right after it and before the command is performed.
        rig.surface.afterScopeRead = { rig.surface.scope = other }
        let before = page.bodies.count
        guard case .failure(let refusal) = await bridge.handle(.next, stamp: live) else { Issue.record("the switch must stop the command"); return }
        #expect(refusal == .otherAccount && rig.surface.scopeReads >= 2, "the scope was read again right before the command (\(rig.surface.scopeReads) reads)")
        try await Task.sleep(for: .milliseconds(40))
        #expect(page.bodies.count == before)
    }
    @Test func theAppsOwnRulesStillApplyToACurrentStampSoAnAdvertisementCannotBeSkipped() async throws {
        let (rig, page, bridge) = try await rig()
        page.send(lifecycleState(position: 2, duration: 15, video: lifecycleAdVideo, ad: true))
        let before = page.bodies.count
        guard case .failure(let refusal) = await bridge.handle(.next, stamp: stamp(rig.scope)) else { Issue.record("an ad cannot be skipped from a widget either"); return }
        guard case .refused(let reason) = refusal else { Issue.record("the app's own reason, got \(refusal)"); return }
        #expect(reason == IntentRefusal.advertisement.message)
        #expect(page.bodies.count == before)
    }
    @Test func theBridgeInstallsOneHandlerOnTheReceiverAndRemovesIt() async throws {
        let (rig, _, bridge) = try await rig()
        let receiver = WidgetCommandReceiver()
        bridge.install(on: receiver)
        #expect(receiver.isInstalled)
        let done = try await receiver.receive(.playPause, stamp: stamp(rig.scope))
        #expect(!done.isEmpty)
        await #expect(throws: WidgetCommandRefusal.otherAccount) { _ = try await receiver.receive(.playPause, stamp: stamp(rig.otherScope)) }
        bridge.uninstall(from: receiver)
        #expect(!receiver.isInstalled)
    }
}
