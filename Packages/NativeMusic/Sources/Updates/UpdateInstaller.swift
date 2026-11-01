import Foundation

/// An explicit request to restart into the update, made by a person pressing the restart button. The initializer is private to this file; the only way
/// to get one is `fromPersonAction()`, and `UpdaterGuardTests` sweeps the sources so that only the Restart to Update button in Settings
/// (`UpdatesSettingsSection`) calls it. A timer, a feed, a check or a background task never does.
public struct RestartConfirmation: Sendable {
    private init() {}
    public static func fromPersonAction() -> RestartConfirmation { RestartConfirmation() }
}

public protocol AppRelaunching: Sendable {
    /// Starts the updated app, then ends the running one through its normal bounded quit.
    @MainActor func relaunch(updatedAppAt url: URL)
}

/// Replaces the installed app with the staged one. Every refusal happens BEFORE anything is replaced; the replacement itself is one atomic
/// filesystem exchange, so a failure leaves the old app exactly as it was.
public final class BundleInstaller: @unchecked Sendable {
    private let signature: any CodeSignatureChecking
    private let info: any BundleInfoReading
    let files: UpdateFiles
    public init(signature: any CodeSignatureChecking, info: any BundleInfoReading = PlistBundleInfoReader()) { self.signature = signature; self.info = info; files = .standard }
    init(signature: any CodeSignatureChecking, info: any BundleInfoReading = PlistBundleInfoReader(), files: UpdateFiles) { self.signature = signature; self.info = info; self.files = files }

    /// - Parameters:
    ///   - playbackActive: asked three times (before anything, after verification, and immediately before the exchange). Playing OR about to play counts.
    /// - Returns: where the new app now is (the old app's location).
    public func install(_ staged: StagedUpdate, over installed: URL, running: RunningApplication, confirmation: RestartConfirmation?, playbackActive: @Sendable () -> Bool) throws -> URL {
        guard confirmation != nil else { throw UpdateRejection.restartNotRequested }
        guard !playbackActive() else { throw UpdateRejection.playbackActive }
        let app = URL(fileURLWithPath: staged.appPath)
        // The staged app must still be a strictly newer build of THIS app, whatever was recorded when it was staged.
        let found = try info.read(app: app)
        guard found.identifier == running.bundleIdentifier, found.identifier == staged.bundleIdentifier else { throw UpdateRejection.bundleMismatch("identifier") }
        guard let version = AppVersion(found.version), version.description == staged.version, Int(found.build) == staged.build else { throw UpdateRejection.bundleMismatch("version") }
        guard version > running.version, staged.build > running.build else { throw UpdateRejection.notNewer }
        try signature.verify(app: app)
        let parent = installed.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else { throw UpdateRejection.installLocationNotWritable }
        guard !playbackActive() else { throw UpdateRejection.playbackActive }
        // Copy beside the installed app (same volume, so the exchange is atomic) and verify the COPY, which is what will run.
        var sibling = installed.deletingLastPathComponent().appendingPathComponent(UpdateFiles.siblingPrefix + UUID().uuidString + ".app", isDirectory: true)
        do {
            sibling = try files.copyBeside(app, installed: installed, name: sibling.lastPathComponent)
            try signature.verify(app: sibling)
            guard !playbackActive() else { throw UpdateRejection.playbackActive }
            let result = try files.exchange(installed: installed, withSibling: sibling)
            return result ?? installed
        } catch {
            files.removeSibling(sibling, installed: installed)
            throw (error as? UpdateRejection) ?? UpdateRejection.installLocationNotWritable
        }
    }
}
