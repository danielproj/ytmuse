import AccountSession
import Foundation
import Observation

/// What the lyrics panel shows. "No lyrics" and "could not load" are different states with different words and different actions.
public enum LyricsState: Equatable, Sendable {
    case idle
    case loading
    /// The source's lyrics, exactly as supplied.
    case loaded(MusicLyricsDocument)
    /// The service was read and has no lyrics for this song (`notOffered`), or answered with a page holding none (`emptyPage`).
    case unavailable(MusicLyricsAbsence)
    /// The read did not complete; trying again may work.
    case failed(LyricsFailure)
}
public enum LyricsFailure: Equatable, Sendable {
    case offline, rateLimited, unreadable, unavailable
    public var message: String {
        switch self {
        case .offline: String(localized: "You’re offline, so the lyrics couldn’t load.")
        case .rateLimited: String(localized: "YouTube Music is asking for a pause, so the lyrics couldn’t load.")
        case .unreadable: String(localized: "YouTube Music sent lyrics this version can’t read.")
        case .unavailable: String(localized: "The lyrics couldn’t load right now.")
        }
    }
}

/// Reads one song's lyrics at a time. Fenced three ways: by request (a slow answer for an earlier song is dropped), by account scope (an answer
/// read for another account is dropped) and by song. The text is never edited here.
@MainActor @Observable public final class LyricsModel {
    public typealias Reader = @Sendable (String) async throws -> MusicBrowseReply<MusicLyricsResult>
    public private(set) var state: LyricsState = .idle
    public private(set) var videoID: String?
    /// The answer came from a signed read (so a signed answer's timing, if any, was offered the chance to appear).
    public private(set) var readSigned = false
    @ObservationIgnored private let reader: Reader
    @ObservationIgnored private let accountScope: @MainActor () -> String
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var cache: [String: MusicLyricsResult] = [:]
    @ObservationIgnored private var cacheOrder: [String] = []
    @ObservationIgnored private var cachedScope = ""
    /// Reads the service has been asked for since this model was made (a measurement for tests: one song is one read).
    @ObservationIgnored public private(set) var readCount = 0

    public init(reader: @escaping Reader, accountScope: @escaping @MainActor () -> String = { "" }) { self.reader = reader; self.accountScope = accountScope }

    /// Shows the lyrics of `videoID` (nil or an unreadable id clears the panel). The same song again keeps what is shown.
    public func show(videoID: String?) async {
        guard let videoID, isVideoID(videoID) else { generation &+= 1; self.videoID = nil; state = .idle; return }
        let scope = accountScope()
        if scope != cachedScope { cache = [:]; cacheOrder = []; cachedScope = scope }
        if videoID == self.videoID {
            switch state { case .loaded, .unavailable, .loading: return; default: break }
        }
        generation &+= 1; let ticket = generation
        self.videoID = videoID
        if let hit = cache[videoID] { state = Self.state(for: hit); return }
        state = .loading
        await read(videoID, ticket: ticket, scope: scope)
    }
    /// Reads again after a failure. Does nothing for a loaded or genuinely unavailable song.
    public func retry() async {
        guard let videoID, case .failed = state else { return }
        generation &+= 1; let ticket = generation
        state = .loading
        await read(videoID, ticket: ticket, scope: accountScope())
    }
    public func accountChanged() { generation &+= 1; cache = [:]; cacheOrder = []; state = .idle; videoID = nil; readSigned = false }

    private func read(_ videoID: String, ticket: UInt64, scope: String) async {
        readCount += 1
        do {
            let reply = try await reader(videoID)
            guard ticket == generation, accountScope() == scope else { return }
            readSigned = reply.mode == .signedIn
            remember(videoID, reply.value)
            state = Self.state(for: reply.value)
        } catch {
            guard ticket == generation, accountScope() == scope else { return }
            state = .failed(Self.failure(error))
        }
    }
    private func remember(_ id: String, _ result: MusicLyricsResult) {
        if cache[id] == nil { cacheOrder.append(id) }
        cache[id] = result
        while cacheOrder.count > 24 { cache[cacheOrder.removeFirst()] = nil }
    }
    static func state(for result: MusicLyricsResult) -> LyricsState {
        switch result {
        case .lyrics(let document): .loaded(document)
        case .none(let reason): .unavailable(reason)
        }
    }
    static func failure(_ error: any Error) -> LyricsFailure {
        switch error as? MusicSessionError {
        case .network?, .timedOut?: .offline
        case .rateLimited?: .rateLimited
        case .unrecognised?, .oversized?: .unreadable
        default: .unavailable
        }
    }
}
private func isVideoID(_ value: String) -> Bool { value.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil }
