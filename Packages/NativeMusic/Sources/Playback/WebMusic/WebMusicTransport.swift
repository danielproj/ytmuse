import Foundation

public enum WebMusicFailure: Sendable, Equatable {
    /// YouTube Music needs a fresh sign-in: a redirect to Google sign-in/consent,
    /// or the page reports it is not signed in (it would otherwise play as a guest).
    case signInRequired
    /// The page tried to leave YouTube Music; the navigation was refused.
    case navigationRefused
    case loadFailed
    /// A per-track YouTube player error. Not terminal: YouTube's queue may move on.
    case notPlayable(code: Int)
    /// WebKit's content process ended; nothing restarts without an explicit Play.
    case playerStopped
    /// The page loaded a document native code did not request (for example a reload).
    case pageReplaced
    case sessionUnavailable
    case timedOut
    /// YouTube served its "not optimized for your browser" page instead of the app.
    case unsupportedBrowser
    /// The document is not the YouTube Music app (no `ytmusic-app`), for any other reason.
    case notMusicApp
    /// A shuffle could not be started as a shuffle (the page never took the service's shuffle endpoint, or its first reports show it playing in order).
    /// Nothing is ever played in order in its place.
    case shuffleFailed
    public var message: String {
        switch self {
        case .signInRequired: "YouTube Music needs you to sign in again. Use Sign In Again in Your Music Account, then press Play."
        case .navigationRefused: "The player tried to open a page outside YouTube Music, so it was stopped."
        case .loadFailed: "YouTube Music did not load. Check the connection and press Play to retry."
        case .notPlayable(let code): "YouTube Music cannot play this track here (player error \(code))."
        case .playerStopped: "The player stopped unexpectedly. Press Play to start again."
        case .pageReplaced: "YouTube Music reloaded by itself, so playback stopped. Press Play to start again."
        case .sessionUnavailable: "Your YouTube Music session could not be read from the Keychain."
        case .timedOut: "YouTube Music did not start playing. Press Play to retry."
        case .unsupportedBrowser: "YouTube Music refused the player as an unsupported browser, so nothing played. Update YTMuse and try again."
        case .notMusicApp: "YouTube Music sent a page without its player, so nothing played. Press Play to retry."
        case .shuffleFailed: "YouTube Music couldn’t shuffle this, so nothing was played. Try Shuffle again."
        }
    }
}
public enum WebMusicPhase: Sendable, Equatable { case idle, loading, playing, paused, buffering, ended, failed(WebMusicFailure) }

/// What the transport shows. During an ad the selected track's metadata and
/// content clock stay as they were; only the Ad state and play/pause change.
public struct WebMusicSnapshot: Sendable, Equatable {
    public var phase: WebMusicPhase = .idle
    public var playlistID: String?
    public var playlistTitle: String?
    public var videoID: String?
    public var title: String?
    public var artist: String?
    public var artworkURL: URL?
    public var position: Double = 0
    public var duration: Double = 0
    public var isAd = false
    public var intent = false
    /// W22 (ROUTE03): the player was paused because its audio output went away, not by a person. It stays paused until a person plays again;
    /// reconnecting the output resumes nothing.
    public var pausedByRouteLoss = false
    public var volume: Double = 1
    /// A non-terminal per-track problem (YouTube player error) shown beside the transport.
    public var notice: WebMusicFailure?
    /// W17: how the page presents the playing item (nil until the page says), and what follows from it.
    public var representation: MediaRepresentation?
    /// A live stream whose player offers a rewindable window; seeking is refused otherwise.
    public var liveRewindable = false
    public var atLiveEdge = true
    /// The decoded picture's size, when the page holds a video track (an ad's creative counts: ads are shown).
    public var pictureSize: CGSize?
    /// The other version of this recording as the service published it.
    public var counterpartVideoID: String?
    public var counterpartRepresentation: MediaRepresentation?
    public var pictureInPicture: WebMusicMediaSample.PictureInPicture = .unsupported
    /// The page is reduced to the video picture for a native surface.
    public var presenting = false
    /// Why the last representation switch started from the beginning.
    public var restart: RepresentationTransition.RestartReason?
    /// The player's quality level and offered levels, and the captions state, as the page reports them (nil/empty when it does not).
    public var quality: String?
    public var qualities: [String] = []
    public var captions: WebMusicMediaSample.Captions = .unavailable
    /// W18: the speed the page's `<video>` element is playing at, as the page reports it (and as a speed command's read-back confirmed it). Nil until
    /// it is known for this item; the app then treats the speed as normal.
    public var elementRate: Double?
    public init() {}
    public var isLive: Bool { representation == .live }
    public var hasPicture: Bool { pictureSize != nil }
    /// W21 (WIN09): the item a cold launch restored, paused, from this Mac's own record of the last session. Nothing is loaded behind it: Play
    /// starts it, so skipping and seeking are off until then.
    public var restored = false
    public var canSeek: Bool { !restored && !isAd && (duration > 0 || (isLive && liveRewindable)) && (phase == .playing || phase == .paused || phase == .buffering) }
    /// Why Audio Only cannot be offered right now (rework F9); nil when it can. The reason is specific, never a generic "nothing playing".
    public var audioOnlyUnavailable: RepresentationTransition.AudioOnlyUnavailable? {
        guard videoID != nil, phase != .idle, phase != .loading, !isFailed else { return .nothingPlaying }
        switch representation {
        case nil: return .presentationUnknown
        case .audio?: return .alreadyAudio
        case .live?: return .liveStream
        case .video?: return counterpartRepresentation == .audio ? nil : .noAudioVersionPublished
        }
    }
    public var canGoLive: Bool { !isAd && isLive && !atLiveEdge && (phase == .playing || phase == .paused || phase == .buffering) }
    public var canSkip: Bool { !restored && !isAd && playlistID != nil && phase != .idle && phase != .loading }
    public var isFailed: Bool { if case .failed = phase { true } else { false } }
}

public enum WebMusicRefusal: Error, Sendable, Equatable {
    case advertisement, nothingLoaded, invalidTarget
    /// A live stream whose player offers no rewindable window.
    case liveNotSeekable
    case notLive, alreadyLive
    public var message: String {
        switch self {
        case .advertisement: String(localized: "Seeking and skipping are unavailable while an ad plays.")
        case .nothingLoaded: String(localized: "Nothing is playing.")
        case .invalidTarget: String(localized: "That position is not valid.")
        case .liveNotSeekable: String(localized: "This live stream offers no earlier part to seek to. Go live is the only way to move.")
        case .notLive: String(localized: "This is not a live stream.")
        case .alreadyLive: String(localized: "Already at the live edge.")
        }
    }
}

/// Pure transport state: document/load generations, accepted samples, ad state
/// and command admission. The WebKit host and the bridge feed it; it never
/// touches WebKit, so every fencing rule is unit-testable.
public struct WebMusicTransport: Sendable {
    public private(set) var snapshot = WebMusicSnapshot()
    /// Native-assigned generation of the document allowed to report (0 = none).
    public private(set) var document: UInt64 = 0
    /// Native playback request generation (0 = nothing requested).
    public private(set) var load: UInt64 = 0
    /// Whether the current load has been confirmed by evidence of the new request.
    public private(set) var confirmed = false
    /// On the in-page router path the outgoing track keeps reporting under the new
    /// load until the router acts, so confirmation needs evidence of the request:
    /// the requested playlist ID, or (when the page reports none) a different video.
    public private(set) var requiresEvidence = false
    /// The current load is a shuffle: only a report of the requested playlist that does not show shuffle off confirms it.
    public private(set) var requiresShuffle = false
    private var outgoingVideo: String?
    private var outgoingPlaylist: String?
    /// Ad creative being played, kept until the content video returns (ad pods).
    private var adVideo: String?
    private var lastEnded: String?
    /// Counterparts the service has published for items played in this session.
    public private(set) var catalog = RepresentationCatalog()
    public private(set) var live: LiveWindow?
    /// The newest media facts accepted for the playing item (frames, picture size, window).
    public private(set) var media: WebMusicMediaSample?
    /// Media facts that arrived before the load was confirmed (same report as the first state sample); applied once it is.
    private var pendingMedia: WebMusicMediaSample?
    public init() {}

    /// A new explicit playback request. Older loads can no longer publish.
    public mutating func begin(playlistID: String, title: String?) -> UInt64 {
        load += 1; confirmed = false; lastEnded = nil; adVideo = nil; requiresShuffle = false; live = nil; media = nil; pendingMedia = nil
        outgoingVideo = snapshot.videoID; outgoingPlaylist = snapshot.playlistID; requiresEvidence = false
        var next = WebMusicSnapshot()
        next.phase = .loading; next.playlistID = playlistID; next.playlistTitle = title; next.intent = true; next.volume = snapshot.volume
        snapshot = next
        return load
    }
    /// The request goes through the in-page router of the existing document.
    public mutating func expectRouter() { requiresEvidence = true }
    /// The request is a shuffle: nothing the page does in order may confirm it.
    public mutating func expectShuffle() { requiresEvidence = true; requiresShuffle = true }
    /// Reserves the generation for the next full document load. A fresh document
    /// cannot carry the outgoing track, so anything it plays belongs to this load.
    public mutating func reserveDocument() -> UInt64 { document += 1; requiresEvidence = false; return document }
    /// Teardown/process loss: no document may report until the next explicit load.
    public mutating func invalidateDocument() { document += 1 }

    public mutating func fail(_ failure: WebMusicFailure, load failedLoad: UInt64? = nil) {
        if let failedLoad, failedLoad != load { return }
        snapshot.phase = .failed(failure); snapshot.intent = false; snapshot.isAd = false
    }
    public mutating func reset() {
        let volume = snapshot.volume
        load += 1; document += 1; confirmed = false; lastEnded = nil; adVideo = nil; outgoingVideo = nil; requiresEvidence = false; requiresShuffle = false
        live = nil; media = nil; pendingMedia = nil; catalog.removeAll()
        snapshot = WebMusicSnapshot(); snapshot.volume = volume
    }
    public mutating func setIntent(_ play: Bool) { snapshot.intent = play }
    public mutating func setRouteLossPause(_ on: Bool) { snapshot.pausedByRouteLoss = on }
    /// A cold launch's restored item: paused, with no page behind it, only while nothing has ever been requested in this session.
    public mutating func restore(playlistID: String, playlistTitle: String?, title: String?, artist: String?, position: Double, duration: Double) -> Bool {
        guard load == 0, snapshot.phase == .idle else { return false }
        var next = WebMusicSnapshot()
        next.phase = .paused; next.playlistID = playlistID; next.playlistTitle = playlistTitle; next.title = title; next.artist = artist
        next.position = position; next.duration = duration; next.intent = false; next.restored = true; next.volume = snapshot.volume
        snapshot = next
        return true
    }
    public mutating func setVolume(_ level: Double) { snapshot.volume = level }

    /// Applies one already-validated message. Returns false when it was stale.
    @discardableResult
    public mutating func apply(_ message: WebMusicMessage) -> Bool {
        guard message.document == document, message.load == load, load > 0 else { return false }
        if snapshot.isFailed { return false }
        switch message.event {
        case .state(let sample):
            apply(sample)
        case .ended(let videoID):
            // One ended report per occurrence of confirmed content; never for an ad.
            guard confirmed, !snapshot.isAd, videoID == nil || videoID != adVideo, lastEnded != videoID || videoID == nil else { return false }
            lastEnded = videoID
            snapshot.phase = .ended; snapshot.position = snapshot.duration
        case .page(let app, let unsupported):
            guard !app else { return true }
            fail(unsupported ? .unsupportedBrowser : .notMusicApp)
        case .media(let sample):
            apply(sample)
        case .playerError(let code):
            // YouTube's own queue may advance past an unplayable track: keep tracking
            // what the page does instead of freezing the transport.
            snapshot.notice = .notPlayable(code: code)
        }
        return true
    }
    private mutating func apply(_ sample: WebMusicSample) {
        if sample.signedIn == false {
            // A signed-out page would play as a guest; never present that as the account.
            fail(.signInRequired); return
        }
        // Kaset's ad-pod continuity, against the same reference the page uses: the
        // requested content's own ID (`v`). A creative is recorded only when its ID
        // differs from that content, so a server-stitched ad (which carries the
        // content's ID) or a lingering ad flag can never latch the content as an ad.
        // Without a known content ID nothing is recorded and the page's own `ad`
        // decision (which already applies the same rule) is used alone.
        let content = sample.contentID
        if let content, adVideo == content { adVideo = nil }
        let awaitingContent = adVideo != nil && content != nil && sample.videoID != content
            && (sample.videoID == nil || sample.videoID == adVideo)
        if sample.ad || awaitingContent {
            if sample.ad, let id = sample.videoID, let content, id != content { adVideo = id }
            snapshot.isAd = true
            // Keep the selected track's title, artist, artwork and content clock.
            snapshot.phase = sample.playing ? .playing : (sample.buffering ? .buffering : (snapshot.intent ? .buffering : .paused))
            return
        }
        adVideo = nil
        snapshot.isAd = false
        let hasMedia = sample.videoID != nil || sample.duration > 0
        guard hasMedia else {
            if !confirmed { snapshot.phase = .loading }
            return
        }
        if !confirmed {
            guard isEvidence(sample) else { snapshot.phase = .loading; return }
            confirmed = true
        }
        defer { if confirmed, let held = pendingMedia { pendingMedia = nil; apply(held) } }
        if let id = sample.videoID, id != snapshot.videoID {
            snapshot.videoID = id; lastEnded = nil; snapshot.notice = nil
            // A new track: never carry the previous track's text into it.
            snapshot.title = nil; snapshot.artist = nil; snapshot.artworkURL = nil
            clearMediaFacts()
        }
        if let title = sample.title { snapshot.title = title }
        if let artist = sample.artist { snapshot.artist = artist }
        if let artwork = sample.artworkURL { snapshot.artworkURL = artwork }
        snapshot.duration = sample.duration
        snapshot.position = min(sample.position, sample.duration > 0 ? sample.duration : sample.position)
        refreshLive()
        if sample.buffering { snapshot.phase = .buffering }
        else if sample.playing { snapshot.phase = .playing }
        else if snapshot.phase == .ended, lastEnded == snapshot.videoID { snapshot.phase = .ended }
        else { snapshot.phase = .paused }
    }
    private mutating func clearMediaFacts() {
        live = nil; media = nil
        snapshot.representation = nil; snapshot.liveRewindable = false; snapshot.atLiveEdge = true; snapshot.pictureSize = nil
        snapshot.counterpartVideoID = nil; snapshot.counterpartRepresentation = nil; snapshot.restart = nil
        snapshot.quality = nil; snapshot.qualities = []; snapshot.captions = .unavailable
        snapshot.elementRate = nil
    }
    /// A speed command's read-back confirmed this element speed.
    public mutating func noteElementRate(_ rate: Double) { snapshot.elementRate = rate }
    /// Media facts describe the item that is playing now: nothing before the load is confirmed, and nothing for another video. During an
    /// ad only the picture (the creative is shown, never hidden) and the Picture in Picture state are taken; the content's presentation
    /// is not the ad's.
    private mutating func apply(_ sample: WebMusicMediaSample) {
        // A pre-roll ad is shown before the load is confirmed (rework F1): its picture is available to be shown, never withheld.
        guard confirmed || snapshot.isAd else { pendingMedia = sample; return }
        if !snapshot.isAd, let id = sample.videoID, let current = snapshot.videoID, id != current { return }
        media = sample
        // The element's speed is taken during an ad too: an advertisement must be seen to play at 1x, not assumed to.
        if let rate = sample.rate { snapshot.elementRate = rate }
        snapshot.pictureSize = sample.pictureWidth > 0 && sample.pictureHeight > 0 ? CGSize(width: sample.pictureWidth, height: sample.pictureHeight) : nil
        snapshot.pictureInPicture = sample.pictureInPicture
        snapshot.presenting = sample.isolated
        if snapshot.isAd { return }
        snapshot.quality = sample.quality; snapshot.qualities = sample.qualities; snapshot.captions = sample.captions
        snapshot.representation = sample.representation
        if sample.representation == .live, let start = sample.liveStart, let end = sample.liveEnd, let window = LiveWindow(start: start, end: end) {
            live = window
        } else { live = nil }
        refreshLive()
        if let current = snapshot.videoID, let other = sample.counterpartID, other != current, let rep = sample.representation, rep != .live {
            let mine = MediaAssetIdentity.youTubeMusic(current), theirs = MediaAssetIdentity.youTubeMusic(other)
            let pair = rep == .video ? PublishedCounterpart(audio: theirs, video: mine) : PublishedCounterpart(audio: mine, video: theirs)
            if let pair { catalog.publish(pair) }
            snapshot.counterpartVideoID = other
            snapshot.counterpartRepresentation = rep == .video ? .audio : .video
        }
    }
    private mutating func refreshLive() {
        snapshot.liveRewindable = live?.isRewindable ?? false
        snapshot.atLiveEdge = live.map { $0.isAtLiveEdge(position: snapshot.position) } ?? true
    }
    /// How far behind the live edge playback is, when the player reported a window.
    public var behindLive: Double? { live.map { $0.behindLive(position: snapshot.position) } }
    /// The player recorded why a representation switch started from the beginning.
    public mutating func setRestart(_ reason: RepresentationTransition.RestartReason?) { snapshot.restart = reason }
    /// What is playing, for the representation use case. Nil until the page said how the item is presented.
    public func current() -> RepresentationTransition.Current? {
        guard let id = snapshot.videoID, let representation = snapshot.representation else { return nil }
        return .init(asset: .youTubeMusic(id), representation: representation, position: snapshot.position,
                     duration: snapshot.duration > 0 ? snapshot.duration : nil, isAdvertisement: snapshot.isAd)
    }
    private func isEvidence(_ sample: WebMusicSample) -> Bool {
        if requiresShuffle {
            // The page must report the requested playlist, and must not report shuffle off.
            guard let playlist = sample.playlistID, playlist == snapshot.playlistID, sample.shuffle != false else { return false }
            // Re-shuffling the playlist that is already playing: the old, in-order playback reports the same playlist, so only an
            // explicit "shuffle on" from the page counts as the new start.
            if playlist == outgoingPlaylist { return sample.shuffle == true }
            return true
        }
        guard requiresEvidence else { return true }
        if let playlist = sample.playlistID { return playlist == snapshot.playlistID }
        guard let id = sample.videoID else { return false }
        return id != outgoingVideo
    }

    /// Seeking is refused during an ad and when nothing seekable is loaded.
    public func admitSeek(_ target: Double) -> Result<Double, WebMusicRefusal> {
        if snapshot.isAd { return .failure(.advertisement) }
        guard snapshot.canSeek else { return snapshot.isLive ? .failure(.liveNotSeekable) : .failure(.nothingLoaded) }
        guard target.isFinite else { return .failure(.invalidTarget) }
        // A live stream is clamped into the window its player can reach; a target past the live edge is the live edge.
        if snapshot.isLive {
            guard let live, let clamped = live.clamp(target) else { return .failure(.liveNotSeekable) }
            return .success(clamped)
        }
        return .success(min(max(0, target), snapshot.duration))
    }
    /// Go live jumps to the live edge of the window the player reported.
    public func admitGoLive() -> Result<Double, WebMusicRefusal> {
        if snapshot.isAd { return .failure(.advertisement) }
        guard snapshot.isLive else { return .failure(.notLive) }
        guard let live, snapshot.phase == .playing || snapshot.phase == .paused || snapshot.phase == .buffering else { return .failure(.nothingLoaded) }
        if snapshot.atLiveEdge { return .failure(.alreadyLive) }
        return .success(live.end)
    }
    /// Next/previous would leave an ad early, so both are refused during one.
    public func admitSkip() -> Result<Void, WebMusicRefusal> {
        if snapshot.isAd { return .failure(.advertisement) }
        guard snapshot.canSkip else { return .failure(.nothingLoaded) }
        return .success(())
    }
    /// PLAY11: Previous restarts after three seconds of playback.
    public var previousRestarts: Bool { snapshot.position > 3 && !snapshot.isLive }
}
