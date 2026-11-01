import Diagnostics
import Domain
import Foundation

/// W27 (DIAG01, DIAG02, SEC03). Builds the Diagnostics screen's report and the support bundle from the app's live facts. Every input is a closure the
/// composition fills from the real owners; nothing here reads a store, a network or a file of its own except through them.
@MainActor final class DiagnosticsCenter {
    struct Sources {
        var appName = "YTMuse"
        var appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        var appBuild: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        var osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
        var architecture: String = {
            #if arch(arm64)
            "arm64"
            #else
            "x86_64"
            #endif
        }()
        var adapterName = "YouTube Music web session"
        var adapterVersion = "unknown"
        /// "Music session verified", "Session expired", "Not signed in": a state in words, no identity.
        var capabilityStatus: @MainActor () -> String = { "Not signed in" }
        var accounts: @MainActor () -> Int = { 0 }
        var playback: @MainActor () -> DiagnosticsReport.Playback = {
            DiagnosticsReport.Playback(engine: "None", engineVersion: "n/a", quality: .unknown("Nothing is playing."))
        }
        var storage: @MainActor () async throws -> DiagnosticsReport.Storage = { DiagnosticsReport.Storage(artworkCacheBytes: 0, pinnedDownloadBytes: 0, automaticDownloadBytes: 0, unlistedDownloadBytes: 0) }
        var changedSettings: @MainActor () -> [SettingChange] = { [] }
        /// Everything the app knows is private right now: account labels and handles, playlist names, search terms. Read at every build, so a name learned later still scrubs earlier lines.
        var privateStrings: @MainActor () -> Set<String> = { [] }
    }
    let log: DiagnosticLog
    let profiler: LocalProfiler
    var sources: Sources
    private(set) var previousRun: RunMarker.Previous
    private let clock: () -> Date
    init(log: DiagnosticLog, profiler: LocalProfiler, sources: Sources, previousRun: RunMarker.Previous = .none, clock: @escaping () -> Date = { Date() }) {
        self.log = log; self.profiler = profiler; self.sources = sources; self.previousRun = previousRun; self.clock = clock
    }
    var context: RedactionContext { RedactionContext(privateStrings: sources.privateStrings()) }

    /// A previous run that never reached its clean quit is recorded once, as a local crash.
    func noteLaunch(previous: RunMarker.Previous) {
        previousRun = previous
        if case .endedUnexpectedly = previous { log.record(.localCrash, component: "launch", detail: "The previous run ended without a clean quit.") }
    }

    func report() async throws -> DiagnosticsReport {
        let storage = try await sources.storage()
        var crashed = false
        if case .endedUnexpectedly = previousRun { crashed = true }
        return DiagnosticsReport(generatedAt: clock(),
            app: .init(name: sources.appName, version: sources.appVersion, build: sources.appBuild, osVersion: sources.osVersion, architecture: sources.architecture),
            adapter: .init(name: sources.adapterName, version: sources.adapterVersion, capabilityStatus: sources.capabilityStatus()),
            accounts: sources.accounts(), playback: sources.playback(), storage: storage, previousRunEndedUnexpectedly: crashed,
            errorSummary: log.summary(), recentErrors: Array(log.snapshot().suffix(30)), changedSettings: sources.changedSettings(), profiling: profiler.status())
    }
    /// The bundle the person previews and may export. On the error path (a source threw) the bundle still says so, redacted.
    func bundle() async -> SupportBundle {
        let ctx = context
        do { return SupportBundle.make(report: try await report(), context: ctx) }
        catch {
            log.record(.internalError, component: "diagnostics", detail: String(describing: error))
            return SupportBundle.makeFailure(category: .internalError, component: "diagnostics", error: String(describing: error), generatedAt: clock(), context: ctx)
        }
    }
}
