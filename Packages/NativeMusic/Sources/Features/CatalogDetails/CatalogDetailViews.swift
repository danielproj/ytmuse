import AccountSession
import DesignSystem
import Domain
import SwiftUI

/// The header every collection page shares: artwork, the title and its lines, linked credits, and the page's actions.
struct CollectionHeaderView: View {
    @Bindable var model: CatalogPageModel
    let header: MusicPageHeader
    let navigator: CatalogNavigator
    var artworkEdge: CGFloat = 200
    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            HStack(alignment: .top, spacing: MusicSpace.lg) {
                CatalogArtworkView(thumbnails: header.thumbnails, edge: artworkEdge, corner: .feature)
                VStack(alignment: .leading, spacing: MusicSpace.xs) {
                    Text(header.title).font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader).accessibilityIdentifier("catalogTitle")
                    if !header.subtitle.isEmpty {
                        Text(header.subtitle.joined(separator: String(localized: "detailSeparator"))).foregroundStyle(MusicStyle.secondaryText)
                    }
                    if !header.credits.isEmpty { CreditLinks(links: header.credits, navigator: navigator) }
                    if let byline = header.byline { Text(byline).foregroundStyle(MusicStyle.secondaryText) }
                    if let audience = header.audienceText { Text(audience).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("catalogAudience") }
                    if !header.secondSubtitle.isEmpty {
                        Text(header.secondSubtitle.joined(separator: String(localized: "detailSeparator"))).font(.callout).foregroundStyle(MusicStyle.secondaryText)
                    }
                    PageActionsBar(model: model)
                    ShowEpisodeControls(model: model)
                    // Where a person would look for Download on a collection: the reason there is none, as words, not a control.
                    if let identifier = try? ServiceID(model.target.browseID) { DownloadCapabilityNote(media: identifier) }
                    PlaylistEditEntry(model: model, header: header, navigator: navigator)
                }
            }
            RichDescriptionView(runs: header.description)
        }
    }
}

/// A podcast show's episode controls: the sort menu, and this show's listening speed. Drawn only on a show page where the shell offers podcasts.
struct ShowEpisodeControls: View {
    @Bindable var model: CatalogPageModel
    @Environment(\.podcastsSurface) private var podcasts
    var body: some View {
        if let podcasts, model.target.browseID.hasPrefix("MPSP") {
            HStack(spacing: MusicSpace.sm) {
                EpisodeSortMenu(surface: podcasts)
                Text("Speed").font(.caption).foregroundStyle(MusicStyle.secondaryText)
                PodcastRateMenu(playback: podcasts.playback, show: model.target.browseID, rate: podcasts.playback.rate(forShow: model.target.browseID))
                PodcastSkipMenu(playback: podcasts.playback)
            }.accessibilityElement(children: .contain).accessibilityIdentifier("showEpisodeControls")
        }
    }
}

/// Artists linked from a credit line; each opens that artist.
struct CreditLinks: View {
    let links: [MusicLink]
    let navigator: CatalogNavigator
    var body: some View {
        HStack(spacing: MusicSpace.xxs) {
            ForEach(Array(links.enumerated()), id: \.offset) { index, link in
                if index > 0 { Text("·").foregroundStyle(MusicStyle.secondaryText) }
                if link.kind == .other { Text(link.title) }
                else { Button(link.title) { navigator.openLink(link) }.buttonStyle(.link).accessibilityIdentifier("catalogCredit-" + link.browseID) }
            }
        }.accessibilityElement(children: .contain)
    }
}

/// An artist, album, playlist or podcast-show page: the header, then every shelf the service sent, in its order.
public struct CollectionDetailView: View {
    @Bindable var model: CatalogPageModel
    let fallbackTitle: String
    let navigator: CatalogNavigator
    public init(model: CatalogPageModel, fallbackTitle: String, navigator: CatalogNavigator) {
        self.model = model; self.fallbackTitle = fallbackTitle; self.navigator = navigator
    }
    public var body: some View {
        CatalogShelvesView(model: model, navigator: navigator) {
            VStack(alignment: .leading, spacing: MusicSpace.sm) {
                HStack {
                    if model.header == nil { Text(model.heading ?? fallbackTitle).font(.largeTitle.bold()).accessibilityIdentifier("catalogTitle") }
                    Spacer()
                    Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .labelStyle(.iconOnly).help(Text("Refresh")).musicButtons().disabled(model.isRefreshing || model.phase == .loading)
                        .accessibilityIdentifier("catalogRefresh")
                }
                if let header = model.header { CollectionHeaderView(model: model, header: header, navigator: navigator) }
            }
        }
        .modifier(PlaylistPageDrop(model: model))
    }
}

/// A song or video opened from a row: credits as links, availability, the actions that really run, and an honest quality line.
public struct SongDetailView: View {
    let detail: SongDetail
    let playback: SearchPlayback
    @Bindable var model: CatalogPageModel
    let navigator: CatalogNavigator
    @Environment(\.libraryLedger) private var ledger
    @Environment(\.socialSurface) private var social
    public init(detail: SongDetail, playback: SearchPlayback, model: CatalogPageModel, navigator: CatalogNavigator) {
        self.detail = detail; self.playback = playback; self.model = model; self.navigator = navigator
    }
    public var body: some View {
        let item = detail.item
        let offers = detail.offers(playback: model.playback)
        ScrollView {
            VStack(alignment: .leading, spacing: MusicSpace.lg) {
                HStack(alignment: .top, spacing: MusicSpace.lg) {
                    CatalogArtworkView(thumbnails: item.thumbnails, edge: 200, corner: .feature)
                    VStack(alignment: .leading, spacing: MusicSpace.xs) {
                        HStack(spacing: MusicSpace.xs) {
                            Text(item.title).font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                                .accessibilityIdentifier("catalogTitle")
                            if item.explicit { ExplicitBadge() }
                        }
                        Text(item.kind.title).foregroundStyle(MusicStyle.secondaryText)
                        if !detail.artists.isEmpty { CreditLinks(links: detail.artists, navigator: navigator) }
                        if let album = detail.album { Button(album.title) { navigator.openLink(album) }.buttonStyle(.link).accessibilityIdentifier("songAlbumLink") }
                        let rest = item.details.filter { part in !item.links.contains { $0.title == part } }
                        if !rest.isEmpty { Text(rest.joined(separator: String(localized: "detailSeparator"))).font(.callout).foregroundStyle(MusicStyle.secondaryText) }
                        if let duration = item.durationText { Text(duration).font(.callout.monospacedDigit()).foregroundStyle(MusicStyle.secondaryText) }
                    }
                }
                if detail.availabilityKnown {
                    Label(detail.isAvailable ? "Available to play" : "Not available to you right now", systemImage: detail.isAvailable ? "checkmark.circle" : "nosign")
                        .accessibilityIdentifier("songAvailability")
                } else {
                    Label("This page was reopened without its details, so availability isn’t known. Play and Copy Link still work.", systemImage: "questionmark.circle")
                        .accessibilityIdentifier("songAvailability")
                }
                Label("Audio quality is chosen by YouTube Music’s own player. YTMuse doesn’t measure or select it.", systemImage: "waveform")
                    .font(.callout).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("songQuality")
                MusicGlassGroup {
                    HStack {
                        ForEach(offers) { offer in
                            Button { Task { await model.perform(offer.action, on: item) } } label: { Label(offer.action.title, systemImage: offer.action.symbol) }
                                .musicButtons(prominent: offer.action == .play).accessibilityIdentifier("songAction-" + offer.action.rawValue)
                        }
                    }
                }
                ForEach(offers) { offer in if let message = offer.unavailable { Text(message).font(.caption).foregroundStyle(MusicStyle.secondaryText) } }
                if let video = item.videoID, let identifier = try? ServiceID(video) { DownloadCapabilityNote(media: identifier) }
                FeedbackLine(feedback: model.feedback[item.id])
                SongAddToPlaylistEntry(item: item)
                // Like and Save appear only when the row this page was opened from published them and the person is signed in.
                if let ledger, model.playback == .available {
                    let controls = LibraryControls.make(item: item, source: nil, ledger: ledger)
                    if !controls.isEmpty {
                        LibraryControlRow(ledger: ledger, controls: controls, identifier: "song", showsTitles: true)
                        LibraryWriteLine(ledger: ledger, keys: controls.map(\.key).uniqued(), scope: "song")
                    }
                }
                // Comments and their moderation (MEDIA10): what the source supplies, or the plain statement that it does not.
                if let social, let video = item.videoID, detail.availabilityKnown {
                    Divider()
                    SocialPanel(surface: social, subject: SocialSubject(kind: .song, id: video, title: item.title))
                }
            }.padding(MusicSpace.lg).frame(maxWidth: .infinity, alignment: .leading)
        }.restoresScroll().accessibilityIdentifier("songDetail")
    }
}
