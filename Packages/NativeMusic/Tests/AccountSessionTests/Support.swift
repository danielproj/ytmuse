import Foundation
import Domain
import AccountSession

func identity(_ channel: String = "synthetic-channel", uuid: UUID = UUID()) throws -> Account {
    let context = try AccountContext(accountID: uuid, channelID: ID<ChannelTag>(channel), region: "US")
    return try Account(id: uuid, serviceIdentity: ServiceID("synthetic-service"), context: context, displayName: "Synthetic " + channel, credential: nil)
}
actor MemoryDirectory: AccountDirectoryStore {
    var value: AccountDirectory = .init()
    var fail = false
    func load() -> AccountDirectory { value }
    func save(_ directory: AccountDirectory) throws {
        if fail { throw DomainError.offline }; value = directory
    }
    func setFailure(_ value: Bool) { fail = value }
}
func testVault() throws -> KeychainVault { try KeychainVault(testNamespace: KeychainVault.applicationNamespace + ".test." + UUID().uuidString, isolatedKeychainURL: FileManager.default.temporaryDirectory.appendingPathComponent("native-music-T04-" + UUID().uuidString + ".keychain-db")) }
func connect(_ lifecycle: AccountLifecycle, _ account: Account) async throws {
    let challenge = try await lifecycle.beginAuthentication()
    try await lifecycle.completeAuthentication(challenge, account: account, secret: Data("synthetic-disposable-session".utf8))
}
