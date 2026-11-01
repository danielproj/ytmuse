import Testing
import Foundation
import AppKit
import SwiftUI
import Domain
import Artwork
import Features
@testable import AppShell

private actor TintSource: ArtworkSource {
    let bytes: Data
    init(_ bytes: Data) { self.bytes = bytes }
    func load(resource: ArtworkResource, owner: ArtworkOwner, generation: UInt64, maximumBytes: Int) -> ArtworkSourceData { .init(bytes: bytes, policy: .memory(until: .distantFuture)) }
}
@MainActor @Observable private final class TintState {
    var request: ArtworkRequest?
    let tint = WindowArtworkTint()
    var lastSource: ArtworkTintIdentity?
}
private struct TintHost: View {
    @Bindable var state: TintState
    let pipeline: ArtworkPipeline
    let authority: ArtworkUIAuthority
    var body: some View {
        NativeArtworkView(pipeline: pipeline, request: state.request, authority: authority, visible: true, paletteChanged: {
            state.lastSource = $1
            state.tint.receive($0, source: $1, current: state.request.map(ArtworkTintIdentity.init), authority: authority)
        }).frame(width: 52, height: 52).environment(\.scenePhase, .inactive)
    }
}
@Suite(.serialized) @MainActor struct TintOwnershipTests {
    @Test func hostedCurrentArtworkClearsOnNoArtAndRejectsLateOldNilCallbacks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = ArtworkPipeline(source: TintSource(try consumerPNG()), diskDirectory: root), authority = ArtworkUIAuthority(), account = try consumerAccount()
        let context = RequestContext(account: account.context, accountGeneration: 1, requestGeneration: 1)
        authority.bind(context); try await pipeline.setAccountGeneration(owner: ArtworkOwner(account: account.context), generation: 1)
        let state = TintState(), a = try consumerRequest(context, id: "A", query: 1), b = try consumerRequest(context, id: "B", query: 2)
        state.request = a
        let host = NSHostingView(rootView: TintHost(state: state, pipeline: pipeline, authority: authority))
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.ignoresMouseEvents = true; window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        func settle() async throws { for _ in 0..<30 { host.layoutSubtreeIfNeeded(); host.display(); try await Task.sleep(for: .milliseconds(20)) } }
        try await settle()
        #expect(state.tint.displayed(for: a, authority: authority) != nil)
        let oldSource = try #require(state.lastSource)
        state.request = nil; try await settle()
        #expect(state.tint.displayed(for: nil, authority: authority) == nil)
        state.request = b; try await settle()
        let palette = try #require(state.tint.displayed(for: b, authority: authority))
        let currentSource = try #require(state.lastSource)
        state.tint.receive(nil, source: oldSource, current: ArtworkTintIdentity(b), authority: authority)
        #expect(state.tint.displayed(for: b, authority: authority) != nil)
        // Own nil for the current request must clear, even though the request itself is unchanged.
        state.tint.receive(nil, source: currentSource, current: ArtworkTintIdentity(b), authority: authority)
        #expect(state.tint.displayed(for: b, authority: authority) == nil)
        // A replacement renderer of the same resource owns subsequent nil publication.
        let replacement = ArtworkTintIdentity(b, consumerID: UUID())
        state.tint.receive(palette, source: replacement, current: ArtworkTintIdentity(b), authority: authority)
        state.tint.receive(nil, source: currentSource, current: ArtworkTintIdentity(b), authority: authority)
        #expect(state.tint.displayed(for: b, authority: authority) != nil)
        let other = try consumerAccount(), otherRequest = try consumerRequest(.init(account: other.context, accountGeneration: 2, requestGeneration: 1), id: "B", query: 2)
        state.tint.receive(nil, source: ArtworkTintIdentity(otherRequest), current: ArtworkTintIdentity(b), authority: authority)
        #expect(state.tint.displayed(for: b, authority: authority) != nil)
        authority.bind(.init(account: nil, accountGeneration: 2, requestGeneration: 0))
        #expect(state.tint.displayed(for: b, authority: authority) == nil)
    }
}
