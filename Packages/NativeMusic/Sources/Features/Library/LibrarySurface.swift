import AccountSession
import Foundation
import Observation

/// One control on an entry: a change the entry published and the person may ask for. The label says what pressing it does.
public struct LibraryControl: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case like, dislike, save, follow }
    public let kind: Kind
    public let key: LibraryWriteKey
    /// Whether the thing is on now (liked, saved, followed), with any change in flight already applied.
    public let isOn: Bool
    /// The change pressing it makes.
    public let intent: LibraryIntent
    public let title: String
    public let symbol: String
    public var id: String { kind.rawValue }
}

/// Which controls an entry offers, from what the entry itself published. Nothing is offered that the entry did not carry; a
/// collection whose membership is the state (an album in Albums is saved) supplies that state, and the target is the id the
/// entry names.
public enum LibraryControls {
    @MainActor public static func make(item: MusicCatalogItem, source: LibrarySource?, ledger: LibraryWriteLedger) -> [LibraryControl] {
        var controls: [LibraryControl] = []
        let kind = source?.kind
        var published = item.controls ?? MusicItemControls()
        // The one action the collection's own membership supplies is Unfollow in Following: an artist listed there is followed, and
        // `subscription/unsubscribe` takes the channel id the row names (`UC…`, or the library's `MPLAUC…` form). Saved albums,
        // playlists and shows, and ratings, are offered only where the entry published the toggle: the web client offers no
        // "remove from library" on the person's own playlists, Liked Music or Episodes for Later, so none is invented from membership.
        if kind == .following, published.follow == nil, item.kind == .artist, let browse = item.browseID,
           let channel = MusicLibraryKind.channelID(fromBrowseID: browse) {
            published.follow = .init(channelID: channel, isFollowing: true, params: nil)
        }
        if let like = published.like {
            let current = ledger.rating(like.videoID, service: like.status)
            let liked = current == .like
            controls.append(LibraryControl(kind: .like, key: .rating(videoID: like.videoID), isOn: liked, intent: .rate(like, to: liked ? .indifferent : .like),
                                           title: liked ? String(localized: "Remove Like") : String(localized: "Like"), symbol: liked ? "heart.fill" : "heart"))
            if like.dislikeExposed {
                let disliked = current == .dislike
                controls.append(LibraryControl(kind: .dislike, key: .rating(videoID: like.videoID), isOn: disliked, intent: .rate(like, to: disliked ? .indifferent : .dislike),
                                               title: disliked ? String(localized: "Remove Dislike") : String(localized: "Dislike"), symbol: disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown"))
            }
        }
        if let song = published.songLibrary, let video = item.videoID {
            let saved = ledger.isSaved(.songSaved(videoID: video), service: song.isSaved)
            if let intent = LibraryIntent.setSongSaved(song, videoID: video, to: !saved) {
                controls.append(LibraryControl(kind: .save, key: .songSaved(videoID: video), isOn: saved, intent: intent,
                                               title: saved ? String(localized: "Remove from Library") : String(localized: "Save to Library"), symbol: saved ? "bookmark.fill" : "bookmark"))
            }
        }
        if let save = published.save, let was = save.isSaved {
            let saved = ledger.isSaved(.playlistSaved(playlistID: save.playlistID), service: was)
            controls.append(LibraryControl(kind: .save, key: .playlistSaved(playlistID: save.playlistID), isOn: saved, intent: .setSaved(save, to: !saved, was: was),
                                           title: saved ? String(localized: "Remove from Library") : String(localized: "Save to Library"), symbol: saved ? "bookmark.fill" : "bookmark"))
        }
        if let follow = published.follow, let was = follow.isFollowing {
            let following = ledger.isFollowing(follow.channelID, service: was)
            controls.append(LibraryControl(kind: .follow, key: .following(channelID: follow.channelID), isOn: following, intent: .setFollowing(follow, to: !following, was: was),
                                           title: following ? String(localized: "Unfollow") : String(localized: "Follow"), symbol: following ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.plus"))
        }
        return controls
    }
    /// The controls a page header publishes for the page itself (an album's Save, an artist's Follow).
    @MainActor public static func make(page actions: MusicPageActions, ledger: LibraryWriteLedger) -> [LibraryControl] {
        var controls: [LibraryControl] = []
        if let save = actions.controls.save, !save.playlistID.isEmpty, let was = save.isSaved {
            let saved = ledger.isSaved(.playlistSaved(playlistID: save.playlistID), service: was)
            controls.append(LibraryControl(kind: .save, key: .playlistSaved(playlistID: save.playlistID), isOn: saved, intent: .setSaved(save, to: !saved, was: was),
                                           title: saved ? String(localized: "Remove from Library") : String(localized: "Save to Library"), symbol: saved ? "bookmark.fill" : "bookmark"))
        }
        if let follow = actions.controls.follow, let was = follow.isFollowing {
            let following = ledger.isFollowing(follow.channelID, service: was)
            controls.append(LibraryControl(kind: .follow, key: .following(channelID: follow.channelID), isOn: following, intent: .setFollowing(follow, to: !following, was: was),
                                           title: following ? String(localized: "Unfollow") : String(localized: "Follow"), symbol: following ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.plus"))
        }
        return controls
    }
}

/// The Library and History destinations' shared state, owned by the shell: one collection model per kind (so Back returns to the
/// same rows), the history, the write ledger, and the plays and links the rows can run.
@MainActor @Observable public final class LibrarySurface {
    public let models: [MusicLibraryKind: LibraryCollectionModel]
    public let history: HistoryModel
    public let ledger: LibraryWriteLedger
    public var selectedKind: MusicLibraryKind = .songs
    /// The Uploads destination's state (W19), set by the composition; the account-change hook below reaches it.
    public var uploads: UploadsSurface?
    /// Playlist editing (W13), set by the shell; nil: no playlist control is offered anywhere.
    public var playlists: PlaylistSurface?
    /// The kept (downloaded) items, set by the composition (W15). With it the Library offers a Downloaded-only section; without it, none.
    public var downloads: DownloadsModel?
    /// Whether the Library currently shows only what is kept on this Mac.
    public var showsDownloadedOnly = false
    public private(set) var feedback: [String: SearchItemFeedback] = [:]
    /// The labelled development data answers instead of the service (Debug, isolated UI runs only).
    public let development: Bool
    @ObservationIgnored public weak var performer: (any SearchActionPerformer)?
    @ObservationIgnored private let playbackState: @MainActor () -> SearchPlayback
    @ObservationIgnored private let accountScope: @MainActor () -> String

    public init(models: [MusicLibraryKind: LibraryCollectionModel], history: HistoryModel, ledger: LibraryWriteLedger, performer: (any SearchActionPerformer)?,
                playback: @escaping @MainActor () -> SearchPlayback, accountScope: @escaping @MainActor () -> String = { "" }, development: Bool = false) {
        self.models = models; self.history = history; self.ledger = ledger; self.performer = performer; playbackState = playback; self.accountScope = accountScope
        self.development = development
    }
    public var model: LibraryCollectionModel { models[selectedKind]! }
    public var playback: SearchPlayback { playbackState() }
    public func offers(for item: MusicCatalogItem) -> [CatalogActionOffer] {
        // An uploaded track plays from the Uploads library; the catalog's radio does not exist for it.
        if item.isUpload {
            return [CatalogActionOffer(action: .play, unavailable: String(localized: "Playing uploads isn’t available in this version.")), ]
        }
        return CatalogActionPlan.offers(for: item, playback: playbackState())
    }
    /// The shell calls this when the active account (or whether its session is live) changes.
    public func accountChanged() {
        for model in models.values { model.accountChanged() }
        history.accountChanged(); ledger.accountChanged(); playlists?.accountChanged(); feedback = [:]
        uploads?.accountChanged()
    }
    public func perform(_ action: CatalogAction, on item: MusicCatalogItem, key: String) async {
        guard let offer = offers(for: item).first(where: { $0.action == action }) else { feedback[key] = .failed(String(localized: "This action isn’t available for this item.")); return }
        if let reason = offer.unavailable { feedback[key] = .failed(reason); return }
        guard let performer else { feedback[key] = .failed(String(localized: "This action isn’t available right now.")); return }
        switch action {
        case .copyLink:
            guard let link = CatalogActionPlan.link(for: item) else { feedback[key] = .failed(String(localized: "This item has no link.")); return }
            performer.copy(link: link); feedback[key] = .copied
        case .play:
            guard let target = CatalogActionPlan.target(for: item) else { feedback[key] = .failed(String(localized: "This item didn’t include anything to play.")); return }
            let scope = accountScope()
            feedback[key] = .working
            let outcome = (target.videoID == nil && target.params == nil)
                ? await performer.play(playlistID: target.playlistID, title: item.title)
                : await performer.play(playlistID: target.playlistID, title: item.title, videoID: target.videoID, params: target.params)
            guard accountScope() == scope else { feedback[key] = nil; return }
            switch outcome {
            case .started: feedback[key] = .started
            case .busy: feedback[key] = nil
            case .stale: feedback[key] = .failed(String(localized: "Your account changed before this started. Try again."))
            case .failed: feedback[key] = .failed(String(localized: "YouTube Music couldn’t start this. Try again."))
            }
        case .shuffle, .radio: feedback[key] = .failed(String(localized: "This action isn’t available for this item."))
        }
    }
    /// Copies the links of the selected entries (a non-changing action on a selection).
    public func copyLinks(of entries: [LibraryEntry]) -> Int {
        let links = entries.compactMap { CatalogActionPlan.link(for: $0.item) }
        guard !links.isEmpty, let performer else { return 0 }
        performer.copy(text: links.map(\.absoluteString).joined(separator: "\n"))
        return links.count
    }
}
