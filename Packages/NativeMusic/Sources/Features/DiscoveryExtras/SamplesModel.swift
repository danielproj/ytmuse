import Foundation
import Observation

/// Why Samples cannot be read, in the words the screen uses. Distinct reasons, never one generic failure.
public enum SamplesFailure: Error, Sendable, Equatable {
    case offline, needsSignIn, sessionEnded, unreadable, rateLimited
    public var message: String {
        switch self {
        case .offline: String(localized: "You’re offline, so Samples couldn’t be loaded.")
        case .needsSignIn: String(localized: "Sign in to YouTube Music to see Samples.")
        case .sessionEnded: String(localized: "Your YouTube Music session ended. Sign in again to see Samples.")
        case .unreadable: String(localized: "YouTube Music’s answer for Samples couldn’t be read, so nothing is shown.")
        case .rateLimited: String(localized: "YouTube Music is asking for a pause. Try Samples again in a moment.")
        }
    }
}

/// Where Samples come from. The application composes `UnresolvedSamplesSource` until a real source route is verified (W38): none of
/// the public YouTube Music responses captured so far carries Samples, so no list, shape or request is assumed here.
public protocol SamplesSource: Sendable {
    /// nil: a route exists. Otherwise why there is none, shown at the place Samples would be.
    var unresolved: String? { get }
    /// The clips the source offers the signed-in account now. An empty list is a real answer ("none right now"), not a failure.
    func clips() async throws -> [SampleClip]
}
public struct UnresolvedSamplesSource: SamplesSource {
    public init() {}
    public var unresolved: String? {
        String(localized: "Samples aren’t available yet. None of the YouTube Music responses this app can read carries them, so there is nothing to show here.")
    }
    public func clips() async throws -> [SampleClip] { throw SamplesFailure.unreadable }
}

public enum SamplesState: Equatable, Sendable {
    /// No route to Samples exists in this app yet; says so.
    case unresolved(String)
    case idle
    case loading
    case clips([SampleClip])
    /// The source answered and has no clips right now.
    case empty
    case failed(SamplesFailure)
}

/// The Samples screen: the clips a source offers, one focused at a time. Focusing a clip may start its preview when the policy allows;
/// pressing Preview always may; Play hands the clip to the shared playback session.
@MainActor @Observable public final class SamplesModel {
    public private(set) var state: SamplesState
    public private(set) var focused: String?
    public private(set) var handoff: PreviewHandoffOutcome?
    public let arbiter: PreviewArbiter
    @ObservationIgnored private let source: any SamplesSource
    @ObservationIgnored private let signedIn: @MainActor () -> SearchPlayback
    @ObservationIgnored private weak var performer: (any SearchActionPerformer)?
    @ObservationIgnored private var generation: UInt64 = 0
    /// Reads of the source since this model was made (a measurement: nothing reads in the background).
    @ObservationIgnored public private(set) var readCount = 0

    public init(source: any SamplesSource, arbiter: PreviewArbiter, performer: (any SearchActionPerformer)?, signedIn: @escaping @MainActor () -> SearchPlayback = { .available }) {
        self.source = source; self.arbiter = arbiter; self.performer = performer; self.signedIn = signedIn
        state = source.unresolved.map(SamplesState.unresolved) ?? .idle
    }
    public var clips: [SampleClip] { if case .clips(let clips) = state { clips } else { [] } }

    public func load() async {
        if let reason = source.unresolved { state = .unresolved(reason); return }
        switch signedIn() {
        case .needsSignIn: state = .failed(.needsSignIn); return
        case .sessionExpired: state = .failed(.sessionEnded); return
        case .available: break
        }
        if case .loading = state { return }
        let ticket = generation
        state = .loading; readCount += 1
        do {
            let found = try await source.clips()
            guard ticket == generation else { return }
            state = found.isEmpty ? .empty : .clips(Self.unique(found))
        } catch let failure as SamplesFailure {
            guard ticket == generation else { return }
            state = .failed(failure)
        } catch {
            guard ticket == generation else { return }
            state = .failed(.unreadable)
        }
    }
    /// A clip listed twice is one clip. The source's order is kept.
    static func unique(_ clips: [SampleClip]) -> [SampleClip] {
        var seen = Set<String>()
        return clips.filter { seen.insert($0.id).inserted }
    }

    /// A clip came into focus (selection, keyboard, scrolling to it). It previews by itself only when the policy allows.
    public func focus(_ id: String?) async {
        focused = id
        guard let id, let clip = clips.first(where: { $0.id == id }) else { await arbiter.stop(.leftScreen); return }
        _ = await arbiter.request(clip, trigger: .autoplay)
    }
    /// The Preview button.
    public func preview(_ id: String) async {
        guard let clip = clips.first(where: { $0.id == id }) else { return }
        focused = id
        _ = await arbiter.request(clip, trigger: .explicit)
    }
    public func stopPreview() async { await arbiter.stop(.requested) }
    /// The Play button: the shared playback session plays the clip's own item after the preview has gone silent.
    public func play(_ id: String) async {
        guard let clip = clips.first(where: { $0.id == id }), let performer else { return }
        switch signedIn() {
        case .needsSignIn: handoff = .notStarted(.failed); return
        case .sessionExpired: handoff = .notStarted(.stale); return
        case .available: break
        }
        handoff = await arbiter.play(clip, performer: performer)
    }
    /// The screen closed or the person moved on: nothing keeps sounding.
    public func leaveScreen() async { focused = nil; await arbiter.stop(.leftScreen) }
    public func accountChanged() {
        generation &+= 1; focused = nil; handoff = nil
        state = source.unresolved.map(SamplesState.unresolved) ?? .idle
        arbiter.accountChanged()
    }
}
