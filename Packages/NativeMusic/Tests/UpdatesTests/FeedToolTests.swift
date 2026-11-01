import Foundation
import Testing

private final class BundleToken {}

/// The release tooling, run as a real process on throwaway keys in a temporary folder: the same commands Docs/Distribution.md shows.
@Suite struct FeedToolTests {
    let scratch = ScratchFolder()
    var tool: URL { Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent().appendingPathComponent("FeedTool") }
    func run(_ arguments: [String]) -> (Int32, String, String) {
        let process = Process(); process.executableURL = tool; process.arguments = arguments
        let out = Pipe(), err = Pipe(); process.standardOutput = out; process.standardError = err
        try! process.run(); process.waitUntilExit()
        return (process.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
    func p(_ name: String) -> String { scratch.url.appendingPathComponent(name).path }

    @Test func theDocumentedFlowKeygenPayloadSignVerifyWorksAndTamperingIsRejected() throws {
        defer { scratch.remove() }
        #expect(FileManager.default.fileExists(atPath: tool.path), "FeedTool not built beside the test bundle: \(tool.path)")
        try Data("pretend disk image".utf8).write(to: URL(fileURLWithPath: p("YTMuse-1.2.0.dmg")))
        try Data("{\"bomFormat\":\"CycloneDX\"}".utf8).write(to: URL(fileURLWithPath: p("sbom.json")))
        #expect(run(["keygen", "--private-out", p("feed.key"), "--public-out", p("feed.pub")]).0 == 0)
        let permissions = try FileManager.default.attributesOfItem(atPath: p("feed.key"))[.posixPermissions] as! Int
        #expect(permissions == 0o600)
        #expect(run(["keygen", "--private-out", p("feed.key"), "--public-out", p("feed2.pub")]).0 == 65, "never overwrites a key")
        let payload = run(["make-payload", "--repository", repository, "--version", "1.2.0", "--build", "120", "--asset", p("YTMuse-1.2.0.dmg"), "--sbom", p("sbom.json"), "--commit", String(repeating: "a", count: 40),
                           "--sequence", "5", "--issued", "2027-01-01T00:00:00Z", "--expires", "2027-12-31T00:00:00Z", "--published", "2027-01-01T00:00:00Z", "--out", p("payload.json")])
        #expect(payload.0 == 0, "\(payload.2)")
        #expect(run(["sign", "--key", p("feed.key"), "--payload", p("payload.json"), "--out", p("feed.json")]).0 == 0)
        let verify = ["verify", "--feed", p("feed.json"), "--public-key", p("feed.pub"), "--repository", repository, "--now", "2027-02-01T00:00:00Z"]
        let ok = run(verify + ["--current-version", "1.0.0", "--current-build", "100"])
        #expect(ok.0 == 0 && ok.1.hasPrefix("OFFER 1.2.0 build 120 sequence 5"), "\(ok.1)")
        #expect(run(verify + ["--current-version", "1.2.0", "--current-build", "120"]).1.hasPrefix("UP-TO-DATE"))
        #expect(run(verify + ["--current-version", "1.0.0", "--last-sequence", "6"]).1 == "REJECTED rollback\n")
        // Tamper with one byte of the signed feed: rejected, exit status 2.
        var feed = try Data(contentsOf: URL(fileURLWithPath: p("feed.json")))
        let at = feed.range(of: Data("\"payload\":\"".utf8))!.upperBound + 10
        feed[at] = feed[at] == UInt8(ascii: "A") ? UInt8(ascii: "B") : UInt8(ascii: "A")
        try feed.write(to: URL(fileURLWithPath: p("tampered.json")))
        let bad = run(["verify", "--feed", p("tampered.json"), "--public-key", p("feed.pub"), "--repository", repository, "--current-version", "1.0.0", "--now", "2027-02-01T00:00:00Z"])
        #expect(bad.0 == 2 && bad.1 == "REJECTED invalidSignature\n", "\(bad.1)")
        #expect(run(verify.map { $0 == p("feed.json") ? p("tampered.json") : $0 } + ["--current-version", "1.0.0"]).0 == 2)
        // The wrong repository pin is refused.
        #expect(run(["verify", "--feed", p("feed.json"), "--public-key", p("feed.pub"), "--repository", "someone/else", "--current-version", "1.0.0", "--now", "2027-02-01T00:00:00Z"]).1 == "REJECTED provenance\n")
    }
    @Test func aPrivateKeyIsNeverWrittenInsideAGitWorkTree() throws {
        // A work tree of this test's own (a folder with a .git marker), so the rule is proved wherever the repository itself is checked out, including a copy with no .git.
        defer { scratch.remove() }
        let work = scratch.url.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let inside = work.appendingPathComponent("should-never-exist.key").path
        #expect(run(["keygen", "--private-out", inside, "--public-out", inside + ".pub"]).0 == 65)
        #expect(!FileManager.default.fileExists(atPath: inside))
        let outside = scratch.url.appendingPathComponent("elsewhere.key").path          // control: the same command outside any work tree is accepted
        #expect(run(["keygen", "--private-out", outside, "--public-out", outside + ".pub"]).0 == 0)
    }
}

/// TH2 (W30 D-L4): the scratch folder is gone when its owner is, whether or not the test remembered to remove it.
@Suite struct ScratchFolderTests {
    @Test func theFolderExistsWhileTheOwnerDoesAndIsGoneWithIt() throws {
        var owner: ScratchFolder? = ScratchFolder()
        let url = try #require(owner?.url)
        #expect(FileManager.default.fileExists(atPath: url.path), "the folder is made when the owner is")
        try Data("x".utf8).write(to: url.appendingPathComponent("f"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)   // a read-only folder, as the staging tests leave one
        owner = nil
        #expect(!FileManager.default.fileExists(atPath: url.path), "the folder (even read-only, with a file in it) is removed with its owner")
    }
    @Test func aSuiteInstanceThatNeverRemovesAnythingLeavesNothing() throws {
        // What every other test in a suite does: it holds one and never calls remove().
        struct NeverRemoves { let scratch = ScratchFolder() }
        var paths: [String] = []
        for _ in 0..<5 { let instance = NeverRemoves(); paths.append(instance.scratch.url.path) }
        #expect(paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) }, "no folder is left behind: \(paths.filter { FileManager.default.fileExists(atPath: $0) })")
    }
}
