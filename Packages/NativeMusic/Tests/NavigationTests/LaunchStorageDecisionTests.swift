#if DEBUG
import Testing
import Foundation
@testable import AppShell

/// C1 item 11 (incident C1-incident-nonisolated-launch): Debug builds default to isolated scratch
/// storage; the real stores need an explicit opt-in. Every case here is the pure decision function:
/// nothing launches the app and nothing opens a store.
@Suite struct LaunchStorageDecisionTests {
    private let optInKey = IsolatedQAStorage.realStoresKey
    private let optInArgument = IsolatedQAStorage.realStoresArgument
    @Test func noEnvironmentAndNoArgumentsIsIsolated() {
        #expect(IsolatedQAStorage.decide(environment: [:], arguments: []) == .isolated, "a launch that lost its environment is isolated")
        #expect(IsolatedQAStorage.decide(environment: [:], arguments: ["YTMuse", "-ApplePersistenceIgnoreState", "YES"]) == .isolated)
        #expect(IsolatedQAStorage.decide(environment: ["HOME": "/Users/someone", "PATH": "/usr/bin"], arguments: []) == .isolated)
    }
    @Test func onlyAnExplicitOptInSelectsTheRealStores() {
        #expect(IsolatedQAStorage.decide(environment: [optInKey: "1"], arguments: []) == .real)
        #expect(IsolatedQAStorage.decide(environment: [:], arguments: [optInArgument]) == .real)
        for lookalike in ["0", "", "true", "YES", " 1", "1 "] {
            #expect(IsolatedQAStorage.decide(environment: [optInKey: lookalike], arguments: []) == .isolated, "'\(lookalike)' is not the opt-in")
        }
        #expect(IsolatedQAStorage.decide(environment: [:], arguments: ["-YTMuseUseRealStore"]) == .isolated, "a near-miss argument is not the opt-in")
        #expect(IsolatedQAStorage.decide(environment: [:], arguments: ["--YTMuseUseRealStores"]) == .isolated)
    }
    @Test func explicitIsolationAlwaysWinsOverTheOptIn() {
        #expect(IsolatedQAStorage.decide(environment: ["YTMUSE_UI_TEST_ISOLATED": "1", optInKey: "1"], arguments: [optInArgument]) == .isolated)
        #expect(IsolatedQAStorage.decide(environment: ["YTMUSE_NATIVE_DESIGN_TEST": "1", optInKey: "1"], arguments: []) == .isolated)
    }
    @Test func theProcessWideDecisionIsTheOneEveryConsumerReads() {
        #expect(IsolatedQAStorage.requested() == (IsolatedQAStorage.launch == .isolated))
        // The test process has no opt-in, so it is isolated.
        #expect(IsolatedQAStorage.launch == .isolated)
        #expect(IsolatedQAStorage.requested([optInKey: "1"], arguments: []) == false)
        #expect(IsolatedQAStorage.requested([:], arguments: []) == true)
    }
    @Test func theOptInIsNamedInOneFileOnly() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 20)
        var naming: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("YTMUSE_USE_REAL_STORES") || text.contains("YTMuseUseRealStores") { naming.append(file.lastPathComponent) }
        }
        #expect(naming == ["IsolatedQAStorage.swift"], "the opt-in has a single definition: \(naming)")
    }
}
#endif
