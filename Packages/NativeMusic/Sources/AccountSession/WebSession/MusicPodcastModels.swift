import Foundation

/// What a podcast episode (a row of a show page, or the episode page itself) printed about the listener's progress and about its own menu.
///
/// Internal notes: in the real anonymous captures EVERY episode row carries a `playedText` ("Played") beside a progress of 0. The label is
/// furniture the row always ships, not a statement that the episode was played, so it is recorded only as `playedLabelPublished` and never
/// read as played. The only played evidence is the service's percentage reaching 100. The scale of `playbackProgressPercentage` (0…100) is
/// taken from its name; a signed capture with a part-played episode is on the end-of-project live list (`Docs/PodcastsLyrics.md`).
public struct MusicEpisodeInfo: Sendable, Equatable {
    /// The service's `playbackProgressPercentage`, 0…100, when it printed one in range. Nil: nothing readable (never "0%").
    public let progressPercent: Double?
    /// The length as the service printed it ("14 min 45 sec", "18 min"), from the progress renderer's own duration text.
    public let durationText: String?
    /// The token the service attached to the progress (`videoPlaybackPositionFeedbackToken`). Parsed and counted, never sent: marking an
    /// episode played at the service is not a write this app makes.
    public let hasPositionFeedbackToken: Bool
    /// The row carried a "Played" label (every real row does, played or not).
    public let playedLabelPublished: Bool
    /// The episode's menu carries YouTube Music's own `offlineVideoEndpoint` ("Download"). It is the web client's action on its own offline store,
    /// not a permission to keep the media on this Mac, so it never becomes a control (W15, `Docs/Downloads.md`).
    public let publishesServiceDownloadAction: Bool
    /// The row's own description text, verbatim (bounded), when the row printed one. A show page lists it under each episode.
    public let summary: String?
    public init(progressPercent: Double? = nil, durationText: String? = nil, hasPositionFeedbackToken: Bool = false, playedLabelPublished: Bool = false,
                publishesServiceDownloadAction: Bool = false, summary: String? = nil) {
        self.progressPercent = progressPercent; self.durationText = durationText; self.hasPositionFeedbackToken = hasPositionFeedbackToken
        self.playedLabelPublished = playedLabelPublished; self.publishesServiceDownloadAction = publishesServiceDownloadAction; self.summary = summary
    }
    /// The service says the episode was played to the end (and not merely that a label exists).
    public var servicePlayedToEnd: Bool { (progressPercent ?? 0) >= 100 }
    /// The service says part of the episode was played.
    public var serviceInProgress: Bool { (progressPercent ?? 0) > 0 && !servicePlayedToEnd }
}

/// The "Episodes for Later" toggle of an episode page: what it acts on, and which directions the page itself published.
///
/// Internal notes: the anonymous capture publishes the REMOVE direction (a `playlistEditEndpoint` on `playlistId: "SE"` with
/// the remove-by-video action) and a sign-in modal in place of the add direction. A signed page is expected to publish
/// `ACTION_ADD_VIDEO` for the add side (the reference clients' form); that shape has not been seen from the service.
public struct MusicEpisodeLater: Sendable, Equatable {
    public let videoID: String
    /// Whether the page shows the episode as already saved (`isToggled`).
    public let isSaved: Bool
    /// The page published an add endpoint for this episode / a remove endpoint for it. A direction is offered only when published.
    public let addPublished: Bool
    public let removePublished: Bool
    public init(videoID: String, isSaved: Bool, addPublished: Bool, removePublished: Bool) {
        self.videoID = videoID; self.isSaved = isSaved; self.addPublished = addPublished; self.removePublished = removePublished
    }
    /// What pressing the control would set, or nil when the page published no way to do it. The control is shown as saved (`shownSaved`) or not;
    /// a saved episode offers Remove only if the page published a remove, an unsaved one offers Save only if it published an add. Never both
    /// directions at once, and never a direction the page did not publish: this is the one gate in front of the write.
    public func offeredChange(shownSaved: Bool) -> Bool? {
        if shownSaved { return removePublished ? false : nil }
        return addPublished ? true : nil
    }
}

/// Every renderer of an episode page, counted by where it ended up. `menuItems == menuRecognised + menuIgnored.count` and
/// `sections == headerSections + descriptionSections + unsupportedSections`; a test compares both with an independent walk of the raw JSON.
public struct MusicEpisodeAccounting: Sendable, Equatable {
    public var sections = 0
    public var headerSections = 0
    public var descriptionSections = 0
    public var unsupportedSections = 0
    public var buttons = 0
    public var buttonsRecognised = 0
    public var buttonsIgnored: [String] = []
    public var menuItems = 0
    public var menuRecognised = 0
    public var menuIgnored: [String] = []
    public var consistent: Bool {
        sections == headerSections + descriptionSections + unsupportedSections
            && buttons == buttonsRecognised + buttonsIgnored.count && menuItems == menuRecognised + menuIgnored.count
    }
    public init() {}
}

/// An episode page (`MPED…`): the episode, the show it belongs to, its progress, its description and its Episodes-for-Later toggle.
public struct MusicEpisodePage: Sendable, Equatable {
    public let videoID: String
    public let title: String
    /// "5 views", "Sep 23", as printed (no year is published, so no date is derived from it).
    public let details: [String]
    /// The show this episode belongs to (its strapline link, or the "Go to podcast" menu item).
    public let show: MusicLink?
    public let thumbnails: [MusicThumbnail]
    public let description: [MusicTextRun]
    public let info: MusicEpisodeInfo
    public let later: MusicEpisodeLater?
    public let accounting: MusicEpisodeAccounting
    public init(videoID: String, title: String, details: [String], show: MusicLink?, thumbnails: [MusicThumbnail], description: [MusicTextRun],
                info: MusicEpisodeInfo, later: MusicEpisodeLater?, accounting: MusicEpisodeAccounting) {
        self.videoID = videoID; self.title = title; self.details = details; self.show = show; self.thumbnails = thumbnails
        self.description = description; self.info = info; self.later = later; self.accounting = accounting
    }
}

// MARK: Lyrics

/// One timed line, in seconds. Only a source that printed times produces these; nothing is estimated.
public struct MusicTimedLyricLine: Sendable, Equatable {
    public let text: String
    public let start: Double
    public let end: Double?
    public init(text: String, start: Double, end: Double?) { self.text = text; self.start = start; self.end = end }
}
/// Lyrics exactly as the source supplied them. `sourceFooter` is the source's own attribution line, verbatim ("Source: …").
public struct MusicLyricsDocument: Sendable, Equatable {
    public enum Body: Sendable, Equatable {
        /// The whole text in one piece, byte for byte as published (line breaks included). No timing exists.
        case plain(String)
        /// Lines with the start times the source printed, in the source's order.
        case timed([MusicTimedLyricLine])
    }
    public let body: Body
    public let sourceFooter: String?
    public init(body: Body, sourceFooter: String?) { self.body = body; self.sourceFooter = sourceFooter }
    public var isTimed: Bool { if case .timed = body { true } else { false } }
}
/// Why a song has no lyrics to show. Distinct from a failed load, which is an error thrown by the read.
public enum MusicLyricsAbsence: Sendable, Equatable {
    /// The song's `next` response was read and offers no lyrics page.
    case notOffered
    /// The lyrics page was read and held no text (a message instead of lyrics).
    case emptyPage
}
public enum MusicLyricsResult: Sendable, Equatable {
    case lyrics(MusicLyricsDocument)
    case none(MusicLyricsAbsence)
}

/// A tab of a song's `next` response, classified by its own endpoint or content, never by its localised title.
public struct MusicWatchNextTab: Sendable, Equatable {
    public enum Kind: String, Sendable { case upNext, lyrics, related, other }
    public let kind: Kind
    /// The browse page the tab opens (lyrics, related), when the tab is selectable.
    public let browseID: String?
    public let unselectable: Bool
    public init(kind: Kind, browseID: String?, unselectable: Bool) { self.kind = kind; self.browseID = browseID; self.unselectable = unselectable }
}
/// What a song's `next` response says about where its lyrics are. A response with no up-next tab is not a watch-next page at all and is
/// refused by the parser, so `lyricsBrowseID == nil` here is a real "no lyrics page offered".
public struct MusicWatchNext: Sendable, Equatable {
    public let tabs: [MusicWatchNextTab]
    public var lyricsBrowseID: String? { tabs.first(where: { $0.kind == .lyrics && !$0.unselectable })?.browseID }
    public init(tabs: [MusicWatchNextTab]) { self.tabs = tabs }
}
