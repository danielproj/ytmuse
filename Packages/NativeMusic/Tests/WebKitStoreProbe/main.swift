// Test-only helper (never linked into the app). Exercises the real
// WebKitMusicDataStores and ledger reconciliation as the FIRST WebKit use in a
// fresh process, the condition that crashed the app at launch (E01 M2 rework).
// No page is fetched: the only load is a local synthetic HTML string.
import AccountSession
import AppKit
import Domain
import Foundation
import WebKit

private actor NoVault: SessionVault {
    func replace(_ reference: CredentialReference, with bytes: Data, context: RequestContext) async throws { throw DomainError.unsupported }
    func bind(_ context: RequestContext) {}
    func insert(_ bytes: Data, for account: AccountContext) throws -> CredentialReference { throw DomainError.unsupported }
    func read(_ reference: CredentialReference, context: RequestContext) throws -> Data { throw DomainError.unsupported }
    func delete(_ reference: CredentialReference, for account: AccountContext) {}
    func deleteAll(for account: AccountContext) {}
}
private struct NoReader: MusicSessionReading {
    func accountMenu(session: MusicCookieSession) async throws -> MusicSignedResult<MusicAccountIdentity> { throw MusicSessionError.policy }
    func likedPlaylists(session: MusicCookieSession) async throws -> MusicSignedResult<MusicLibraryPlaylists> { throw MusicSessionError.policy }
    func avatar(_ url: URL) async throws -> Data { throw MusicSessionError.policy }
}
func check(_ condition: Bool, _ label: String) { print((condition ? "ok " : "FAIL ") + label); if !condition { exit(1) } }

/// The store's on-disk directory. WebKit names it after the identifier (lowercase
/// observed); both spellings are checked so the assertion cannot pass vacuously.
func storeDirectory(_ identifier: UUID) -> URL? {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/WebKit/WebKitStoreProbe/WebsiteDataStore")
    return [identifier.uuidString.lowercased(), identifier.uuidString].map { root.appendingPathComponent($0) }
        .first { FileManager.default.fileExists(atPath: $0.path) }
}
/// Synthetic cookie only; never a real Google value.
@MainActor func populate(_ identifier: UUID) async {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: identifier)
    var view: WKWebView? = WKWebView(frame: .init(x: 0, y: 0, width: 10, height: 10), configuration: configuration)
    let cookie = HTTPCookie(properties: [.name: "SYNTHETIC_PROBE", .value: "synthetic", .domain: ".youtube.com", .path: "/",
                                         .expires: Date().addingTimeInterval(3600)])!
    await configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
    view?.loadHTMLString("<p>synthetic probe</p>", baseURL: nil)
    try? await Task.sleep(for: .milliseconds(800))
    view?.stopLoading(); view = nil
}
@MainActor func cookieCount(_ identifier: UUID) async -> Int {
    await WKWebsiteDataStore(forIdentifier: identifier).httpCookieStore.allCookies().count
}
/// Removal with the same kind of retry the coordinator applies.
func removeEventually(_ stores: WebKitMusicDataStores, _ identifier: UUID) async -> Bool {
    for _ in 0..<20 { if await stores.remove(identifier) { return true }; try? await Task.sleep(for: .milliseconds(250)) }
    return false
}

/// A view whose configuration (and so its store object) is owned only by the view.
@MainActor func liveView(_ identifier: UUID) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: identifier)
    return WKWebView(frame: .init(x: 0, y: 0, width: 10, height: 10), configuration: configuration)
}

_ = NSApplication.shared
let ledgerDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
Task { @MainActor in
    let stores = WebKitMusicDataStores()
    // 1. Cold: the first WebKit call in this process is a store removal.
    check(await stores.remove(UUID()), "cold removal of a store that does not exist is confirmed without crashing")
    // 2. A populated attempt store is removed once its web view is released.
    let used = UUID()
    await populate(used)
    check(storeDirectory(used) != nil, "populated attempt store exists on disk before removal")
    check(await cookieCount(used) == 1, "populated attempt store holds its synthetic cookie")
    check(await stores.wipe(used), "wipe reported")
    check(await cookieCount(used) == 0, "wipe deleted every cookie while the store directory still exists")
    check(await removeEventually(stores, used), "released attempt store removed")
    check(storeDirectory(used) == nil, "attempt store directory is gone after confirmed removal")
    // 2b. SS1 ordering: while a web view on the store is still alive, WebKit refuses
    //     removal ("in use"); once that view is deallocated, removal succeeds.
    let held = UUID()
    var alive: WKWebView? = liveView(held)
    alive?.loadHTMLString("<p>synthetic probe</p>", baseURL: nil)
    try? await Task.sleep(for: .milliseconds(800))
    check(!(await stores.remove(held)), "a store whose web view is still alive is refused as in use")
    alive?.stopLoading(); alive = nil
    var removedAfterRelease = false
    for _ in 0..<12 where !removedAfterRelease {
        removedAfterRelease = await stores.remove(held)
        if !removedAfterRelease { try? await Task.sleep(for: .milliseconds(250)) }
    }
    check(removedAfterRelease, "the same store is removed once its web view is released")
    // 3. Reconciliation touches only ledger IDs and clears confirmed removals.
    let interrupted = UUID(), neverCreated = UUID()
    await populate(interrupted)
    let ledger = FileMusicSignInLedger(url: ledgerDirectory.appendingPathComponent("web-sign-in-attempts.json"))
    try? await ledger.add(interrupted); try? await ledger.add(neverCreated)
    let coordinator = MusicSessionCoordinator(vault: NoVault(), reader: NoReader(), stores: stores, ledger: ledger, presenter: nil)
    await coordinator.reconcileWebStores()
    let left = (try? await ledger.pending()) ?? [UUID()]
    check(left.isEmpty, "reconciliation cleared every ledger entry")
    check(storeDirectory(interrupted) == nil, "reconciled store directory is gone")
    print("PASS")
    exit(0)
}
RunLoop.main.run(until: Date().addingTimeInterval(60))
print("FAIL timeout")
exit(2)
