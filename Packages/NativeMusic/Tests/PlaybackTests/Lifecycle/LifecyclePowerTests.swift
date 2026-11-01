import AppKit
import Foundation
import Testing
@testable import Playback
@testable import AppShell
import OutputRoutes

/// A recording stand-in for the playback owner.
@MainActor final class RecordingTransport: PowerTransporting {
    var wasPlaying = true
    var personChanged = false, timerExpired = false, ownerChanged = false
    private(set) var holds = 0, finishes: [Bool] = [], silences = 0
    func holdForSleep() async -> Bool { holds += 1; return wasPlaying }
    func holdFacts() async -> (personChanged: Bool, timerExpired: Bool, ownerChanged: Bool) { (personChanged, timerExpired, ownerChanged) }
    func finishWake(resume: Bool) async -> Bool { finishes.append(resume); return resume }
    func silenceAfterWake() async { silences += 1 }
}
let headphones = RouteIdentity(uid: "SYNTH-BT-HEADPHONES", transport: 0x626C7565)
let speakers = RouteIdentity(uid: "SYNTH-BUILT-IN-SPEAKERS", transport: 0x626C746E)
struct FixedRoute: RouteConfirming {
    let result: Bool
    func identity() -> RouteIdentity? { headphones }
    func wait(for recorded: RouteIdentity?, within timeout: Duration) async -> RouteOutcome { result ? .same : .absent }
}
/// The default output as a test scripts it: what it is at the sleep, and what it is when the wake looks (compared exactly as the system's is).
@MainActor final class ScriptedRoute: RouteConfirming {
    nonisolated(unsafe) var current: RouteIdentity?
    nonisolated(unsafe) private(set) var waits = 0
    init(_ current: RouteIdentity?) { self.current = current }
    nonisolated func identity() -> RouteIdentity? { current }
    nonisolated func wait(for recorded: RouteIdentity?, within timeout: Duration) async -> RouteOutcome {
        waits += 1
        guard let recorded else { return .absent }
        guard let now = current else { return .absent }
        return now == recorded ? .same : .changed
    }
}
@MainActor final class CountingRoute: RouteConfirming {
    nonisolated(unsafe) private(set) var asked = 0
    nonisolated func identity() -> RouteIdentity? { headphones }
    nonisolated func wait(for recorded: RouteIdentity?, within timeout: Duration) async -> RouteOutcome { asked += 1; return .same }
}

/// T21.4 / WIN07 / WIN08 / PLAY17: lock and display sleep keep audio; system sleep holds it; a wake resumes only a still-wanted session.
@Suite @MainActor struct LifecyclePowerTests {
    private func coordinator(_ transport: RecordingTransport, route: any RouteConfirming = FixedRoute(result: true), preference: Bool = true,
                             display: ShellDisplayState = ShellDisplayState()) -> PowerLifecycleCoordinator {
        PowerLifecycleCoordinator(transport: transport, route: route, display: display, resumePreference: { preference }, sleep: { _ in })
    }
    @Test func theDecisionIsExhaustiveAndResumesOnlyWhenEveryConditionHolds() {
        var resumes = 0
        for bits in 0..<64 {
            let facts = WakeFacts(held: bits & 1 != 0, preference: bits & 2 != 0, routeConfirmed: bits & 4 != 0, personChangedPlayback: bits & 8 != 0,
                                  timerExpired: bits & 16 != 0, ownerChanged: bits & 32 != 0)
            let expected = facts.held && facts.preference && facts.routeConfirmed && !facts.personChangedPlayback && !facts.timerExpired && !facts.ownerChanged
            #expect((SleepWakePolicy.decide(facts) == .resume) == expected, "\(facts)")
            if SleepWakePolicy.decide(facts) == .resume { resumes += 1 }
        }
        #expect(resumes == 1, "exactly one combination of the 64 resumes")
    }
    @Test func eachReasonToStayPausedIsNamed() {
        let good = WakeFacts(held: true, preference: true, routeConfirmed: true, personChangedPlayback: false, timerExpired: false, ownerChanged: false)
        var f = good; f.held = false; #expect(SleepWakePolicy.decide(f) == .stayPaused(.nothingWasPlaying))
        f = good; f.personChangedPlayback = true; #expect(SleepWakePolicy.decide(f) == .stayPaused(.personChangedPlayback))
        f = good; f.timerExpired = true; #expect(SleepWakePolicy.decide(f) == .stayPaused(.timerExpired))
        f = good; f.ownerChanged = true; #expect(SleepWakePolicy.decide(f) == .stayPaused(.ownerChanged))
        f = good; f.preference = false; #expect(SleepWakePolicy.decide(f) == .stayPaused(.preferenceOff))
        f = good; f.routeConfirmed = false; #expect(SleepWakePolicy.decide(f) == .stayPaused(.routeNotConfirmed))
        f = good; f.routeConfirmed = false; f.routeChanged = true; #expect(SleepWakePolicy.decide(f) == .stayPaused(.routeChanged), "another output is playing now: not this one")
        #expect(SleepWakePolicy.decide(good) == .resume)
    }
    @Test func lockAndDisplaySleepNeverTouchTheTransportAndOnlyStopDecorativeWork() async {
        let transport = RecordingTransport(), display = ShellDisplayState()
        let power = coordinator(transport, display: display)
        for event in [PowerEvent.screenLocked, .displaySlept] { await power.handle(event); #expect(!display.active, "\(event): nothing visible is drawn") }
        await power.handle(.screenUnlocked); #expect(!display.active, "the display is still asleep")
        await power.handle(.displayWoke); #expect(display.active)
        #expect(transport.holds == 0 && transport.finishes.isEmpty && transport.silences == 0, "audio continues through a lock and display sleep: the transport was never touched")
        #expect(power.holds == 0 && power.lastDecision == nil)
    }
    @Test func aWakeResumesWhatWasPlayingOnceTheRouteIsConfirmed() async {
        let transport = RecordingTransport(), display = ShellDisplayState()
        let power = coordinator(transport, display: display)
        await power.handle(.systemWillSleep)
        #expect(transport.holds == 1 && power.holds == 1 && !display.active)
        await power.handle(.systemDidWake)
        #expect(transport.finishes == [true] && power.lastDecision == .resume && display.active)
        #expect(transport.silences == 0, "a resumed session is not silenced")
    }
    @Test func aWakeStaysPausedForEveryReasonAndThePageIsKeptQuiet() async {
        let cases: [(String, (RecordingTransport) -> Void, Bool, Bool, WakeStay)] = [
            ("person", { $0.personChanged = true }, true, true, .personChangedPlayback),
            ("timer", { $0.timerExpired = true }, true, true, .timerExpired),
            ("account", { $0.ownerChanged = true }, true, true, .ownerChanged),
            ("preference", { _ in }, false, true, .preferenceOff),
            ("route", { _ in }, true, false, .routeNotConfirmed),
            ("not playing", { $0.wasPlaying = false }, true, true, .nothingWasPlaying),
        ]
        for (name, configure, preference, route, stay) in cases {
            let transport = RecordingTransport(); configure(transport)
            let power = coordinator(transport, route: FixedRoute(result: route), preference: preference)
            await power.handle(.systemWillSleep); await power.handle(.systemDidWake)
            #expect(transport.finishes == [false] && power.lastDecision == .stayPaused(stay), "\(name)")
            #expect(transport.silences >= 1, "\(name): after a wake that does not resume, nothing may be audible that no person asked for")
        }
    }
    @Test func aPageThatStartsItselfAfterAWakeIsSilencedAgainShortlyAfter() async {
        let transport = RecordingTransport(); transport.personChanged = true
        let power = coordinator(transport)
        await power.handle(.systemWillSleep); await power.handle(.systemDidWake)
        for _ in 0..<50 where transport.silences < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(transport.silences == 2, "an immediate check and the later one")
    }
    @Test func theRouteIsOnlyAwaitedWhenNothingElseAlreadyDecidedAgainstResuming() async {
        let counted = CountingRoute(), transport = RecordingTransport(); transport.personChanged = true
        let power = coordinator(transport, route: counted)
        await power.handle(.systemWillSleep); await power.handle(.systemDidWake)
        #expect(counted.asked == 0)
        let fine = RecordingTransport()
        let again = coordinator(fine, route: counted)
        await again.handle(.systemWillSleep); await again.handle(.systemDidWake)
        #expect(counted.asked == 1 && fine.finishes == [true])
    }
    // F1 / WIN08 / addendum 6: a wake resumes only on the route that was playing.
    @Test func aWakeResumesWhenTheSameRouteReturns() async {
        let transport = RecordingTransport(), route = ScriptedRoute(headphones)
        let power = coordinator(transport, route: route)
        await power.handle(.systemWillSleep)
        route.current = nil                       // the headphones went to sleep with the Mac
        route.current = headphones                // ... and are the default output again at the wake
        await power.handle(.systemDidWake)
        #expect(power.lastDecision == .resume && transport.finishes == [true] && route.waits == 1)
    }
    @Test func aWakeNeverResumesOnTheSpeakersWhenTheHeadphonesLeftDuringSleep() async {
        let transport = RecordingTransport(), route = ScriptedRoute(headphones)
        let power = coordinator(transport, route: route)
        await power.handle(.systemWillSleep)
        route.current = speakers                  // the headphones are gone; the built-in speakers are alive and the default
        await power.handle(.systemDidWake)
        #expect(power.lastDecision == .stayPaused(.routeChanged), "\(String(describing: power.lastDecision))")
        #expect(transport.finishes == [false] && transport.silences >= 1, "nothing was played, and the page is kept quiet")
    }
    @Test func aWakeStaysPausedWhenTheRouteNeverReturnsOrWasNeverKnown() async {
        let transport = RecordingTransport(), route = ScriptedRoute(headphones)
        let power = coordinator(transport, route: route)
        await power.handle(.systemWillSleep)
        route.current = nil
        await power.handle(.systemDidWake)
        #expect(power.lastDecision == .stayPaused(.routeNotConfirmed) && transport.finishes == [false])
        let unknown = RecordingTransport(), blind = ScriptedRoute(nil)     // the output could not be read at the sleep: nothing to compare with
        let second = coordinator(unknown, route: blind)
        await second.handle(.systemWillSleep); blind.current = speakers
        await second.handle(.systemDidWake)
        #expect(second.lastDecision == .stayPaused(.routeNotConfirmed) && unknown.finishes == [false], "no recorded route, no resume")
    }
    @Test func theSystemRouteComparesTheRecordedIdentityExactly() async {
        let route = SystemOutputRoute()
        #expect(await route.wait(for: nil, within: .milliseconds(1)) == .absent)
        let other = RouteIdentity(uid: "SYNTH-NOT-A-DEVICE", transport: 0)
        let outcome = await route.wait(for: other, within: .milliseconds(1))
        #expect(outcome == .changed || outcome == .absent, "a device that is not the default is never 'same'")
        if let current = route.identity() { #expect(await route.wait(for: current, within: .milliseconds(1)) == .same) }
    }
    /// R1: AirPods that reconnect a moment after the wake still get the resume; a device that never comes back does not.
    @Test func theRealRouteKeepsPollingWhileADifferentOutputIsTheDefaultAndResumesWhenTheRecordedOneReturns() async {
        final class Script: @unchecked Sendable { var reads: [RouteIdentity?]; var polls = 0; init(_ reads: [RouteIdentity?]) { self.reads = reads }
            func next() -> RouteIdentity? { polls += 1; return reads.isEmpty ? nil : (reads.count > 1 ? reads.removeFirst() : reads[0]) } }
        let reconnecting = Script([speakers, speakers, headphones])
        let route = SystemOutputRoute(read: { reconnecting.next() }, pause: { _ in }, interval: .milliseconds(1))
        #expect(await route.wait(for: headphones, within: .seconds(5)) == .same && reconnecting.polls == 3, "speakers for two polls, then the recorded device: resumed")
        let never = Script([speakers])
        let stuck = SystemOutputRoute(read: { never.next() }, pause: { _ in try? await Task.sleep(for: .milliseconds(2)) }, interval: .milliseconds(1))
        #expect(await stuck.wait(for: headphones, within: .milliseconds(30)) == .changed && never.polls > 2, "it kept looking until the timeout, then said changed")
        let gone = SystemOutputRoute(read: { nil }, pause: { _ in try? await Task.sleep(for: .milliseconds(2)) }, interval: .milliseconds(1))
        #expect(await gone.wait(for: headphones, within: .milliseconds(20)) == .absent)
    }
    @Test func aWakeWithNoSleepBeforeItHasNothingToResume() async {
        let transport = RecordingTransport()
        let power = coordinator(transport)
        await power.handle(.systemDidWake)
        #expect(transport.finishes == [false] && power.lastDecision == .stayPaused(.nothingWasPlaying))
    }
    @Test func eachSleepCycleIsIndependent() async {
        let transport = RecordingTransport()
        let power = coordinator(transport)
        await power.handle(.systemWillSleep); await power.handle(.systemDidWake)
        transport.wasPlaying = false
        await power.handle(.systemWillSleep); await power.handle(.systemDidWake)
        #expect(transport.finishes == [true, false] && transport.holds == 2)
    }
    @Test func theObserverListensToExactlyTheSixSystemNotificationsAndNothingElse() async throws {
        let workspace = NotificationCenter(), distributed = NotificationCenter()
        var seen: [PowerEvent] = []
        let observer = SystemPowerObserver(workspace: workspace, distributed: distributed) { seen.append($0) }
        #expect(observer.observedCount == 6)
        distributed.post(name: SystemPowerObserver.lockedName, object: nil); distributed.post(name: SystemPowerObserver.unlockedName, object: nil)
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil); workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil); workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        workspace.post(name: NSWorkspace.willPowerOffNotification, object: nil)
        for _ in 0..<50 where seen.count < 6 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(seen == [.screenLocked, .screenUnlocked, .displaySlept, .displayWoke, .systemWillSleep, .systemDidWake])
        observer.stop()
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(seen.count == 6, "stopped")
    }
    @Test func theLockNotificationNamesAreTheSystemsOwn() {
        #expect(SystemPowerObserver.lockedName.rawValue == "com.apple.screenIsLocked" && SystemPowerObserver.unlockedName.rawValue == "com.apple.screenIsUnlocked")
    }
    @Test func displayStateRepostsOnlyWhenWhatIsVisibleChanges() {
        let display = ShellDisplayState()
        var posts = 0
        let token = NotificationCenter.default.addObserver(forName: ShellDisplayState.didChange, object: display, queue: nil) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        display.apply(.screenLocked); display.apply(.displaySlept); display.apply(.screenUnlocked); display.apply(.displayWoke)
        #expect(posts == 2, "inactive once (lock), active once (display woke): the intermediate steps changed nothing visible")
        display.apply(.systemWillSleep); display.apply(.systemDidWake)
        #expect(posts == 4 && display.active)
    }
    /// WIN07/WIN08: nothing in the package prevents sleep. The only activity is the hidden player's, and it allows idle system sleep (C1).
    @Test func noSourceTakesAPowerAssertionOrPreventsSleep() async throws {
        let (uses, activities, allowed) = await LifecycleSources.offMain { () -> ([String], [String], Bool) in
            let forbidden = ["IOPMAssertion", "kIOPMAssertion", "PreventUserIdleSystemSleep", "PreventSystemSleep", "idleSystemSleepDisabled", "suddenTerminationDisabled", "caffeinate"]
            var uses: [String] = [], activities: [String] = [], allowed = true
            for file in LifecycleSources.swiftFiles(under: LifecycleSources.packageRoot.appendingPathComponent("Sources")) {
                for (line, code) in LifecycleSources.code(file) {
                    for word in forbidden where code.contains(word) { uses.append("\(file.lastPathComponent):\(line) \(word)") }
                    if code.contains("beginActivity") { activities.append("\(file.lastPathComponent):\(line)"); if !code.contains(".userInitiatedAllowingIdleSystemSleep") { allowed = false } }
                }
            }
            return (uses, activities, allowed)
        }
        #expect(uses.isEmpty, "\(uses)")
        #expect(allowed, "the one activity allows idle system sleep")
        #expect(activities.count == 1, "the one App Nap activity is the hidden player's: \(activities)")
    }
}
