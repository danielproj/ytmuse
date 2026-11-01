import Domain
import Foundation

/// Deliberately separate from service resolution. Accepts only these bundled, owned signals.
public struct OwnedMedia: PlaybackResolver, CapabilityProvider, NativeAssetProvider {
    public static let label = "Owned test audio · Not YouTube Music"
    public static let account = try! AccountContext(accountID: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!, channelID: ID("owned-test-media"), region: "US")
    public static let items = [try! ServiceID("owned-a"), try! ServiceID("owned-b")]
    /// W17: the owned synthetic video (video-only, silent), played by the native AVKit path. Not part of `items`, so the owned audio queue is unchanged.
    public static let videoItem = try! ServiceID("owned-video")
    /// The owned video exists in DEBUG builds only (rework F12): it is generated at first use, so no video asset ships in Release.
    #if DEBUG
    static let playable = items + [videoItem]
    #else
    static let playable = items
    #endif
    private let wall: any WallClock
    public init(wall: any WallClock = SystemWallClock()) { self.wall = wall }
    private func permission(_ context: RequestContext) throws -> Capability {
        guard context.account == Self.account else { throw DomainError.forbidden }
        return try Capability(state: .supported, source: Self.label, context: Self.account, checkedAt: wall.now(), expiresAt: nil)
    }
    public func capabilities(context: RequestContext) async -> ServiceResult<AccountCapabilities> {
        do { return .init(context: context, outcome: .success(try AccountCapabilities(context: Self.account, features: [.playback: permission(context)]))) }
        catch { return .init(context: context, outcome: .failure(.forbidden)) }
    }
    public func validateEligibility(_ media: ServiceID, context: PlaybackContext) async -> PlaybackResult<Capability> {
        do { guard Self.playable.contains(media) else { throw DomainError.unavailableContent }; return .init(context: context, outcome: .success(try permission(context.request))) }
        catch { return .init(context: context, outcome: .failure(.unavailableContent)) }
    }
    public func resolve(_ media: ServiceID, context: PlaybackContext) async -> PlaybackResult<[MediaVariant]> {
        guard context.request.account == Self.account, Self.playable.contains(media) else { return .init(context: context, outcome: .failure(.unavailableContent)) }
        if media == Self.videoItem {
            return .init(context: context, outcome: .success([try! MediaVariant(id: media, codec: "H.264 video, no audio", container: "MP4", bitrate: 400_000, sampleRate: nil, expiresAt: nil, seekable: true, authorization: ID("owned-bundle-only"))]))
        }
        return .init(context: context, outcome: .success([try! MediaVariant(id: media, codec: "PCM signed 16-bit", container: "WAVE", bitrate: 1_536_000, sampleRate: 48_000, expiresAt: nil, seekable: true, authorization: ID("owned-bundle-only"))]))
    }
    /// W39: the bundled owned audio file for `media`, for the Cast relay (a receiver fetches a file; it cannot be handed an `AVAsset`). nil for anything that is not
    /// one of the owned audio signals: a kept download is encrypted at rest and is never decrypted for a receiver, and the owned video has no audio.
    public static func castableFile(for media: ServiceID) -> URL? {
        guard items.contains(media) else { return nil }
        return Bundle.module.url(forResource: media.rawValue, withExtension: "wav")
    }
    public func refresh(_ variant: MediaVariant, context: PlaybackContext) async -> PlaybackResult<MediaVariant> {
        let result = await resolve(variant.id, context: context)
        return .init(context: context, outcome: result.outcome.flatMap { $0.first.map(Result.success) ?? .failure(.unavailableContent) })
    }
    public func report(_ event: ServicePlaybackEvent, context: PlaybackContext) async -> PlaybackResult<Void> { .init(context: context, outcome: .success(())) }
    public func assetSession(for variant: MediaVariant, context: PlaybackContext) async throws -> NativeAssetSession {
        NativeAssetSession(asset: try await nativeAsset(for: variant, context: context), userSeekable: variant.seekable,
                           decodedAccess: .localPCM, authorizeUserSeek: {
            guard variant.seekable else { throw DomainError.unsupported }
        })
    }
    public func asset(for variant: MediaVariant, context: PlaybackContext) async throws -> URL {
        guard context.request.account == Self.account, Self.playable.contains(variant.id), variant.authorization.rawValue == "owned-bundle-only" else { throw DomainError.forbidden }
        #if DEBUG
        if variant.id == Self.videoItem { return try await OwnedTestVideo.url() }
        #endif
        guard let url = Bundle.module.url(forResource: variant.id.rawValue, withExtension: "wav") else { throw DomainError.forbidden }
        return url
    }
}
