import Foundation
import Testing

/// TH1 rework 2: `Tests/Build/test-build-signing.sh` names its scratch folders `ytmuse-build-signing.<creating pid>.<random>` and, at start, removes a leftover only
/// when the process that created it is gone (and it is owned by this user and not a symlink). Never by age: other lanes' runs share the prefix
/// (`Docs/Harness-Brief.md`: "Delete only files your own run created"). Run here against a sandbox `TMPDIR`, with the real script and its shims.
@Suite struct SigningScriptSweepTests {
    @Test func aLeftoverIsRemovedOnlyWhenItsCreatingProcessIsGone() throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent("ytmuse-th1-sweep-" + UUID().uuidString)
        try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sandbox) }
        // A process id that is certainly gone: a child that has finished.
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/true"); try child.run(); child.waitUntilExit()
        let dead = child.processIdentifier, live = ProcessInfo.processInfo.processIdentifier
        let old = Date(timeIntervalSinceNow: -86_400)
        func folder(_ name: String) throws -> URL {
            let url = sandbox.appendingPathComponent(name)
            try fm.createDirectory(at: url.appendingPathComponent("repo"), withIntermediateDirectories: true)
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
            return url
        }
        let alive = try folder("ytmuse-build-signing.\(live).LIVE01")          // its creator is running (this process): must survive, however old
        let gone = try folder("ytmuse-build-signing.\(dead).GONE01")           // its creator is gone: removed
        let goneFile = sandbox.appendingPathComponent("ytmuse-build-signing.\(dead).marker.GONE02")
        fm.createFile(atPath: goneFile.path, contents: Data())
        let noPid = try folder("ytmuse-build-signing.notapid.OTHER1")          // not this script's naming scheme: left alone
        let oldScheme = try folder("ytmuse-build-signing.OLDOWN")              // the pre-rework scheme (no pid): left alone, it cannot be proved dead
        let elsewhere = try folder("someone-elses-folder")
        let target = try folder("link-target")
        let link = sandbox.appendingPathComponent("ytmuse-build-signing.\(dead).LINK01")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)          // a symlink is never followed or removed
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [LifecycleSources.repositoryRoot.appendingPathComponent("Tests/Build/test-build-signing.sh").path]
        process.environment = ["TMPDIR": sandbox.path + "/", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        #expect(process.terminationStatus == 0 && text.contains("PASS"), "\(text)")
        let left = Set(try fm.contentsOfDirectory(atPath: sandbox.path))
        #expect(left.contains(alive.lastPathComponent), "a folder whose creator is still running is never removed")
        #expect(!left.contains(gone.lastPathComponent), "a folder whose creator is gone is removed")
        #expect(!left.contains(goneFile.lastPathComponent), "so is a leftover marker file of a dead creator")
        for kept in [noPid, oldScheme, elsewhere, target] { #expect(left.contains(kept.lastPathComponent), "left alone: \(kept.lastPathComponent)") }
        #expect(left.contains(link.lastPathComponent) && fm.fileExists(atPath: target.path), "a symlink is left alone and its target is untouched")
        #expect(left.count == 6, "the run left nothing of its own behind: \(left.sorted())")
    }
}
