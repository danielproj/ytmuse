import Foundation
import Testing
@testable import Updates

func run(_ tool: String, _ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return -1 }
    process.waitUntilExit()
    return process.terminationStatus
}

/// T30.2 with the real system checks: the code-signature verifier against real (ad-hoc signed, throwaway) bundles, and the real disk-image extractor
/// against a real image of one. Only the account-free temporary folder is touched; the mount point is inside it.
@Suite struct SystemVerificationTests {
    let scratch = ScratchFolder()
    func signedApp(identifier: String = "test.ytmuse.signed") throws -> URL {
        let app = scratch.url.appendingPathComponent("Signed/YTMuse.app")
        try makeApp(at: app, identifier: identifier, version: "1.2.0", build: 120)
        #expect(run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", identifier, app.path]) == 0)
        return app
    }

    @Test func theRealCheckAcceptsAnIntactBundleAndRefusesATamperedOne() throws {
        defer { scratch.remove() }
        let app = try signedApp()
        let checker = SecurityCodeSignatureChecker(requirement: #"identifier "test.ytmuse.signed""#)
        try checker.verify(app: app)                                                                // control: intact and matching
        try Data("version 9.9.9 (tampered)".utf8).write(to: app.appendingPathComponent("Contents/Resources/marker.txt"))
        #expect(throws: UpdateRejection.self) { try checker.verify(app: app) }                      // a resource changed after signing
    }
    @Test func theRealCheckRefusesAnotherIdentityAndAnUnsignedBundle() throws {
        defer { scratch.remove() }
        let app = try signedApp()
        #expect(throws: UpdateRejection.codeSignature("requirement not met")) { try SecurityCodeSignatureChecker(requirement: #"identifier "someone.else""#).verify(app: app) }
        let unsigned = scratch.url.appendingPathComponent("Unsigned/YTMuse.app")
        try makeApp(at: unsigned, version: "1.2.0", build: 120)
        #expect(throws: UpdateRejection.self) { try SecurityCodeSignatureChecker(requirement: #"identifier "test.ytmuse.signed""#).verify(app: unsigned) }
        #expect(throws: UpdateRejection.codeSignature("requirement")) { try SecurityCodeSignatureChecker(requirement: "this is not a requirement").verify(app: app) }
    }
    @Test func anAdHocBuildHasNoDesignatedRequirementToMatchSoItCannotSelfUpdate() throws {
        defer { scratch.remove() }
        let app = try signedApp()
        #expect(RunningSignature.designatedRequirement(of: app) == nil)   // ad hoc: no team identifier
    }
    @Test func theRealExtractorOpensADiskImageAndCopiesTheOneAppOut() throws {
        defer { scratch.remove() }
        let app = try signedApp()
        let image = scratch.url.appendingPathComponent("Release.dmg")
        #expect(run("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", app.deletingLastPathComponent().path, "-volname", "YTMuse", "-format", "UDZO", image.path]) == 0)
        let out = scratch.url.appendingPathComponent("Updates/app", isDirectory: true)   // the staging layout: <Updates>/app
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let extracted = try HdiutilExtractor().extractApp(from: image, into: out)
        #expect(extracted.lastPathComponent == "YTMuse.app" && marker(of: extracted) == "version 1.2.0")
        try SecurityCodeSignatureChecker(requirement: #"identifier "test.ytmuse.signed""#).verify(app: extracted)   // the signature survives the image
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []) == ["YTMuse.app"], "the mount point was detached and removed")
        // A file that is not a disk image is refused.
        let junk = scratch.url.appendingPathComponent("junk.dmg"); try Data("not an image".utf8).write(to: junk)
        #expect(throws: UpdateRejection.self) { try HdiutilExtractor().extractApp(from: junk, into: out) }
    }
}
