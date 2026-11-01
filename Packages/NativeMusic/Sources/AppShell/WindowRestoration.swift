import Foundation
import SwiftUI
import CryptoKit
import Darwin
import Observation
import Domain
import AccountSession

public struct WindowOwner: Codable, Hashable, Sendable {
    public let accountID: UUID
    public let channel: String
    public let region: String
    public init(_ account: AccountContext) { accountID = account.accountID; channel = account.channelID.rawValue; region = account.region }
    var partition: String { SHA256.hash(data: Data((channel + "|" + region).utf8)).map { String(format: "%02x", $0) }.joined() }
}
public enum WindowRestorationError: Error { case staleOwner, removedAccount, storageUnavailable, invalidRecord }
/// App-owned private state; all serialization/I/O is actor isolated, never scroll-time main-thread I/O.
/// Saves and revocation have no suspension between authorization and atomic file publication.
public actor WindowRestorationStore {
    private let directory: URL
    private let parent: URL
    private let requestedParent: URL
    private var context = RequestContext(account: nil, accountGeneration: 0, requestGeneration: 0)
    private var removed: Set<UUID> = []
    private var prepared = false
    private var disabled = false
    private struct EpochRecord: Codable { let value: UInt64 }
    private var epoch: UInt64 = 0
    public var currentEpoch: UInt64 { epoch }
    public var historyAvailable: Bool { prepared && !disabled && context.account.map { !removed.contains($0.accountID) } != false }
    private var publicationFD: Int32?
    private var pending: [WindowOwner: [UUID: BrowserSession]] = [:]
    public init(directory: URL) {
        requestedParent = directory.deletingLastPathComponent().standardizedFileURL
        parent = requestedParent.resolvingSymlinksInPath().standardizedFileURL
        self.directory = parent.appendingPathComponent(directory.lastPathComponent)
    }
    private func validateParent() throws {
        guard requestedParent.resolvingSymlinksInPath().standardizedFileURL.path == parent.path else { throw WindowRestorationError.storageUnavailable }
        if FileManager.default.fileExists(atPath: requestedParent.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: requestedParent.path)
            // The shared parent need not be owner-only; private history itself still must be.
            // Initial links/untrusted ownership fail only history, before any child is touched.
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid() else { throw WindowRestorationError.storageUnavailable }
        }
    }
    private static func storageFailure(_ error: Error) -> Bool {
        if let error = error as? WindowRestorationError { return error == .storageUnavailable || error == .invalidRecord }
        if error is DecodingError { return true }
        let domain = (error as NSError).domain
        return domain == NSCocoaErrorDomain || domain == NSPOSIXErrorDomain
    }
    private func requireHistory() throws { guard !disabled else { throw WindowRestorationError.storageUnavailable } }
    private func prepare() throws {
        try validateParent()
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: directory.path)
        if !prepared && !exists {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let attributes = try fm.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else { throw WindowRestorationError.storageUnavailable }
        if fm.fileExists(atPath: directory.appendingPathComponent("reset-in-progress.plist").path) { throw WindowRestorationError.storageUnavailable }
        let revocations = directory.appendingPathComponent("removed-accounts.plist")
        if fm.fileExists(atPath: revocations.path) { removed.formUnion(try PropertyListDecoder().decode(Set<UUID>.self, from: boundedRead(revocations))) }
        let epochFile = directory.appendingPathComponent("history-epoch.plist")
        if fm.fileExists(atPath: epochFile.path) { epoch = max(epoch, try PropertyListDecoder().decode(EpochRecord.self, from: boundedRead(epochFile)).value) }
        prepared = true
    }
    private func boundedRead(_ file: URL) throws -> Data {
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) <= 16 * 1024 * 1024,
              ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else { throw WindowRestorationError.invalidRecord }
        return try Data(contentsOf: file)
    }
    private func withPublicationLock<T>(_ operation: () throws -> T) throws -> T {
        if publicationFD != nil { return try operation() }
        let fd = directory.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw WindowRestorationError.storageUnavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw WindowRestorationError.storageUnavailable }
        publicationFD = fd
        defer { publicationFD = nil; _ = flock(fd, LOCK_UN); Darwin.close(fd) }
        return try operation()
    }
    private static func canonicalEntry(_ name: String) -> Bool {
        name == "removed-accounts.plist" || name == "history-epoch.plist" || name == "reset-in-progress.plist" || name.range(of: #"^[0-9A-Fa-f-]{36}\.[0-9a-f]{64}\.[0-9A-Fa-f-]{36}\.window$"#, options: .regularExpression) != nil
    }
    private static func foundationStage(_ name: String) -> Bool {
        guard let separator = name.range(of: ".sb-", options: .backwards) else { return false }
        let target = String(name[..<separator.lowerBound]), suffix = String(name[separator.upperBound...])
        return canonicalEntry(target) && suffix.range(of: #"^[0-9a-fA-F]{8}-[A-Za-z0-9]{6}$"#, options: .regularExpression) != nil
    }
    private func publish(_ data: Data, to file: URL) throws {
        guard data.count <= 16 * 1024 * 1024 else { throw WindowRestorationError.invalidRecord }
        try withPublicationLock {
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
    private func accepts(_ value: RequestContext) -> Bool {
        value.account != nil && value.account == context.account && value.accountGeneration == context.accountGeneration && !removed.contains(value.account!.accountID)
    }
    private func file(_ owner: WindowOwner, _ window: UUID) -> URL {
        directory.appendingPathComponent(owner.accountID.uuidString + "." + owner.partition + "." + window.uuidString + ".window")
    }
    @discardableResult public func bind(_ value: RequestContext) throws -> Bool {
        try Task.checkCancellation()
        guard value.accountGeneration > context.accountGeneration || (value.accountGeneration == context.accountGeneration && value.account == context.account) else { throw WindowRestorationError.staleOwner }
        context = value // Account authority advances even when this secondary store is off.
        if let account = value.account, removed.contains(account.accountID) { throw WindowRestorationError.removedAccount }
        guard !disabled else { return false }
        do {
            try prepare()
            if let account = value.account, removed.contains(account.accountID) { throw WindowRestorationError.removedAccount }
            // Another owner's pending writes cannot gate this owner or its account.
            try flushPending(only: value.account.map(WindowOwner.init))
            return true
        } catch {
            guard Self.storageFailure(error) else { throw error }
            disabled = true; return false
        }
    }
    private func flushPending(only selected: WindowOwner? = nil) throws {
        for (owner, sessions) in pending {
            if let selected, selected != owner { continue }
            if removed.contains(owner.accountID) { pending[owner] = nil; continue }
            for (window, session) in sessions {
                try publish(session.encoded(), to: file(owner, window))
                pending[owner]?[window] = nil
            }
            if pending[owner]?.isEmpty == true { pending[owner] = nil }
        }
    }
    public func save(_ session: BrowserSession, context value: RequestContext) throws {
        try Task.checkCancellation()
        guard accepts(value), let account = value.account, session.owner == WindowOwner(account), (session.historyEpoch ?? 0) == epoch else { throw WindowRestorationError.staleOwner }
        try requireHistory()
        do {
            try prepare()
            pending[WindowOwner(account), default: [:]][session.windowID] = session
            try flushPending(only: WindowOwner(account))
        } catch {
            guard Self.storageFailure(error) else { throw error }
            disabled = true; throw WindowRestorationError.storageUnavailable
        }
    }
    public func restore(window: UUID, context value: RequestContext) throws -> BrowserSession? {
        try Task.checkCancellation()
        guard accepts(value), let account = value.account else { throw WindowRestorationError.staleOwner }
        try requireHistory()
        do {
            try prepare()
            let owner = WindowOwner(account), path = file(owner, window)
            guard FileManager.default.fileExists(atPath: path.path) else { return nil }
            let session = try BrowserSession.restore(boundedRead(path))
            guard session.windowID == window, session.owner == owner, (session.historyEpoch ?? 0) == epoch else { throw WindowRestorationError.invalidRecord }
            return session
        } catch {
            guard Self.storageFailure(error) else { throw error }
            disabled = true; throw WindowRestorationError.storageUnavailable
        }
    }
    /// Trusted lifecycle snapshot flush: fence first, then save the captured outgoing windows.
    /// Delayed consumer saves/restores cannot cross this barrier, even when storage fails.
    @discardableResult public func detach(previous: RequestContext, barrier: RequestContext, outgoing: [BrowserSession]) throws -> Bool {
        guard barrier.account == nil, barrier.accountGeneration > context.accountGeneration else { throw WindowRestorationError.staleOwner }
        let old = context; context = barrier
        if let account = previous.account, old.account == previous.account, old.accountGeneration == previous.accountGeneration, !removed.contains(account.accountID) {
            let owner = WindowOwner(account)
            for session in outgoing where session.owner == owner && (session.historyEpoch ?? 0) == epoch { pending[owner, default: [:]][session.windowID] = session }
        }
        guard !disabled else { return false }
        do { try prepare(); if let account = previous.account { try flushPending(only: WindowOwner(account)) }; return true }
        catch { guard Self.storageFailure(error) else { throw error }; disabled = true; return false }
    }
    public func remove(accountID: UUID) throws {
        removed.insert(accountID)
        pending = pending.filter { $0.key.accountID != accountID }
        if context.account?.accountID == accountID { context = RequestContext(account: nil, accountGeneration: context.accountGeneration, requestGeneration: 0) }
        do {
            try prepare()
            try withPublicationLock {
                try publish(PropertyListEncoder().encode(removed), to: directory.appendingPathComponent("removed-accounts.plist"))
                for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.lastPathComponent.hasPrefix(accountID.uuidString + ".") { try GuardedFiles(root: directory).remove(url) }
            }
        } catch {
            guard Self.storageFailure(error) else { throw error }
            disabled = true; throw WindowRestorationError.storageUnavailable
        }
    }
    /// Only the confirmed, explicit UI action calls this. No recursive deletion or symlink traversal.
    public func resetSavedWindowState(context value: RequestContext) throws -> Bool {
        try Task.checkCancellation()
        guard value.account == context.account, value.accountGeneration == context.accountGeneration else { throw WindowRestorationError.staleOwner }
        disabled = true; pending.removeAll()
        try validateParent()
        let fm = FileManager.default
        let existingAttributes = try? fm.attributesOfItem(atPath: directory.path)
        if let attributes = existingAttributes {
            guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid() else { throw WindowRestorationError.storageUnavailable }
            let type = attributes[.type] as? FileAttributeType
            if type == .typeSymbolicLink || type == .typeRegular {
                // Remove the exact obstructing app-owned entry, never its symlink destination.
                try GuardedFiles(root: directory).remove(directory, allowRoot: true)
            } else if type != .typeDirectory { throw WindowRestorationError.storageUnavailable }
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return try withPublicationLock { try resetContents() }
    }
    private func resetContents() throws -> Bool {
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let entries = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        // Validate all names/types before deleting any saved record.
        for url in entries {
            let name = url.lastPathComponent
            let stage = Self.foundationStage(name)
            let known = Self.canonicalEntry(name) || stage
            let attr = try fm.attributesOfItem(atPath: url.path), type = attr[.type] as? FileAttributeType
            if stage {
                let mode = (attr[.posixPermissions] as? NSNumber)?.intValue ?? 0
                guard type == .typeRegular, [0o600, 0o644].contains(mode),
                      ((attr[.size] as? NSNumber)?.intValue ?? Int.max) <= 16 * 1024 * 1024,
                      (attr[.referenceCount] as? NSNumber)?.intValue == 1 else { throw WindowRestorationError.storageUnavailable }
            }
            let emptyDirectory = type == .typeDirectory ? try fm.contentsOfDirectory(atPath: url.path).isEmpty : false
            guard known, (attr[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(), type == .typeRegular || type == .typeSymbolicLink || emptyDirectory else { throw WindowRestorationError.storageUnavailable }
        }
        // Known symlinks are unlinked as entries; they are never read or overwritten through.
        for url in entries {
            let type = (try fm.attributesOfItem(atPath: url.path))[.type] as? FileAttributeType
            if type == .typeSymbolicLink || type == .typeDirectory { try GuardedFiles(root: directory).remove(url) }
        }
        // Untrusted revocation bytes may only add denials during explicit reset, never grant reads.
        let revoked = directory.appendingPathComponent("removed-accounts.plist")
        if let attributes = try? fm.attributesOfItem(atPath: revoked.path), attributes[.type] as? FileAttributeType == .typeRegular,
           ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 16 * 1024 * 1024,
           let bytes = try? Data(contentsOf: revoked), let known = try? PropertyListDecoder().decode(Set<UUID>.self, from: bytes) { removed.formUnion(known) }
        let epochFile = directory.appendingPathComponent("history-epoch.plist")
        if let bytes = try? boundedRead(epochFile), let prior = try? PropertyListDecoder().decode(EpochRecord.self, from: bytes).value { epoch = max(epoch, prior) }
        let resetMarker = directory.appendingPathComponent("reset-in-progress.plist")
        try publish(Data([1]), to: resetMarker)
        guard epoch < .max else { throw WindowRestorationError.storageUnavailable }
        epoch += 1 // Persist before purge: surviving old records cannot publish after partial failure/restart.
        try publish(PropertyListEncoder().encode(EpochRecord(value: epoch)), to: epochFile)
        try publish(PropertyListEncoder().encode(removed), to: revoked)
        for url in entries {
            let discarded = url.lastPathComponent.hasSuffix(".window") || Self.foundationStage(url.lastPathComponent)
            if discarded && fm.fileExists(atPath: url.path) { try GuardedFiles(root: directory).remove(url) }
        }
        try GuardedFiles(root: directory).remove(resetMarker)
        prepared = true; disabled = false
        return historyAvailable
    }

}
@MainActor @Observable public final class WindowNavigationAuthority {
    public private(set) var context = RequestContext(account: nil, accountGeneration: 0, requestGeneration: 0)
    public var failure: String?
    public private(set) var historyEnabled = true
    private var historyEpoch: UInt64 = 0
    public static let unavailableNotice = "Saved window state is unavailable. Your account is still usable. You can reset this app’s saved windows, searches, filters and selections."
    private struct WeakWindow { weak var value: BrowserNavigation? }
    private var windows: [UUID: WeakWindow] = [:]
    private var removed: Set<UUID> = []
    private var closing: [UUID: BrowserSession] = [:]
    private var closed: Set<UUID> = []
    public init() {}
    public func accepts(_ value: RequestContext) -> Bool { context.account == value.account && context.accountGeneration == value.accountGeneration && value.account.map { !removed.contains($0.accountID) } != false }
    public func register(_ navigation: BrowserNavigation) {
        windows = windows.filter { $0.value.value != nil }
        closed = closed.filter { windows[$0] != nil }
        closed.remove(navigation.session.windowID)
        closing[navigation.session.windowID] = nil // A live reattached window owns its newest edits.
        windows[navigation.session.windowID] = WeakWindow(value: navigation)
        let owner = context.account.map(WindowOwner.init)
        if navigation.session.owner != owner { navigation.reset(owner: owner) }
        navigation.session.historyEpoch = historyEpoch
    }
    public func close(_ navigation: BrowserNavigation) {
        if navigation.session.owner != nil { closing[navigation.session.windowID] = navigation.session }
        // Keep a weak live registration: SwiftUI disappearance may mean hiding,
        // and a still-live view must redact before it can be shown again.
        closed.insert(navigation.session.windowID)
    }
    public func savedClosed(_ window: UUID, context: RequestContext) { if accepts(context) { closing[window] = nil } }
    @discardableResult public func installRestored(_ session: BrowserSession, context value: RequestContext, revision: UInt64, into navigation: BrowserNavigation) -> Bool {
        guard historyEnabled, accepts(value), let account = value.account, session.owner == WindowOwner(account), navigation.session.owner == session.owner,
              (session.historyEpoch ?? 0) == historyEpoch,
              session.windowID == navigation.session.windowID, navigation.revision == revision,
              !closed.contains(session.windowID), windows[session.windowID]?.value === navigation else { return false }
        navigation.session = session
        return true
    }
    public func detach(_ barrier: RequestContext) -> [BrowserSession] {
        guard barrier.accountGeneration > context.accountGeneration else { return [] }
        let outgoing = windows.values.compactMap { $0.value?.session } + closing.values
        closing.removeAll()
        var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
        withTransaction(transaction) {
            context = barrier
            for window in windows.values { window.value?.reset(owner: nil) }
        }
        return outgoing
    }
    public func bind(_ value: RequestContext, historyAvailable: Bool = true, epoch: UInt64 = 0) {
        guard value.accountGeneration > context.accountGeneration || (value.accountGeneration == context.accountGeneration && value.account == context.account) else { return }
        let enabled = historyAvailable && value.account.map({ !removed.contains($0.accountID) }) != false
        context = value; historyEnabled = enabled; historyEpoch = epoch
        for window in windows.values { window.value?.reset(owner: value.account.map(WindowOwner.init)); window.value?.session.historyEpoch = epoch }
        if !enabled { failure = Self.unavailableNotice }
    }
    public func historyUnavailable() {
        historyEnabled = false; failure = Self.unavailableNotice
        // Persistence availability is not an account/privacy barrier. Keep live state.

    }
    public func historyReset(context value: RequestContext, enabled: Bool, epoch: UInt64) {
        guard accepts(value) else { return }
        closing.removeAll(); bind(value, historyAvailable: enabled, epoch: epoch)
        failure = enabled ? nil : Self.unavailableNotice
    }
    public func remove(_ account: UUID) {
        removed.insert(account)
        closing = closing.filter { $0.value.owner?.accountID != account }
        for window in windows.values where window.value?.session.owner?.accountID == account { window.value?.reset(owner: nil) }
    }
}
public actor WindowAccountParticipant: AccountLifecycleParticipant {
    public nonisolated let participantID = "private-window-restoration"
    private let store: WindowRestorationStore
    private let presentation: WindowNavigationAuthority
    public init(store: WindowRestorationStore, presentation: WindowNavigationAuthority) { self.store = store; self.presentation = presentation }
    public func detach(previous: RequestContext, barrier: RequestContext) async throws {
        let outgoing = await presentation.detach(barrier)
        let saved = try await store.detach(previous: previous, barrier: barrier, outgoing: outgoing)
        if !saved { await presentation.historyUnavailable() }
    }
    public func restorePaused(_ identity: LocalIdentity, context: RequestContext) async throws {
        guard identity.id == context.account else { throw WindowRestorationError.staleOwner }
        let enabled: Bool
        do { enabled = try await store.bind(context) }
        catch WindowRestorationError.removedAccount { enabled = false }
        let epoch = await store.currentEpoch
        await presentation.bind(context, historyAvailable: enabled, epoch: epoch)
    }
    public func removeLocal(_ account: AccountContext, context: RequestContext) async throws {
        await presentation.remove(account.accountID)
        do { try await store.remove(accountID: account.accountID) }
        catch { await presentation.historyUnavailable(); throw error }
    }
}
