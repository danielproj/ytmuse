import AppKit
import Features
import Foundation
import Observation
import SwiftUI
import Synchronization
import Testing
@testable import AppShell
@testable import SystemIntegration

/// W24 rework 1 (finding 4): a search an App Intent asks for is a request that waits for a window and is reported honestly. These tests drive the REAL
/// consumer (`SearchRequestReceiver`, the modifier `BrowserShell` applies) in a hosted SwiftUI view with a real `SearchModel`, so removing or disabling
/// any step of "type the words and press Return" fails them.
@Suite @MainActor struct SearchRequestInboxTests {
    @Test func aRequestWaitsForAnEligibleWindowAndIsPerformedExactlyOnce() {
        let inbox = SearchRequestInbox()
        let serial = inbox.post("daft punk")
        var performed: [String] = []
        #expect(!inbox.claim(eligible: false) { performed.append($0) } && performed.isEmpty && inbox.pending?.serial == serial, "a window that is not eligible leaves it waiting")
        #expect(inbox.claim(eligible: true) { performed.append($0) })
        #expect(!inbox.claim(eligible: true) { performed.append($0) }, "a second window cannot take it again")
        #expect(performed == ["daft punk"] && inbox.pending == nil && inbox.performedSerial == serial)
    }
    @Test func aNewerRequestReplacesAnUnclaimedOlderOneAndWithdrawingRemovesOnlyItsOwn() {
        let inbox = SearchRequestInbox()
        let first = inbox.post("one"), second = inbox.post("two")
        inbox.withdraw(first)
        #expect(inbox.pending?.text == "two", "withdrawing a request that was already replaced does not touch the newer one")
        inbox.withdraw(second)
        #expect(inbox.pending == nil)
    }
    @Test func theIntentIsToldTheTruthWhetherAWindowTookTheRequestInTime() async {
        let inbox = SearchRequestInbox()
        let late = inbox.post("late")
        #expect(await !inbox.waitUntilPerformed(late, timeout: .milliseconds(60)), "no window: not done")
        inbox.withdraw(late)
        var ran = false
        #expect(!inbox.claim(eligible: true) { _ in ran = true } && !ran, "a withdrawn request is never run by a window that appears afterwards")
        let soon = inbox.post("soon")
        Task { try? await Task.sleep(for: .milliseconds(40)); inbox.claim(eligible: true) { _ in } }
        #expect(await inbox.waitUntilPerformed(soon, timeout: .seconds(30)), "a window that appears after the post still takes it")   // TH2: a failure bound, not a duration: it returns when the claim lands
    }

    @Test func requestShowsAWindowOnceWaitsForItAndWithdrawsWhatNoWindowTook() async {
        let inbox = SearchRequestInbox()
        var shown = 0
        let none = await inbox.request("nobody", show: { shown += 1 }, timeout: .milliseconds(60))
        #expect(!none && shown == 1 && inbox.pending == nil, "no window took it: not done, and withdrawn so a later window does not run it")
        var ran = false
        #expect(!inbox.claim(eligible: true) { _ in ran = true } && !ran)
        var performed: [String] = []
        let taken = await inbox.request("somebody", show: { Task { @MainActor in try? await Task.sleep(for: .milliseconds(30)); inbox.claim(eligible: true) { performed.append($0) } } }, timeout: .seconds(30))
        #expect(taken && performed == ["somebody"] && shown == 1)
    }

    @Test func twoSearchesWithinTheTimeoutOnlyTheNewerIsPerformedAndTheOlderIsToldItWasNot() async {
        let inbox = SearchRequestInbox()
        var performed: [String] = []
        async let first = inbox.request("first words", show: {}, timeout: .seconds(8))
        try? await Task.sleep(for: .milliseconds(60))
        async let second = inbox.request("second words", show: {}, timeout: .seconds(8))
        try? await Task.sleep(for: .milliseconds(60))
        #expect(inbox.claim(eligible: true) { performed.append($0) })
        let (a, b) = await (first, second)
        #expect(performed == ["second words"], "only the newer request's words were searched")
        #expect(!a, "the replaced request reports that it was NOT performed (it does not say \"searching\")")
        #expect(b)
    }
    /// Resumes a continuation once, with the first value offered.
    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock(); private var continuation: CheckedContinuation<T, Never>?; private var done = false
        func install(_ c: CheckedContinuation<T, Never>) { lock.withLock { continuation = c } }
        func finish(_ value: T) { let c: CheckedContinuation<T, Never>? = lock.withLock { if done { return nil }; done = true; return continuation }; c?.resume(returning: value) }
    }
    /// "Told at once", measured: the request's own timeout is an hour, so a reply within `bound` of NOW (the replace or the clear, on the monotonic clock) can only be the
    /// inbox telling it. TH2 rework (critic M2): the bound is a timer that does not depend on the request, so a request that really waits is abandoned (and cancelled) at the
    /// bound and reported as nil in `bound`, instead of holding the test for the hour. (A task group would wait for the request, as `withinDeadline` once did.)
    private func repliesBeforeItsTimeout(_ request: Task<Bool, Never>, within bound: Duration = .seconds(3)) async -> (reply: Bool?, elapsed: Duration) {
        let started = ContinuousClock.now
        let once = Once<Bool?>()
        let reply: Bool? = await withCheckedContinuation { continuation in
            once.install(continuation)
            Task.detached { once.finish(await request.value) }
            Task.detached { try? await Task.sleep(for: bound); request.cancel(); once.finish(nil) }
        }
        return (reply, ContinuousClock.now - started)
    }
    @Test func aReplacedRequestIsToldAtOnceNotAfterItsTimeout() async {
        let inbox = SearchRequestInbox()
        let first = Task { @MainActor in await inbox.request("old", show: {}, timeout: .seconds(3600)) }
        await wait { inbox.pending?.text == "old" }
        _ = inbox.post("new")
        let (reply, elapsed) = await repliesBeforeItsTimeout(first)
        #expect(reply == false, "it did not wait out its timeout for words that will never be searched (nil would mean it did, after \(elapsed))")
        // and a later request being performed never counts for an older serial
        let older = inbox.post("older"), newer = inbox.post("newer")
        inbox.claim(eligible: true) { _ in }
        #expect(await !inbox.waitUntilPerformed(older, timeout: .milliseconds(80)) && inbox.performedSerial == newer)
    }
    @Test func theIntentReportsNothingSearchedWhenItsRequestWasReplaced() async throws {
        let rig = try await IntentRig.make()
        rig.surface.searchPerforms = false
        let outcome = await rig.run(.search("old words"))
        guard case .failed(let why)? = outcome.refusal else { Issue.record("\(outcome)"); return }
        #expect(why.contains("not searched") && why.contains("replaced"), "the sentence names both ways it can fail")
    }

    @Test func clearingWithdrawsThePendingRequestAndTellsAWaitingIntentAtOnce() async {
        let inbox = SearchRequestInbox()
        let waiting = Task { @MainActor in await inbox.request("old account's words", show: {}, timeout: .seconds(3600)) }
        await wait { inbox.pending?.text == "old account's words" }
        inbox.clear()
        let (reply, elapsed) = await repliesBeforeItsTimeout(waiting)
        #expect(reply == false, "told at once, not after its timeout (nil would mean it waited, after \(elapsed))")
        var ran = false
        #expect(!inbox.claim(eligible: true) { _ in ran = true } && !ran, "a window that appears afterwards finds nothing to run")
    }
    @Test func anAccountBarrierClearsTheShellsPendingSearchSoItNeverRunsUnderTheNextAccount() async throws {
        let rig = try await MediaRig.make()
        let shell = ShellCoordinator(playback: rig.model, loginItem: InMemoryLoginItemService(), application: FakeApplication(),
                                     preferences: UserDefaults(suiteName: "local.native-music.test-" + UUID().uuidString)!, installsStatusItem: false)
        let serial = shell.searchInbox.post("words typed under the old account")
        #expect(shell.searchInbox.pending?.serial == serial)
        try await rig.detach()                                  // the account is switched away: the authority's barrier
        await rig.wait { shell.searchInbox.pending == nil }
        #expect(shell.searchInbox.pending == nil, "the barrier withdrew the request")
        var ran = false
        #expect(!shell.searchInbox.claim(eligible: true) { _ in ran = true } && !ran, "a window cannot take it afterwards")
        // A request made after the barrier (for the account that is live now) is untouched.
        let next = shell.searchInbox.post("new account's words")
        #expect(shell.searchInbox.pending?.serial == next)
    }

    // MARK: the real consumer, hosted

    @MainActor @Observable final class WindowState { var visible = false; var frontmost = true }
    private struct Host: View {
        let state: WindowState, inbox: SearchRequestInbox, search: SearchModel, opened: Opened
        var body: some View {
            Color.clear.frame(width: 4, height: 4)
                .modifier(SearchRequestReceiver(inbox: inbox, search: search, visible: state.visible, isFrontmost: { state.frontmost }, open: { opened.count += 1 }))
        }
    }
    @MainActor final class Opened { var count = 0 }
    final class RemoteLog: Sendable {
        private let lines = Mutex<[String]>([])
        func add(_ line: String) { lines.withLock { $0.append(line) } }
        var all: [String] { lines.withLock { $0 } }
    }
    private func makeSearch(_ log: RemoteLog) -> SearchModel {
        SearchModel(sources: [], remote: { query in log.add(query); throw URLError(.notConnectedToInternet) },
                    debounce: .seconds(3600), playback: { .available })
    }
    private func host(_ view: some View) -> NSWindow {
        let window = lifecycleWindow()
        window.contentView = NSHostingView(rootView: view)
        return window
    }
    /// A condition wait. The deadline only turns a condition that never comes into a failing expectation; it is not a duration the product is held to.
    private func wait(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func aVisibleFrontmostWindowOpensSearchTypesTheWordsAndPressesReturn() async {
        let inbox = SearchRequestInbox(), state = WindowState(), opened = Opened(), log = RemoteLog()
        state.visible = true
        let search = makeSearch(log)
        let window = host(Host(state: state, inbox: inbox, search: search, opened: opened))
        defer { window.close() }
        let serial = inbox.post("radiohead")
        await wait { inbox.performedSerial == serial }
        #expect(inbox.performedSerial == serial && opened.count == 1, "the Search destination was opened")
        #expect(search.query == "radiohead", "the words were typed")
        await wait { log.all == ["radiohead"] }
        #expect(log.all == ["radiohead"], "Return was pressed: the immediate remote search ran (the 1-hour debounce could not have)")
    }
    @Test func aWindowThatIsNotVisibleYetTakesTheRequestWhenItBecomesVisibleAndNotBefore() async {
        let inbox = SearchRequestInbox(), state = WindowState(), opened = Opened(), log = RemoteLog()
        let search = makeSearch(log)
        let window = host(Host(state: state, inbox: inbox, search: search, opened: opened))
        defer { window.close() }
        let serial = inbox.post("later")
        try? await Task.sleep(for: .milliseconds(120))
        #expect(inbox.pending?.serial == serial && search.query.isEmpty && opened.count == 0, "not visible: the request is not consumed, so it cannot be lost")
        state.visible = true
        await wait { inbox.performedSerial == serial }
        #expect(inbox.performedSerial == serial && search.query == "later" && opened.count == 1)
    }
    @Test func aRequestPostedBeforeTheWindowExistsIsTakenWhenTheWindowAppears() async {
        let inbox = SearchRequestInbox(), state = WindowState(), opened = Opened(), log = RemoteLog()
        state.visible = true
        let search = makeSearch(log)
        let serial = inbox.post("cold start")
        let window = host(Host(state: state, inbox: inbox, search: search, opened: opened))
        defer { window.close() }
        await wait { inbox.performedSerial == serial }
        #expect(inbox.performedSerial == serial && search.query == "cold start" && opened.count == 1)
    }
    @Test func aWindowThatIsNotFrontmostLeavesItAndOnlyOneOfTwoWindowsRunsIt() async {
        let inbox = SearchRequestInbox(), opened = Opened(), log = RemoteLog()
        let backState = WindowState(), frontState = WindowState()
        backState.visible = true; backState.frontmost = false; frontState.visible = true
        let backSearch = makeSearch(log), frontSearch = makeSearch(log)
        let back = host(Host(state: backState, inbox: inbox, search: backSearch, opened: opened)), front = host(Host(state: frontState, inbox: inbox, search: frontSearch, opened: opened))
        defer { back.close(); front.close() }
        let serial = inbox.post("once")
        await wait { inbox.performedSerial == serial && frontSearch.query == "once" && log.all == ["once"] }
        try? await Task.sleep(for: .milliseconds(60))   // an ABSENCE (the back window stays empty) is checked after the positive, never instead of it
        #expect(frontSearch.query == "once" && backSearch.query.isEmpty && opened.count == 1, "the frontmost window ran it, the other did not")
        #expect(log.all == ["once"])
    }
}
