#if DEBUG
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Observation
import Domain
import Queue
import Artwork
import Features

/// Original local image bytes for the explicitly labelled, opt-in native design test mode.
actor DevelopmentDesignSource: ArtworkSource {
    private var data: Data?
    func load(resource: ArtworkResource, owner: ArtworkOwner, generation: UInt64, maximumBytes: Int) throws -> ArtworkSourceData {
        if data == nil {
            let edge = 1024, pixels = Data(repeating: 170, count: edge * edge * 4)
            guard let provider = CGDataProvider(data: pixels as CFData),
                  let image = CGImage(width: edge, height: edge, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: edge * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw ArtworkError.invalidImage }
            let bytes = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else { throw ArtworkError.invalidImage }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw ArtworkError.invalidImage }; data = bytes as Data
        }
        guard let data, data.count <= maximumBytes else { throw ArtworkError.inputTooLarge }
        return ArtworkSourceData(bytes: data, policy: .memory(until: .distantFuture))
    }
}
/// W44-prep: the design pipeline's source on a synthetic performance launch: catalog thumbnails come from the generated-image source, everything else
/// (the brand art the shell asks for) from the ordinary development source. Neither reaches a network.
struct DevelopmentPerformanceArtworkSource: ArtworkSource {
    let catalog: CatalogArtworkSource
    private let design = DevelopmentDesignSource()
    func load(resource: ArtworkResource, owner: ArtworkOwner, generation: UInt64, maximumBytes: Int) async throws -> ArtworkSourceData {
        resource.namespace == CatalogArtworkSource.namespace
            ? try await catalog.load(resource: resource, owner: owner, generation: generation, maximumBytes: maximumBytes)
            : try await design.load(resource: resource, owner: owner, generation: generation, maximumBytes: maximumBytes)
    }
}
private actor DevelopmentQueueStorage: QueuePersistence {
    var value: QueueSnapshot?
    func load(context: RequestContext) -> QueueSnapshot? { value }
    func save(_ snapshot: QueueSnapshot, context: RequestContext) { value = snapshot }
}
private struct DevelopmentSilentBoundary: QueuePlaybackBoundary {
    func select(_ entry: QueueEntry, token: UUID, context: RequestContext, origin: CommandOrigin) {}
    func pause(context: RequestContext, origin: CommandOrigin) {}
}
@MainActor @Observable final class DevelopmentDesignQueue {
    var snapshot: QueueSnapshot?
    var failure: String?
    let commands: QueueCommands
    let context: RequestContext
    let titles: [ServiceID: String]
    let tracked: ServiceID
    private init(commands: QueueCommands, context: RequestContext, titles: [ServiceID: String], tracked: ServiceID) { self.commands = commands; self.context = context; self.titles = titles; self.tracked = tracked }
    static func prepare(context: RequestContext) async throws -> DevelopmentDesignQueue {
        guard let account = context.account else { throw DomainError.staleContext }
        let queueCount = DevelopmentPerformance.enabled ? DevelopmentPerformance.Scale.standard.queueItems : 240
        let media = try (0..<queueCount).map { try ServiceID("development-queue-\($0)") }
        var machine = QueueMachine(account: account, supportsAutoplay: false)
        try machine.replaceContext(media, source: ServiceID("original-development-queue"))
        let commands = try QueueCommands(machine: machine, context: context, persistence: DevelopmentQueueStorage(), playback: DevelopmentSilentBoundary(), repeatSupported: true)
        let model = DevelopmentDesignQueue(commands: commands, context: context, titles: Dictionary(uniqueKeysWithValues: media.enumerated().map { ($0.element, (DevelopmentPerformance.enabled ? DevelopmentPerformance.queueTitle($0.offset) : String(localized: "Development queue item \($0.offset + 1)"))) }), tracked: media[10])
        model.snapshot = try await commands.snapshot(); return model
    }
    func send(_ command: QueueCommand) async {
        do { _ = try await commands.execute(command, context: context, origin: .userInterface); snapshot = try await commands.snapshot(); failure = nil }
        catch { failure = String(localized: "The development queue action failed. Try the action again.") }
    }
    var trackedIndex: Int { snapshot?.session.entries.firstIndex { $0.media == tracked } ?? -1 }
}
#endif
