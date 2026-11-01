// Test-only helper (never linked into the app). Runs a real NSApplication with the
// app's PlaybackApplicationDelegate in a fresh process and quits it through
// `requestQuit`, the path the quit Apple Event and the Quit menu use (Q1).
//   QuitProbe complete  — shutdown hops to the main actor and an actor, then finishes
//   QuitProbe hang      — shutdown never finishes (a restore/teardown that never completes)
// The parent test measures how long the quit takes. TH1: the probe measures it itself, from the instant the quit is requested to the
// instant the application is about to terminate (printed as `QUIT-ELAPSED-MS <n>`), because the parent's wall clock also counts the process
// launch (dyld, AppKit start-up), which grows without bound on a loaded machine and has nothing to do with the quit deadline.
import AppKit
import AppShell
import Foundation

actor Busy { func touch() async { try? await Task.sleep(for: .milliseconds(50)) } }
/// Holds the never-resumed continuation so the runtime does not report a leak.
@MainActor final class Stuck { static var held: [CheckedContinuation<Void, Never>] = [] }
@MainActor final class Timing { static var requested: ContinuousClock.Instant? }
let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "complete"
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let delegate = PlaybackApplicationDelegate()
app.delegate = delegate
NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
    MainActor.assumeIsolated {
        if let requested = Timing.requested {
            let parts = (ContinuousClock.now - requested).components
            print("QUIT-ELAPSED-MS \(Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000))")
        }
    }
}
PlaybackApplicationDelegate.shutdownDeadline = .milliseconds(1500)
PlaybackApplicationDelegate.setShutdown {
    if mode == "hang" {
        print("SHUTDOWN-STARTED")
        // Never resumed: models a teardown/restore await that never completes.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in Stuck.held.append(continuation) }
    }
    await Busy().touch()
    await MainActor.run { print("SHUTDOWN-MAIN-ACTOR") }
    print("SHUTDOWN-DONE")
}
// Quit from inside a GCD main-queue block, the worst caller (Q1 sample).
DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
    print("QUIT-REQUESTED")
    Timing.requested = .now
    PlaybackApplicationDelegate.requestQuit()
}
// Hard stop so a hang can never outlive the test.
DispatchQueue.global().asyncAfter(deadline: .now() + 20) { print("FAIL hard timeout"); exit(3) }
app.run()
