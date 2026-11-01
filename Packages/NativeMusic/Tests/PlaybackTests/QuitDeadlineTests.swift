import AppKit
import Foundation
import Synchronization
import Testing
@testable import AppShell

/// Q1: quit replies exactly once, from the shutdown or the deadline, whichever is first.
@MainActor final class StuckShutdown { var held: [CheckedContinuation<Void, Never>] = [] }
private let testScheduler: BoundedTermination.Scheduler = { deadline, fire in
    Task.detached { try? await Task.sleep(for: deadline); fire() }
}

@Suite @MainActor struct QuitDeadlineTests {
    @Test func aShutdownThatNeverCompletesStillRepliesAtTheDeadline() async throws {
        // TH1: the instant of the reply is taken where the reply FIRES (on the deadline timer, off the main actor). It used to be taken where this
        // test noticed it, which on a busy main actor in a whole-package run was late by however long other tests held the actor.
        let state = Mutex((replies: 0, firedAt: ContinuousClock.Instant?.none)), stuck = StuckShutdown()
        let reply = TerminationReply { state.withLock { $0.replies += 1; $0.firedAt = .now } }
        let start = ContinuousClock.now
        BoundedTermination.begin(shutdown: {
            // A restore/teardown await that never finishes.
            await withCheckedContinuation { stuck.held.append($0) }
        }, deadline: .milliseconds(150), schedule: testScheduler, reply: reply)
        while !reply.hasFired, ContinuousClock.now - start < .seconds(30) { try await Task.sleep(for: .milliseconds(10)) }
        let (replies, firedAt) = state.withLock { ($0.replies, $0.firedAt) }
        #expect(reply.hasFired && replies == 1)
        let at = try #require(firedAt, "the reply never fired")
        #expect(at - start < .seconds(1), "replied at the deadline, not never")
        for continuation in stuck.held { continuation.resume() }
    }
    @Test func aPromptShutdownRepliesOnceAndTheLaterDeadlineDoesNothing() async throws {
        let replies = Mutex(0)
        let reply = TerminationReply { replies.withLock { $0 += 1 } }
        BoundedTermination.begin(shutdown: { await Task.yield() }, deadline: .milliseconds(100), schedule: testScheduler, reply: reply)
        while !reply.hasFired { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(replies.withLock { $0 } == 1, "exactly one reply to applicationShouldTerminate")
    }
    @Test func theQuitPathDoesNotTerminateFromAGCDMainQueueBlock() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/AppShell/PlaybackApplicationDelegate.swift").standardizedFileURL, encoding: .utf8)
        #expect(!source.contains("DispatchQueue.main.async { NSApplication.shared.terminate"), "Q1 root cause must not return")
        #expect(source.contains("RunLoop.main.perform"))
    }
}

// MARK: C1 — QL1 (bounded sheet closing) and QL3 (a deadline-driven quit is logged)

/// A window whose attached sheet never goes away, however often it is asked to end.
@MainActor private final class StubbornHost: SheetHosting {
    var attachedSheet: NSWindow? { ended < 100_000 ? sheet : nil }   // the cap on the double itself, so a regression fails instead of hanging
    let sheet = NSWindow()
    var ended = 0
    func endSheet(_ sheet: NSWindow) { ended += 1 }
}
/// A window with `count` nested sheets that each end when asked.
@MainActor private final class CooperativeHost: SheetHosting {
    private var sheets: [NSWindow]
    var ended = 0
    init(count: Int) { sheets = (0..<count).map { _ in NSWindow() } }
    var attachedSheet: NSWindow? { sheets.last }
    func endSheet(_ sheet: NSWindow) { ended += 1; sheets.removeAll { $0 === sheet } }
}

@Suite @MainActor struct QuitSheetAndDeadlineLogTests {
    @Test func aSheetThatRefusesToEndIsAskedAtMostEightTimes() {
        let host = StubbornHost()
        let ended = PlaybackApplicationDelegate.endAttachedSheets(of: host)
        #expect(ended == PlaybackApplicationDelegate.sheetClosingLimit && host.ended == 8, "QL1: bounded, not a spin on the main thread (\(host.ended) calls)")
    }
    @Test func cooperativeSheetsAreAllEndedWithinTheCap() {
        let host = CooperativeHost(count: 3)
        #expect(PlaybackApplicationDelegate.endAttachedSheets(of: host) == 3 && host.ended == 3 && host.attachedSheet == nil)
        let none = CooperativeHost(count: 0)
        #expect(PlaybackApplicationDelegate.endAttachedSheets(of: none) == 0)
    }
    @Test func aQuitThatEndsAtTheDeadlineIsLoggedOnceAndAPromptOneIsNot() async throws {
        let deadlineLogs = Mutex(0), stuck = StuckShutdown()
        let reply = TerminationReply {}
        BoundedTermination.begin(shutdown: { await withCheckedContinuation { stuck.held.append($0) } }, deadline: .milliseconds(60),
                                 schedule: testScheduler, reply: reply, onDeadline: { deadlineLogs.withLock { $0 += 1 } })
        // TH1: `reply.fire()` becomes true BEFORE `onDeadline` runs, on the timer's thread. Waiting for the reply and then a fixed 50 ms let a loaded
        // machine read the log count in between. Wait for the log line itself (bounded), then a short quiet window for "exactly once".
        let waitStart = ContinuousClock.now
        while deadlineLogs.withLock({ $0 }) == 0, ContinuousClock.now - waitStart < .seconds(30) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(reply.hasFired)
        try await Task.sleep(for: .milliseconds(100))
        #expect(deadlineLogs.withLock { $0 } == 1, "QL3: the cut-off quit leaves exactly one local log line")
        for continuation in stuck.held { continuation.resume() }

        // W21 rework (F6) made this half independent of when the shutdown task starts. TH1 makes it independent of every clock: the deadline timer is
        // HELD by the test's scheduler and delivered by hand only after the shutdown has finished and replied, which is the ordering the
        // test names (a quit that finished in time, then its later deadline). A real 250 ms timer could, on a starved main actor, fire before the
        // shutdown's last line ran and turn a prompt quit into a cut-off one. The product deadline and `BoundedTermination` are untouched.
        let promptLogs = Mutex(0)
        let prompt = TerminationReply {}
        let held = Mutex<(@Sendable () -> Void)?>(nil)
        BoundedTermination.begin(shutdown: { await Task.yield() }, deadline: .milliseconds(250), schedule: { _, fire in held.withLock { $0 = fire } }, reply: prompt,
                                 onDeadline: { promptLogs.withLock { $0 += 1 } })
        let promptStart = ContinuousClock.now
        while !prompt.hasFired, ContinuousClock.now - promptStart < .seconds(30) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(prompt.hasFired, "the prompt shutdown replied")
        let deliver = try #require(held.withLock { $0 }, "the deadline timer was armed")
        deliver()   // the deadline passes AFTER the reply
        #expect(promptLogs.withLock { $0 } == 0, "a quit that finished in time is not reported as cut off")
    }
    @Test func theDeadlineLogLineCarriesNoIdentityOrSecret() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/AppShell/PlaybackApplicationDelegate.swift").standardizedFileURL, encoding: .utf8)
        let line = try #require(source.components(separatedBy: "\n").first { $0.contains(".notice(") })
        #expect(!line.contains("\\("), "fixed text only, no interpolation")
    }
}
