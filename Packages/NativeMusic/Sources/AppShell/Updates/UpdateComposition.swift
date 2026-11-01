import AppKit
import Foundation
import Updates

// W30 (BUILD06, SEC09). Builds the updater for this launch. A source or Debug build has no feed, no pinned key and no release signature, so it is
// `unavailable` and never contacts anything; an isolated (test or QA) session is forced unavailable even if a feed were configured.

/// Starts the updated app, then ends this one through the normal checkpointed quit, so playback state is saved exactly as for any other quit.
struct SystemUpdateRelauncher: AppRelaunching {
    @MainActor func relaunch(updatedAppAt url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            MainActor.assumeIsolated { if error == nil { PlaybackApplicationDelegate.requestQuit() } }
        }
    }
}

@MainActor enum UpdateComposition {
    static func make(info: [String: Any], bundle: Bundle = .main, preferences: UserDefaults, isolated: Bool, requirement: String? = RunningSignature.designatedRequirement(),
                     stagingRoot: URL? = nil, playbackActive: @escaping @MainActor () -> Bool) -> UpdateController {
        let version = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init) ?? AppVersion("0.0.0")!
        let build = (info["CFBundleVersion"] as? String).flatMap(Int.init) ?? 0
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let running = RunningApplication(version: version, build: build, bundleIdentifier: bundle.bundleIdentifier ?? "", system: SystemVersion(major: os.majorVersion, minor: os.minorVersion, patch: os.patchVersion))
        let configuration = isolated ? nil : UpdateConfiguration(infoDictionary: info)
        let reason: UpdateUnavailableReason? = isolated ? .isolatedSession : (configuration != nil && requirement == nil ? .notSignedForUpdates : nil)
        let network = SystemUpdateNetwork.make()
        var stager: UpdateStager?
        var installer: BundleInstaller?
        if configuration != nil, reason == nil, let requirement {
            let checker = SecurityCodeSignatureChecker(requirement: requirement)
            let root = stagingRoot ?? (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?
                .appendingPathComponent(bundle.bundleIdentifier ?? "YTMuse", isDirectory: true).appendingPathComponent("Updates", isDirectory: true)
            if let root { stager = UpdateStager(root: root, network: network, extractor: HdiutilExtractor(), signature: checker) }
            installer = BundleInstaller(signature: checker)
        }
        return UpdateController(configuration: configuration, capability: reason, running: running, installedBundle: bundle.bundleURL, store: UserDefaultsUpdateStateStore(defaults: preferences),
                                network: network, stager: stager, installer: installer, relauncher: SystemUpdateRelauncher(), playbackActive: playbackActive)
    }
}

extension LocalAccountBootstrap {
    /// Wires the updater to the shell: the playback gate reads the one playback owner, and the hourly tick starts only when updates are available.
    func installUpdates() {
        let shell = shell
        #if DEBUG
        let isolated = IsolatedQAStorage.requested()
        #else
        let isolated = false
        #endif
        let controller = UpdateComposition.make(info: Bundle.main.infoDictionary ?? [:], preferences: shell.preferences, isolated: isolated,
                                                playbackActive: { [weak shell] in shell.map { $0.transport.isPlaying || $0.transport.isLoading } ?? false })
        shell.updates = controller
        if controller.isAvailable { controller.startPeriodicChecks() }
    }
}
