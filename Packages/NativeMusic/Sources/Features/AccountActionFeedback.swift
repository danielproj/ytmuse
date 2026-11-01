import SwiftUI
import AccountSession

/// Fixed local text only; never render an upstream error description or URL.
public enum GoogleAuthorizationFeedback {
    public static func message(for error: DesktopOAuthError) -> String {
        switch error {
        case .missingClientSecret: String(localized: "Google requires this app’s client secret. The developer must provision its secure configuration before retrying. No Music connection was verified.")
        case .invalidClient, .invalidConfiguration, .configurationMissing: String(localized: "Google client configuration is unavailable or was rejected. The developer must check this app’s registration.")
        case .invalidRequest: String(localized: "Google rejected the authorization request. The developer must check this app’s OAuth configuration.")
        case .revoked: String(localized: "Google authorization expired, was revoked, or its code was rejected. Try authorizing again.")
        case .networkFailure: String(localized: "Google authorization could not reach the server. Check the connection and retry.")
        case .rateLimited: String(localized: "Google is limiting authorization requests. Wait before retrying.")
        case .temporarilyUnavailable: String(localized: "Google authorization is temporarily unavailable. Retry later.")
        case .denied: String(localized: "Google authorization was denied. No Music connection was verified.")
        case .expired: String(localized: "Google authorization timed out. Try again.")
        case .stale: String(localized: "Google authorization was cancelled or replaced. Try again when ready.")
        case .invalidCallback: String(localized: "The Google callback was not accepted. No Music connection was verified.")
        case .invalidGrant: String(localized: "The Google response could not be verified. No Music connection was verified.")
        default: String(localized: "Google authorization could not finish. No Music connection was verified. Try again.")
        }
    }
}
/// Both native surfaces render exactly this observable message/pending state.
public struct AccountActionFeedback: View {
    private let model: AccountsModel
    public init(model: AccountsModel) { self.model = model }
    public var body: some View {
        VStack {
            if let message = model.message {
                Label(message, systemImage: "exclamationmark.triangle").accessibilityIdentifier("accountError")
            }
            if let pending = model.pendingMessage { ProgressView(pending).controlSize(.small) }
        }
    }
}
