import Domain
import Foundation

/// Every sentence the Downloads screen and the item notes use. One place, so the String Catalog and the screens agree.
public enum DownloadsText {
    /// Shown at a YouTube Music item and on the Downloads screen. Never a button.
    public static var youTubeMusicExplanation: String { String(localized: "YouTube Music doesn’t offer downloads on Mac.") }
    public static var youTubeMusicDetail: String {
        String(localized: "Its songs play through YouTube Music and aren’t kept on this Mac. Audio files you add here are kept encrypted on this Mac, and you can play them from this screen.")
    }
    public static func phase(_ phase: DownloadPhase) -> String {
        switch phase {
        case .queued: String(localized: "Queued")
        case .resolving: String(localized: "Preparing")
        case .downloading: String(localized: "Downloading")
        case .paused: String(localized: "Paused")
        case .validating: String(localized: "Checking")
        case .available: String(localized: "Downloaded")
        case .renewing: String(localized: "Renewing")
        case .expired: String(localized: "Expired")
        case .failed: String(localized: "Failed")
        }
    }
    public static func pause(_ cause: DownloadPauseCause) -> String {
        switch cause {
        case .userPaused: String(localized: "Paused by you")
        case .offline: String(localized: "Waiting for a network connection")
        case .constrainedNetwork: String(localized: "Waiting: Low Data Mode is on for this connection")
        case .expensiveNetwork: String(localized: "Waiting: this connection is metered")
        case .storageBudgetFull: String(localized: "Download storage is full")
        case .volumeReserve: String(localized: "Not enough free space on this Mac")
        case .smartCapReached: String(localized: "Automatic downloads reached their limit")
        case .diskFull: String(localized: "The disk is full")
        case .accountUnavailable: String(localized: "Sign in again to continue")
        }
    }
    public static func failure(_ failure: DownloadFailure) -> String {
        switch failure {
        case .retriesExhausted: String(localized: "Couldn’t finish after several tries")
        case .corruptBytes: String(localized: "The saved copy was damaged and was removed")
        case .missingKey: String(localized: "The key for this download is no longer available")
        case .accountRevoked: String(localized: "This account signed out, so its downloads were removed")
        case .sourceUnavailable: String(localized: "The source is no longer available")
        case .permissionDenied: String(localized: "The source no longer allows keeping this item")
        case .storageUnavailable: String(localized: "Storage wasn’t available")
        }
    }
    public static func action(_ action: DownloadAction) -> String {
        switch action {
        case .play: String(localized: "Play")
        case .pause: String(localized: "Pause")
        case .resume: String(localized: "Resume")
        case .retry: String(localized: "Try Again")
        case .cancel: String(localized: "Cancel")
        case .remove: String(localized: "Remove Download")
        case .renew: String(localized: "Renew")
        case .downloadAgain: String(localized: "Download Again")
        case .pin: String(localized: "Keep on This Mac")
        case .unpin: String(localized: "Stop Keeping")
        case .downloadOnThisNetwork: String(localized: "Download on This Connection")
        }
    }
    public static func storageChoice(_ choice: DownloadStorageChoice) -> String {
        switch choice {
        case .raiseBudget: String(localized: "Raise the storage limit")
        case .removeDownloads: String(localized: "Remove downloads you no longer need")
        case .removeAutomaticDownloads: String(localized: "Remove automatic downloads")
        case .freeDiskSpace: String(localized: "Free disk space on this Mac")
        }
    }
    public static func refusal(_ error: DomainError, subject: String?) -> String {
        switch error {
        case .unauthorized: String(localized: "Select a signed-in account first, then try again.")
        case .unsupported: String(localized: "That item can’t be kept. Choose an audio file.")
        case .forbidden: String(localized: "Automatic downloads are off. Turn on Smart Downloads first.")
        case .invalidInput: String(localized: "That change isn’t possible right now.")
        default: String(localized: "That didn’t work. Nothing was changed. Try again.")
        }
    }
    public static var smartUnavailable: String { String(localized: "Smart Downloads isn’t available yet: nothing on this Mac can suggest items to keep. Nothing is downloaded automatically.") }
    public static func bytes(_ count: Int64) -> String { count.formatted(.byteCount(style: .file)) }
}
