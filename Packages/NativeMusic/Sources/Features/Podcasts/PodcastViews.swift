import AccountSession
import DesignSystem
import Domain
import SwiftUI

/// "Played", "42% played", or nothing for an unplayed episode, with whose figure it is. A "Played" label is shown only when it is the truth.
struct EpisodeProgressLine: View {
    let progress: EpisodeProgress
    /// Names the item the line belongs to, so each row's progress is its own element.
    var scope = ""
    var body: some View {
        switch progress.status {
        case .unplayed: EmptyView()
        case .played:
            line(Label(String(localized: "Played"), systemImage: "checkmark.circle.fill"))
        case .inProgress(let fraction):
            VStack(alignment: .leading, spacing: MusicSpace.hairline) {
                if let fraction { ProgressView(value: fraction).frame(maxWidth: 160).accessibilityLabel(Text("Episode progress")).accessibilityValue(Text("\(Int((fraction * 100).rounded())) percent")) }
                line(Label(fraction.map { String(localized: "\(Int(($0 * 100).rounded()))% played") } ?? String(localized: "Started"), systemImage: "circle.lefthalf.filled"))
            }
        }
    }
    private func line(_ label: Label<Text, Image>) -> some View {
        HStack(spacing: MusicSpace.xs) {
            label.font(.caption)
            if let provenance = progress.provenance { Text("· " + provenance).font(.caption).foregroundStyle(MusicStyle.secondaryText) }
        }.foregroundStyle(MusicStyle.secondaryText).accessibilityElement(children: .combine).accessibilityIdentifier("episodeProgress-" + scope)
    }
}

/// What a show page's episode row adds: its progress, a Play button that starts the show's playlist at this episode, and the reason when it can't.
struct EpisodeRowExtras: View {
    let item: MusicCatalogItem
    let show: String?
    let showPlaylist: String?
    let readAt: Date
    @Environment(\.podcastsSurface) private var surface
    var body: some View {
        if let surface {
            let progress = surface.playback.progress(for: item, pageReadAt: readAt)
            VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                if let summary = item.episode?.summary { Text(summary).font(.caption).foregroundStyle(MusicStyle.secondaryText).lineLimit(2).accessibilityIdentifier("episodeSummary") }
                HStack(spacing: MusicSpace.sm) {
                    EpisodeProgressLine(progress: progress, scope: item.id)
                    Spacer(minLength: 0)
                    if let request = EpisodePlayTargets.request(videoID: item.videoID, title: item.title, showBrowseID: show, publishedShowPlaylist: showPlaylist) {
                        Button { Task { await surface.play(request) } } label: { Label(progress.resumePosition != nil ? "Resume" : "Play", systemImage: "play.fill") }
                            .labelStyle(.iconOnly).help(Text(progress.resumePosition != nil ? "Resume \(item.title)" : "Play \(item.title)"))
                            .accessibilityLabel(Text(progress.resumePosition != nil ? "Resume \(item.title)" : "Play \(item.title)"))
                            .accessibilityIdentifier("episodePlay-" + item.id).musicButtons().disabled(surface.playbackState != .available)
                    }
                }
                if let text = item.videoID.flatMap({ surface.feedbackText(for: $0) }) { Text(text).font(.caption).foregroundStyle(MusicStyle.errorText).accessibilityIdentifier("episodePlayFailure") }
            }
        }
    }
}

/// Sorting for a show's episode list. The default is the show's own order; every other order is a view over it.
public struct EpisodeSortMenu: View {
    @Bindable var surface: PodcastsSurface
    public init(surface: PodcastsSurface) { self.surface = surface }
    public var body: some View {
        Menu {
            Picker("Sort episodes", selection: $surface.episodeSort) { ForEach(EpisodeSort.allCases) { Text($0.title).tag($0) } }.pickerStyle(.inline)
        } label: { Label(surface.episodeSort.title, systemImage: "arrow.up.arrow.down") }
            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel(Text("Sort episodes")).accessibilityIdentifier("episodeSortMenu")
    }
}

/// Speed and the jump buttons, shown beside the transport while an episode is the item being played.
public struct PodcastTransportControls: View {
    @Bindable var playback: PodcastPlaybackModel
    /// The speed chosen for the show, and the speed the player says it is actually playing at (they differ after an ad or a new item until it is re-applied).
    let rate: Double
    let actual: Double?
    public init(playback: PodcastPlaybackModel, rate: Double, actual: Double? = nil) { self.playback = playback; self.rate = rate; self.actual = actual }
    public var body: some View {
        HStack(spacing: MusicSpace.xs) {
            Button { Task { await playback.skipBack() } } label: { Label("Back \(playback.skip.back) seconds", systemImage: "gobackward.\(playback.skip.back)") }
                .labelStyle(.iconOnly).help(Text("Back \(playback.skip.back) seconds")).accessibilityIdentifier("podcastSkipBack")
            Button { Task { await playback.skipForward() } } label: { Label("Forward \(playback.skip.forward) seconds", systemImage: "goforward.\(playback.skip.forward)") }
                .labelStyle(.iconOnly).help(Text("Forward \(playback.skip.forward) seconds")).accessibilityIdentifier("podcastSkipForward")
            PodcastRateMenu(playback: playback, show: playback.current?.show, rate: rate, actual: actual)
            PodcastSkipMenu(playback: playback)
        }.musicButtons()
        if let notice = playback.notice { Text(notice.message).font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("podcastNotice") }
    }
}
/// What the speed control says. The label is the speed the player is ACTUALLY playing at; when that differs from the show's chosen speed the help
/// names both. Pure, so it can be tested.
public struct PodcastRateDisplay: Equatable {
    public let title: String
    public let accessibilityValue: String
    /// Non-nil only when the actual speed differs from the choice.
    public let differenceHelp: String?
    public init(chosen: Double, actual: Double?) {
        let shown = actual ?? chosen
        title = PodcastRate.label(shown); accessibilityValue = PodcastRate.label(shown)
        differenceHelp = abs(shown - chosen) > 0.001 ? String(localized: "Playing at \(PodcastRate.label(shown)); you chose \(PodcastRate.label(chosen))") : nil
    }
}
/// The speed menu: 0.5× to 3×, remembered for the show. "Use for All Shows" changes the default; "Reset" returns this show to the default.
public struct PodcastRateMenu: View {
    @Bindable var playback: PodcastPlaybackModel
    let show: String?
    let rate: Double
    /// The player's actual speed, when it differs the label shows IT (and says what was chosen) rather than the choice.
    var actual: Double? = nil
    public init(playback: PodcastPlaybackModel, show: String?, rate: Double, actual: Double? = nil) { self.playback = playback; self.show = show; self.rate = rate; self.actual = actual }
    private var display: PodcastRateDisplay { PodcastRateDisplay(chosen: rate, actual: actual) }
    public var body: some View {
        Menu {
            Picker("Speed", selection: Binding(get: { rate }, set: { value in guard let show else { return }; Task { await playback.setRate(value, forShow: show) } })) {
                ForEach(PodcastRate.steps, id: \.self) { Text(PodcastRate.label($0)).tag($0) }
            }.pickerStyle(.inline)
            if let show, playback.state.preferences.hasOwnRate(forShow: show) {
                Button("Use Default Speed for This Show") { Task { await playback.clearRate(forShow: show) } }
            }
        } label: { Text(display.title).monospacedDigit() }
            .menuStyle(.borderlessButton).fixedSize().disabled(show == nil)
            .help(Text(display.differenceHelp ?? String(localized: "Listening speed for this show")))
            .accessibilityLabel(Text("Listening speed")).accessibilityValue(Text(display.accessibilityValue))
            .accessibilityIdentifier("podcastRate")
    }
}

/// The lengths of the two jump buttons, chosen from the offered lists (kept on this Mac only).
public struct PodcastSkipMenu: View {
    @Bindable var playback: PodcastPlaybackModel
    public init(playback: PodcastPlaybackModel) { self.playback = playback }
    public var body: some View {
        Menu {
            Picker("Skip back", selection: Binding(get: { playback.skip.back }, set: { playback.setSkip(back: $0, forward: playback.skip.forward) })) {
                ForEach(PodcastSkipIntervals.backChoices, id: \.self) { Text("Back \($0) seconds").tag($0) }
            }.pickerStyle(.inline)
            Picker("Skip forward", selection: Binding(get: { playback.skip.forward }, set: { playback.setSkip(back: playback.skip.back, forward: $0) })) {
                ForEach(PodcastSkipIntervals.forwardChoices, id: \.self) { Text("Forward \($0) seconds").tag($0) }
            }.pickerStyle(.inline)
        } label: { Label("Skip lengths", systemImage: "gearshape") }
            .labelStyle(.iconOnly).menuStyle(.borderlessButton).fixedSize().help(Text("Choose the skip lengths")).accessibilityIdentifier("podcastSkipMenu")
    }
}
/// The settings for the jump buttons and the default speed.
public struct PodcastPreferencesView: View {
    @Bindable var playback: PodcastPlaybackModel
    public init(playback: PodcastPlaybackModel) { self.playback = playback }
    public var body: some View {
        Form {
            Picker("Skip back", selection: Binding(get: { playback.skip.back }, set: { playback.setSkip(back: $0, forward: playback.skip.forward) })) {
                ForEach(PodcastSkipIntervals.backChoices, id: \.self) { Text("\($0) seconds").tag($0) }
            }.accessibilityIdentifier("podcastSkipBackSetting")
            Picker("Skip forward", selection: Binding(get: { playback.skip.forward }, set: { playback.setSkip(back: playback.skip.back, forward: $0) })) {
                ForEach(PodcastSkipIntervals.forwardChoices, id: \.self) { Text("\($0) seconds").tag($0) }
            }.accessibilityIdentifier("podcastSkipForwardSetting")
            Picker("Default speed", selection: Binding(get: { playback.state.preferences.defaultRate }, set: { _ = playback.setDefaultRate($0) })) {
                ForEach(PodcastRate.steps, id: \.self) { Text(PodcastRate.label($0)).tag($0) }
            }.accessibilityIdentifier("podcastDefaultRate")
            Text("These choices are kept on this Mac only. A show you give its own speed keeps it.").font(.caption).foregroundStyle(MusicStyle.secondaryText)
        }
    }
}

/// An episode's own page: header, progress, what can be done, chapters (only from the description's own timestamps) and the description.
public struct EpisodeDetailView: View {
    @Bindable var model: EpisodePageModel
    let surface: PodcastsSurface
    let navigator: CatalogNavigator
    @Environment(\.libraryLedger) private var ledger
    public init(model: EpisodePageModel, surface: PodcastsSurface, navigator: CatalogNavigator) { self.model = model; self.surface = surface; self.navigator = navigator }
    public var body: some View {
        ScrollView {
            switch model.phase {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity).padding(MusicSpace.xxl).accessibilityLabel(Text("Loading episode"))
            case .failed(let failure):
                VStack(spacing: MusicSpace.sm) {
                    Label(failure.message, systemImage: "exclamationmark.circle").accessibilityIdentifier("episodeFailure")
                    Button("Try Again") { Task { await model.refresh() } }.musicButtons().accessibilityIdentifier("episodeRetry")
                }.padding(MusicSpace.xxl).frame(maxWidth: .infinity)
            case .loaded(let page):
                content(page)
            }
        }.restoresScroll().task { await model.load() }.accessibilityIdentifier("episodeDetail")
    }
    @ViewBuilder private func content(_ page: MusicEpisodePage) -> some View {
        let progress = EpisodeProgressResolver.resolve(service: page.info, local: surface.playback.localRecord(page.videoID), pageReadAt: model.readAt)
        let request = EpisodePlayTargets.request(videoID: page.videoID, title: page.title, showBrowseID: page.show?.browseID)
        VStack(alignment: .leading, spacing: MusicSpace.lg) {
            MusicHeroLayout() {
                CatalogArtworkView(thumbnails: page.thumbnails, edge: 200, corner: .feature)
                VStack(alignment: .leading, spacing: MusicSpace.xs) {
                    Text(page.title).font(MusicPageStyle.title).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader).accessibilityIdentifier("catalogTitle")
                    if let show = page.show { Button(show.title) { navigator.openLink(show) }.buttonStyle(.link).accessibilityIdentifier("episodeShowLink") }
                    if !page.details.isEmpty { Text(page.details.joined(separator: String(localized: "detailSeparator"))).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("episodeDetails") }
                    if let length = page.info.durationText { Text(length).font(.callout).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("episodeLength") }
                    EpisodeProgressLine(progress: progress, scope: "page")
                    actions(page, request: request, progress: progress)
                }
            }
            if let reason = playbackReason(surface.playbackState) { Text(reason).font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("episodePlaybackReason") }
            if let note = playNote(request: request) { Text(note).font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("episodePlayNote") }
            if let text = surface.feedbackText(for: page.videoID) { Text(text).font(.caption).foregroundStyle(MusicStyle.errorText).accessibilityIdentifier("episodePlayFailure") }
            if let identifier = try? ServiceID(page.videoID) { DownloadCapabilityNote(media: identifier) }
            chapters(page)
            RichDescriptionView(runs: page.description)
            if !surface.playback.state.progress.isEmpty || progress.origin == .thisMac {
                Text("Progress marked “On this Mac” is kept on this Mac only. YouTube’s own player reports its progress to YouTube Music by itself.")
                    .font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("episodeProgressNote")
            }
        }.musicPageContent().frame(maxWidth: .infinity, alignment: .leading)
    }
    private func playbackReason(_ state: SearchPlayback) -> String? {
        switch state {
        case .available: nil
        case .needsSignIn: String(localized: "Sign in to YouTube Music to play episodes.")
        case .sessionExpired: String(localized: "Your YouTube Music session ended. Sign in again to play episodes.")
        }
    }
    private func playNote(request: EpisodePlayRequest?) -> String? {
        if request != nil { return nil }
        return String(localized: "This episode didn’t say which show to play it from, so Play isn’t offered here. Open the show to play it.")
    }
    @ViewBuilder private func actions(_ page: MusicEpisodePage, request: EpisodePlayRequest?, progress: EpisodeProgress) -> some View {
        MusicGlassGroup {
            HStack {
                if let request {
                    Button { Task { await surface.play(request) } } label: { Label(progress.resumePosition != nil ? "Resume" : "Play", systemImage: "play.fill") }
                        .musicButtons(prominent: true).disabled(surface.playbackState != .available).accessibilityIdentifier("episodePlayButton")
                }
                Button {
                    surface.playback.mark(page.videoID, played: !progress.isPlayed, duration: EpisodeDuration.seconds(from: page.info.durationText), show: page.show?.browseID)
                } label: { Label(progress.isPlayed ? "Mark as Unplayed" : "Mark as Played", systemImage: progress.isPlayed ? "circle" : "checkmark.circle") }
                    .musicButtons().help(Text("Changes only what this Mac shows")).accessibilityIdentifier("episodeMarkPlayed")
                if let later = page.later, let ledger, model.signedIn { EpisodeLaterButton(ledger: ledger, later: later) }
            }
        }
        if let later = page.later, let ledger, model.signedIn { LibraryWriteLine(ledger: ledger, keys: [.episodeLater(videoID: later.videoID)], scope: "episodeLater") }
        else if page.later != nil, !model.signedIn {
            Label("Sign in to save this episode for later.", systemImage: "info.circle").font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("episodeLaterNote")
        }
    }
    @ViewBuilder private func chapters(_ page: MusicEpisodePage) -> some View {
        let list = model.chapters
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                Text("Chapters").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                ForEach(list) { chapter in
                    HStack {
                        Text(EpisodeDuration.clock(chapter.start)).font(.callout.monospacedDigit()).foregroundStyle(MusicStyle.secondaryText).frame(minWidth: 52, alignment: .trailing)
                        Text(chapter.title)
                        Spacer()
                        if surface.playback.current?.videoID == page.videoID {
                            Button("Go") { Task { await surface.playback.seek(to: chapter.start) } }.musicButtons().accessibilityIdentifier("chapterGo-\(Int(chapter.start))")
                        }
                    }.accessibilityElement(children: .combine).accessibilityIdentifier("chapterRow-\(Int(chapter.start))")
                }
                Text("Chapters come from the timestamps in the episode’s description.").font(.caption).foregroundStyle(MusicStyle.secondaryText)
            }.accessibilityElement(children: .contain).accessibilityIdentifier("episodeChapters")
        }
    }
}
