import Domain
import Foundation
import Observation

/// Where settings values physically live. The app's one preferences store is a `UserDefaults` (the throwaway plist under QA isolation); tests use a
/// dictionary. Nothing here knows a path: the backing is injected, so a reset can only ever reach the store it was given.
public protocol SettingsBacking: AnyObject {
    func setting(forKey key: String) -> Any?
    func setSetting(_ value: Any?, forKey key: String) throws
    func removeSetting(forKey key: String) throws
    func settingKeys(withPrefix prefix: String) -> [String]
}
/// The app's preferences store behind its guard: every write and removal is refused when the store is the account holder's real preferences domain and the process
/// is isolated (`GuardedDefaults`). There is no `UserDefaults` conformance: a bare defaults object cannot back the settings.
extension GuardedDefaults: SettingsBacking {
    public func setting(forKey key: String) -> Any? { value(forKey: key) }
    public func setSetting(_ value: Any?, forKey key: String) throws { try set(value, forKey: key) }
    public func removeSetting(forKey key: String) throws { try remove(key) }
    public func settingKeys(withPrefix prefix: String) -> [String] { keys(withPrefix: prefix) }
}
public final class MemorySettingsBacking: SettingsBacking, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    public init() {}
    public func setting(forKey key: String) -> Any? { lock.lock(); defer { lock.unlock() }; return values[key] }
    public func setSetting(_ value: Any?, forKey key: String) throws { lock.lock(); values[key] = value; lock.unlock() }
    public func removeSetting(forKey key: String) throws { lock.lock(); values[key] = nil; lock.unlock() }
    public func settingKeys(withPrefix prefix: String) -> [String] { lock.lock(); defer { lock.unlock() }; return values.keys.filter { $0.hasPrefix(prefix) } }
}

/// The component that owns a behaviour reads and resets its setting through this. The store never reaches into the owner any other way.
public struct SettingOwnerBinding: @unchecked Sendable {
    /// Reads the setting `id` (an owner may hold several). nil: the owner has no value yet, so the default shows.
    public var read: @MainActor (String) -> SettingValue?
    /// Writes the setting `id`. nil: this owner's settings are not set through the store (its own pane does).
    public var write: (@MainActor (String, SettingValue) async -> Void)?
    public var reset: @MainActor () async -> Void
    public init(read: @escaping @MainActor (String) -> SettingValue?, write: (@MainActor (String, SettingValue) async -> Void)? = nil, reset: @escaping @MainActor () async -> Void) { self.read = read; self.write = write; self.reset = reset }
}

public enum SettingsError: Error, Equatable {
    case unknownSetting, wrongType, outOfRange, notChoosable, noAccount, windowRequired, newerSchema
}

/// W27. Reads and writes settings by scope.
/// - global: this Mac, key = the definition's key.
/// - account: the live account only. Key = `settings.v1.account.<account uuid>.<id>`. Switching account changes which keys are read, so one account's choices
///   never show under another. Account removal deletes the keys (`removeAccount`), SEC08.
/// - window: one window. Key = `settings.v1.window.<window uuid>.<id>`.
/// Per-category reset removes only that category's keys for the scope(s) in play (the live account, never another one) and calls the owner's reset for
/// owner-held settings. It touches no remote content: there is no network type in this file.
@MainActor @Observable public final class SettingsStore {
    public static let accountPrefix = "settings.v1.account."
    public static let windowPrefix = "settings.v1.window."
    @ObservationIgnored public let backing: any SettingsBacking
    @ObservationIgnored private let account: @MainActor () -> UUID?
    @ObservationIgnored private var owners: [String: SettingOwnerBinding] = [:]
    /// Bumped on every change so SwiftUI re-reads.
    public private(set) var revision = 0
    public private(set) var migrated = false

    public init(backing: any SettingsBacking, account: @escaping @MainActor () -> UUID? = { nil }) throws {
        self.backing = backing; self.account = account
        try migrate()
    }
    /// The schema version in the store. A newer version than this build knows is never overwritten (an older app opened a newer store).
    private func migrate() throws {
        let stored = (backing.setting(forKey: SettingsRegistry.schemaVersionKey) as? Int) ?? 0
        guard stored <= SettingsRegistry.schemaVersion else { throw SettingsError.newerSchema }
        if stored < SettingsRegistry.schemaVersion {
            try backing.setSetting(SettingsRegistry.schemaVersion, forKey: SettingsRegistry.schemaVersionKey); migrated = stored != 0
        }
    }
    public func attach(owner id: String, _ binding: SettingOwnerBinding) { owners[id] = binding; revision += 1 }
    public func hasOwner(_ id: String) -> Bool { owners[id] != nil }

    // MARK: Keys

    func key(for definition: SettingDefinition, window: UUID? = nil) throws -> String? {
        guard let global = definition.storedKey else { return nil }
        switch definition.scope {
        case .global: return global
        case .account:
            guard let account = account() else { throw SettingsError.noAccount }
            return Self.accountPrefix + account.uuidString + "." + definition.id
        case .window:
            guard let window else { throw SettingsError.windowRequired }
            return Self.windowPrefix + window.uuidString + "." + definition.id
        }
    }

    // MARK: Read

    /// The current value: the stored one when valid, else the default. A damaged stored value reads as the default and is not rewritten.
    public func value(_ id: String, window: UUID? = nil) -> SettingValue {
        guard let definition = SettingsRegistry.definition(id) else { return .text("") }
        _ = revision
        if case .owner(let owner) = definition.storage, let binding = owners[owner], let value = binding.read(id) { return value }
        guard let key = try? key(for: definition, window: window), let raw = backing.setting(forKey: key), let value = Self.coerce(raw, like: definition.defaultValue), (try? validate(value, for: definition)) != nil else { return definition.defaultValue }
        return value
    }
    public func bool(_ id: String) -> Bool { value(id).boolValue ?? false }
    public func text(_ id: String) -> String { value(id).textValue ?? "" }
    public func double(_ id: String) -> Double { value(id).doubleValue ?? 0 }
    public func isDefault(_ id: String, window: UUID? = nil) -> Bool { value(id, window: window) == SettingsRegistry.definition(id)?.defaultValue }

    private static func coerce(_ raw: Any, like template: SettingValue) -> SettingValue? {
        switch template {
        case .bool: return (raw as? Bool).map(SettingValue.bool)
        case .int: return (raw as? Int).map(SettingValue.int)
        case .double: return (raw as? Double).map(SettingValue.double) ?? (raw as? Int).map { .double(Double($0)) }
        case .text: return (raw as? String).map(SettingValue.text)
        }
    }
    func validate(_ value: SettingValue, for definition: SettingDefinition) throws {
        switch (definition.control, value) {
        case (.toggle, .bool): return
        case (.choice(let choices), .text(let text)): guard choices.contains(where: { $0.value == text }) else { throw SettingsError.outOfRange }
        case (.slider(let range, _), _): guard let number = value.doubleValue, number.isFinite, range.contains(number) else { throw SettingsError.outOfRange }
        case (.readOnly, _): throw SettingsError.notChoosable
        default: throw SettingsError.wrongType
        }
    }

    // MARK: Write

    /// Sets a stored setting. Refuses an unknown id, a read-only or unavailable one, a wrong type or an out-of-range value; changes nothing then.
    public func set(_ id: String, _ value: SettingValue, window: UUID? = nil) async throws {
        guard let definition = SettingsRegistry.definition(id) else { throw SettingsError.unknownSetting }
        guard definition.availability.isControllable else { throw SettingsError.notChoosable }
        if case .owner(let owner) = definition.storage {
            guard let binding = owners[owner], let write = binding.write else { throw SettingsError.notChoosable }
            await write(id, value); revision += 1; return
        }
        try validate(value, for: definition)
        guard let key = try key(for: definition, window: window) else { throw SettingsError.notChoosable }
        try backing.setSetting(Self.raw(value), forKey: key); revision += 1
    }
    private static func raw(_ value: SettingValue) -> Any {
        switch value { case .bool(let v): v; case .int(let v): v; case .double(let v): v; case .text(let v): v }
    }

    // MARK: Reset

    public struct ResetOutcome: Equatable, Sendable {
        public let category: SettingCategory
        public var restored: [String]
        /// Settings with nothing to restore (a fixed policy or an unavailable capability).
        public var notApplicable: [String]
        /// Settings of this page that are restored only by their own explicit action (the remembered output).
        public var explicit: [String] = []
    }
    /// Runs first in every reset: the session's guard. It throws when the session's stores are not ones a reset may touch.
    @ObservationIgnored public var preflight: (@MainActor () throws -> Void)?
    /// Restore defaults for ONE category. Other categories, other accounts and every remote thing are untouched, and so is any setting that has its own explicit
    /// restore action (`SettingDefinition.restoresOnlyOnRequest`). Refused entirely when the guard refuses.
    @discardableResult
    public func reset(_ category: SettingCategory, window: UUID? = nil, includingExplicit: Bool = false) async throws -> ResetOutcome {
        try preflight?()
        var outcome = ResetOutcome(category: category, restored: [], notApplicable: [])
        var resetOwners = Set<String>()
        for definition in SettingsRegistry.settings(in: category) {
            if definition.restoresOnlyOnRequest, !includingExplicit { outcome.explicit.append(definition.id); continue }
            switch definition.storage {
            case .policy: outcome.notApplicable.append(definition.id)
            case .stored:
                if let key = try? key(for: definition, window: window) {
                    try backing.removeSetting(forKey: key)
                    // A suite named by a file path (the isolated Debug preferences) keeps showing, within the same process, a value an EARLIER process left in the file, even
                    // after removeObject; the file itself is updated. Say the default explicitly in that case, so this process reads the default too.
                    if backing.setting(forKey: key) != nil { try backing.setSetting(Self.raw(definition.defaultValue), forKey: key) }
                    outcome.restored.append(definition.id)
                }
            case .owner(let owner):
                if resetOwners.insert(owner).inserted, let binding = owners[owner] { await binding.reset() }
                outcome.restored.append(definition.id)
            }
        }
        revision += 1
        return outcome
    }
    /// The explicit restore of one setting that is not part of a page's Restore Defaults.
    public func restoreOne(_ id: String) async throws {
        try preflight?()
        guard let definition = SettingsRegistry.definition(id), case .owner(let owner) = definition.storage, let binding = owners[owner] else { throw SettingsError.unknownSetting }
        await binding.reset(); revision += 1
    }
    /// Restore every category (preferences only; the local-data reset is `LocalDataEraser`), explicit ones included.
    public func resetAll(window: UUID? = nil) async throws {
        try preflight?()
        for category in SettingCategory.allCases { try await reset(category, window: window, includingExplicit: true) }
        for key in backing.settingKeys(withPrefix: Self.windowPrefix) { try backing.removeSetting(forKey: key) }
        // This is the local privacy reset: every account's own settings go too, including those of an account that no longer exists (an interrupted removal).
        for key in backing.settingKeys(withPrefix: Self.accountPrefix) { try backing.removeSetting(forKey: key) }
        revision += 1
    }

    /// After the preferences root was emptied underneath the store: re-stamp the schema version and tell the views to read again.
    public func refreshAfterErase() {
        try? backing.setSetting(SettingsRegistry.schemaVersion, forKey: SettingsRegistry.schemaVersionKey); revision += 1
    }

    // MARK: Account scope

    /// SEC08: an account's settings are deleted with it. Other accounts' keys are untouched.
    public func removeAccount(_ id: UUID) throws {
        for key in backing.settingKeys(withPrefix: Self.accountPrefix + id.uuidString + ".") { try backing.removeSetting(forKey: key) }
        revision += 1
    }
    public func accountIDsWithSettings() -> Set<UUID> {
        Set(backing.settingKeys(withPrefix: Self.accountPrefix).compactMap { key in
            let rest = key.dropFirst(Self.accountPrefix.count); return UUID(uuidString: String(rest.prefix(36)))
        })
    }
    public func removeWindow(_ id: UUID) throws { for key in backing.settingKeys(withPrefix: Self.windowPrefix + id.uuidString + ".") { try backing.removeSetting(forKey: key) }; revision += 1 }

    /// Settings that differ from their defaults, for the support bundle: the id only (never a value) when the value may be private.
    public func changedSettings() -> [(id: String, value: String?)] {
        SettingsRegistry.definitions.compactMap { definition in
            guard definition.hasUserValue, !isDefault(definition.id) else { return nil }
            return (definition.id, value(definition.id).description)
        }
    }
}
