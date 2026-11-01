import CryptoKit
import Foundation
import Testing
@testable import Updates

/// A release whose asset is `bytes`: the length and SHA-256 are the real ones, as the signed feed would carry.
func offeredRelease(for bytes: Data, version: String = "1.2.0", build: Int = 120) throws -> FeedRelease {
    var b = FeedBuilder()
    var r = FeedBuilder.release(version: version, build: build)
    var asset = r["asset"] as! [String: Any]
    asset["length"] = bytes.count
    asset["sha256"] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    r["asset"] = asset
    b.releases = [r]
    return try FeedVerifier.verify(b.signed(), policy: b.policy, running: runningApp, now: testNow, lastAcceptedSequence: 0).offer!
}

/// T30.2: what happens to the downloaded bytes and the app inside them.
@Suite struct StagingTests {
    let scratch = ScratchFolder()
    let bytes = Data("a pretend disk image".utf8)
    func make(network: FakeNetwork = FakeNetwork(), extractor: FakeExtractor = FakeExtractor(), signature: FakeSignature = FakeSignature()) -> (UpdateStager, FakeNetwork, FakeExtractor, FakeSignature) {
        (UpdateStager(root: scratch.url.appendingPathComponent("Updates"), network: network, extractor: extractor, signature: signature), network, extractor, signature)
    }
    func stage(_ stager: UpdateStager, release: FeedRelease) async -> UpdateRejection? {
        do { _ = try await stager.stage(release, running: runningApp); return nil } catch { return error as? UpdateRejection }
    }

    @Test func aMatchingAssetIsStagedAndVerifiedInOrder() async throws {
        defer { scratch.remove() }
        let net = FakeNetwork(); net.asset = bytes
        let (stager, _, extractor, signature) = make(network: net)
        let record = try await stager.stage(try offeredRelease(for: bytes), running: runningApp)
        #expect(record.version == "1.2.0" && record.build == 120)
        #expect(extractor.calls == 1 && signature.calls == 1)
        #expect(stager.staged(running: runningApp) == record)
        #expect(marker(of: URL(fileURLWithPath: record.appPath)) == "version 1.2.0")
    }
    @Test func aStagingFolderThatIsNotItsOwnIsNeverWiped() async throws {
        defer { scratch.remove() }
        let precious = scratch.url.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: precious, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: precious.appendingPathComponent("file.txt"))
        let net = FakeNetwork(); net.asset = bytes
        let stager = UpdateStager(root: precious, network: net, extractor: FakeExtractor(), signature: FakeSignature())
        #expect(await stage(stager, release: try offeredRelease(for: bytes)) == .transport("staging folder"))
        stager.discard()
        #expect(try String(contentsOf: precious.appendingPathComponent("file.txt"), encoding: .utf8) == "keep")
        #expect(net.count == 0, "nothing was even downloaded")
    }
    @Test func aTamperedAssetIsRefusedBeforeAnythingIsOpened() async throws {
        defer { scratch.remove() }
        let net = FakeNetwork(); var tampered = bytes; tampered[3] ^= 0x01; net.asset = tampered
        let (stager, _, extractor, signature) = make(network: net)
        #expect(await stage(stager, release: try offeredRelease(for: bytes)) == .assetHashMismatch)
        #expect(extractor.calls == 0 && signature.calls == 0)               // hash first: an altered image is never mounted
        #expect(stager.staged(running: runningApp) == nil)
        #expect(!FileManager.default.fileExists(atPath: scratch.url.appendingPathComponent("Updates").path))
    }
    @Test func aTruncatedOrExtendedAssetIsRefused() async throws {
        defer { scratch.remove() }
        for changed in [bytes.dropLast(), bytes + Data([0])] {
            let net = FakeNetwork(); net.asset = Data(changed)
            let (stager, _, extractor, _) = make(network: net)
            #expect(await stage(stager, release: try offeredRelease(for: bytes)) == .assetLengthMismatch)
            #expect(extractor.calls == 0)
        }
    }
    @Test func theBundleInsideMustBeTheReleaseTheFeedDescribed() async throws {
        defer { scratch.remove() }
        let release = try offeredRelease(for: bytes)
        for (version, build, identifier, expected) in [("1.0.5", 120, runningApp.bundleIdentifier, UpdateRejection.bundleMismatch("version")),      // a downgrade smuggled in under a newer feed entry
                                                       ("1.2.0", 999, runningApp.bundleIdentifier, .bundleMismatch("build")),
                                                       ("1.2.0", 120, "evil.other.app", .bundleMismatch("identifier"))] {
            let net = FakeNetwork(); net.asset = bytes
            let extractor = FakeExtractor(); extractor.version = version; extractor.build = build; extractor.identifier = identifier
            let (stager, _, _, signature) = make(network: net, extractor: extractor)
            #expect(await stage(stager, release: release) == expected, "\(version) \(build) \(identifier)")
            #expect(signature.calls == 0)
            #expect(stager.staged(running: runningApp) == nil)
        }
    }
    @Test func aBundleThatIsNotNewerThanTheRunningAppIsRefused() async throws {
        defer { scratch.remove() }
        let net = FakeNetwork(); net.asset = bytes
        let (stager, _, _, _) = make(network: net)
        // The feed entry (1.2.0) is stale relative to a running app that has since become 1.2.0: not newer.
        let newer = RunningApplication(version: AppVersion("1.2.0")!, build: 120, bundleIdentifier: runningApp.bundleIdentifier, system: runningApp.system)
        do { _ = try await stager.stage(try offeredRelease(for: bytes), running: newer); Issue.record("staged a same-version release") } catch { #expect(error as? UpdateRejection == .notNewer) }
    }
    @Test func aFailedCodeSignatureCheckStagesNothing() async throws {
        defer { scratch.remove() }
        let net = FakeNetwork(); net.asset = bytes
        let signature = FakeSignature(); signature.failing = true
        let (stager, _, _, _) = make(network: net, signature: signature)
        #expect(await stage(stager, release: try offeredRelease(for: bytes)) == .codeSignature("invalid"))
        #expect(stager.staged(running: runningApp) == nil)
    }
    @Test func aTransportFailureLeavesNoStagingBehind() async throws {
        defer { scratch.remove() }
        let net = FakeNetwork(); net.failure = URLError(.notConnectedToInternet)
        let (stager, _, _, _) = make(network: net)
        #expect(await stage(stager, release: try offeredRelease(for: bytes)) == .transport("download"))
        #expect(!FileManager.default.fileExists(atPath: scratch.url.appendingPathComponent("Updates").path))
    }
    @Test func aStagingRecordForAnOlderOrOutsideAppIsDiscarded() async throws {
        defer { scratch.remove() }
        let net = FakeNetwork(); net.asset = bytes
        let (stager, _, _, _) = make(network: net)
        _ = try await stager.stage(try offeredRelease(for: bytes), running: runningApp)
        let caughtUp = RunningApplication(version: AppVersion("1.2.0")!, build: 120, bundleIdentifier: runningApp.bundleIdentifier, system: runningApp.system)
        #expect(stager.staged(running: caughtUp) == nil)                                  // the app was updated meanwhile
        #expect(!FileManager.default.fileExists(atPath: scratch.url.appendingPathComponent("Updates").path))
        _ = try await stager.stage(try offeredRelease(for: bytes), running: runningApp)
        // A record pointing outside the staging folder is not trusted.
        var record = try JSONDecoder().decode(StagedUpdate.self, from: Data(contentsOf: stager.recordURL))
        record = StagedUpdate(version: record.version, build: record.build, bundleIdentifier: record.bundleIdentifier, appPath: "/Applications/YTMuse.app", assetSHA256: record.assetSHA256)
        try JSONEncoder().encode(record).write(to: stager.recordURL)
        #expect(stager.staged(running: runningApp) == nil)
    }
}

/// T30.2: never installs during playback or without an explicit restart, and refuses everything before replacing anything.
@Suite struct InstallTests {
    let scratch = ScratchFolder()
    struct Fixture { let installed: URL; let staged: StagedUpdate; let installer: BundleInstaller; let signature: FakeSignature }
    func fixture(stagedVersion: String = "1.2.0", stagedBuild: Int = 120) throws -> Fixture {
        let applications = scratch.url.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let installed = applications.appendingPathComponent("YTMuse.app")
        try makeApp(at: installed, version: "1.0.0", build: 100)
        let stagedApp = scratch.url.appendingPathComponent("Updates/app/YTMuse.app")
        try makeApp(at: stagedApp, version: stagedVersion, build: stagedBuild)
        let record = StagedUpdate(version: stagedVersion, build: stagedBuild, bundleIdentifier: runningApp.bundleIdentifier, appPath: stagedApp.path, assetSHA256: "00")
        let signature = FakeSignature()
        return Fixture(installed: installed, staged: record, installer: BundleInstaller(signature: signature), signature: signature)
    }
    func attempt(_ f: Fixture, confirmation: RestartConfirmation? = .fromPersonAction(), playing: PlaybackFlag = PlaybackFlag()) -> UpdateRejection? {
        do { _ = try f.installer.install(f.staged, over: f.installed, running: runningApp, confirmation: confirmation, playbackActive: { playing.ask() }); return nil } catch { return error as? UpdateRejection }
    }
    func untouched(_ f: Fixture) -> Bool {
        marker(of: f.installed) == "version 1.0.0" &&
        ((try? FileManager.default.contentsOfDirectory(atPath: f.installed.deletingLastPathComponent().path)) ?? []).sorted() == ["YTMuse.app"]
    }

    @Test func aPersonsExplicitRestartInstallsTheStagedApp() throws {
        defer { scratch.remove() }
        let f = try fixture()
        #expect(attempt(f) == nil)
        #expect(marker(of: f.installed) == "version 1.2.0")
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.installed.deletingLastPathComponent().path) == ["YTMuse.app"])   // no leftovers
        #expect(f.signature.calls >= 2)                                                                                               // the staged app and the copy that runs
    }
    @Test func withoutAnExplicitRestartNothingIsInstalled() throws {
        defer { scratch.remove() }
        let f = try fixture()
        #expect(attempt(f, confirmation: nil) == .restartNotRequested)
        #expect(untouched(f))
        #expect(f.signature.calls == 0)
    }
    @Test func nothingIsInstalledWhilePlaying() throws {
        defer { scratch.remove() }
        let f = try fixture()
        let playing = PlaybackFlag(); playing.playing = true
        #expect(attempt(f, playing: playing) == .playbackActive)
        #expect(untouched(f))
    }
    @Test func playbackThatStartsDuringTheInstallStopsItBeforeTheExchange() throws {
        defer { scratch.remove() }
        for flip in 0..<3 {                                  // the three places the gate is asked (start, after verification, after the copy)
            let f = try fixture()
            let playing = PlaybackFlag(); playing.flipAfter = flip
            #expect(attempt(f, playing: playing) == .playbackActive, "flip after \(flip)")
            #expect(untouched(f), "flip after \(flip)")
            try? FileManager.default.removeItem(at: f.installed.deletingLastPathComponent())
        }
    }
    @Test func aStagedAppThatBecameADowngradeIsRefused() throws {
        defer { scratch.remove() }
        let f = try fixture()
        // Replaced on disk after staging with an older build: Info.plist no longer agrees with the record.
        try makeApp(at: URL(fileURLWithPath: f.staged.appPath).deletingLastPathComponent().appendingPathComponent("tmp.app"), version: "0.9.0", build: 90)
        try FileManager.default.removeItem(at: URL(fileURLWithPath: f.staged.appPath))
        try FileManager.default.moveItem(at: URL(fileURLWithPath: f.staged.appPath).deletingLastPathComponent().appendingPathComponent("tmp.app"), to: URL(fileURLWithPath: f.staged.appPath))
        #expect(attempt(f) == .bundleMismatch("version"))
        #expect(untouched(f))
        // And one whose record and bundle agree but which is not newer than the running app.
        let g = try fixture(stagedVersion: "1.0.0", stagedBuild: 100)
        #expect(attempt(g) == .notNewer)
        #expect(untouched(g))
    }
    @Test func aStagedAppOfAnotherIdentifierIsRefused() throws {
        defer { scratch.remove() }
        let f = try fixture()
        let app = URL(fileURLWithPath: f.staged.appPath)
        try FileManager.default.removeItem(at: app)
        try makeApp(at: app, identifier: "evil.other.app", version: "1.2.0", build: 120)
        #expect(attempt(f) == .bundleMismatch("identifier"))
        #expect(untouched(f))
    }
    @Test func aFailingSignatureCheckInstallsNothing() throws {
        defer { scratch.remove() }
        let f = try fixture()
        f.signature.failing = true
        #expect(attempt(f) == .codeSignature("invalid"))
        #expect(untouched(f))
    }
    @Test func anInstallLocationThatCannotBeWrittenIsRefusedUpFront() throws {
        defer { scratch.remove() }
        let f = try fixture()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.installed.deletingLastPathComponent().path)
        #expect(attempt(f) == .installLocationNotWritable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.installed.deletingLastPathComponent().path)
        #expect(untouched(f))
    }
}
