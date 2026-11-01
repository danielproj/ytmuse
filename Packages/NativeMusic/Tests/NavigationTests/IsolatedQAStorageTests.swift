#if DEBUG
import Testing
import Foundation
import AccountSession
import Domain
@testable import AppShell

/// UI automation launches the account holder's bundle; its isolated namespace must
/// live entirely under a fresh temporary root with isolated keychain files.
@Suite struct IsolatedQAStorageTests {
    @Test func isolatedStorageIsTemporaryAndRemovedOnDestroy() async throws {
        let storage = try await IsolatedQAStorage.create()
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path
        #expect(storage.root.standardizedFileURL.path.hasPrefix(temporary))
        #expect(storage.root.lastPathComponent.hasPrefix("ytmuse-ui-test-isolated-"))
        let production = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        #expect(!storage.root.path.hasPrefix(production.path))
        #expect(FileManager.default.fileExists(atPath: storage.root.appendingPathComponent("session.keychain-db").path))
        #expect(FileManager.default.fileExists(atPath: storage.root.appendingPathComponent("owned.keychain-db").path))
        // A record written through the isolated vault round-trips without the login Keychain.
        let account = try AccountContext(accountID: UUID(), channelID: ID("isolated-qa"), region: "US")
        let context = RequestContext(account: account, accountGeneration: 1, requestGeneration: 1)
        await storage.sessionVault.bind(context)
        let reference = try await storage.sessionVault.insert(Data("synthetic".utf8), for: account)
        #expect(try await storage.sessionVault.read(reference, context: context) == Data("synthetic".utf8))
        await storage.destroy()
        #expect(!FileManager.default.fileExists(atPath: storage.root.path))
    }
}
#endif
