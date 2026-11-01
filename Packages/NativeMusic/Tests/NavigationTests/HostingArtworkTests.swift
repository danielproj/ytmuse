import Testing
import Foundation
import SwiftUI
import AppKit
import Domain
import Artwork
import Features
import DesignSystem
@testable import AppShell

private actor HostingSource: ArtworkSource {
    let bytes: Data
    init(_ bytes: Data) { self.bytes = bytes }
    func load(resource: ArtworkResource, owner: ArtworkOwner, generation: UInt64, maximumBytes: Int) -> ArtworkSourceData { .init(bytes: bytes, policy: .memory(until: .distantFuture)) }
}
@MainActor @Observable private final class HostingState {
    var expanded = false
    var compactMounted = false
    var secondVisible = true
    let first = WindowArtworkTint(), second = WindowArtworkTint()
}
private struct HostingSwap: View {
    @Namespace var namespace
    @Bindable var state: HostingState
    let pipeline: ArtworkPipeline
    let request: ArtworkRequest
    let authority: ArtworkUIAuthority
    var body: some View {
        VStack {
            if state.expanded {
                CurrentArtwork(pipeline: pipeline, request: request, authority: authority, namespace: namespace, expanded: true, isExpandedDestination: true, visible: true)
            }
            Spacer()
            CurrentArtwork(pipeline: pipeline, request: request, authority: authority, namespace: namespace, expanded: false, isExpandedDestination: state.expanded, visible: true, visibilityChanged: { state.compactMounted = $0 })
        }.environment(\.scenePhase, .inactive) // Visible but inactive must still request pixels.
    }
}
private struct HostingTwoWindows: View {
    @Bindable var state: HostingState
    let pipeline: ArtworkPipeline
    let request: ArtworkRequest
    let authority: ArtworkUIAuthority
    var body: some View {
        HStack {
            NativeArtworkView(pipeline: pipeline, request: request, authority: authority, visible: true, paletteChanged: { state.first.receive($0, source: $1, current: ArtworkTintIdentity(request), authority: authority) }).frame(width: 52, height: 52)
            NativeArtworkView(pipeline: pipeline, request: request, authority: authority, visible: state.secondVisible, paletteChanged: { state.second.receive($0, source: $1, current: ArtworkTintIdentity(request), authority: authority) }).frame(width: 52, height: 52)
        }.environment(\.scenePhase, .inactive)
        .onChange(of: state.secondVisible) { _, visible in if !visible { state.second.retract() } }
    }
}
@Suite(.serialized) @MainActor struct HostingArtworkTests {
    private func host<V: View>(_ view: V) -> (NSHostingView<V>, NSWindow) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 1240, height: 820), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.ignoresMouseEvents = true
        window.orderFrontRegardless() // Never key or on-screen; no desktop/AX/permission action.
        return (host, window)
    }
    private func settle<V>(_ host: NSHostingView<V>) async throws {
        for _ in 0..<30 { host.layoutSubtreeIfNeeded(); host.display(); try await Task.sleep(for: .milliseconds(20)) }
    }
    @Test func realSourceSwapRequests52Then240VariantsAndCanReverse() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = ArtworkPipeline(source: HostingSource(try largeOriginalPNG()), diskDirectory: directory)
        let authority = ArtworkUIAuthority(), account = try consumerAccount(), state = HostingState()
        let context = RequestContext(account: account.context, accountGeneration: 1, requestGeneration: 1)
        authority.bind(context); try await pipeline.setAccountGeneration(owner: ArtworkOwner(account: account.context), generation: 1)
        let request = try consumerRequest(context, query: 1)
        let (host, window) = host(HostingSwap(state: state, pipeline: pipeline, request: request, authority: authority))
        defer { window.orderOut(nil); window.contentView = nil }
        try await settle(host)
        #expect(state.compactMounted, "Positive control: the compact consumer is actually mounted")
        let small = await pipeline.nativeSnapshot()
        let edge52 = Int(52 * window.backingScaleFactor)
        #expect(small.largestRasterBytes == edge52 * edge52 * 4)
        withAnimation(.easeInOut(duration: MusicMotion.artworkExpansion.seconds)) { state.expanded = true }
        try await settle(host)
        #expect(!state.compactMounted, "N04: the compact consumer must withdraw, not remain a second matched source")
        let expanded = await pipeline.nativeSnapshot(), edge240 = Int(240 * window.backingScaleFactor)
        print("W09 C1 actual native compact=\(small.largestRasterBytes) expanded=\(expanded.largestRasterBytes) expectedEdge=\(edge240)")
        #expect(expanded.largestRasterBytes == edge240 * edge240 * 4)
        #expect(await pipeline.snapshot().decodes == 2)
        // Reverse, including an interrupted expansion, without another decode or any transport.
        withAnimation(.easeInOut(duration: 0.32)) { state.expanded = false }
        try await settle(host)
        withAnimation(.easeInOut(duration: 0.32)) { state.expanded = true }
        try await Task.sleep(for: .milliseconds(20))
        withAnimation(.easeInOut(duration: 0.32)) { state.expanded = false }
        try await settle(host)
        #expect(state.compactMounted, "Reversal restores the compact consumer")
        #expect(await pipeline.nativeSnapshot().mainThreadWorkViolations == 0)
        #expect(await pipeline.snapshot().decodes == 2)
    }
    @Test func twoVisibleConsumersKeepIndependentTintAndAccountBarrierRetractsBoth() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = ArtworkPipeline(source: HostingSource(try consumerPNG()), diskDirectory: directory)
        let authority = ArtworkUIAuthority(), account = try consumerAccount(), state = HostingState()
        let context = RequestContext(account: account.context, accountGeneration: 1, requestGeneration: 1)
        authority.bind(context); try await pipeline.setAccountGeneration(owner: ArtworkOwner(account: account.context), generation: 1)
        let request = try consumerRequest(context, query: 1)
        let (host, window) = host(HostingTwoWindows(state: state, pipeline: pipeline, request: request, authority: authority))
        defer { window.orderOut(nil); window.contentView = nil }
        try await settle(host)
        #expect(state.first.displayed(for: request, authority: authority) != nil && state.second.displayed(for: request, authority: authority) != nil)
        state.secondVisible = false; try await settle(host)
        #expect(state.first.displayed(for: request, authority: authority) != nil)
        #expect(state.second.displayed(for: request, authority: authority) == nil)
        authority.bind(.init(account: nil, accountGeneration: 2, requestGeneration: 0))
        #expect(state.first.displayed(for: request, authority: authority) == nil && state.second.displayed(for: request, authority: authority) == nil)
        state.first.receive(nil, source: ArtworkTintIdentity(request), current: ArtworkTintIdentity(request), authority: authority)
        #expect(state.first.displayed(for: request, authority: authority) == nil)
    }
}
