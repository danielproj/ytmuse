import Domain
import Foundation
import Testing
import Persistence
import Features
@testable import AppShell

/// The immediate full-text source over the W03 store. Uses a scratch store in a temporary
/// directory created and removed by the test; no production store is opened.
@Suite @MainActor struct StoredMediaSearchTests {
    private func context(_ account: String, generation: UInt64 = 1) throws -> RequestContext {
        try RequestContext(account: AccountContext(accountID: UUID(uuidString: account)!, channelID: ID<ChannelTag>("synthetic-channel-" + account.suffix(2)), region: "US"), accountGeneration: generation, requestGeneration: 1)
    }
    private func media(_ id: String, _ title: String, kind: MediaKind = .song, explicit: Bool = false) throws -> MediaItem {
        try MediaItem(id: ServiceID(id), kind: kind, title: title, artists: [ServiceID("artist")], duration: 100, artwork: [ServiceID("art")], explicit: explicit, availability: .available)
    }
    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-music-W10-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }
    @Test func fullTextMatchesAreImmediateDiacriticInsensitiveAndScopedToTheAccount() async throws {
        let directory = try scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let a = try context("00000000-0000-0000-0000-0000000000a1"), b = try context("00000000-0000-0000-0000-0000000000b2", generation: 2)
        let store = try SQLiteStore(directory: directory.appendingPathComponent("database"), context: a)
        try await store.saveAccount(Account(id: a.account!.accountID, serviceIdentity: ServiceID("svc-a"), context: a.account!, displayName: "A", credential: CredentialReference("00000000-0000-0000-0000-000000000099")), context: a)
        try await store.saveMedia([media("aaaaaaaaaa1", "Café del Mar", explicit: true), media("aaaaaaaaaa2", "Naïve Melody"), media("aaaaaaaaaa3", "Unrelated"), media("aaaaaaaaaa4", "Live set", kind: .live)], context: a)
        var current: RequestContext? = a
        let source = StoredMediaSearchSource(store: store, context: { current })
        #expect(source.scopes == [.all, .library])
        for typed in ["cafe", "Café", "Cafe\u{301}", "CAFÉ del"] {
            let found = await source.search(FoldedQuery(typed), limit: 10)
            #expect(found.map(\.title) == ["Café del Mar"], "\(typed)")
            #expect(found.first?.badges == [.local, .explicit] && found.first?.target.videoID == "aaaaaaaaaa1" && found.first?.kind == .song)
        }
        #expect(await source.search(FoldedQuery("naive"), limit: 10).map(\.title) == ["Naïve Melody"])
        #expect(await source.search(FoldedQuery("live"), limit: 10).isEmpty, "a live stream is not a kind search presents")
        current = nil
        #expect(await source.search(FoldedQuery("cafe"), limit: 10).isEmpty, "no request context, no private read")
        current = b
        #expect(await source.search(FoldedQuery("cafe"), limit: 10).isEmpty, "another account's context cannot read these records")
    }
}
