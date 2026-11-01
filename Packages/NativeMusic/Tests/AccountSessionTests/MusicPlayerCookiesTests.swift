import Foundation
import Testing
import Domain
@testable import AccountSession

/// In-memory vault with KeychainVault's generation rule for read and replace.
private actor PlayerVault: SessionVault {
    var records: [String: Data] = [:]
    var active: RequestContext?
    var replacements = 0
    func bind(_ context: RequestContext) {
        if let active, context.accountGeneration < active.accountGeneration { return }
        active = context
    }
    func insert(_ bytes: Data, for account: AccountContext) throws -> CredentialReference {
        let reference = try CredentialReference(UUID().uuidString); records[reference.rawValue] = bytes; return reference
    }
    func read(_ reference: CredentialReference, context: RequestContext) throws -> Data {
        guard active == context, let bytes = records[reference.rawValue] else { throw DomainError.staleContext }
        return bytes
    }
    func replace(_ reference: CredentialReference, with bytes: Data, context: RequestContext) throws {
        guard active == context, records[reference.rawValue] != nil else { throw DomainError.staleContext }
        records[reference.rawValue] = bytes; replacements += 1
    }
    func delete(_ reference: CredentialReference, for account: AccountContext) { records[reference.rawValue] = nil }
    func deleteAll(for account: AccountContext) { records = [:] }
    func count() -> Int { replacements }
    func only() -> Data? { records.values.first }
}
private struct Still: WallClock { func now() -> Date { Date(timeIntervalSince1970: 1_700_000_000) } }
private let now = Date(timeIntervalSince1970: 1_700_000_000)
private func raw(_ name: String, _ value: String, domain: String = ".youtube.com") -> HTTPCookie {
    HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: "/", .expires: now.addingTimeInterval(86_400)])!
}
/// One connected synthetic Music account whose exact record holds a sanitized session.
private func connected() async throws -> (AccountLifecycle, PlayerVault, AccountContext, RequestContext) {
    let vault = PlayerVault()
    let lifecycle = try await AccountLifecycle.open(vault: vault, store: MemoryDirectory(), participants: [])
    let id = UUID()
    let context = try AccountContext(accountID: id, channelID: ID("UCsyntheticCookies"), region: "US")
    let account = try Account(id: id, serviceIdentity: ServiceID("UCsyntheticCookies"), context: context, displayName: "Synthetic", credential: nil)
    let session = try MusicCookieSession(accountID: id, cookies: [raw("SAPISID", "SYNTHETIC-SAPISID"), raw("SID", "SYNTHETIC-SID"),
                                                                  raw("SIDCC", "SYNTHETIC-SIDCC-1"), raw("PREF", "f6=40000000")], now: now)
    let challenge = try await lifecycle.beginAuthentication()
    try await lifecycle.completeAuthentication(challenge, account: account, secret: session.encoded())
    try await lifecycle.switchIdentity(to: context)
    return (lifecycle, vault, context, await lifecycle.snapshot().context)
}

@Suite struct MusicPlayerCookiesTests {
    @Test func bootstrapInstallsOnlyTheRecordsYouTubeCookiesWithTheSitesProtections() async throws {
        let (lifecycle, vault, _, request) = try await connected()
        let cookies = try await MusicPlayerCookies(vault: vault, lifecycle: lifecycle, context: request, clock: Still()).playerCookies()
        #expect(Set(cookies.map(\.name)) == ["SAPISID", "SID", "SIDCC", "PREF"])
        #expect(cookies.allSatisfy { $0.domain == ".youtube.com" && $0.isSecure && $0.path == "/" })
        let byName = Dictionary(uniqueKeysWithValues: cookies.map { ($0.name, $0) })
        #expect(byName["SID"]?.isHTTPOnly == true && byName["SIDCC"]?.isHTTPOnly == true)
        #expect(byName["SAPISID"]?.isHTTPOnly == false && byName["PREF"]?.isHTTPOnly == false, "the page's own script reads these on the real site too")
    }
    @Test func rotationIsMergedIntoTheExactRecordAndNothingOutsideTheAllowlistIsAdded() async throws {
        let (lifecycle, vault, context, request) = try await connected()
        let player = MusicPlayerCookies(vault: vault, lifecycle: lifecycle, context: request, clock: Still())
        let changed = try await player.recordRotation([raw("SIDCC", "SYNTHETIC-SIDCC-2"), raw("YSC", "SYNTHETIC-TRACKING"),
                                                       raw("SID", "SYNTHETIC-GOOGLE-SID", domain: ".google.com"), raw("SAPISID", "SYNTHETIC-SAPISID")])
        let writes = await vault.count()
        #expect(changed && writes == 1)
        let stored = try MusicCookieSession.decode(try #require(await vault.only()), accountID: context.accountID)
        let values = Dictionary(uniqueKeysWithValues: stored.cookies.map { ($0.name, $0.value) })
        #expect(values["SIDCC"] == "SYNTHETIC-SIDCC-2" && values["SID"] == "SYNTHETIC-SID", "a google.com SID never replaces the youtube.com one")
        #expect(values["YSC"] == nil && stored.cookies.count == 4)
        let unchanged = try await player.recordRotation([raw("SIDCC", "SYNTHETIC-SIDCC-2")])
        let after = await vault.count()
        #expect(!unchanged && after == 1, "an identical store writes nothing")
    }
    @Test func aSourceFromAnOlderGenerationCannotReadOrWrite() async throws {
        let (lifecycle, vault, context, request) = try await connected()
        let player = MusicPlayerCookies(vault: vault, lifecycle: lifecycle, context: request, clock: Still())
        try await lifecycle.switchIdentity(to: context) // a newer generation of the same account
        await #expect(throws: MusicSessionError.stale) { try await player.playerCookies() }
        await #expect(throws: MusicSessionError.stale) { try await player.recordRotation([raw("SIDCC", "SYNTHETIC-SIDCC-3")]) }
        #expect(await vault.count() == 0)
        try await lifecycle.signOut(context)
        let fresh = MusicPlayerCookies(vault: vault, lifecycle: lifecycle, context: await lifecycle.snapshot().context, clock: Still())
        await #expect(throws: MusicSessionError.stale) { try await fresh.playerCookies() }
    }
    /// F5: the record holds a newer SIDCC (written by the signed coordinator) than
    /// the player installed. The player sends only what changed in its own store, so
    /// the newer value survives; re-sending the stale installed value would roll it back.
    @Test func aPlayerBatchOfOnlyChangedNamesNeverRollsBackANewerRecordValue() async throws {
        let (lifecycle, vault, context, request) = try await connected()
        let player = MusicPlayerCookies(vault: vault, lifecycle: lifecycle, context: request, clock: Still())
        _ = try await player.recordRotation([raw("SIDCC", "SYNTHETIC-SIDCC-COORDINATOR")]) // the coordinator's newer write
        let changed = try await player.recordRotation([raw("YSC", "SYNTHETIC-TRACKING")])  // what the player now sends
        let stored = try MusicCookieSession.decode(try #require(await vault.only()), accountID: context.accountID)
        #expect(!changed && stored.cookies.first(where: { $0.name == "SIDCC" })?.value == "SYNTHETIC-SIDCC-COORDINATOR")
    }
}
