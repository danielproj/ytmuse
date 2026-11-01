import Foundation
import Testing
import Domain
import Playback
@testable import AccountSession
@testable import Diagnostics
@testable import Features
@testable import AppShell

/// Strings that stand for things a diagnostic must never carry. Every one contains "canary" so a single lowercase search finds any survivor.
enum Canary {
    static let email = "pat.canary@example.org"
    static let bearer = "ya29.CANARYbearerTOKEN0123456789abcdefghij"
    static let sapisid = "CANARYsapisid0123456789/AbCdEfGhIj"
    static let signedURL = "https://rr3---sn-canary.googlevideo.com/videoplayback?expire=1999999999&sig=CANARYsig&lsig=CANARYlsig&id=o-CANARYid&q=whisper%20canary"
    static let playlist = "Mum's Canary 60th Mix"
    static let search = "my secret canary search"
    static let accountName = "Pat Canary"
    static let handle = "@patcanary"
    static let path = "/Users/patcanary/Music/canary.m4a"
    static let jwt = "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJjYW5hcnkifQ.CANARYsignature123"
    static let all = [email, bearer, sapisid, signedURL, playlist, search, accountName, handle, path, jwt]
    static func survivors(in text: String) -> [String] {
        let lowered = text.lowercased()
        return ["canary", "example.org", "googlevideo", "ya29", "eyj"].filter { lowered.contains($0) }
    }
}

struct LeakyError: Error, CustomStringConvertible {
    var description: String {
        "request to \(Canary.signedURL) failed for \(Canary.email); Authorization: Bearer \(Canary.bearer); Cookie: \(Canary.sapisid); SAPISID=\(Canary.sapisid); "
            + "token \(Canary.jwt); while opening “\(Canary.playlist)” after searching \(Canary.search) as \(Canary.accountName) (\(Canary.handle)) at \(Canary.path)"
    }
}

/// T27.4. Redaction as text, then the same canaries fed through the real inputs.
@Suite struct DiagnosticRedactionTests {
    static let context = RedactionContext(privateStrings: [Canary.playlist, Canary.search, Canary.accountName, Canary.handle, "patcanary"])

    @Test func everyShapeASecretTakesIsRemoved() {
        let lines = [
            "Cookie: SID=abc; \(Canary.sapisid); HSID=xyz", "set-cookie: __Secure-1PSID=CANARYvalue; Path=/", "Authorization: Bearer \(Canary.bearer)", "authorization=Basic Q0FOQVJZOnBhc3M=",
            "x-goog-authuser: 0 x-goog-api-key: CANARYkey", "got token \(Canary.jwt) in the reply", "access_token=\(Canary.bearer)&refresh_token=\(Canary.bearer)",
            "GET \(Canary.signedURL) -> 403", "redirected to https://user:canarypass@host.example/path?sig=CANARYsig#frag", "mail to \(Canary.email) and pat.canary%40example.org and pat.canary&#64;example.org",
            "{\"access_token\": \"\(Canary.bearer)\", \"q\": \"\(Canary.search)\", \"email\": \"\(Canary.email)\"}", "opened \(Canary.path)", "a long opaque run abcdefghijklmnopqrstuvwxyz0123456789ABCDEF-canary here",
            "SAPISIDHASH 1700000000_CANARYhash0123456789abcdef", "search_query=\(Canary.search.replacingOccurrences(of: " ", with: "+"))", "q=\(Canary.search.replacingOccurrences(of: " ", with: "%20"))",
        ]
        for line in lines {
            let redacted = DiagnosticRedactor.redact(line, context: Self.context)
            #expect(Canary.survivors(in: redacted).isEmpty, "\(line)\n→ \(redacted)")
            #expect(DiagnosticRedactor.redact(redacted, context: Self.context) == redacted, "idempotent: \(redacted)")
        }
    }
    @Test func privateNamesAreFoundWhateverFormTheyTake() {
        let name = "Mum’s Café Mix 2026"
        let context = RedactionContext(privateStrings: [name])
        for form in [name, name.uppercased(), name.lowercased(), "Mum’s Cafe Mix 2026", name.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!, name.replacingOccurrences(of: " ", with: "+"),
                     "\"" + name + "\"", String(data: try! JSONEncoder().encode(name), encoding: .utf8)!.dropFirst().dropLast().description] {
            #expect(!DiagnosticRedactor.redact("opened [\(form)] ok", context: context).lowercased().contains("caf"), "form: \(form)")
        }
        #expect(DiagnosticRedactor.redact("a b", context: RedactionContext(privateStrings: ["a"])) == "a b", "a one-letter private string is ignored, not erased everywhere")
    }
    @Test func whatIsNotSecretIsKept() {
        let line = "adapter web-session-1 on macOS 27.0 state=paused volume=0.5 host music.youtube.com category sourceOutage at 2026-11-01T10:00:00Z"
        #expect(DiagnosticRedactor.redact(line) == line)
        #expect(DiagnosticRedactor.redact("see https://music.youtube.com/watch?v=abc") == "see https://music.youtube.com/<redacted>", "the host stays: network destinations are enumerated (SEC02)")
    }
    @Test func theLogRedactsAtRecordTimeAndAgainAtExportWithWhatItLearnedSince() {
        nonisolated(unsafe) var known: Set<String> = []
        let log = DiagnosticLog(context: { RedactionContext(privateStrings: known) })
        log.record(.sourceOutage, component: "adapter", detail: "no answer while loading Late Night Canary List")
        #expect(log.snapshot()[0].detail.contains("Canary List"), "not yet known to be private")
        known = ["Late Night Canary List"]
        #expect(!log.snapshot()[0].detail.contains("Canary"), "a name learned later still scrubs the earlier line")
    }
    @Test func theLogIsBoundedInEntriesAgeAndSizeAndKeepsOnlyAVocabularyForComponents() {
        nonisolated(unsafe) var now = Date(timeIntervalSince1970: 1_000_000)
        let log = DiagnosticLog(limits: .init(maxEntries: 5, maxAge: 100, maxDetailLength: 40), clock: { now })
        for index in 0..<12 { log.record(.storage, component: "files", detail: String(repeating: "x", count: 200) + "\(index)") }
        #expect(log.count == 5 && log.snapshot().allSatisfy { $0.detail.count <= 41 })
        log.record(.storage, component: "Playlist: \(Canary.playlist)", detail: "")
        #expect(log.snapshot().last?.component == "unknown", "a component is a short identifier, never a title")
        now = now.addingTimeInterval(500)
        #expect(log.count == 0, "old entries age out")
        let ids = (0..<20).map { _ in log.record(.internalError, component: "x").id }
        #expect(Set(ids).count == 20 && ids.allSatisfy { $0.count == 12 }, "opaque local correlation ids")
    }
}

/// The same canaries through the real inputs: the private-context collector, the search recents, an error's own description, a capability status string and a
/// changed setting. Happy path and error path, preview and export.
@Suite @MainActor struct SupportBundleTests {
    static func proof() throws -> MusicProofState {
        .signedIn(MusicAccountProof(identity: MusicAccountIdentity(serviceID: "UCsyntheticCanary", displayName: Canary.accountName, handle: Canary.handle, photoURL: URL(string: "https://yt3.ggpht.com/canary-avatar")),
                                    library: MusicLibraryPlaylists(playlists: [MusicLibraryPlaylist(id: "PLcanary", title: Canary.playlist, countText: "12 songs", itemCount: 12)], complete: true), avatar: nil))
    }
    func center(storage: @escaping @MainActor () async throws -> DiagnosticsReport.Storage = { .init(artworkCacheBytes: 100, pinnedDownloadBytes: 200, automaticDownloadBytes: 0, unlistedDownloadBytes: 0) },
                scratch: Scratch) throws -> (DiagnosticsCenter, UserDefaults, String) {
        let suite = "ytmuse-diag-test-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        // The real search recents record the term; the real collector turns the live objects into the context.
        SearchRecents(defaults: defaults, scope: { "x" }).record(query: Canary.search)
        let identities = [LocalIdentity(account: try syntheticAccount(name: Canary.accountName))]
        let proof = try Self.proof()
        nonisolated(unsafe) let shared = defaults
        let log = DiagnosticLog(context: { PrivateContext.make(identities: identities, proof: proof, searchTerms: SearchRecents.recordedTerms(defaults: shared)) })
        var sources = DiagnosticsCenter.Sources()
        sources.adapterVersion = "9.9.9-test"
        sources.capabilityStatus = { "Signed in as \(Canary.accountName) via \(Canary.signedURL)" }
        sources.accounts = { identities.count }
        sources.storage = storage
        sources.changedSettings = { [SettingChange(id: "newPlaylistVisibility", value: Canary.playlist)] }
        sources.privateStrings = { PrivateContext.make(identities: identities, proof: proof, searchTerms: SearchRecents.recordedTerms(defaults: shared)).privateStrings }
        return (DiagnosticsCenter(log: log, profiler: LocalProfiler(directory: scratch.url.appendingPathComponent("diagnostics")), sources: sources), defaults, suite)
    }

    @Test func thePreviewAndTheExportCarryNoSecretEmailPrivateNameSearchOrSignedURL() async throws {
        let scratch = try Scratch(); defer { scratch.cleanup() }
        let (center, defaults, suite) = try center(scratch: scratch); defer { defaults.removePersistentDomain(forName: suite) }
        center.log.record(.sourceOutage, component: "adapter", detail: String(describing: LeakyError()))
        center.log.record(.playbackFailure, component: "player", detail: LeakyError().description)
        let bundle = await center.bundle()
        #expect(Canary.survivors(in: bundle.text).isEmpty, "\(Canary.survivors(in: bundle.text)) in:\n\(bundle.text.prefix(1500))")
        // Not vacuous: the report really carried them, and the redactor really removed them.
        #expect(bundle.redactions > 0 && bundle.text.contains("<redacted>") && bundle.text.contains("sourceOutage") && bundle.text.contains("9.9.9-test"))
        #expect(bundle.text.contains("<private>"), "the private names were matched from the live objects")
        // What was previewed is what is saved.
        let file = scratch.url.appendingPathComponent("bundle.json")
        let written = try bundle.export(to: file)
        let readBack = try Data(contentsOf: file)
        #expect(written == bundle.byteCount && readBack == bundle.data)
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)
        #expect(Canary.survivors(in: try String(contentsOf: file, encoding: .utf8)).isEmpty)
    }

    @Test func theErrorPathRedactsToo() async throws {
        let scratch = try Scratch(); defer { scratch.cleanup() }
        let (center, defaults, suite) = try center(storage: { throw LeakyError() }, scratch: scratch); defer { defaults.removePersistentDomain(forName: suite) }
        let bundle = await center.bundle()
        #expect(bundle.sections == ["failure"] && bundle.text.contains("internalError") && bundle.text.contains("could not be built"))
        #expect(Canary.survivors(in: bundle.text).isEmpty, Comment(rawValue: bundle.text))
        // The failure was logged, redacted, for the next bundle.
        #expect(center.log.snapshot().contains { $0.category == .internalError } && Canary.survivors(in: center.log.snapshot().map(\.detail).joined()).isEmpty)
        // And a failure made without any context still removes the pattern-shaped canaries.
        let plain = SupportBundle.makeFailure(category: .storage, component: "x", error: LeakyError().description, generatedAt: Date(), context: .empty)
        #expect(!plain.text.contains(Canary.email) && !plain.text.contains(Canary.bearer) && !plain.text.contains("googlevideo"))
    }

    @Test func exportWritesOnlyToTheInjectedDestinationAndRefusesAnythingElse() async throws {
        let scratch = try Scratch(); defer { scratch.cleanup() }
        let bundle = SupportBundle.makeFailure(category: .storage, component: "x", error: "plain", generatedAt: Date(), context: .empty)
        #expect(throws: SupportBundle.ExportError.destinationIsADirectory) { try bundle.export(to: scratch.url) }
        #expect(throws: SupportBundle.ExportError.notAFileURL) { try bundle.export(to: URL(string: "https://example.invalid/x")!) }
        let huge = SupportBundle(text: String(repeating: "x", count: SupportBundle.maxBytes + 1), redactions: 0, sections: [])
        #expect(throws: SupportBundle.ExportError.tooLarge) { try huge.export(to: scratch.url.appendingPathComponent("huge.json")) }
        #expect(throws: SupportBundle.ExportError.writeFailed) { try bundle.export(to: scratch.url.appendingPathComponent("missing/dir/x.json")) }
        let left = try FileManager.default.contentsOfDirectory(atPath: scratch.url.path)
        #expect(left.isEmpty, "nothing was written anywhere on refusal")
    }

    @Test func mediaFilesAreNotInputsAndTheBundleIsBounded() async throws {
        let scratch = try Scratch(); defer { scratch.cleanup() }
        // 6 MB of "downloaded media" and a cookie jar beside the diagnostics directory.
        try Data(repeating: 0x41, count: 6 << 20).write(to: scratch.url.appendingPathComponent("kept-song-CANARYmedia.m4a"))
        try Data("Cookie: SAPISID=CANARYjar".utf8).write(to: scratch.url.appendingPathComponent("cookies.txt"))
        let (center, defaults, suite) = try center(scratch: scratch); defer { defaults.removePersistentDomain(forName: suite) }
        for index in 0..<400 { center.log.record(.sourceOutage, component: "adapter", detail: String(repeating: "word \(index) ", count: 80)) }
        let bundle = await center.bundle()
        #expect(bundle.byteCount <= SupportBundle.maxBytes && !bundle.text.contains("CANARYmedia") && !bundle.text.contains("CANARYjar"))
        #expect(!bundle.text.contains("kept-song"))
        let report = try await center.report()
        #expect(report.recentErrors.count <= 30, "the report carries at most the last 30 entries")
        #expect(report.exclusions.contains { $0.contains("No media files") } && report.exclusions.contains { $0.contains("cookies") })
    }
}

/// T27.5 / DIAG01 / DIAG02.
@Suite @MainActor struct DiagnosticsReportTests {
    func report(previousCrash: Bool = false, _ entries: [(DiagnosticCategory, String)] = [], quality: MediaQualityObservation = .unknown("Nothing is playing.")) async throws -> DiagnosticsReport {
        let scratch = try Scratch(); defer { scratch.cleanup() }
        let log = DiagnosticLog()
        var sources = DiagnosticsCenter.Sources(); sources.adapterVersion = "web-session-1"; sources.playback = { .init(engine: "YouTube Music web player (hidden)", engineVersion: "web", quality: quality) }
        let center = DiagnosticsCenter(log: log, profiler: LocalProfiler(directory: scratch.url), sources: sources)
        if previousCrash { center.noteLaunch(previous: .endedUnexpectedly(since: Date())) }
        for (category, component) in entries { log.record(category, component: component, detail: "x") }
        return try await center.report()
    }

    @Test func theReportShowsTheAdapterVersionTheEngineAndWhatIsUnknownAboutQuality() async throws {
        let unknown = MediaQualityObservation.unknown("The YouTube Music web player does not report this to the app.")
        let value = try await report(quality: unknown)
        #expect(value.adapter.version == "web-session-1" && value.playback.engine.contains("YouTube Music") && value.app.version.isEmpty == false && !value.app.osVersion.isEmpty)
        #expect(unknown.unknownFields == ["codec", "bitrate", "sample rate", "output route"] && value.playback.quality.codec.unknownReason?.contains("does not report") == true)
        let known = MediaQualityObservation(codec: .value("aac"), bitrateKbps: .value(256), sampleRateHz: .value(48_000), route: .unknown(reason: "The system output could not be read."))
        #expect(known.unknownFields == ["output route"] && known.codec.value == "aac")
        do { let r = try await report(quality: known); #expect(r.playback.quality == known) }
    }
    @Test func aSourceOutageIsToldApartFromALocalCrash() async throws {
        do { let r = try await report(); #expect(r.faultVerdict == .noFaults) }
        do { let r = try await report([(.sourceOutage, "adapter")]); #expect(r.faultVerdict == .sourceOutage) }
        do { let r = try await report([(.sourceChanged, "adapter")]); #expect(r.faultVerdict == .sourceOutage, "a changed response is the service's doing too") }
        do { let r = try await report([(.networkOffline, "adapter")]); #expect(r.faultVerdict == .networkOffline) }
        do { let r = try await report([(.storage, "files")]); #expect(r.faultVerdict == .localFault) }
        let crashed = try await report(previousCrash: true, [(.sourceOutage, "adapter")])
        #expect(crashed.faultVerdict == .localCrash && crashed.previousRunEndedUnexpectedly && crashed.errorSummary.contains { $0.category == .localCrash }, "an ended-unexpectedly run wins over service faults")
        #expect(DiagnosticCategory.sourceOutage.origin == .source && DiagnosticCategory.localCrash.origin == .local && DiagnosticCategory.networkOffline.origin == .network && DiagnosticCategory.authExpired.origin == .user)
        #expect(Set(DiagnosticCategory.allCases.filter { $0.origin == .source }) == [.sourceOutage, .sourceChanged])
    }
    @Test func theRunMarkerSeesACleanQuitAndAMissingOne() throws {
        let scratch = try Scratch(); defer { scratch.cleanup() }
        let marker = RunMarker(directory: scratch.url)
        #expect(marker.begin() == .none)
        guard case .endedUnexpectedly = RunMarker(directory: scratch.url).begin() else { Issue.record("a run that never quit cleanly is reported"); return }
        marker.endCleanly()
        #expect(RunMarker(directory: scratch.url).begin() == .endedCleanly)
    }
    @Test func theClassifierMapsEveryServiceFaultToACategoryWithoutQuotingTheError() {
        let cases: [(MusicSessionError, DiagnosticCategory)] = [(.network, .networkOffline), (.rateLimited, .sourceOutage), (.server, .sourceOutage), (.timedOut, .sourceOutage), (.unrecognised, .sourceChanged), (.oversized, .sourceChanged),
                                                                (.signedOut, .authExpired), (.invalidSession, .authExpired), (.notSignedIn, .authExpired), (.keychain, .storage), (.policy, .policyRefusal)]
        for (error, category) in cases { #expect(FaultClassifier.category(for: error, component: "adapter")?.category == category, "\(error)") }
        #expect(FaultClassifier.category(for: LeakyError(), component: "adapter")?.category == .internalError && Canary.survivors(in: FaultClassifier.category(for: LeakyError(), component: "adapter")?.detail ?? "").isEmpty)
        // Review finding: a cancelled request is not a fault of anyone.
        #expect(FaultClassifier.category(for: CancellationError(), component: "adapter") == nil && FaultClassifier.category(for: MusicSessionError.cancelled, component: "adapter") == nil && FaultClassifier.category(for: URLError(.cancelled), component: "adapter") == nil)
        #expect(FaultClassifier.category(for: WebMusicFailure.loadFailed).category == .sourceOutage && FaultClassifier.category(for: WebMusicFailure.playerStopped).category == .localCrash)
        #expect(FaultClassifier.category(for: WebMusicFailure.signInRequired).category == .authExpired && FaultClassifier.category(for: WebMusicFailure.notPlayable(code: 150)).category == .playbackFailure)
    }
}

/// DIAG02: opt-in, local, bounded profiling.
@Suite struct ProfilerTests {
    @Test func offByDefaultRecordsNothingAndWritesNoFile() throws {
        let scratch = try Scratch(); defer { scratch.cleanup() }
        let profiler = LocalProfiler(directory: scratch.url)
        #expect(!profiler.isEnabled)
        profiler.record(.searchRequest, milliseconds: 5); _ = profiler.measure(.playbackStart) { 1 + 1 }
        let listing = try FileManager.default.contentsOfDirectory(atPath: scratch.url.path)
        #expect(profiler.summary().isEmpty && listing.isEmpty && profiler.status() == ProfilingStatus(enabled: false, sampleCount: 0, fileBytes: 0, maxFileBytes: 64 * 1024))
    }
    @Test func onItKeepsBoundedTimingsInOneSmallOwnerOnlyFileAndOffDeletesIt() throws {
        let scratch = try Scratch(); defer { scratch.cleanup() }
        let profiler = LocalProfiler(directory: scratch.url, limits: .init(maxSamplesPerEvent: 100, maxFileBytes: 1024))
        profiler.setEnabled(true)
        for index in 0..<5_000 { profiler.record(ProfileEvent.allCases[index % ProfileEvent.allCases.count], milliseconds: Double(index % 97)) }
        let status = profiler.status()
        #expect(status.enabled && status.fileBytes > 0 && status.fileBytes <= 1024, "\(status)")
        #expect(profiler.summary().values.allSatisfy { $0.recent.count <= 100 } && profiler.summary().values.reduce(0) { $0 + $1.count } == 5_000, "counts are kept; samples are bounded")
        let file = scratch.url.appendingPathComponent("profile.json")
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)
        // The file is CURRENT (shrunk to fit the cap, not left behind at the last size that fitted) and holds only the fixed vocabulary.
        let onDisk = try JSONDecoder().decode([String: LocalProfiler.Aggregate].self, from: Data(contentsOf: file))
        #expect(Set(onDisk.keys) == Set(ProfileEvent.allCases.map(\.rawValue)))
        for (name, aggregate) in onDisk { #expect(aggregate.count == profiler.summary()[ProfileEvent(rawValue: name)!]?.count, "\(name): the file's count is the live count") }
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("http") && !text.contains("/Users"))
        let expected = 5_000 / ProfileEvent.allCases.count + (5_000 % ProfileEvent.allCases.count > ProfileEvent.allCases.firstIndex(of: .searchRequest)! ? 1 : 0)
        profiler.record(.searchRequest, milliseconds: -1); profiler.record(.searchRequest, milliseconds: .nan)
        #expect(profiler.summary()[.searchRequest]?.count == expected, "invalid timings are not recorded")
        let neighbour = scratch.url.appendingPathComponent("someone-elses.txt"); try Data("x".utf8).write(to: neighbour)
        profiler.setEnabled(false)
        #expect(FileManager.default.fileExists(atPath: neighbour.path), "only its own file is ever deleted")
        #expect(!FileManager.default.fileExists(atPath: file.path) && profiler.summary().isEmpty && !profiler.isEnabled, "turning it off deletes the file")
    }
    @Test @MainActor func theProfilingSettingDrivesTheProfilerAndRestoreDefaultsTurnsItOff() async throws {
        let rig = try SettingsRig()
        let scratch = try Scratch(); defer { scratch.cleanup(); rig.cleanup() }
        let profiler = LocalProfiler(directory: scratch.url)
        SettingsOwners.attach(to: rig.store, shell: rig.shell, downloads: rig.downloads, downloadMirror: rig.mirror, outputs: { rig.outputs }, profiler: { profiler })
        try await rig.store.set("profiling", .bool(true))
        #expect(profiler.isEnabled && rig.defaults.bool(forKey: SettingsOwners.profilingKey) && rig.store.bool("profiling"))
        profiler.record(.playbackStart, milliseconds: 3)
        #expect(FileManager.default.fileExists(atPath: scratch.url.appendingPathComponent("profile.json").path))
        _ = try await rig.store.reset(.diagnostics)
        #expect(!profiler.isEnabled && !rig.store.bool("profiling") && !FileManager.default.fileExists(atPath: scratch.url.appendingPathComponent("profile.json").path))
    }
}
