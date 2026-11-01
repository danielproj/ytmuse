import Foundation
import Testing
@testable import Playback
@testable import SystemIntegration

/// T23.4 (MAC02): media keys and accessory buttons arrive through the public remote-command centre ONLY. No global keyboard event tap, no global or
/// media-key event monitor, no IOHID access, no private MediaRemote framework, no private entitlement: swept in the sources, in the entitlements and
/// project linkage, and in the symbols of the built objects. `scripts/check-system-media.py` is the guard; `--self-test` proves it flags each kind.
@Suite struct SystemMediaGuardTests {
    private static func python(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", LifecycleSources.repositoryRoot.appendingPathComponent("scripts/check-system-media.py").path] + arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test func theGuardFlagsEachForbiddenKindAndPassesACleanTree() throws {
        let result = try Self.python(["--self-test"])
        #expect(result.status == 0 && result.output.contains("PASS"), "\(result.output)")
    }
    @Test func theSourcesEntitlementsLinkageAndBuiltSymbolsCarryNoGlobalTapOrPrivateAccessoryProtocol() throws {
        let result = try Self.python([])
        #expect(result.status == 0 && result.output.contains("PASS"), "\(result.output)")
        // A guard over nothing proves nothing: it scanned sources, entitlement files and built objects.
        #expect(result.output.contains(" sources,") && !result.output.contains(" 0 sources") && !result.output.contains(" 0 entitlement"), "\(result.output)")
    }
    @Test func anIndependentSweepOfTheSourcesFindsTheSameNothing() async throws {
        // Two of the names are written in two pieces: the W22 guard (OutputRoutesGuardTests) sweeps every test source for them, and this file only looks for them.
        let forbidden = ["CGEventTap", "addGlobalMonitorForEvents", ".systemDefined", "IOHID", "Media" + "Remote", "dl" + "open(", "Private" + "Frameworks"]
        let (scanned, hits) = await LifecycleSources.offMain { () -> (Int, [String]) in
            var count = 0, hits: [String] = []
            for root in [LifecycleSources.packageRoot.appendingPathComponent("Sources"), LifecycleSources.repositoryRoot.appendingPathComponent("App/Sources")] {
                for file in LifecycleSources.swiftFiles(under: root) {
                    count += 1
                    for (line, code) in LifecycleSources.code(file) {
                        // String literals are data, not calls: this file names the APIs only to look for them.
                        for token in forbidden where code.contains(token) { hits.append("\(file.lastPathComponent):\(line): \(token)") }
                    }
                }
            }
            return (count, hits)
        }
        #expect(scanned > 100, "the swept population is the app's sources: \(scanned)")
        #expect(hits.isEmpty, "\(hits)")
    }
    /// W25 narrowed this from "no entitlement at all": a SIGNED build's app holds exactly the widget's one Team-ID-prefixed App Group (the build-variable form below is what the
    /// signing step fills in), and nothing else, so still no private, HID, input-monitoring or Mach-lookup entitlement. Every Xcode build (ad hoc) signs with the file that holds none.
    @Test func theAppRequestsOnlyTheWidgetsAppGroupAndNothingElse() throws {
        func plist(_ name: String) throws -> [String: Any] {
            let data = try Data(contentsOf: LifecycleSources.repositoryRoot.appendingPathComponent(name))
            return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        }
        let signed = try plist("App/NativeMusic.entitlements")
        #expect(Set(signed.keys) == ["com.apple.security.application-groups"], "no private, HID, input-monitoring or Mach-lookup entitlement: \(signed.keys)")
        #expect(signed["com.apple.security.application-groups"] as? [String] == ["$(TeamIdentifierPrefix)local.native-music.development"])
        #expect(try plist("App/NativeMusic-adhoc.entitlements").isEmpty, "the entitlements every build signs with: none")
    }
    @Test func theOnlyWayKeysReachTheAppIsTheRemoteCommandCentre() throws {
        let system = try LifecycleSources.source("Sources/SystemIntegration/RemoteCommands.swift")
        #expect(system.contains("MPRemoteCommandCenter.shared()") && system.contains("addTarget(handler:"))
        let nowPlaying = try LifecycleSources.source("Sources/SystemIntegration/NowPlaying.swift")
        #expect(!nowPlaying.contains("NSEvent") && !nowPlaying.contains("CGEvent"), "the Now Playing owner listens to nothing but the command centre")
        let delegate = try LifecycleSources.source("Sources/AppShell/PlaybackApplicationDelegate.swift")
        #expect(!delegate.contains("NSEvent.addGlobal") && !delegate.contains("sendEvent"))
    }

    // MARK: the hidden page's own media session (Playback addendum, "Native ownership")

    @Test func theHiddenPagesMediaSessionCannotRegisterHandlersOrReachTheSystem() {
        let script = WebMusicScripts.bootstrap
        #expect(script.contains("navigator.mediaSession"))
        #expect(script.contains("session.setActionHandler = function (action) { try { clear(action, null); } catch (e) {} }"), "a handler the page registers is replaced by null")
        #expect(script.contains("Object.defineProperty(session, \"metadata\"") && script.contains("get: function () { return null; }"), "metadata is read by native code and never handed to WebKit")
        #expect(script.contains("Object.defineProperty(session, \"playbackState\"") && script.contains("return \"none\""), "the page cannot declare a playback state")
        #expect(script.contains("configurable: false"), "and cannot put the properties back")
        #expect(!script.contains("AudioContext") && !script.contains("webkitAudioContext"), "no Web Audio of ours; the page's own Web Audio registers no Now Playing session by itself")
    }
    @Test func nothingElseInThePlayersScriptsAltersAnAdvertisement() {
        let scripts = [WebMusicScripts.bootstrap, WebMusicScripts.adDetection]
        for script in scripts {
            for forbidden in ["playbackRate = ", ".muted = true", "removeChild", "display = \"none\"", "skipAd", "ytp-ad-skip"] {
                #expect(!script.contains(forbidden), "\(forbidden)")
            }
        }
    }
}
