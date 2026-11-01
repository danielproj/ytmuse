import Testing
import SwiftUI
import AppKit
import Domain
import Artwork
import Features
@testable import AppShell
@testable import Features

private actor DemandSource: ArtworkSource {
    let bytes: Data
    init(_ bytes: Data) { self.bytes = bytes }
    func load(resource: ArtworkResource, owner: ArtworkOwner, generation: UInt64, maximumBytes: Int) -> ArtworkSourceData { .init(bytes: bytes, policy: .memory(until: .distantFuture)) }
}
/// W09-F1 regression guard. The failure itself (a body re-evaluation caused by the size becoming known that the task never
/// saw) is a SwiftUI scheduling race seen in about 1 of 10 UI runs and not reproducible in a hosted view: this test passed
/// 300 of 300 rounds against the pre-fix `GeometryReader` + `.task(id:)` structure as well. It guards the property the fix must keep
/// (a demand that arrives in pieces, with the size last, still starts the decode); the UI loop is the evidence for the fix.
/// The order seen in the W09-F1 failing UI runs: mounted with no pipeline or request and visible, then hidden, then the
/// pipeline arrives, then the request arrives, and only then the window reports visible again.
@MainActor @Observable private final class LateDemandState {
    var pipeline: ArtworkPipeline?
    var request: ArtworkRequest?
    var visible = true
    var edge = 0.0
}
private struct LateDemandView: View {
    @Bindable var state: LateDemandState
    let authority: ArtworkUIAuthority
    var body: some View {
        NativeArtworkView(pipeline: state.pipeline, request: state.request, authority: authority, visible: state.visible).environment(\.scenePhase, .active)
    }
}
@Suite(.serialized) @MainActor struct ArtworkDemandStartTests {
    static func runOnce(spacing: Int) async throws -> Int {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = ArtworkPipeline(source: DemandSource(try consumerPNG()), diskDirectory: directory)
        let authority = ArtworkUIAuthority(), account = try consumerAccount(), state = LateDemandState()
        let context = RequestContext(account: account.context, accountGeneration: 1, requestGeneration: 1)
        authority.bind(context); try await pipeline.setAccountGeneration(owner: ArtworkOwner(account: account.context), generation: 1)
        let request = try consumerRequest(context, query: 1)
        let host = NSHostingView(rootView: LateDemandView(state: state, authority: authority))
        host.frame = CGRect(x: 0, y: 0, width: 0, height: 0)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.ignoresMouseEvents = true; window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        func turn() async { host.layoutSubtreeIfNeeded(); for _ in 0..<spacing { await Task.yield() } }
        await turn()
        state.visible = false; await turn()
        state.pipeline = pipeline; await turn()
        state.request = request; await turn()
        host.setFrameSize(NSSize(width: 52, height: 52)); host.layoutSubtreeIfNeeded()
        state.visible = true
        for _ in 0..<60 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)); if await pipeline.nativeSnapshot().completedDecodes > 0 { break } }
        return await pipeline.nativeSnapshot().completedDecodes
    }
    @Test func aDemandThatArrivesInPiecesStillStartsTheDecode() async throws {
        var failures = 0
        for round in 0..<60 { if try await Self.runOnce(spacing: round % 4) == 0 { failures += 1 } }
        #expect(failures == 0, "\(failures) of 60 mounts never decoded")
    }
}

@Suite @MainActor struct ArtworkDemandDriverTests {
    /// W09-F2: the work of a demand waits on a gate the test opens, not on a clock. The earlier version slept 150 ms and the test slept 30 ms
    /// and 300 ms around it; on a loaded machine the test could resume after the work had simply finished, which reads as "not cancelled".
    /// A load that is cancelled before its gate opens never finishes however late the test gets scheduled, and one that is not cancelled
    /// finishes as soon as the gate opens, so both outcomes are decided by the driver and not by timing.
    @MainActor private final class Log {
        var started: [String] = [], finished: [String] = [], open: Set<String> = []
    }
    private func work(_ name: String, _ log: Log) -> @MainActor () async -> Void {
        {
            log.started.append(name)
            do { while !log.open.contains(name) { try await Task.sleep(for: .milliseconds(2)) }; try Task.checkCancellation() } catch { return }
            log.finished.append(name)
        }
    }
    /// Waits for a positive condition under a generous deadline.
    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }
    /// Lets cancelled work run to its end (it returns at its next suspension point) before asserting what did NOT happen.
    private func drain() async { for _ in 0..<100 { await Task.yield() }; try? await Task.sleep(for: .milliseconds(50)) }
    @Test func theSameDemandStartsOnceAndANewOneSupersedesTheLoad() async throws {
        let driver = ArtworkDemandDriver(), log = Log()
        driver.apply("a", work("a", log)); driver.apply("a", work("a", log))
        let startedA = await eventually { !log.started.isEmpty }
        #expect(startedA, "the first demand never started")
        await drain()
        #expect(log.started == ["a"], "applying the same demand again must not restart the load")
        driver.apply("b", work("b", log))
        let startedB = await eventually { log.started.count == 2 }
        #expect(startedB, "the new demand never started")
        log.open = ["a", "b"]          // both gates open: only a load that is still running can finish
        let finishedB = await eventually { log.finished.contains("b") }
        #expect(finishedB, "the superseding load never finished")
        await drain()
        #expect(log.started == ["a", "b"] && log.finished == ["b"], "the superseded load is cancelled before it finishes: started=\(log.started) finished=\(log.finished)")
    }
    @Test func aSuspendedDriverStartsNothingUntilResumedThenStartsTheLatestDemand() async throws {
        let driver = ArtworkDemandDriver(), log = Log()
        driver.apply("a", work("a", log))
        let startedA = await eventually { !log.started.isEmpty }
        #expect(startedA, "the first demand never started")
        driver.suspend(); driver.apply("b", work("b", log))
        log.open = ["a", "b"]          // a running load would finish now; a new one would start
        await drain()
        #expect(log.started == ["a"] && log.finished.isEmpty, "a view that left the hierarchy neither finishes nor starts loads")
        driver.resume()
        let finishedB = await eventually { log.finished.contains("b") }
        #expect(finishedB, "the latest demand never finished after resume")
        await drain()
        #expect(log.started == ["a", "b"] && log.finished == ["b"])
    }
}

/// W09-F1b. The YouTube Music bar and Now Playing artwork views decode `player.artwork` (a `Data`) through the same driver.
@Suite @MainActor struct WebMusicArtworkDriverTests {
    @MainActor private final class Log { var decoded: [Data] = [] }
    @Test func equalArtworkBytesDecodeOnceAndChangedBytesDecodeAgain() async throws {
        let driver = ArtworkDemandDriver(), log = Log()
        let first = Data([1, 2, 3]), same = Data([1, 2, 3]), other = Data([9, 9])
        driver.apply(first) { log.decoded.append(first) }; driver.apply(same) { log.decoded.append(same) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(log.decoded == [first], "the same bytes (a new Data value) must not decode again on every body evaluation")
        driver.apply(other) { log.decoded.append(other) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(log.decoded == [first, other])
    }
    @Test func nilArtworkIsAnIdAndClearsTheImage() async throws {
        let driver = ArtworkDemandDriver()
        var shown: Data? = Data([1])
        driver.apply(Data?.some(Data([1]))) { shown = Data([1]) }
        driver.apply(Data?.none) { shown = nil }
        try await Task.sleep(for: .milliseconds(30))
        #expect(shown == nil, "losing the artwork (a new item without art) must clear the previous image")
    }
    @Test func theArtworkViewsNoLongerDecodeFromATaskModifier() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/AppShell")
        for name in ["MusicTransportBar.swift", "WebMusicQueueViews.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            #expect(!text.contains(".task(id: player.artwork)"), "\(name) must decode through ArtworkDemandDriver")
            #expect(text.contains("ArtworkDemandDriver()") && text.contains("artworkDecode.apply(player.artwork)"), "\(name) positive control")
            // A view that leaves and returns must decode again: both lifecycle calls are required, not just the apply.
            #expect(text.contains(".onAppear { artworkDecode.resume() }"), "\(name) must resume the driver on appear")
            #expect(text.contains(".onDisappear { artworkDecode.suspend() }"), "\(name) must suspend the driver on disappear")
        }
    }
}
