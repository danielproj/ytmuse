import Foundation
import Testing

/// The real-device safety rules (Docs/Harness-Brief.md, W22 addendum): no test target can reach a call that changes the Mac's outputs, volume, AirPlay or
/// Bluetooth state, and the real CoreAudio / AVFoundation implementations are named in exactly one place in the app. These are source sweeps; each rule
/// proves it can fire on its own sample, and each sweep proves it read something.
@Suite struct OutputRoutesGuardTests {
    static let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let repositoryRoot = packageRoot.deletingLastPathComponent().deletingLastPathComponent()

    static func swiftFiles(under root: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var result: [URL] = []
        for case let url as URL in walker {
            if url.lastPathComponent == ".build" || url.lastPathComponent == ".git" { walker.skipDescendants(); continue }
            if url.pathExtension == "swift" { result.append(url) }
        }
        return result
    }
    /// Comments are not code: a rule must not fire on the sentence that explains it. A `//` inside a string literal (a URL) is not a comment, so a call
    /// after it on the same line stays visible.
    static func code(_ text: String) -> String {
        var out = "", inString = false, escaped = false
        var iterator = text.makeIterator(), pending: Character? = nil
        func next() -> Character? { if let p = pending { pending = nil; return p }; return iterator.next() }
        while let c = next() {
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" || c == "\n" { inString = false }
                continue
            }
            if c == "\"" { inString = true; out.append(c); continue }
            if c == "/" {
                if let d = next() {
                    if d == "/" { while let e = next(), e != "\n" {}; out.append("\n"); continue }
                    pending = d
                }
            }
            out.append(c)
        }
        return out
    }

    /// Calls that change what the Mac plays through, how loud it is, or its wireless state; none may exist anywhere in the package, the app or a test.
    static let systemChanging = [
        "AudioObjectSetPropertyData", "AudioHardwareSetProperty", "AudioDeviceSetProperty", "AudioHardwareServiceSetPropertyData",
        "AudioHardwareCreateAggregateDevice", "AudioHardwareDestroyAggregateDevice", "AudioHardwareCreateProcessTap", "CATapDescription",
        "kAudioDevicePropertyVolumeScalar\\s*,[^)]*Set", "IOBluetooth", "CoreBluetooth", "CBCentralManager", "CBPeripheralManager",
        "MediaRemote", "MRMediaRemote", "AVOutputContext", "AVOutputDevice", "PrivateFrameworks", "dlopen\\(",
    ]
    /// The per-player, per-engine and discovery calls: only `HardwareOutput.swift` / `CoreAudioOutputDirectory.swift` may hold them.
    static let realImplementations = ["audioOutputDeviceUniqueID", "setDeviceID", "AVFoundationOutputApplier", "CoreAudioOutputDirectory", "AirPlayRouteDetection", "AVRouteDetector", "AVRoutePickerView", "AudioObjectAddPropertyListenerBlock"]

    static func hits(_ patterns: [String], in text: String) -> [String] { patterns.filter { text.range(of: $0, options: .regularExpression) != nil } }

    @Test func noSourceAnywhereCanChangeTheSystemsOutputsVolumeOrWirelessState() throws {
        var swept = 0
        // Every Swift source: the package's sources and tests, the app, and the repository's own test targets (the UI tests, the probes' helpers).
        for root in [Self.packageRoot.appendingPathComponent("Sources"), Self.packageRoot.appendingPathComponent("Tests"), Self.repositoryRoot.appendingPathComponent("App"),
                     Self.repositoryRoot.appendingPathComponent("Tests"), Self.repositoryRoot.appendingPathComponent("Extensions")] {
            for file in Self.swiftFiles(under: root) where file.lastPathComponent != "OutputRoutesGuardTests.swift" {
                swept += 1
                let found = Self.hits(Self.systemChanging, in: Self.code(try String(contentsOf: file, encoding: .utf8)))
                #expect(found.isEmpty, "\(file.path) reaches \(found)")
            }
        }
        #expect(swept > 300, "the sweep read \(swept) files; an empty sweep proves nothing")
    }
    @Test func noTestSourceNamesARealDeviceImplementationOrCall() throws {
        var swept = 0
        var sawUITests = false
        for file in Self.swiftFiles(under: Self.packageRoot.appendingPathComponent("Tests")) + Self.swiftFiles(under: Self.repositoryRoot.appendingPathComponent("Tests")) where file.lastPathComponent != "OutputRoutesGuardTests.swift" {
            swept += 1; if file.lastPathComponent == "NativeMusicUITests.swift" { sawUITests = true }
            let text = Self.code(try String(contentsOf: file, encoding: .utf8))
            let found = Self.hits(Self.realImplementations, in: text)
            #expect(found.isEmpty, "\(file.path) names \(found): tests use scripted directories and recording engines only")
        }
        #expect(swept > 100 && sawUITests, "the UI test target is part of the sweep")
    }
    @Test func theRealImplementationsLiveInExactlyTheirFiles() throws {
        let sources = Self.packageRoot.appendingPathComponent("Sources")
        var homes: [String: Set<String>] = [:]
        for file in Self.swiftFiles(under: sources) {
            let text = Self.code(try String(contentsOf: file, encoding: .utf8))
            for name in Self.realImplementations where text.contains(name) { homes[name, default: []].insert(file.lastPathComponent) }
        }
        let expected: [String: Set<String>] = [
            "audioOutputDeviceUniqueID": ["HardwareOutput.swift"],
            "setDeviceID": ["HardwareOutput.swift"],
            "AVRouteDetector": ["HardwareOutput.swift"],
            "AVRoutePickerView": ["OutputViews.swift"],
            "AudioObjectAddPropertyListenerBlock": ["CoreAudioOutputDirectory.swift"],
            "AVFoundationOutputApplier": ["HardwareOutput.swift", "OutputComposition.swift"],
            // PowerLifecycle.swift: W21's read-only default-route read (`SystemOutputRoute`), which tests replace through its `read` seam.
            "CoreAudioOutputDirectory": ["CoreAudioOutputDirectory.swift", "HardwareOutput.swift", "OutputComposition.swift", "PowerLifecycle.swift"],
            "AirPlayRouteDetection": ["HardwareOutput.swift", "OutputComposition.swift", "OutputController.swift"],
        ]
        for (name, files) in expected { #expect(homes[name] == files, "\(name): \(homes[name] ?? [])") }
        #expect(Set(homes.keys) == Set(expected.keys), "\(homes.keys)")
    }
    @Test func theAppliersOnlyActOnThePlayerOrEngineTheyAreHandedNeverOnTheSystemDefault() throws {
        let text = Self.code(try String(contentsOf: Self.packageRoot.appendingPathComponent("Sources/OutputRoutes/HardwareOutput.swift"), encoding: .utf8))
        #expect(!text.contains("kAudioHardwarePropertyDefaultOutputDevice") && !text.contains("kAudioHardwarePropertyDefaultSystemOutputDevice"))
        let directory = Self.code(try String(contentsOf: Self.packageRoot.appendingPathComponent("Sources/OutputRoutes/CoreAudioOutputDirectory.swift"), encoding: .utf8))
        #expect(directory.contains("AudioObjectGetPropertyData") && !directory.contains("SetPropertyData"), "the directory only reads")
    }
    @Test func everyRuleFiresOnItsOwnSample() {
        for sample in ["AudioObjectSetPropertyData(id, &a, 0, nil, size, &v)", "import IOBluetooth", "let c = CBCentralManager()", "AVOutputContext.shared()", "dlopen(\"/System/Library/PrivateFrameworks/X\", 0)"] {
            #expect(!Self.hits(Self.systemChanging, in: sample).isEmpty, "\(sample)")
        }
        for sample in ["player.audioOutputDeviceUniqueID = x", "try unit.setDeviceID(d)", "CoreAudioOutputDirectory()", "AVRoutePickerView()"] {
            #expect(!Self.hits(Self.realImplementations, in: sample).isEmpty, "\(sample)")
        }
        #expect(Self.hits(Self.systemChanging, in: Self.code("// AudioObjectSetPropertyData is never called")).isEmpty, "a comment is not a call")
        #expect(!Self.hits(Self.systemChanging, in: Self.code("let u = \"https://x.example\"; AudioObjectSetPropertyData(a, &b, 0, nil, 1, &c)")).isEmpty, "a call after a URL literal on one line is still seen")
        #expect(Self.hits(Self.systemChanging, in: Self.code("let t = 1 // AudioObjectSetPropertyData(a)")).isEmpty && Self.hits(Self.systemChanging, in: Self.code("/// IOBluetooth is not used")).isEmpty)
    }
    @Test func theHiddenPlayerKeepsWebKitsAirPlayOffAndHasNoCaptureOrPickerCode() throws {
        let page = try String(contentsOf: Self.packageRoot.appendingPathComponent("Sources/Playback/WebMusic/WebMusicPage.swift"), encoding: .utf8)
        #expect(page.contains("configuration.allowsAirPlayForMediaPlayback = false"))
        let scripts = try String(contentsOf: Self.packageRoot.appendingPathComponent("Sources/Playback/WebMusic/WebMusicScripts.swift"), encoding: .utf8)
        for forbidden in ["setSinkId", "selectAudioOutput", "webkitShowPlaybackTargetPicker", "getUserMedia", "enumerateDevices"] {
            #expect(!scripts.contains(forbidden), "the page bridge never routes or captures audio: \(forbidden)")
        }
        let sources = Self.swiftFiles(under: Self.packageRoot.appendingPathComponent("Sources/Playback/WebMusic"))
        for file in sources {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("requestMediaCapturePermission"), "\(file.lastPathComponent): the page is never granted capture")
        }
        #expect(sources.count >= 5)
    }
}
