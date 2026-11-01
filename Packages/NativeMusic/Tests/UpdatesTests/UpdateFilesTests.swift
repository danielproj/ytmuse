import Domain
import Foundation
import Testing
@testable import Updates

/// D-M1 (W30 review): every confinement and isolation refusal of the updater's one filesystem wrapper, one test each. FAIL-SAFE by construction: every target is inside this test's
/// own scratch folder or a private folder under /private/var/tmp that the test makes and removes, and the "real" stores are a FAKE home inside the scratch folder (never the
/// account holder's), so a broken guard could only touch those. Each refusal is paired with a control that is allowed, so a guard that refuses everything also fails.
@Suite struct UpdateFilesTests {
    let scratch = ScratchFolder()
    /// A private folder that is NOT inside the system's temporary folder (so the isolation rule "nothing outside the temporary folder" applies to it).
    let outside = URL(fileURLWithPath: "/private/var/tmp/ytmuse-w30-" + UUID().uuidString, isDirectory: true)
    var fake: RealStores { RealStores(home: scratch.url.appendingPathComponent("home", isDirectory: true)) }
    var files: UpdateFiles { UpdateFiles(forceIsolated: true, real: fake) }
    func make(_ url: URL, _ text: String = "x") throws { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try Data(text.utf8).write(to: url) }
    func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    func cleanup() { scratch.remove(); try? FileManager.default.removeItem(at: outside) }

    // MARK: confinement

    @Test func onlyAFolderNamedUpdatesIsEverWiped() throws {
        defer { cleanup() }
        let other = scratch.url.appendingPathComponent("Documents"), staging = scratch.url.appendingPathComponent("Updates")
        try make(other.appendingPathComponent("keep.txt")); try make(staging.appendingPathComponent("gone.txt"))
        #expect(!files.wipeStaging(other) && text(other.appendingPathComponent("keep.txt")) == "x")
        #expect(files.wipeStaging(staging) && !FileManager.default.fileExists(atPath: staging.path), "control: its own folder is wiped")
    }
    @Test func removeAndCopyStayInsideTheStagingFolder() throws {
        defer { cleanup() }
        let root = scratch.url.appendingPathComponent("Updates"), inside = root.appendingPathComponent("a.txt"), foreign = scratch.url.appendingPathComponent("foreign.txt")
        try make(inside); try make(foreign)
        files.remove(foreign, insideStaging: root)
        #expect(text(foreign) == "x", "a file outside the staging folder is not removed")
        files.remove(root, insideStaging: root)
        #expect(FileManager.default.fileExists(atPath: root.path), "the folder itself is not removed through remove")
        files.remove(inside, insideStaging: root)
        #expect(text(inside) == nil, "control: a file inside is removed")
        try make(inside)
        #expect(throws: UpdateRejection.self) { try files.copy(foreign, toStaged: root.appendingPathComponent("b.txt"), insideStaging: root) }      // source outside
        #expect(throws: UpdateRejection.self) { try files.copy(inside, toStaged: scratch.url.appendingPathComponent("c.txt"), insideStaging: root) } // destination outside
        #expect(!FileManager.default.fileExists(atPath: scratch.url.appendingPathComponent("c.txt").path))
        try files.copy(inside, toStaged: root.appendingPathComponent("d.txt"), insideStaging: root)
        #expect(text(root.appendingPathComponent("d.txt")) == "x", "control: inside to inside is copied")
        #expect(throws: UpdateRejection.self) { try files.copy(inside, toStaged: scratch.url.appendingPathComponent("e.txt"), insideStaging: scratch.url) }   // a root not named Updates
    }
    @Test func aDownloadIsMovedOnlyFromTheTemporaryFolderIntoAStagingFolder() throws {
        defer { cleanup() }
        let staging = scratch.url.appendingPathComponent("Updates"); try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let notTemporary = outside.appendingPathComponent("d.tmp"); try make(notTemporary, "elsewhere")
        #expect(throws: UpdateRejection.self) { try files.placeDownload(notTemporary, at: staging.appendingPathComponent("download.dmg")) }
        #expect(text(notTemporary) == "elsewhere", "a file from outside the temporary folder is not moved")
        let temporary = scratch.url.appendingPathComponent("tmp.download"); try make(temporary, "bytes")
        #expect(throws: UpdateRejection.self) { try files.placeDownload(temporary, at: scratch.url.appendingPathComponent("download.dmg")) }   // not a staging folder
        try files.placeDownload(temporary, at: staging.appendingPathComponent("download.dmg"))
        #expect(text(staging.appendingPathComponent("download.dmg")) == "bytes", "control")
        files.discardTemporary(notTemporary)
        #expect(text(notTemporary) == "elsewhere", "discardTemporary only touches the temporary folder")
    }
    @Test func theInstalledAppIsReplacedOnlyByAVerifiedSiblingOfItsOwn() throws {
        defer { cleanup() }
        let apps = scratch.url.appendingPathComponent("Applications"), installed = apps.appendingPathComponent("YTMuse.app")
        try make(installed.appendingPathComponent("v.txt"), "old")
        let staged = scratch.url.appendingPathComponent("staged/YTMuse.app"); try make(staged.appendingPathComponent("v.txt"), "new")
        let stranger = apps.appendingPathComponent("Other.app"); try make(stranger.appendingPathComponent("v.txt"), "stranger")
        let wrongPrefix = apps.appendingPathComponent(".not-ours.app"); try make(wrongPrefix.appendingPathComponent("v.txt"), "wrong")
        let elsewhere = scratch.url.appendingPathComponent("Elsewhere/" + UpdateFiles.siblingPrefix + "1.app"); try make(elsewhere.appendingPathComponent("v.txt"), "far")
        #expect(throws: UpdateRejection.self) { _ = try files.exchange(installed: installed, withSibling: stranger) }       // a foreign app, not a sibling of ours
        #expect(throws: UpdateRejection.self) { _ = try files.exchange(installed: installed, withSibling: wrongPrefix) }
        #expect(throws: UpdateRejection.self) { _ = try files.exchange(installed: installed, withSibling: elsewhere) }      // not beside the installed app
        #expect(throws: UpdateRejection.self) { _ = try files.exchange(installed: apps.appendingPathComponent("notes.txt"), withSibling: stranger) }   // not an app
        #expect(text(installed.appendingPathComponent("v.txt")) == "old" && text(stranger.appendingPathComponent("v.txt")) == "stranger", "nothing was replaced")
        #expect(throws: UpdateRejection.self) { _ = try files.copyBeside(staged, installed: installed, name: "Evil.app") }
        #expect(throws: UpdateRejection.self) { _ = try files.copyBeside(staged, installed: installed, name: UpdateFiles.siblingPrefix + "../x.app") }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: apps.path)) ?? []).sorted() == [".not-ours.app", "Other.app", "YTMuse.app"], "no sibling was created")
        files.removeSibling(wrongPrefix, installed: installed); files.removeSibling(elsewhere, installed: installed)
        #expect(text(wrongPrefix.appendingPathComponent("v.txt")) == "wrong" && text(elsewhere.appendingPathComponent("v.txt")) == "far", "removeSibling removes only our own siblings")
        let sibling = try files.copyBeside(staged, installed: installed, name: UpdateFiles.siblingPrefix + "ok.app")
        _ = try files.exchange(installed: installed, withSibling: sibling)
        #expect(text(installed.appendingPathComponent("v.txt")) == "new", "control: the verified sibling replaces the installed app")
    }

    // MARK: isolated process: real stores and anywhere outside the temporary folder

    @Test func underIsolationARealStoreIsRefusedAtEveryCall() throws {
        defer { cleanup() }
        let real = fake.applicationSupport.appendingPathComponent("Updates")                  // a folder named Updates INSIDE the (fake) real Application Support
        try make(real.appendingPathComponent("marker.txt"), "real")
        #expect(!files.wipeStaging(real) && text(real.appendingPathComponent("marker.txt")) == "real")
        files.remove(real.appendingPathComponent("marker.txt"), insideStaging: real)
        #expect(text(real.appendingPathComponent("marker.txt")) == "real")
        try make(real.appendingPathComponent("src.txt"), "s")
        #expect(throws: UpdateRejection.self) { try files.copy(real.appendingPathComponent("src.txt"), toStaged: real.appendingPathComponent("dst.txt"), insideStaging: real) }
        let temporary = scratch.url.appendingPathComponent("tmp.download"); try make(temporary, "bytes")
        #expect(throws: UpdateRejection.self) { try files.placeDownload(temporary, at: real.appendingPathComponent("download.dmg")) }
        #expect(text(temporary) == "bytes" && text(real.appendingPathComponent("dst.txt")) == nil && text(real.appendingPathComponent("download.dmg")) == nil)
        // and an installed app inside a real store (the fake group container) is never replaced
        let installed = fake.groupContainers.appendingPathComponent("YTMuse.app"); try make(installed.appendingPathComponent("v.txt"), "old")
        let staged = scratch.url.appendingPathComponent("staged/YTMuse.app"); try make(staged.appendingPathComponent("v.txt"), "new")
        #expect(throws: UpdateRejection.self) { _ = try files.copyBeside(staged, installed: installed, name: UpdateFiles.siblingPrefix + "x.app") }
        #expect(text(installed.appendingPathComponent("v.txt")) == "old")
        // control: the same operations on an ordinary scratch staging folder are allowed
        let ok = scratch.url.appendingPathComponent("Updates"); try make(ok.appendingPathComponent("m.txt"))
        #expect(files.wipeStaging(ok))
    }
    @Test func underIsolationNothingOutsideTheTemporaryFolderIsRemovedCopiedOrReplaced() throws {
        defer { cleanup() }
        let staging = outside.appendingPathComponent("Updates"); try make(staging.appendingPathComponent("keep.txt"), "keep")
        #expect(!files.wipeStaging(staging) && text(staging.appendingPathComponent("keep.txt")) == "keep")
        files.remove(staging.appendingPathComponent("keep.txt"), insideStaging: staging)
        #expect(text(staging.appendingPathComponent("keep.txt")) == "keep")
        let installed = outside.appendingPathComponent("YTMuse.app"); try make(installed.appendingPathComponent("v.txt"), "old")
        let staged = scratch.url.appendingPathComponent("staged/YTMuse.app"); try make(staged.appendingPathComponent("v.txt"), "new")
        #expect(throws: UpdateRejection.self) { _ = try files.copyBeside(staged, installed: installed, name: UpdateFiles.siblingPrefix + "x.app") }
        let sibling = installed.deletingLastPathComponent().appendingPathComponent(UpdateFiles.siblingPrefix + "y.app"); try make(sibling.appendingPathComponent("v.txt"), "sib")
        #expect(throws: UpdateRejection.self) { _ = try files.exchange(installed: installed, withSibling: sibling) }
        files.removeSibling(sibling, installed: installed)
        #expect(text(installed.appendingPathComponent("v.txt")) == "old" && text(sibling.appendingPathComponent("v.txt")) == "sib", "an app outside the temporary folder is never replaced from an isolated process")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: outside.path)) ?? []).sorted() == [UpdateFiles.siblingPrefix + "y.app", "Updates", "YTMuse.app"].sorted())
    }
    @Test func theStagerRefusesAStagingFolderInARealStoreBeforeDownloadingAnything() async throws {
        defer { cleanup() }
        let real = fake.applicationSupport.appendingPathComponent("Updates"); try make(real.appendingPathComponent("marker.txt"), "real")
        let net = FakeNetwork(); net.asset = Data("img".utf8)
        let stager = UpdateStager(root: real, network: net, extractor: FakeExtractor(), signature: FakeSignature(), files: files)
        do { _ = try await stager.stage(try offeredRelease(for: Data("img".utf8)), running: runningApp); Issue.record("staged into a real store") } catch { #expect(error is UpdateRejection) }
        #expect(text(real.appendingPathComponent("marker.txt")) == "real")
        stager.discard()
        #expect(text(real.appendingPathComponent("marker.txt")) == "real", "discard refuses too")
    }

    // MARK: a link named like an app (L1)

    @Test func aSymbolicLinkNamedLikeAnAppInsideTheImageIsRefused() throws {
        defer { cleanup() }
        let target = scratch.url.appendingPathComponent("elsewhere/Real.app"); try makeApp(at: target, version: "1.2.0", build: 120)
        let pack = scratch.url.appendingPathComponent("pack", isDirectory: true); try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: pack.appendingPathComponent("YTMuse.app"), withDestinationURL: target)
        let image = scratch.url.appendingPathComponent("link.dmg")
        #expect(run("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", pack.path, "-volname", "YTMuse", "-format", "UDZO", image.path]) == 0)
        let out = scratch.url.appendingPathComponent("Updates/app", isDirectory: true); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        #expect(throws: UpdateRejection.bundleMismatch("image contents")) { _ = try HdiutilExtractor(files: files).extractApp(from: image, into: out) }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []).isEmpty, "nothing was copied out, and the mount point is gone")
    }
}
