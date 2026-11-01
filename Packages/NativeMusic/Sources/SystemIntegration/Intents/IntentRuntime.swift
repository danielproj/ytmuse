import Foundation
import Synchronization

// W24 (ARCH03, ARCH09). How an intent reaches the running app, and the rule that no test and no intent donates to the system.

/// Who asked. An intent is never a reason to donate (a donation says "the person just did this in the app", and an intent did not happen in the
/// app's UI); only a user action in the app's own window is.
public enum IntentOrigin: Hashable, Sendable { case intent, userInterface }

/// What a donation carries: the command's stable name and the scope. Never a title, a query or an identifier.
public struct IntentDonation: Hashable, Sendable {
    public let command: String
    public let scope: IntentScope
    public init(command: String, scope: IntentScope) { self.command = command; self.scope = scope }
}

/// Where donations go. This node installs none in production: no file in the repository names the system's donation or Shortcuts-refresh calls, and
/// `IntentDonationGuardTests` sweeps every source, test and UI-test file to keep it so. Every test and every isolated launch gets a sink that keeps or
/// drops what it is given.
public protocol IntentDonationSink: Sendable {
    func donate(_ donation: IntentDonation) async
}
/// Drops every donation. The default, so a process that never installs a sink cannot reach the system.
public struct DiscardingDonationSink: IntentDonationSink {
    public init() {}
    public func donate(_ donation: IntentDonation) async {}
}
/// Keeps donations for a test to assert on.
public final class RecordingDonationSink: IntentDonationSink, Sendable {
    private let records = Mutex<[IntentDonation]>([])
    public init() {}
    public var donations: [IntentDonation] { records.withLock { $0 } }
    public func donate(_ donation: IntentDonation) async { records.withLock { $0.append(donation) } }
}

/// The in-process rendezvous between App Intents (static types with no initialiser arguments) and the running app.
///
/// An intent finds its channel here. When the app was started BY the intent (a cold launch) the channel does not exist yet: `channel(timeout:)`
/// waits for the app to install it and finish restoring its account, and gives up with `appNotReady` rather than guessing. A test builds its own
/// hub and runs the intent inside `IntentHub.$current.withValue(_:operation:)`, so no test shares or replaces the app's hub.
@MainActor public final class IntentHub {
    public static let shared = IntentHub()
    @TaskLocal public static var current: IntentHub?
    /// The hub an intent running now uses: the task's own (tests) or the app's.
    public static var active: IntentHub { current ?? shared }

    public private(set) var channel: (any IntentCommandChannel)?
    /// Where donations go; the discarding sink until a normal (non-isolated) launch installs the system's.
    public var donations: any IntentDonationSink = DiscardingDonationSink()
    /// How long an intent waits for a cold-launching app to be ready before it says so. A test sets it short.
    public var startupTimeout: Duration = .seconds(20)
    public init() {}

    /// How a choice among duplicates is put to the person. Nil: the intent uses the SDK's `requestChoice(between:)`; a test installs its own.
    public var chooser: (@MainActor ([String]) async throws -> Int)?

    public func install(_ channel: any IntentCommandChannel) { self.channel = channel }
    public func uninstall() { channel = nil }

    /// The channel once the app is ready, or nil after `timeout`. Never starts playback or opens a window by itself. A cold launch through an
    /// intent installs the channel within the app's own startup; this polls for it (cheaply, on the main actor) rather than racing it.
    public func readyChannel(timeout: Duration? = nil) async -> (any IntentCommandChannel)? {
        let deadline = ContinuousClock.now + (timeout ?? startupTimeout)
        while channel == nil, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let channel else { return nil }
        await channel.awaitReady()
        return channel
    }

    /// Runs one command. A refusal comes back as `IntentRefusal`; success as the sentence to say. An intent never donates (origin `.intent`).
    public func run(_ command: IntentCommand) async -> IntentOutcome {
        guard let channel = await readyChannel() else { return .refused(.appNotReady) }
        let outcome = await channel.perform(command)
        await donate(command, origin: .intent, scope: nil, outcome: outcome)
        return outcome
    }
    /// What every intent calls: the sentence to say, or the refusal thrown (so the system shows the app's own words).
    public func perform(_ command: IntentCommand) async throws -> String {
        switch await run(command) {
        case .done(let text): return text
        case .refused(let refusal): throw refusal
        }
    }
    /// The one donation gate. Only a user action in the app's own UI can donate, and only a successful one; an intent never does.
    @discardableResult public func donate(_ command: IntentCommand, origin: IntentOrigin, scope: IntentScope?, outcome: IntentOutcome) async -> Bool {
        guard origin == .userInterface, outcome.isDone, let scope else { return false }
        await donations.donate(IntentDonation(command: command.name, scope: scope))
        return true
    }
}
