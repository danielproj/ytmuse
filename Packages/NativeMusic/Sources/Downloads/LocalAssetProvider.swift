@preconcurrency import AVFoundation
import Foundation
import Domain
import Playback
import Synchronization

/// Owned-route observation seam: no credentials/URLs/bytes and no permission bypass.
public enum OwnedLoaderStage: Sendable { case preflightSucceeded, requestStarted, requestFailed, requestFailureDiscarded }
private typealias LoaderObservation = @Sendable (OwnedLoaderStage, ServiceID, PlaybackContext) async -> Void

/// The decoder can request arbitrary byte ranges without gaining a user-seek right.
private final class EncryptedLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let pending = Mutex<[ObjectIdentifier: Task<Void, Never>]>([:])
    private let activeStoreWork = Mutex<Set<ObjectIdentifier>>([])
    let store: EncryptedStore; let variant: ServiceID; let context: PlaybackContext
    let observation: LoaderObservation?
    /// The UTType the decoder is told the bytes are (the owned signals are WAVE; kept files carry their own).
    let contentType: String
    weak var session: NativeAssetSession?
    init(store: EncryptedStore, variant: ServiceID, context: PlaybackContext, observation: LoaderObservation?, contentType: String = "com.microsoft.waveform-audio") {
        self.store = store; self.variant = variant; self.context = context; self.observation = observation; self.contentType = contentType
    }
    func cancelAll() {
        let tasks = pending.withLock { value in let tasks = Array(value.values); return tasks }
        for task in tasks { task.cancel() }
    }
    func cancelAndDrain() async {
        let tasks = pending.withLock { tasks -> [Task<Void, Never>] in
            for task in tasks.values { task.cancel() }
            let active = activeStoreWork.withLock { $0 }
            return tasks.filter { active.contains($0.key) }.map(\.value)
        }
        // Held observation callbacks have no lease. They remain cancelled and must
        // pass Task.checkCancellation before any later store access, but cannot
        // unnecessarily hold account erasure hostage after native I/O has drained.
        for task in tasks { await task.value }
    }
    private func usingStore<T: Sendable>(_ identity: ObjectIdentifier, _ body: () async throws -> T) async throws -> T {
        try pending.withLock { _ in
            try Task.checkCancellation()
            guard session?.isClosed == false else { throw CancellationError() }
            activeStoreWork.withLock { $0.insert(identity) }
        }
        defer { activeStoreWork.withLock { $0.remove(identity) } }
        return try await body()
    }
    private func cancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        let identity = ObjectIdentifier(request)
        let admitted = pending.withLock { state -> Bool in
            guard state.count < 8 else { return false }
            state[identity] = Task {
                defer { pending.withLock { $0[identity] = nil } }
                do {
                    await observation?(.requestStarted, variant, context)
                    try Task.checkCancellation()
                    let length = try await usingStore(identity) { try await store.length(variant: variant.rawValue, context: context.request) }
                    if let info = request.contentInformationRequest {
                        info.contentType = contentType; info.contentLength = Int64(length)
                        // Decoder byte access is independent of the user's seek permission.
                        info.isByteRangeAccessSupported = true
                    }
                    if let data = request.dataRequest {
                        var offset = Int(data.currentOffset)
                        let end = data.requestsAllDataToEndOfResource ? length : min(length, Int(data.requestedOffset) + data.requestedLength)
                        while offset < end && !request.isCancelled {
                            try Task.checkCancellation()
                            let count = min(EncryptedStore.chunkSize, end - offset)
                            try await usingStore(identity) {
                                try await store.deliverDecoderBytes(variant: variant.rawValue, offset: offset, count: count, context: context.request) { bytes in
                                    if !request.isCancelled { data.respond(with: bytes) }
                                }
                            }
                            offset += count
                        }
                    }
                    if !request.isCancelled { request.finishLoading() }
                } catch {
                    guard !cancellation(error), !request.isCancelled else { return }
                    // A deterministic observation can hold an already real source failure.
                    // Disposal/cancellation is checked AGAIN after this suspension.
                    await observation?(.requestFailed, variant, context)
                    guard !Task.isCancelled, !request.isCancelled, let session, !session.isClosed else {
                        await observation?(.requestFailureDiscarded, variant, context)
                        return
                    }
                    let category = (error as? DomainError) ?? (error as? any NativeAssetFailure)?.playbackError ?? .transientTransport
                    session.fail(category)
                    if !request.isCancelled { request.finishLoading(with: error) }
                }
            }
            return true
        }
        if !admitted {
            session?.fail(.invalidInput(.invalidRange))
            request.finishLoading(with: OfflineRecovery.invalidRange)
        }
        return true
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        pending.withLock { $0[ObjectIdentifier(request)] }?.cancel()
    }
}

/// Owned WAVE only. A trusted caller supplies this seam; an URL alone grants nothing.
public actor LocalFirstOwnedAssets: NativeAssetProvider {
    private let store: EncryptedStore
    private let fallback: any NativeAssetProvider
    private let observation: LoaderObservation?
    private var legacySessions: [NativeAssetSession] = []
    public init(store: EncryptedStore, fallback: any NativeAssetProvider, observation: (@Sendable (OwnedLoaderStage, ServiceID, PlaybackContext) async -> Void)? = nil) {
        self.store = store; self.fallback = fallback; self.observation = observation
    }
    public func asset(for variant: MediaVariant, context: PlaybackContext) async throws -> URL { throw OfflineRecovery.invalidRange }
    public func nativeAsset(for variant: MediaVariant, context: PlaybackContext) async throws -> AVURLAsset {
        // AVAssetReader callers retain this provider. Engine users own their session directly.
        let session = try await assetSession(for: variant, context: context)
        legacySessions.append(session)
        if legacySessions.count > 2 { legacySessions.removeFirst().dispose() }
        return session.asset
    }
    public func assetSession(for variant: MediaVariant, context: PlaybackContext) async throws -> NativeAssetSession {
        // W17: the owned synthetic VIDEO is bundled and never retained in the encrypted store; it goes straight to the bundle provider.
        if context.request.account == OwnedMedia.account, variant.id == OwnedMedia.videoItem, variant.authorization.rawValue == "owned-bundle-only" {
            return try await fallback.assetSession(for: variant, context: context)
        }
        guard context.request.account == OwnedMedia.account, OwnedMedia.items.contains(variant.id), variant.authorization.rawValue == "owned-bundle-only" else { throw OfflineRecovery.reconnect }
        do { _ = try await store.length(variant: variant.id.rawValue, context: context.request) }
        catch OfflineRecovery.notRetained { return try await fallback.assetSession(for: variant, context: context) }
        let seekable = try await store.userSeekAllowed(variant: variant.id.rawValue, context: context.request)
        let loader = EncryptedLoader(store: store, variant: variant.id, context: context, observation: observation)
        let asset = AVURLAsset(url: URL(string: "owned-encrypted://media/\(UUID().uuidString).wav")!)
        let observer = Mutex<UUID?>(nil)
        let session = NativeAssetSession(asset: asset, userSeekable: variant.seekable && seekable, decodedAccess: .authorizedNative, authorizeUserSeek: { [store] in
            guard variant.seekable else { throw DomainError.unsupported }
            guard try await store.userSeekAllowed(variant: variant.id.rawValue, context: context.request) else { throw OfflineRecovery.seekNotPermitted }
        }, authorizeDecodedRead: { [store] in
            _ = try await store.length(variant: variant.id.rawValue, context: context.request)
        }, drain: { await loader.cancelAndDrain() }, dispose: { [store] in
            loader.cancelAll()
            let id = observer.withLock { $0 }
            Task { await loader.cancelAndDrain(); if let id { await store.removeDecoderObserver(id) }; await store.clearReadCaches(context: context.request) }
        })
        let id = try await store.observeDecoder(variant: variant.id.rawValue, context: context.request, invalidated: { [weak session] error in session?.fail(error) }, drain: { await loader.cancelAndDrain() })
        observer.withLock { $0 = id }
        loader.session = session
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "owned-encrypted-loader"))
        await observation?(.preflightSucceeded, variant.id, context)
        return session
    }
}

extension OfflineRecovery: NativeAssetFailure {
    public var playbackError: DomainError {
        switch self {
        case .reconnect, .missingKey: .unauthorized
        case .storageUnavailable: .transientTransport
        case .staleGrant, .seekNotPermitted: .forbidden
        case .renewRights, .clockChanged: .expiredMedia
        case .notRetained: .unavailableContent
        case .invalidRange: .invalidInput(.invalidRange)
        case .storageFull, .redownload: .malformedResponse
        }
    }
}


/// Native playback of kept (downloaded) items straight from the W14 encrypted store: no cleartext file, no local server, no
/// network. Admitted by `RetainedMediaAdmission`; the store re-checks account, key, rights and expiry on every read, and a seek is
/// allowed only while the retained grant carries the seek right.
public actor RetainedAssets: NativeAssetProvider {
    private let store: EncryptedStore
    private let contentType: @Sendable (String) -> String?
    private var legacySessions: [NativeAssetSession] = []
    public init(store: EncryptedStore, contentType: @escaping @Sendable (String) -> String? = { _ in nil }) { self.store = store; self.contentType = contentType }
    public func asset(for variant: MediaVariant, context: PlaybackContext) async throws -> URL { throw OfflineRecovery.invalidRange }
    public func nativeAsset(for variant: MediaVariant, context: PlaybackContext) async throws -> AVURLAsset {
        let session = try await assetSession(for: variant, context: context)
        legacySessions.append(session)
        if legacySessions.count > 2 { legacySessions.removeFirst().dispose() }
        return session.asset
    }
    public func assetSession(for variant: MediaVariant, context: PlaybackContext) async throws -> NativeAssetSession {
        guard variant.authorization.rawValue == RetainedMediaAdmission.authorization, context.request.account != nil else { throw OfflineRecovery.reconnect }
        _ = try await store.length(variant: variant.id.rawValue, context: context.request)
        let seekable = try await store.userSeekAllowed(variant: variant.id.rawValue, context: context.request)
        let loader = EncryptedLoader(store: store, variant: variant.id, context: context, observation: nil, contentType: contentType(variant.id.rawValue) ?? "public.audio")
        let asset = AVURLAsset(url: URL(string: "\(RetainedMediaAdmission.scheme)://media/\(UUID().uuidString)")!)
        let observer = Mutex<UUID?>(nil)
        let session = NativeAssetSession(asset: asset, userSeekable: variant.seekable && seekable, decodedAccess: .authorizedNative, authorizeUserSeek: { [store] in
            guard variant.seekable else { throw DomainError.unsupported }
            guard try await store.userSeekAllowed(variant: variant.id.rawValue, context: context.request) else { throw OfflineRecovery.seekNotPermitted }
        }, authorizeDecodedRead: { [store] in
            _ = try await store.length(variant: variant.id.rawValue, context: context.request)
        }, drain: { await loader.cancelAndDrain() }, dispose: { [store] in
            loader.cancelAll()
            let id = observer.withLock { $0 }
            Task { await loader.cancelAndDrain(); if let id { await store.removeDecoderObserver(id) }; await store.clearReadCaches(context: context.request) }
        })
        let id = try await store.observeDecoder(variant: variant.id.rawValue, context: context.request, invalidated: { [weak session] error in session?.fail(error) }, drain: { await loader.cancelAndDrain() })
        observer.withLock { $0 = id }
        loader.session = session
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "retained-encrypted-loader"))
        return session
    }
}

/// Resolves a kept item to the one retained variant that plays it, and states that playing it is permitted. Nothing here reaches a
/// service: a kept item that is not currently Downloaded is simply unavailable.
public struct RetainedPlayback: PlaybackResolver, CapabilityProvider {
    private let lookup: @Sendable (ServiceID) async -> PlayableDownload?
    private let wall: any WallClock
    public init(wall: any WallClock = SystemWallClock(), lookup: @escaping @Sendable (ServiceID) async -> PlayableDownload?) { self.lookup = lookup; self.wall = wall }
    public func capabilities(context: RequestContext) async -> ServiceResult<AccountCapabilities> {
        guard let account = context.account else { return .init(context: context, outcome: .failure(.unauthorized)) }
        do { return .init(context: context, outcome: .success(try AccountCapabilities(context: account, features: [.playback: Capability(state: .supported, source: "Kept on this Mac", context: account, checkedAt: wall.now(), expiresAt: nil)]))) }
        catch { return .init(context: context, outcome: .failure(.forbidden)) }
    }
    public func validateEligibility(_ media: ServiceID, context: PlaybackContext) async -> PlaybackResult<Capability> {
        guard let account = context.request.account, await lookup(media) != nil, let capability = try? Capability(state: .supported, source: "Kept on this Mac", context: account, checkedAt: wall.now(), expiresAt: nil) else { return .init(context: context, outcome: .failure(.unavailableContent)) }
        return .init(context: context, outcome: .success(capability))
    }
    public func resolve(_ media: ServiceID, context: PlaybackContext) async -> PlaybackResult<[MediaVariant]> {
        guard let kept = await lookup(media), kept.context.account == context.request.account, let id = try? ServiceID(kept.variant),
              let variant = try? MediaVariant(id: id, codec: "kept file", container: kept.contentType ?? "audio", bitrate: nil, sampleRate: nil, expiresAt: nil, seekable: kept.seekable, authorization: ID(RetainedMediaAdmission.authorization)) else { return .init(context: context, outcome: .failure(.unavailableContent)) }
        return .init(context: context, outcome: .success([variant]))
    }
    public func refresh(_ variant: MediaVariant, context: PlaybackContext) async -> PlaybackResult<MediaVariant> { .init(context: context, outcome: .success(variant)) }
    public func report(_ event: ServicePlaybackEvent, context: PlaybackContext) async -> PlaybackResult<Void> { .init(context: context, outcome: .success(())) }
}
