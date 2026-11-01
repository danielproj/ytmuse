import SwiftUI
import Observation
import Artwork
import Features
import Domain

/// A real insertion/removal source swap. The expanded view owns its 240pt frame.
struct CurrentArtwork: View {
    let pipeline: ArtworkPipeline?
    let request: ArtworkRequest?
    let authority: ArtworkUIAuthority
    let namespace: Namespace.ID?
    let expanded: Bool
    let isExpandedDestination: Bool
    let visible: Bool
    var compactEdge: Double = 52
    var expandedEdge: Double = 240
    var visibilityChanged: ((Bool) -> Void)? = nil
    var paletteChanged: ((ArtworkPalette?, ArtworkTintIdentity?) -> Void)? = nil
    var body: some View {
        let edge = expanded ? expandedEdge : compactEdge
        Group {
            if expanded == isExpandedDestination {
                Group {
                if let namespace {
                    NativeArtworkView(pipeline: pipeline, request: request, authority: authority, visible: visible, paletteChanged: paletteChanged)
                        .frame(width: edge, height: edge)
                        .matchedGeometryEffect(id: "current-artwork", in: namespace, properties: .frame, isSource: true)
                } else {
                    NativeArtworkView(pipeline: pipeline, request: request, authority: authority, visible: visible, paletteChanged: paletteChanged).frame(width: edge, height: edge)
                }
                }
                .onAppear { visibilityChanged?(true) }
                .onDisappear { visibilityChanged?(false) }
            } else { Color.clear.frame(width: compactEdge, height: compactEdge).accessibilityHidden(true) }
        }
    }
}
@MainActor @Observable final class WindowArtworkTint {
    private var palette: ArtworkPalette?
    private var identity: ArtworkTintIdentity?
    func receive(_ value: ArtworkPalette?, source: ArtworkTintIdentity?, current: ArtworkTintIdentity?, authority: ArtworkUIAuthority) {
        if source == nil && current == nil { retract(); return }
        guard let source, let current, source.matchesRequest(current), authority.accepts(current.context) else { return }
        if value == nil, identity?.consumerID != source.consumerID { return }
        palette = value; identity = source // Own-current nil clears; old consumer nil is ignored.
    }
    func displayed(for request: ArtworkRequest?, authority: ArtworkUIAuthority) -> ArtworkPalette? {
        guard let request, identity?.matchesRequest(ArtworkTintIdentity(request)) == true, authority.accepts(request.context) else { return nil }
        return palette
    }
    func retract() { palette = nil; identity = nil }
}
