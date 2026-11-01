import Domain
import Foundation

/// The hidden YouTube Music player's view of the active account's session: the
/// allowlisted `.youtube.com` cookies from the exact Keychain record, bound to one
/// account generation. Rotation observed in the player's in-memory store is
/// merged and written back through `SessionVault.replace` only while that same
/// generation is still the lifecycle's owner. Google-domain cookies are never
/// added to the record.
public actor MusicPlayerCookies {
    private let vault: any SessionVault
    private weak var lifecycle: AccountLifecycle?
    private let context: RequestContext
    private let clock: any WallClock
    /// Cookies the website sets HttpOnly. Installing them HttpOnly keeps page
    /// script from reading anything the real site would not let it read.
    static let httpOnlyNames: Set<String> = [
        "SID", "HSID", "SSID", "__Secure-1PSID", "__Secure-3PSID", "__Secure-1PSIDTS", "__Secure-3PSIDTS",
        "SIDCC", "__Secure-1PSIDCC", "__Secure-3PSIDCC", "LOGIN_INFO", "VISITOR_INFO1_LIVE", "VISITOR_PRIVACY_METADATA",
    ]
    public init(vault: any SessionVault, lifecycle: AccountLifecycle, context: RequestContext, clock: any WallClock = SystemWallClock()) {
        self.vault = vault; self.lifecycle = lifecycle; self.context = context; self.clock = clock
    }
    public nonisolated var requestContext: RequestContext { context }

    /// Fails with `.stale` once the account generation changed, `.signedOut` when
    /// the record no longer holds a usable session, `.keychain` on a local fault.
    public func playerCookies() async throws(MusicSessionError) -> [HTTPCookie] {
        let (_, session) = try await current()
        return session.cookies.compactMap(Self.cookie)
    }

    /// Merges rotation from the player store. Returns whether the record changed.
    @discardableResult
    public func recordRotation(_ cookies: [HTTPCookie]) async throws(MusicSessionError) -> Bool {
        var (reference, session) = try await current()
        guard session.merge(MusicCookieSession.updates(from: cookies), now: clock.now()) else { return false }
        // A rotation must never write a record that is no longer signed in.
        guard session.isUsable(at: clock.now()) else { return false }
        try await fence()
        do { try await vault.replace(reference, with: session.encoded(), context: context) }
        catch { throw (error as? DomainError) == .staleContext ? .stale : .keychain }
        return true
    }

    private func fence() async throws(MusicSessionError) {
        guard let lifecycle, await lifecycle.accepts(context) else { throw .stale }
    }
    private func current() async throws(MusicSessionError) -> (CredentialReference, MusicCookieSession) {
        try await fence()
        guard let lifecycle, let account = context.account,
              case .success(let stored) = await lifecycle.reference(for: account, context: context).outcome,
              let reference = stored else { throw .signedOut }
        let bytes: Data
        do { bytes = try await vault.read(reference, context: context) }
        catch { throw (error as? DomainError) == .staleContext ? .stale : .keychain }
        let session = try MusicCookieSession.decode(bytes, accountID: account.accountID)
        guard session.isUsable(at: clock.now()) else { throw .signedOut }
        return (reference, session)
    }

    static func cookie(_ value: MusicSessionCookie) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: value.name, .value: value.value, .domain: ".youtube.com",
            .path: value.path.isEmpty ? "/" : value.path, .secure: "TRUE",
        ]
        if let expires = value.expires { properties[.expires] = expires }
        if httpOnlyNames.contains(value.name) { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        return HTTPCookie(properties: properties)
    }
}
