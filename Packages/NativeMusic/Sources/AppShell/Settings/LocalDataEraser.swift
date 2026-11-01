import AccountSession
import Domain
import Features
import Foundation

/// W27 (SEC08, T27.3). The local privacy reset, an account's cache clearing, a category's Restore Defaults and removing an account from this Mac.
///
/// What these do NOT do: nothing here can make a request. The eraser holds no network type, no session and no transport; the account lifecycle it calls deletes its OWN
/// credentials, keys, snapshots, indexes and queued writes locally, and "Full removal never invokes a remote deletion" (Docs/Accounts.md). A queued write that was never
/// sent is deleted unsent. The Google account, the YouTube Music library, every playlist and every remote setting are untouched.
///
/// Every action starts with `DestructiveActionGuard.verify(roots, touches:)`: the roots the session declared AND what the destructive objects actually hold (read from
/// the live objects by `targets.touches`). Below that, every raw delete is behind a guarded wrapper that refuses a real store at the call.
@MainActor final class LocalDataEraser {
    /// What the eraser acts on. Closures, so a test hands in recording stand-ins and the composition hands in the live objects bound to the SAME injected roots.
    struct Targets {
        var identities: @MainActor () async -> [AccountContext]
        /// The lifecycle's full local removal for one account: keychain items and keys, database partition (outbox, snapshots, index), private files, downloads, artwork,
        /// history, and the account's own settings (a lifecycle participant).
        var removeAccount: @MainActor (AccountContext) async throws -> Void
        /// Cached artwork of ONE account. Nothing the person made.
        var clearAccountCaches: @MainActor (AccountContext) async throws -> Void
        var clearAllCaches: @MainActor () async throws -> Void
        var clearSpotlight: @MainActor () async throws -> Void
        var clearWidgetSnapshot: @MainActor () async throws -> Void
        /// The owned-audio store (its files and Keychain items), which lives beside, not inside, the application directory.
        var eraseOwnedAudio: @MainActor () async throws -> Void
        /// Resets every setting and empties the preferences root.
        var resetPreferences: @MainActor () async throws -> Void
        /// Files the app wrote beside the account data that belong to no account (the profiler's file, the run marker), relative to the application directory.
        var diagnosticsFiles: [String]
        var clearDiagnosticsLog: @MainActor () -> Void
        var turnOffLoginItem: @MainActor () async -> Void
        /// What these targets actually hold, read from the live objects.
        var touches: @MainActor () -> LocalDataTouches
    }
    struct StepResult: Equatable { let name: String; let failure: String? }
    struct Report: Equatable {
        var steps: [StepResult] = []
        var refusal: String?
        var succeeded: Bool { refusal == nil && steps.allSatisfy { $0.failure == nil } }
        var failedSteps: [String] { steps.filter { $0.failure != nil }.map(\.name) }
    }

    let roots: LocalDataRoots
    let fileSystem: any ErasureFileSystem
    let targets: Targets
    init(roots: LocalDataRoots, fileSystem: any ErasureFileSystem, targets: Targets) {
        self.roots = roots; self.fileSystem = fileSystem; self.targets = targets
    }

    static func describe(_ error: any Error) -> String {
        switch error as? DestructiveActionRefusal {
        case .realRoot(let what): return "refused: \(what) is a real store"
        case .outsideInjectedRoot: return "refused: outside the injected root"
        case .notConfirmed: return "refused: not confirmed"
        case .touchesUndeclared(let what): return "refused: \(what) is not the one declared"
        case nil:
            if error is GuardRefusal { return "refused: a guarded wrapper refused a real store" }
            return "failed"
        }
    }
    private func refuse(_ error: any Error) -> String { Self.describe(error) }

    /// The guard on the declared roots AND what the targets hold. Throws the refusal.
    @discardableResult
    func verify(confirmation: PersonConfirmation?) throws -> VerifiedRoots { try DestructiveActionGuard.verify(roots, touches: targets.touches(), confirmation: confirmation) }

    /// The local privacy reset. Removes every account from this Mac, clears the caches and the Spotlight and widget copies, the owned-audio store, restores every
    /// preference and removes the diagnostics files. Every step runs even when an earlier one failed (an interrupted reset can be run again); the report names each.
    func eraseEverything(confirmation: PersonConfirmation?) async -> Report {
        var report = Report()
        let verified: VerifiedRoots
        do { verified = try verify(confirmation: confirmation) } catch { report.refusal = refuse(error); return report }
        func step(_ name: String, _ work: @MainActor () async throws -> Void) async {
            do { try await work(); report.steps.append(StepResult(name: name, failure: nil)) }
            catch { report.steps.append(StepResult(name: name, failure: refuse(error))) }
        }
        for account in await targets.identities() { await step("account") { try await self.targets.removeAccount(account) } }
        await step("caches") { try await self.targets.clearAllCaches() }
        await step("ownedAudio") { try await self.targets.eraseOwnedAudio() }
        await step("spotlight") { try await self.targets.clearSpotlight() }
        await step("widget") { try await self.targets.clearWidgetSnapshot() }
        await step("diagnostics") {
            self.targets.clearDiagnosticsLog()
            for name in self.targets.diagnosticsFiles { try self.fileSystem.remove(verified.roots.applicationDirectory.appendingPathComponent(name)) }
        }
        await step("loginItem") { await self.targets.turnOffLoginItem() }
        await step("preferences") { try await self.targets.resetPreferences() }
        return report
    }

    /// Account-local cache clearing: one account's cached artwork. Its downloads, playlists, queue, history and queued writes stay.
    func clearCaches(of account: AccountContext, confirmation: PersonConfirmation?) async -> Report {
        var report = Report()
        do { try verify(confirmation: confirmation) } catch { report.refusal = refuse(error); return report }
        do { try await targets.clearAccountCaches(account); report.steps.append(StepResult(name: "caches", failure: nil)) }
        catch { report.steps.append(StepResult(name: "caches", failure: refuse(error))) }
        return report
    }

    /// Removes one account from this Mac (local only). Its account-scope settings go with it (a lifecycle participant).
    func removeAccount(_ account: AccountContext, confirmation: PersonConfirmation?) async -> Report {
        var report = Report()
        do { try verify(confirmation: confirmation) } catch { report.refusal = refuse(error); return report }
        do { try await targets.removeAccount(account); report.steps.append(StepResult(name: "account", failure: nil)) }
        catch { report.steps.append(StepResult(name: "account", failure: refuse(error))) }
        return report
    }
}

/// W27 rework 1 (SEC08): an account's own settings are deleted with it on EVERY removal path (the Settings page, the Accounts sheet, a retry at launch), because the
/// settings store is a lifecycle participant like the database and the files.
actor SettingsAccountParticipant: AccountLifecycleParticipant {
    nonisolated let participantID = "settings-account-scope"
    private let remove: @MainActor @Sendable (UUID) throws -> Void
    init(remove: @escaping @MainActor @Sendable (UUID) throws -> Void) { self.remove = remove }
    func detach(previous: RequestContext, barrier: RequestContext) async throws {}
    func restorePaused(_ identity: LocalIdentity, context: RequestContext) async throws {}
    func removeLocal(_ account: AccountContext, context: RequestContext) async throws {
        let remove = self.remove
        try await MainActor.run { try remove(account.accountID) }
    }
}
