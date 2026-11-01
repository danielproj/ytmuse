import Foundation
import Security
import Domain

// Only serialized inside app-owned Keychain records, never ordinary metadata.
public protocol RedactedGoogleValue: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {}
public extension RedactedGoogleValue {
    nonisolated var description: String { "[redacted Google authorization]" }
    nonisolated var debugDescription: String { description }
    nonisolated var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}
struct GoogleGrant: Codable, Sendable, RedactedGoogleValue {
    let clientID: String
    let subject: String
    let nonce: String
    let accessToken: String
    let refreshToken: String?
    let scopes: Set<String>
    let expiresIn: Int
}
struct GoogleGrantBinding: Sendable, Equatable {
    let generation: UInt64
    let target: AccountContext?
}
protocol GoogleGrantStorage: Actor {
    func begin(_ binding: GoogleGrantBinding) async throws -> UUID
    func publish(_ grant: GoogleGrant, permit: UUID) async throws
    func read(permit: UUID) async throws -> GoogleGrant
    func hasStoredGrant() async throws -> Bool
    func removeStoredGrant() async throws -> GoogleGrant?
    func clear() async throws
    func discard(permit: UUID) async throws
}
/// Separate from SessionVault.insert: no Music account, enrollment or erasure
/// epoch can be created by Google authorization or late refresh. All reads/writes
/// require an unguessable live permit; clear invalidates it before Keychain I/O.
actor GoogleKeychainGrantStore: GoogleGrantStorage {
    private let service: String
    private var keychain: SecKeychain?
    private var permit: UUID?
    private var binding: GoogleGrantBinding?
    private var closed = false
    private struct StoredBinding: Codable, Equatable {
        let generation: UInt64; let accountID: UUID?; let channel: String?; let region: String?
        init(_ value: GoogleGrantBinding) {
            generation = value.generation; accountID = value.target?.accountID
            channel = value.target?.channelID.rawValue; region = value.target?.region
        }
    }
    private struct Record: Codable, RedactedGoogleValue { let grant: GoogleGrant; let binding: StoredBinding }
    init(testNamespace: String? = nil, isolatedKeychainURL: URL? = nil) throws {
        if let testNamespace { guard testNamespace.hasPrefix(KeychainVault.applicationNamespace + ".test.") else { throw LifecycleError.invalidDirectory } }
        service = (testNamespace ?? KeychainVault.applicationNamespace) + ".google-candidate"
        if let isolatedKeychainURL {
            guard testNamespace != nil, !FileManager.default.fileExists(atPath: isolatedKeychainURL.path) else { throw LifecycleError.invalidDirectory }
            var created: SecKeychain?
            let password = UUID().uuidString
            let status = password.withCString { SecKeychainCreate(isolatedKeychainURL.path, UInt32(password.utf8.count), $0, false, nil, &created) }
            guard status == errSecSuccess, let created else { throw LifecycleError.keychain(status) }
            keychain = created
        }
        if testNamespace == nil { KeychainInteraction.disallowUserInteraction() }
    }
    func destroyIsolatedTestKeychain() throws {
        guard let keychain else { throw LifecycleError.invalidDirectory }
        permit = nil; binding = nil; closed = true
        let status = SecKeychainDelete(keychain)
        guard status == errSecSuccess else { throw LifecycleError.keychain(status) }
        self.keychain = nil
    }
    private func query() -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "candidate", kSecAttrSynchronizable as String: false,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        if let keychain { q[kSecMatchSearchList as String] = [keychain] }
        else { q[kSecUseDataProtectionKeychain as String] = false }
        return q
    }
    func begin(_ binding: GoogleGrantBinding) throws -> UUID {
        // A restart cannot silently restore Google tokens into a new lifecycle
        // generation. Explicit new consent replaces the exact pending record.
        guard !closed else { throw DesktopOAuthError.stale }
        try clear()
        let next = UUID(); permit = next; self.binding = binding; return next
    }
    func publish(_ grant: GoogleGrant, permit: UUID) throws {
        guard self.permit == permit, let binding else { throw DesktopOAuthError.stale }
        let bytes = try JSONEncoder().encode(Record(grant: grant, binding: StoredBinding(binding)))
        guard bytes.count <= 131_072 else { throw DesktopOAuthError.invalidGrant }
        let q = query()
        var status = GuardedKeychain.update(q as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q; add[kSecValueData as String] = bytes
            add.removeValue(forKey: kSecMatchSearchList as String)
            if let keychain { add[kSecUseKeychain as String] = keychain }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw LifecycleError.keychain(status) }
    }
    func read(permit: UUID) throws -> GoogleGrant {
        guard self.permit == permit, binding != nil else { throw DesktopOAuthError.stale }
        var q = query(); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess, let bytes = result as? Data else { throw LifecycleError.keychain(status) }
        let record = try JSONDecoder().decode(Record.self, from: bytes)
        guard record.binding == StoredBinding(binding!) else { throw DesktopOAuthError.stale }
        return record.grant
    }
    func hasStoredGrant() throws -> Bool {
        guard !closed else { throw DesktopOAuthError.stale }
        var q = query(); q[kSecReturnAttributes as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw LifecycleError.keychain(status) }
        return true
    }
    func removeStoredGrant() throws -> GoogleGrant? {
        permit = nil; binding = nil
        guard !closed else { throw DesktopOAuthError.stale }
        var q = query(); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        let grant: GoogleGrant?
        if status == errSecSuccess, let data = value as? Data, data.count <= 131_072 {
            grant = (try? JSONDecoder().decode(Record.self, from: data))?.grant
        } else { grant = nil }
        // Local removal is attempted even if data cannot be read/decoded. Remote
        // revoke is best effort; a broken record cannot prevent local deletion.
        try clear()
        return grant
    }
    func discard(permit: UUID) throws {
        if self.permit == permit { try clear() }
    }
    func clear() throws {
        permit = nil; binding = nil
        guard !closed else { throw DesktopOAuthError.stale }
        let status = GuardedKeychain.delete(query() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LifecycleError.keychain(status) }
    }
}
actor GoogleGrantCapture: RedactedGoogleValue {
    private var value: (grant: GoogleGrant, deadline: TimeInterval)?
    func set(_ grant: GoogleGrant, deadline: TimeInterval) { value = (grant, deadline) }
    func take() -> (grant: GoogleGrant, deadline: TimeInterval)? { defer { value = nil }; return value }
}
public protocol GoogleClientSecretSource: Sendable { func optionalSecret(clientID: String) async throws -> String? }
/// Exact app-owned optional configuration record. Never enumerates Keychains.
public struct AppOwnedGoogleClientSecret: GoogleClientSecretSource {
    public init() {}
    public func optionalSecret(clientID: String) async throws -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainVault.applicationNamespace + ".oauth-config", kSecAttrAccount as String: clientID,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail, kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: false, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 4096,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { throw DesktopOAuthError.invalidConfiguration }
        return value
    }
}
