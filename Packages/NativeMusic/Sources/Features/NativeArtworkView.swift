import SwiftUI
import Observation
import Domain
import Artwork
import DesignSystem

/// Starts the load for the current demand from the view body instead of from `.task(id:)`.
///
/// W09-F1: in roughly one UI run in ten the artwork view body ran with a complete demand (size, request, visible window)
/// and neither `.task(id: demand)` nor an independent `.onChange(of: demand)` fired for it, though both had fired for every
/// earlier change. Nothing then reached the pipeline for the life of the window: placeholder artwork and no tint. The body
/// evaluation itself was reliable, so the demand is applied there. `apply` is idempotent per demand, cancels the superseded
/// load, and does nothing else; `suspend`/`resume` mirror the view leaving and re-entering the hierarchy.
/// Shared by the YouTube Music artwork views, which had the same `.task(id:)` shape (W09-F1b).
@MainActor public final class ArtworkDemandDriver {
    public init() {}
    private var applied: AnyHashable?
    private var latest: (id: AnyHashable, work: @MainActor () async -> Void)?
    private var task: Task<Void, Never>?
    private var suspended = false
    /// W21 (WIN10): a second, independent reason not to decode: the window showing the view is hidden, minimized, covered or its display is off.
    /// It does not depend on the view leaving the hierarchy (a minimized window's views never disappear).
    private var held = false
    public func apply(_ id: AnyHashable, _ work: @escaping @MainActor () async -> Void) {
        latest = (id, work)
        guard !suspended, !held, applied != id else { return }
        applied = id; start()
    }
    public func suspend() { suspended = true; applied = nil; task?.cancel(); task = nil }
    public func resume() {
        guard suspended else { return }
        suspended = false
        if !held, let latest { applied = latest.id; start() }
    }
    /// Holds the driver while its window shows nothing: an in-flight decode is cancelled and none starts until the hold ends, which decodes the newest demand.
    public func hold(_ on: Bool) {
        guard held != on else { return }
        held = on
        if on { applied = nil; task?.cancel(); task = nil }
        else if !suspended, let latest { applied = latest.id; start() }
    }
    private func start() {
        task?.cancel()
        guard let work = latest?.work else { return }
        task = Task { @MainActor in await work() }
    }
    isolated deinit { task?.cancel() }
}
/// MainActor publication fence. Only the app's account lifecycle binds this shared authority.
/// It complements the pipeline fence by retracting pixels already returned before a switch.
@MainActor @Observable public final class ArtworkUIAuthority {
    public private(set) var context = RequestContext(account: nil, accountGeneration: 0, requestGeneration: 0)
    private var removedAccounts: Set<UUID> = []
    public init() {}
    public func removeAccount(_ id: UUID) {
        var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
        withTransaction(transaction) { _ = removedAccounts.insert(id) }
    }
    @discardableResult public func bind(_ value: RequestContext) -> Bool {
        if let account = value.account, removedAccounts.contains(account.accountID) { return false }
        guard value.accountGeneration > context.accountGeneration || (value.accountGeneration == context.accountGeneration && value.account == context.account) else { return false }
        var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
        withTransaction(transaction) { context = value }
        return true
    }
    public func accepts(_ request: RequestContext) -> Bool {
        context.account != nil && !removedAccounts.contains(context.account!.accountID) && context.account == request.account && context.accountGeneration == request.accountGeneration
    }
}
/// Identity of the current artwork, independent of the display-sized raster variant.
public struct ArtworkTintIdentity: Hashable, Sendable {
    public let resource: ArtworkResource
    public let policy: ArtworkCachePolicy
    public let context: RequestContext
    public let consumerID: UUID?
    public init(_ request: ArtworkRequest) { self.init(request, consumerID: nil) }
    public init(_ request: ArtworkRequest, consumerID: UUID?) { resource = request.resource; policy = request.policy; context = request.context; self.consumerID = consumerID }
    public func matchesRequest(_ other: Self) -> Bool { resource == other.resource && policy == other.policy && context == other.context }
}
public struct ArtworkConsumerKey: Hashable, Sendable {
    let resource: ArtworkResource; let size: ArtworkSize; let policy: ArtworkCachePolicy; let context: RequestContext
    public init(_ request: ArtworkRequest) { resource = request.resource; size = request.size; policy = request.policy; context = request.context }
}
/// Each view owns one consumer; peers may have unrelated query generations.
@MainActor @Observable public final class ArtworkConsumer {
    private var image: ArtworkImage?
    public private(set) var unavailable = false
    private var current: ArtworkConsumerKey?
    private var revision: UInt64 = 0
    public init() {}
    public func cancel() { revision += 1; current = nil; image = nil; unavailable = false }
    public func displayed(for request: ArtworkRequest?, authority: ArtworkUIAuthority) -> ArtworkImage? {
        guard let request, current == ArtworkConsumerKey(request), authority.accepts(request.context) else { return nil }
        return image
    }
    public func load(_ request: ArtworkRequest, pipeline: ArtworkPipeline, authority: ArtworkUIAuthority, visible: Bool = true) async {
        revision += 1; let ticket = revision
        current = ArtworkConsumerKey(request); image = nil; unavailable = false
        guard visible, authority.accepts(request.context), !Task.isCancelled else { return }
        for attempt in 0...1 {
            do {
                let response = try await pipeline.image(for: request)
                try Task.checkCancellation()
                guard ticket == revision, current == ArtworkConsumerKey(request), response.context == request.context, authority.accepts(response.context) else { return }
                image = response.image
                return
            } catch {
                guard ticket == revision, !Task.isCancelled, authority.accepts(request.context) else { return }
                if error as? ArtworkError == .pressureRevoked, attempt == 0 {
                    // One cooled retry per explicit demand. Repeated pressure never spins.
                    do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                    guard ticket == revision, !Task.isCancelled, current == ArtworkConsumerKey(request), authority.accepts(request.context) else { return }
                    continue
                }
                unavailable = true
                return
            }
        }
    }
}

public enum ArtworkDisplayRequest {
    /// A template carries identity/policy/context; actual geometry determines the decode variant.
    public static func make(_ template: ArtworkRequest?, width: Double, height: Double, scale: Double) -> ArtworkRequest? {
        guard let template, let size = try? ArtworkSize(pointsWidth: width, pointsHeight: height, scale: scale) else { return nil }
        return ArtworkRequest(resource: template.resource, size: size, policy: template.policy, context: template.context)
    }
}

/// The caller supplies an adapter-issued resource and source retention policy.
/// Nil request renders original static brand art without inventing a service image or permission.
public struct NativeArtworkView: View {
    let pipeline: ArtworkPipeline?
    let request: ArtworkRequest?
    let authority: ArtworkUIAuthority
    let visible: Bool
    let paletteChanged: ((ArtworkPalette?, ArtworkTintIdentity?) -> Void)?
    @State private var consumer = ArtworkConsumer()
    @State private var tintConsumerID = UUID()
    @State private var size = CGSize.zero
    @State private var driver = ArtworkDemandDriver()
    @Environment(\.displayScale) private var scale
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    public init(pipeline: ArtworkPipeline?, request: ArtworkRequest?, authority: ArtworkUIAuthority, visible: Bool, paletteChanged: ((ArtworkPalette?, ArtworkTintIdentity?) -> Void)? = nil) {
        self.pipeline = pipeline; self.request = request; self.authority = authority; self.visible = visible; self.paletteChanged = paletteChanged
    }
    private struct TintPublication: Equatable { let palette: ArtworkPalette?; let identity: ArtworkTintIdentity? }
    private struct Demand: Hashable { let key: ArtworkConsumerKey?; let visible: Bool; let owner: RequestContext }
    /// The measured edge is read into state (not inside a `GeometryReader` content closure) so the demand below is built
    /// in the body itself. The demand is applied by `driver` rather than `.task(id:)`: see `ArtworkDemandDriver`.
    public var body: some View {
        artwork(ArtworkDisplayRequest.make(request, width: size.width, height: size.height, scale: scale))
            .aspectRatio(1, contentMode: .fit).clipped().accessibilityHidden(true)
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { size = $0 }
    }
    private func artwork(_ measured: ArtworkRequest?) -> some View {
        let image = consumer.displayed(for: measured, authority: authority)
        let publication = TintPublication(palette: image?.palette, identity: measured.map { ArtworkTintIdentity($0, consumerID: tintConsumerID) })
        let demand = Demand(key: measured.map(ArtworkConsumerKey.init), visible: visible && phase != .background, owner: authority.context)
        driver.apply(demand) { [consumer, authority, pipeline] in
            guard demand.visible, let pipeline, let measured else { consumer.cancel(); return }
            await consumer.load(measured, pipeline: pipeline, authority: authority)
        }
        return ZStack {
            if let image {
                Color(red: image.palette.red, green: image.palette.green, blue: image.palette.blue).opacity(image.palette.opacity)
                Image(decorative: image.cgImage, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else { ResonanceArtwork() }
        }
        .musicAnimation(.artworkColor, value: image?.palette, reduceMotion: reduceMotion, lowPower: lowPower, visible: demand.visible)
        .onChange(of: publication, initial: true) { _, value in paletteChanged?(value.palette, value.identity) }
        .onAppear { driver.resume() }
        .onDisappear { driver.suspend(); consumer.cancel() }
        .onReceive(MusicGlassPower.changes) { _ in lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled }
    }
}
