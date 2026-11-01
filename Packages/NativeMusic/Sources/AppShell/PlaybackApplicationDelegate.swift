import AppKit
import Foundation
import OSLog
import Synchronization

/// Replies to `applicationShouldTerminate` exactly once, from whichever finishes
/// first: the shutdown work or the deadline. Quit therefore always completes.
final class TerminationReply: Sendable {
    private let fired = Mutex(false)
    private let reply: @Sendable () -> Void
    init(_ reply: @escaping @Sendable () -> Void) { self.reply = reply }
    /// Returns whether this call was the one that replied.
    @discardableResult func fire() -> Bool {
        let first = fired.withLock { done -> Bool in guard !done else { return false }; done = true; return true }
        if first { reply() }
        return first
    }
    var hasFired: Bool { fired.withLock { $0 } }
}

/// The bounded shutdown, separated from AppKit so a never-finishing shutdown can be
/// tested. `schedule` must deliver its callback even while AppKit runs the
/// terminate modal loop; production uses a run-loop block in the common modes.
enum BoundedTermination {
    typealias Scheduler = @Sendable (Duration, @escaping @Sendable () -> Void) -> Void
    /// QL3: a quit that ends because the deadline passed (not because the shutdown finished)
    /// is recorded in the local unified log, so "fast and complete" can be told from "cut
    /// off". Fixed text only: no identity, path, token or secret, and no telemetry (SEC01).
    static let logDeadline: @Sendable () -> Void = {
        Logger(subsystem: "local.native-music.development", category: "quit").notice("Quit replied at the shutdown deadline; shutdown had not finished")
    }
    @MainActor static func begin(shutdown: (@MainActor () async -> Void)?, deadline: Duration,
                                 schedule: Scheduler = runLoopDeadline, reply: TerminationReply,
                                 onDeadline: @escaping @Sendable () -> Void = logDeadline) {
        schedule(deadline) { if reply.fire() { onDeadline() } }
        Task { @MainActor in
            await shutdown?()
            reply.fire()
        }
    }
    /// A background timer that hands the reply to the main run loop in the common
    /// modes (which include the modal-panel mode `terminate:` runs). It does not use
    /// the GCD main queue, so it fires even if a main-queue job never returns.
    static let runLoopDeadline: Scheduler = { deadline, fire in
        let parts = deadline.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
            let main = CFRunLoopGetMain()
            CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) { fire() }
            CFRunLoopWakeUp(main)
        }
    }
}

/// Explicit quit runs the checkpoint/transport stop before termination, bounded
/// by `shutdownDeadline`; an asynchronous willTerminate observer could not
/// guarantee either operation finishes before process exit.
@MainActor public final class PlaybackApplicationDelegate: NSObject, NSApplicationDelegate {
    static var shutdown: (@MainActor () async -> Void)?
    /// Dismisses app-owned modal state (the sign-in sheet) before quitting.
    static var beforeQuit: (@MainActor () -> Void)?
    /// Quit always replies within this bound, even if the shutdown never finishes
    /// (for example behind a restore stuck on a Keychain prompt).
    public static var shutdownDeadline: Duration = .seconds(3)
    /// Test seam: installs the shutdown closure (the app composition sets it internally).
    public static func setShutdown(_ work: (@MainActor () async -> Void)?) { shutdown = work }
    private var terminating = false
    /// W21: set by the composition; run once when the application has finished launching (the status item and power observers start here).
    static var didFinishLaunching: (@MainActor () -> Void)?
    /// W21: run when termination begins, before the checkpointed shutdown: the shell's windows and status item go first.
    static var willTerminate: (@MainActor () -> Void)?
    /// W21: reopening (Dock click, `open`, Spotlight) with no visible window asks the shell for one; the shell restores the regular policy first.
    static var reopen: (@MainActor () -> Void)?
    /// A window with an attached sheet makes AppKit refuse the quit Apple Event
    /// (observed live: -128 "User canceled" with the Accounts sheet open). Quit
    /// therefore ends every attached sheet first, then terminates normally so
    /// `applicationShouldTerminate` still runs the shutdown checkpoint.
    public func applicationWillFinishLaunching(_ notification: Notification) {
        LaunchContext.establishFromCurrentEvent()
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleQuit(_:reply:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
    }
    public func applicationDidFinishLaunching(_ notification: Notification) {
        // How this process was started: a login launch opens menu-bar only (no window, no audio). The Apple event is only current here.
        LaunchContext.establishFromCurrentEvent()
        Self.didFinishLaunching?()
    }
    /// Closing the last window never quits: the menu bar item and eligible audio stay (WIN02, WIN03).
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag, let reopen = Self.reopen else { return true }
        reopen()
        return false
    }
    /// W25 (MAC05): a Spotlight result for one of the app's entries was opened. Set by the composition; receives the result's identifier.
    static var spotlightResult: (@MainActor (String) -> Void)?
    public func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == SpotlightActivation.activityType, let handler = Self.spotlightResult,
              let identifier = userActivity.userInfo?[SpotlightActivation.identifierKey] as? String else { return false }
        handler(identifier)
        return true
    }
    @objc private func handleQuit(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) { Self.requestQuit() }
    /// QL1: one attached sheet that refuses to end must not spin the main thread, because
    /// the deadline is delivered through that same run loop and could then never fire.
    static let sheetClosingLimit = 8
    @discardableResult static func endAttachedSheets(of host: some SheetHosting, limit: Int = sheetClosingLimit) -> Int {
        var ended = 0
        while ended < limit, let sheet = host.attachedSheet { host.endSheet(sheet); ended += 1 }
        return ended
    }
    public static func requestQuit() {
        beforeQuit?()
        for window in NSApplication.shared.windows { endAttachedSheets(of: window) }
        // Q1 root cause: this used to be `DispatchQueue.main.async { terminate }`.
        // `terminate:` with `.terminateLater` spins a nested run loop until the reply,
        // and GCD never drains the serial main queue re-entrantly while one of its
        // blocks is running, so every MainActor job (the shutdown Task itself) was
        // stuck behind the block that was waiting for it: quit never finished. A
        // run-loop perform runs outside any GCD block (and still on a later turn, so
        // SwiftUI finishes dismissing sheets first).
        RunLoop.main.perform(inModes: [.default, .modalPanel]) {
            MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
        }
    }
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Self.willTerminate?()
        let reply = TerminationReply {
            // Always on the main thread: the Task is MainActor and the deadline is a
            // main run-loop block.
            MainActor.assumeIsolated { NSApplication.shared.reply(toApplicationShouldTerminate: true) }
        }
        BoundedTermination.begin(shutdown: Self.shutdown, deadline: Self.shutdownDeadline, reply: reply)
        return .terminateLater
    }
}

/// What the quit path needs of a window; `NSWindow` conforms, and a test double can refuse to end.
@MainActor protocol SheetHosting {
    var attachedSheet: NSWindow? { get }
    func endSheet(_ sheet: NSWindow)
}
extension NSWindow: SheetHosting {}
