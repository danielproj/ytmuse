import Domain
import Foundation
import Security

/// W27 rework 1. The only place a Keychain item is deleted or updated. In an isolated process (every test, every QA launch) a query whose service name is not a
/// test-namespaced one is refused AT THE CALL: the production service names (`local.native-music.development.sessions`, its `.google-candidate` and `.oauth-config`
/// items, the owned-audio vault) cannot be reached from a test or an isolated launch, whoever builds the query.
enum GuardedKeychain {
    /// errSecAuthFailed: the refusal reads like any refused Keychain operation to the caller.
    static let refused = errSecAuthFailed
    static func service(of query: CFDictionary) -> String? { (query as NSDictionary)[kSecAttrService as String] as? String }
    static func allows(_ query: CFDictionary) -> Bool {
        guard ProcessIsolation.isIsolated else { return true }
        guard let service = service(of: query) else { return false }
        return service.contains(".test.")
    }
    /// `backend` is the Security call itself. Production passes the real one; a test of the guard passes a fake, so a broken guard can never reach the real Keychain.
    static func delete(_ query: CFDictionary, backend: (CFDictionary) -> OSStatus = { SecItemDelete($0) }) -> OSStatus { allows(query) ? backend(query) : refused }
    static func update(_ query: CFDictionary, _ attributes: CFDictionary, backend: (CFDictionary, CFDictionary) -> OSStatus = { SecItemUpdate($0, $1) }) -> OSStatus { allows(query) ? backend(query, attributes) : refused }
}
