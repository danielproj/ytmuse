import AccountSession
import Diagnostics
import Foundation
import Playback

/// W27 (DIAG02). Turns the errors the app already has into diagnostic categories, so "the service did not answer" is never recorded as "the app broke" and the
/// other way round. Only a category, a component name and a fixed phrase come out: never the error's own text, which can carry a URL or a name.
enum FaultClassifier {
    struct Fault { let category: DiagnosticCategory; let component: String; let detail: String }
    static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? MusicSessionError) == .cancelled || (error as? URLError)?.code == .cancelled || (error as NSError).code == NSURLErrorCancelled && (error as NSError).domain == NSURLErrorDomain
    }
    static func category(for failure: WebMusicFailure) -> Fault {
        switch failure {
        case .signInRequired: Fault(category: .authExpired, component: "player", detail: "The player needs a fresh sign-in.")
        case .navigationRefused: Fault(category: .policyRefusal, component: "player", detail: "The player tried to leave YouTube Music; refused.")
        case .loadFailed: Fault(category: .sourceOutage, component: "player", detail: "The player page did not load.")
        case .notPlayable: Fault(category: .playbackFailure, component: "player", detail: "The service reported this item cannot play.")
        case .playerStopped: Fault(category: .localCrash, component: "player", detail: "The player's web content process ended.")
        case .pageReplaced: Fault(category: .internalError, component: "player", detail: "The player page was replaced.")
        case .sessionUnavailable: Fault(category: .authExpired, component: "player", detail: "The player's session was unavailable.")
        case .timedOut: Fault(category: .sourceOutage, component: "player", detail: "The player did not answer in time.")
        case .unsupportedBrowser, .notMusicApp: Fault(category: .sourceChanged, component: "player", detail: "The service's page was not the expected player.")
        case .shuffleFailed: Fault(category: .playbackFailure, component: "player", detail: "Shuffle did not apply.")
        }
    }
    /// nil for a cancellation: the person typed another letter or closed the page, and that is not a fault of anyone (Search cancels its in-flight request on every keystroke).
    static func category(for error: any Error, component: String) -> Fault? {
        if isCancellation(error) { return nil }
        if let session = error as? MusicSessionError {
            switch session {
            case .network: return Fault(category: .networkOffline, component: component, detail: "No network path to the service.")
            case .rateLimited: return Fault(category: .sourceOutage, component: component, detail: "The service is rate limiting this client.")
            case .server, .timedOut: return Fault(category: .sourceOutage, component: component, detail: "The service did not answer in time or reported a server fault.")
            case .unrecognised, .oversized: return Fault(category: .sourceChanged, component: component, detail: "The service answered in a shape the adapter does not recognise.")
            case .notSignedIn, .invalidSession, .signedOut: return Fault(category: .authExpired, component: component, detail: "The session is not signed in.")
            case .keychain, .cleanupRequired: return Fault(category: .storage, component: component, detail: "A credential could not be read or cleaned up.")
            case .policy: return Fault(category: .policyRefusal, component: component, detail: "A request was refused by policy.")
            case .cancelled: return nil
            case .stale, .differentAccount, .duplicateAccount: return Fault(category: .internalError, component: component, detail: "Stale or conflicting account state.")
            }
        }
        return Fault(category: .internalError, component: component, detail: "Unclassified failure.")
    }
}
