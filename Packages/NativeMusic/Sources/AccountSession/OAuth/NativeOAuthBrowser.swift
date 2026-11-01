import AppKit
import Foundation

/// Opens only the fixed Google authorization origin after DesktopOAuthFlow has
/// bound its callback. Never used on launch, refresh, expiry or a timer.
public struct NativeOAuthBrowser: OAuthBrowser {
    public init() {}
    public func open(_ authorizationURL: URL) async throws {
        guard authorizationURL.scheme == "https", authorizationURL.host == "accounts.google.com",
              authorizationURL.port == nil, authorizationURL.path == "/o/oauth2/v2/auth",
              authorizationURL.user == nil, authorizationURL.password == nil,
              authorizationURL.fragment == nil else { throw DesktopOAuthError.invalidConfiguration }
        try Task.checkCancellation()
        let opened = await MainActor.run { NSWorkspace.shared.open(authorizationURL) }
        guard opened else { throw DesktopOAuthError.invalidConfiguration }
    }
}
