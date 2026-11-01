import CryptoKit
import Domain
import Foundation

/// Values below are only ever serialized into the account's exact Keychain record.
/// Every ordinary/debug/reflected description is opaque so logs, errors, receipts
/// and test output cannot carry a cookie or SAPISID value by accident.
public protocol RedactedMusicSessionValue: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {}
public extension RedactedMusicSessionValue {
    nonisolated var description: String { "[redacted Music session]" }
    nonisolated var debugDescription: String { description }
    nonisolated var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

/// One `youtube.com` cookie from the app's own web sign-in store or a Music response.
public struct MusicSessionCookie: Codable, Sendable, Equatable, RedactedMusicSessionValue {
    public let name: String
    public let value: String
    public let path: String
    public let expires: Date?
    public init(name: String, value: String, path: String = "/", expires: Date?) {
        self.name = name; self.value = value; self.path = path; self.expires = expires
    }
}

/// The Music session: only the allowlisted `.youtube.com` cookies that the YouTube
/// Music web client presents to `music.youtube.com/youtubei/v1`, bound to one local
/// account. Provenance and time fields come from an injected wall clock.
public struct MusicCookieSession: Codable, Sendable, Equatable, RedactedMusicSessionValue {
    public static let origin = "https://music.youtube.com"
    public static let provenance = "accounts.google.com sign-in in an app-owned web view, continued to music.youtube.com"
    /// Authentication family plus the preference/consent cookies the web client sends.
    /// Tracking-only, analytics and unrelated Google-domain cookies are never copied.
    public static let allowedNames: Set<String> = [
        "SAPISID", "__Secure-1PAPISID", "__Secure-3PAPISID", "APISID",
        "SID", "HSID", "SSID", "__Secure-1PSID", "__Secure-3PSID",
        "__Secure-1PSIDTS", "__Secure-3PSIDTS", "SIDCC", "__Secure-1PSIDCC", "__Secure-3PSIDCC",
        "LOGIN_INFO", "PREF", "SOCS", "CONSENT", "VISITOR_INFO1_LIVE", "VISITOR_PRIVACY_METADATA",
    ]
    static let maximumCookies = 32
    static let maximumValueBytes = 4096
    static let maximumHeaderBytes = 16_384

    public let accountID: UUID
    public private(set) var cookies: [MusicSessionCookie]
    public let source: String
    public let capturedAt: Date
    public private(set) var rotatedAt: Date?

    /// Accepts only a cookie scoped to `youtube.com` (host-only or domain) whose name
    /// is allowlisted and whose value is header-safe. Domain spoofing is rejected.
    public static func accepts(name: String, domain: String, value: String) -> Bool {
        let host = domain.lowercased().hasPrefix(".") ? String(domain.lowercased().dropFirst()) : domain.lowercased()
        return host == "youtube.com" && allowedNames.contains(name) && isHeaderSafe(value)
    }
    static func isHeaderSafe(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumValueBytes
            && value.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7F && $0 != 0x3B && $0 != 0x2C && $0 != 0x22 && $0 != 0x5C }
    }

    /// Selects from every cookie the web store holds. Throws `.notSignedIn` unless a
    /// valid SAPISID-family and SID-family pair is present, so completion is never inferred.
    public init(accountID: UUID, cookies candidates: [HTTPCookie], now: Date) throws(MusicSessionError) {
        var selected: [String: MusicSessionCookie] = [:]
        for cookie in candidates where Self.accepts(name: cookie.name, domain: cookie.domain, value: cookie.value) {
            if let expiry = cookie.expiresDate, expiry <= now { continue }
            selected[cookie.name] = MusicSessionCookie(name: cookie.name, value: cookie.value, path: cookie.path, expires: cookie.expiresDate)
        }
        try self.init(accountID: accountID, selected: Array(selected.values), capturedAt: now)
    }
    init(accountID: UUID, selected: [MusicSessionCookie], capturedAt: Date) throws(MusicSessionError) {
        self.accountID = accountID; source = Self.provenance; self.capturedAt = capturedAt
        cookies = selected.sorted { $0.name < $1.name }
        guard cookies.count <= Self.maximumCookies else { throw .invalidSession }
        guard isUsable(at: capturedAt) else { throw .notSignedIn }
        guard cookieHeader.utf8.count <= Self.maximumHeaderBytes else { throw .invalidSession }
    }

    private func cookie(_ name: String) -> MusicSessionCookie? { cookies.first { $0.name == name } }
    /// The website hashes `__Secure-3PAPISID` when present and `SAPISID` otherwise.
    public var sapisid: String? { (cookie("__Secure-3PAPISID") ?? cookie("SAPISID"))?.value }
    /// Earliest expiry of the cookies that authenticate the session.
    public var expiresAt: Date? {
        ["SAPISID", "__Secure-3PAPISID", "SID", "__Secure-3PSID"].compactMap { cookie($0)?.expires }.min()
    }
    public func isUsable(at now: Date) -> Bool {
        let live = cookies.filter { $0.expires.map { $0 > now } ?? true }.map(\.name)
        return (live.contains("SAPISID") || live.contains("__Secure-3PAPISID"))
            && (live.contains("SID") || live.contains("__Secure-3PSID"))
    }
    public var cookieHeader: String { cookies.map { $0.name + "=" + $0.value }.joined(separator: "; ") }

    /// Applies Google's rotation from a Music response or the web store observer.
    /// Allowlisted names only; an expired Set-Cookie deletes. Returns whether anything changed.
    @discardableResult
    public mutating func merge(_ updates: [MusicSessionCookie], now: Date) -> Bool {
        var byName = Dictionary(uniqueKeysWithValues: cookies.map { ($0.name, $0) })
        var changed = false
        for update in updates where Self.allowedNames.contains(update.name) {
            if let expiry = update.expires, expiry <= now {
                if byName.removeValue(forKey: update.name) != nil { changed = true }
            } else if Self.isHeaderSafe(update.value), byName[update.name] != update {
                byName[update.name] = update; changed = true
            }
        }
        guard changed, byName.count <= Self.maximumCookies else { return false }
        cookies = byName.values.sorted { $0.name < $1.name }; rotatedAt = now
        return true
    }
    /// Filters raw response/web-store cookies to allowlisted `youtube.com` names.
    /// Deletions (past expiry) are kept so `merge` can remove the cookie.
    public static func updates(from cookies: [HTTPCookie]) -> [MusicSessionCookie] {
        cookies.compactMap { cookie in
            let domain = cookie.domain.lowercased()
            let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            guard host == "youtube.com", allowedNames.contains(cookie.name), cookie.value.utf8.count <= maximumValueBytes else { return nil }
            return MusicSessionCookie(name: cookie.name, value: cookie.value, path: cookie.path, expires: cookie.expiresDate)
        }
    }

    func encoded() throws(MusicSessionError) -> Data {
        do { return try JSONEncoder().encode(self) } catch { throw .invalidSession }
    }
    static func decode(_ data: Data, accountID: UUID) throws(MusicSessionError) -> MusicCookieSession {
        guard data.count <= 131_072, let value = try? JSONDecoder().decode(MusicCookieSession.self, from: data),
              value.accountID == accountID, value.source == provenance, value.cookies.count <= maximumCookies else { throw .invalidSession }
        return value
    }
}

/// `SAPISIDHASH <ts>_<sha1(ts + " " + SAPISID + " " + origin)>`, as the website sends.
public enum SAPISIDHash {
    public static func value(timestamp: Int, sapisid: String, origin: String = MusicCookieSession.origin) -> String {
        let digest = Insecure.SHA1.hash(data: Data("\(timestamp) \(sapisid) \(origin)".utf8))
        return "\(timestamp)_" + digest.map { String(format: "%02x", $0) }.joined()
    }
    public static func authorization(timestamp: Int, sapisid: String, origin: String = MusicCookieSession.origin) -> String {
        "SAPISIDHASH " + value(timestamp: timestamp, sapisid: sapisid, origin: origin)
    }
}

/// Fixed local categories only. No case carries a cookie, header, URL or server text.
public enum MusicSessionError: Error, Sendable, Equatable, CustomStringConvertible {
    case notSignedIn, invalidSession, signedOut, unrecognised, oversized, network, rateLimited, server
    case cancelled, timedOut, stale, differentAccount, duplicateAccount, policy, cleanupRequired, keychain
    public var description: String { "music session \(self.category)" }
    public var category: String {
        switch self {
        case .notSignedIn: "not-signed-in"
        case .invalidSession: "invalid-session"
        case .signedOut: "signed-out"
        case .unrecognised: "unrecognised"
        case .oversized: "oversized"
        case .network: "network"
        case .rateLimited: "rate-limited"
        case .server: "server"
        case .cancelled: "cancelled"
        case .timedOut: "timed-out"
        case .stale: "stale"
        case .differentAccount: "different-account"
        case .duplicateAccount: "duplicate-account"
        case .policy: "policy"
        case .cleanupRequired: "cleanup-required"
        case .keychain: "keychain"
        }
    }
}
