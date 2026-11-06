import AccountSession
import DesignSystem
import SwiftUI

private struct SampleVideoSurfaceKey: EnvironmentKey { static let defaultValue: (@MainActor (SampleClip) -> AnyView)? = nil }
public extension EnvironmentValues {
    /// The native picture surface for a previewing clip (W17's single-owner surfaces, supplied by the application). Nil: no picture is shown.
    var sampleVideoSurface: (@MainActor (SampleClip) -> AnyView)? {
        get { self[SampleVideoSurfaceKey.self] }
        set { self[SampleVideoSurfaceKey.self] = newValue }
    }
}

/// A state the source cannot fill yet, said at the place the content would be. It carries no control that pretends to work.
struct CapabilityNote: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: String
    let identifier: String
    var body: some View {
        MusicState(title, systemImage: symbol) { Text(verbatim: message) }
            .accessibilityElement(children: .combine).accessibilityIdentifier(identifier)
    }
}

struct DiscoveryTitle: View {
    let title: LocalizedStringKey
    let development: Bool
    var body: some View {
        HStack {
            Text(title).font(MusicPageStyle.title).accessibilityAddTraits(.isHeader).accessibilityIdentifier("destinationTitle")
            Spacer()
            if development { Text("Development data · Not YouTube Music").font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("developmentDataLabel") }
        }
    }
}

/// The four entries Explore shows for the discovery extras. They open their own screens; nothing here claims the source has content.
public struct DiscoveryEntryRow: View {
    let open: (DiscoveryEntry) -> Void
    public init(open: @escaping (DiscoveryEntry) -> Void) { self.open = open }
    public var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: MusicSpace.lg) {
                ForEach(DiscoveryEntry.allCases, id: \.self) { entry in
                    Button { open(entry) } label: { Label(entry.title, systemImage: entry.symbol) }
                        .musicPageAction().accessibilityIdentifier("discoveryEntry-" + entry.rawValue)
                }
            }.padding(.vertical, MusicSpace.xs)
        }.scrollIndicators(.hidden)
        .accessibilityElement(children: .contain).accessibilityLabel(Text("Discovery"))
    }
}
public enum DiscoveryEntry: String, CaseIterable, Sendable {
    case samples, tuner, recap, badges
    /// This Mac's own listening record. Its own entry, so it never sits under the Recap title.
    case local
    public var title: LocalizedStringKey {
        switch self { case .samples: "Samples"; case .tuner: "Music tuner"; case .recap: "Recap"; case .badges: "Badges"; case .local: "On this Mac" }
    }
    public var symbol: String {
        switch self { case .samples: "play.rectangle.on.rectangle"; case .tuner: "slider.horizontal.3"; case .recap: "chart.bar.doc.horizontal"; case .badges: "rosette"; case .local: "desktopcomputer" }
    }
}

// MARK: Samples

struct SampleClipRow: View {
    @Bindable var model: SamplesModel
    let clip: SampleClip
    @Environment(\.sampleVideoSurface) private var surface
    var body: some View {
        let previewing = model.arbiter.isPreviewing(clip.id)
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
        HStack(spacing: MusicSpace.sm) {
            CatalogArtworkView(thumbnails: clip.thumbnails, edge: MusicFixedArtworkSize.row.edge, corner: .thumbnail)
            VStack(alignment: .leading, spacing: MusicSpace.hairline) {
                Text(verbatim: clip.title).font(.body.weight(.semibold)).lineLimit(2)
                if let artist = clip.artist { Text(verbatim: artist).font(.callout).foregroundStyle(MusicStyle.secondaryText).lineLimit(1) }
                if previewing { Label("Previewing", systemImage: "waveform").font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("samplePreviewing-" + clip.id) }
            }
            Spacer()
                HStack(spacing: MusicSpace.xs) {
                    if previewing {
                        Button { Task { await model.stopPreview() } } label: { Label("Stop Preview", systemImage: "stop.fill") }
                            .musicPageAction().accessibilityIdentifier("sampleStop-" + clip.id)
                    } else {
                        Button { Task { await model.preview(clip.id) } } label: { Label("Preview", systemImage: "play.circle") }
                            .musicPageAction().accessibilityIdentifier("samplePreview-" + clip.id)
                    }
                    Button { Task { await model.play(clip.id) } } label: { Label("Play", systemImage: "play.fill") }
                        .musicAction(.secondary).accessibilityIdentifier("samplePlay-" + clip.id)
                }
        }
        // The previewing clip's picture, in the one native surface the player owns (nothing else shows it while this does).
        if previewing, let surface { surface(clip).accessibilityIdentifier("samplePicture-" + clip.id) }
        }
        .musicRow(hoverable: false).tag(clip.id)
        .accessibilityElement(children: .contain).accessibilityLabel(Text(verbatim: clip.title)).accessibilityIdentifier("sampleClip-" + clip.id)
        .accessibilityActions {
            Button(previewing ? "Stop Preview" : "Preview") { Task { if previewing { await model.stopPreview() } else { await model.preview(clip.id) } } }
            Button("Play") { Task { await model.play(clip.id) } }
        }
    }
}

public struct SamplesView: View {
    @Bindable var model: SamplesModel
    let development: Bool
    public init(model: SamplesModel, development: Bool = false) { self.model = model; self.development = development }
    public var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            DiscoveryTitle(title: "Samples", development: development)
            autoplayControls
            content
            if let handoff = model.handoff { handoffLine(handoff) }
        }
        .musicPageContent().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await model.load() }
        .onDisappear { Task { await model.leaveScreen() } }
        .accessibilityElement(children: .contain).accessibilityIdentifier("samplesScreen")
    }
    @ViewBuilder private var autoplayControls: some View {
        if case .unresolved = model.state { EmptyView() } else {
            @Bindable var arbiter = model.arbiter
                HStack(spacing: MusicSpace.xs) {
                    Picker("Previews that start by themselves", selection: $arbiter.preference) {
                        Text("Automatic").tag(PreviewAutoplayPreference.automatic)
                        Text("Off").tag(PreviewAutoplayPreference.off)
                        Text("On").tag(PreviewAutoplayPreference.on)
                    }.pickerStyle(.menu).accessibilityIdentifier("samplesAutoplayPreference")
                    Spacer()
                }
            if let refusal = model.arbiter.autoplayRefusal {
                Label(refusal.message, systemImage: refusal == .playbackBusy ? "speaker.wave.2" : "bolt.slash").font(.callout)
                    .foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("samplesAutoplayDisabled")
            }
            if let refusal = model.arbiter.lastRefusal, refusal == .engineFailed {
                Label(refusal.message, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(MusicStyle.errorText).accessibilityIdentifier("samplesPreviewFailed")
            }
        }
    }
    @ViewBuilder private var content: some View {
        switch model.state {
        case .unresolved(let reason):
            CapabilityNote(symbol: "clock.arrow.circlepath", title: "Samples aren’t available yet", message: reason, identifier: "samplesUnresolved")
        case .idle, .loading:
            LoadingState("Loading Samples…")
        case .empty:
            EmptyState(title: "No Samples right now", message: "YouTube Music has no Samples for you at the moment.").accessibilityIdentifier("samplesEmpty")
        case .failed(let failure):
            ErrorState(title: "Samples couldn’t be loaded", message: LocalizedStringKey(failure.message)) { Task { await model.load() } }.accessibilityIdentifier("samplesFailed")
        case .clips(let clips):
            List(selection: Binding(get: { model.focused }, set: { id in Task { await model.focus(id) } })) {
                ForEach(clips) { SampleClipRow(model: model, clip: $0) }
            }.scrollContentBackground(.hidden).accessibilityIdentifier("samplesList")
        }
    }
    @ViewBuilder private func handoffLine(_ outcome: PreviewHandoffOutcome) -> some View {
        switch outcome {
        case .started: Label("Playing in the player. The preview ended first.", systemImage: "checkmark.circle").font(MusicPageStyle.note).accessibilityIdentifier("samplesHandoff-started")
        case .nothingToPlay: Label("This Sample names nothing to play.", systemImage: "nosign").font(MusicPageStyle.note).accessibilityIdentifier("samplesHandoff-nothing")
        case .notStarted: Label("YouTube Music could not start this. Try Play again.", systemImage: "exclamationmark.circle").font(MusicPageStyle.note).foregroundStyle(MusicStyle.errorText).accessibilityIdentifier("samplesHandoff-failed")
        }
    }
}

// MARK: Tuner

public struct TunerView: View {
    @Bindable var model: TunerModel
    let development: Bool
    public init(model: TunerModel, development: Bool = false) { self.model = model; self.development = development }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MusicPageStyle.sectionSpacing) {
                DiscoveryTitle(title: "Music tuner", development: development)
                Text("Pick something to start its radio. Only radios YouTube Music offers are listed, and the tuner shows only controls it supplies.")
                    .font(MusicPageStyle.note).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("tunerIntro")
                if let failure = model.failure {
                    HStack { Label(failure.message, systemImage: "exclamationmark.circle").foregroundStyle(MusicStyle.errorText).accessibilityIdentifier("tunerFailure")
                        Button("Dismiss") { model.dismissFailure() }.musicPageAction() }
                }
                radioNow.padding(MusicSpace.md).frame(maxWidth: .infinity, alignment: .leading).musicInsetSurface()
                seeds.padding(.top, MusicSpace.sm)
            }.musicPageContent().frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("tunerScreen")
    }
    @ViewBuilder private var radioNow: some View {
        if let context = model.context {
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                Text("Radio").font(MusicPageStyle.group).accessibilityAddTraits(.isHeader)
                Label("Radio from “\(context.seed.title)”", systemImage: "dot.radiowaves.left.and.right").accessibilityIdentifier("tunerContext")
                switch model.capability {
                case .controlsSupplied:
                    ForEach(model.controls) { control in
                        let identity = model.controlsIdentity
                        HStack {
                            Text(verbatim: control.title).accessibilityIdentifier("tunerControlTitle-" + control.id)
                            Picker(control.title, selection: Binding(get: { control.selectedOption?.id ?? "" }, set: { id in Task { await model.choose(option: id, in: control.id, suppliedBy: identity) } })) {
                                if control.selectedOption == nil { Text("Not chosen").tag("") }
                                ForEach(control.options) { Text($0.title).tag($0.id).disabled(!model.canApply($0)) }
                            }.pickerStyle(.menu).disabled(model.busy).accessibilityIdentifier("tunerControl-" + control.id)
                        }
                    }
                    if model.selectionUnconfirmed {
                        Text("YouTube Music hasn’t confirmed the requested filter. The selection shown comes from its queue.")
                            .font(MusicPageStyle.note).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("tunerSelectionUnconfirmed")
                    }
                    if model.controls.contains(where: { $0.options.contains(where: { !model.canApply($0) }) }) {
                        Text("Filters require this radio’s active player, readable queue and supported playback options. Restart the radio to reload its controls.").font(MusicPageStyle.note).foregroundStyle(MusicStyle.secondaryText)
                    }
                case .unresolved(let reason):
                    Label(reason, systemImage: "clock.arrow.circlepath").font(MusicPageStyle.note).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("tunerControlsUnresolved")
                case .loadingControls:
                    ProgressView("Loading radio filters…").accessibilityIdentifier("tunerFiltersLoading")
                case .controlsFailed:
                    Text("Radio filters couldn’t load. The radio has started.").foregroundStyle(MusicStyle.secondaryText)
                    Button("Retry radio filters") { Task { await model.retryControls() } }.musicStateAction().disabled(model.busy)
                        .accessibilityIdentifier("tunerFiltersRetry")
                case .noControlsSupplied:
                    Label("This radio’s queue was read and carried no tuning controls.", systemImage: "slider.horizontal.3")
                        .font(MusicPageStyle.note).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("tunerNoControls")
                case .noRadio:
                    EmptyView()
                }
            }
        } else {
            Label("No radio started. Tuning controls can be shown here only once this app can read a radio’s queue.", systemImage: "slider.horizontal.3")
                .font(MusicPageStyle.note).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("tunerNoRadio")
        }
    }
    @ViewBuilder private var seeds: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            Text("Start a radio from").font(MusicPageStyle.group).accessibilityAddTraits(.isHeader)
            if model.seeds.isEmpty {
                Label("Nothing to start from yet. Open songs, artists and playlists in Home and Explore; the radios YouTube Music offers for them are listed here.", systemImage: "music.note.list")
                    .font(MusicPageStyle.note).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("tunerNoSeeds")
            } else {
                ForEach(model.seeds) { seed in
                    HStack {
                        VStack(alignment: .leading, spacing: MusicSpace.hairline) {
                            Text(verbatim: seed.title).font(.body.weight(.semibold)).lineLimit(1)
                            if let subtitle = seed.subtitle { Text(verbatim: subtitle).font(.caption).foregroundStyle(MusicStyle.secondaryText).lineLimit(1) }
                        }
                        Spacer()
                        MusicChip(title: "Start Radio", isSelected: model.context?.seed == seed, systemImage: "play.fill") { Task { await model.start(seed) } }
                            .disabled(model.busy).accessibilityLabel(Text("Start radio from \(seed.title)"))
                            .accessibilityIdentifier("tunerSeed-" + seed.id)
                    }
                    .accessibilityElement(children: .contain)
                }
            }
        }
    }
}

// MARK: Recap and badges

struct SummaryStateView<P: Equatable & Sendable, Loaded: View>: View {
    let state: SummaryState<P>
    let kind: String
    let retry: () -> Void
    @ViewBuilder let loaded: (P) -> Loaded
    var body: some View {
        switch state {
        case .unresolved(let reason):
            CapabilityNote(symbol: "clock.arrow.circlepath", title: "Not available yet", message: reason, identifier: kind + "Unresolved")
        case .idle, .loading:
            LoadingState()
        case .signInRequired:
            CapabilityNote(symbol: "person.crop.circle.badge.questionmark", title: "Sign in to see this", message: String(localized: "Sign in to YouTube Music to see what it has for your account."), identifier: kind + "SignIn")
        case .sessionEnded:
            CapabilityNote(symbol: "person.crop.circle.badge.exclamationmark", title: "Your session ended", message: String(localized: "Sign in again to see what YouTube Music has for your account."), identifier: kind + "SessionEnded")
        case .payloadMissing:
            CapabilityNote(symbol: "tray", title: "Nothing to show yet", message: String(localized: "YouTube Music answered, but sent nothing for your account here. Nothing is estimated in its place."), identifier: kind + "PayloadMissing")
        case .accountUnsupported(let why):
            CapabilityNote(symbol: "person.crop.circle.badge.xmark", title: "Not available for this account", message: why, identifier: kind + "AccountUnsupported")
        case .serviceMessage(let message):
            ServiceMessageNote(message: message, identifier: kind + "ServiceMessage", retry: retry)
        case .failed(let failure):
            ErrorState(title: "This couldn’t be loaded", detail: kind == "recap" ? failure.recapMessage : failure.message, retry: retry).accessibilityIdentifier(kind + "Failed")
        case .loaded(let payload):
            loaded(payload)
        }
    }
}

/// What the service sent in place of the summary, in its own words (verbatim: never localized, reworded or marked up), and a Retry that asks again
/// once. The note says plainly that the message is the service's answer and that its meaning is not known here; it does not say there is no
/// Recap or that the account cannot have one.
struct ServiceMessageNote: View {
    let message: SummaryServiceMessage
    let identifier: String
    let retry: () -> Void
    var body: some View {
        ContentUnavailableView {
            Label("YouTube Music sent a message", systemImage: "text.bubble")
        } description: {
            VStack(spacing: MusicSpace.xs) {
                Text(verbatim: message.headline).accessibilityIdentifier(identifier + "Headline")
                if let detail = message.detail { Text(verbatim: detail).accessibilityIdentifier(identifier + "Detail") }
                Text("This is YouTube Music’s answer, shown as it was sent. This app can’t tell whether it is about your account or a temporary problem.")
                    .font(MusicPageStyle.note).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier(identifier + "Note")
            }
        } actions: {
            Button("Retry", action: retry).musicStateAction().accessibilityIdentifier(identifier + "Retry")
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier(identifier)
    }
}

struct LocalListeningSection: View {
    @Bindable var model: AccountSummaryModel
    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            Label { Text("Counted by YTMuse from what it played on this Mac. This is not YouTube Music’s Recap, and it never leaves this Mac.") } icon: { Image(systemName: "lock.fill") }
                .font(MusicPageStyle.note).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("localListeningNote")
            if let local = model.local {
                LocalListeningTotals(summary: local)
                if local.recentDays.contains(where: { $0.plays > 0 }) { LocalListeningDays(days: local.recentDays) }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: MusicSpace.md) { rankings(local) }
                    VStack(alignment: .leading, spacing: MusicSpace.md) { rankings(local) }
                }
            } else {
                Label { Text("Nothing has been played in YTMuse on this Mac yet.") } icon: { Image(systemName: "waveform") }
                    .font(.callout).foregroundStyle(MusicStyle.secondaryText).padding(MusicSpace.md)
                    .frame(maxWidth: .infinity, alignment: .leading).musicInsetSurface().accessibilityIdentifier("localListeningNone")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain).accessibilityIdentifier("localListening")
    }
    @ViewBuilder private func rankings(_ local: LocalListeningSummary) -> some View {
        if !local.topArtists.isEmpty { LocalRankingCard(title: "Most played artists on this Mac", symbol: "music.mic", entries: local.topArtists, identifier: "localTopArtists") }
        if !local.topTracks.isEmpty { LocalRankingCard(title: "Most played songs on this Mac", symbol: "music.note", entries: local.topTracks, identifier: "localTopSongs") }
    }
}

/// Plays, time heard, and how many different songs and artists, as large figures.
private struct LocalListeningTotals: View {
    let summary: LocalListeningSummary
    var body: some View {
        let listened = Duration.seconds(summary.listenedSeconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: MusicSpace.sm) { tiles(listened) }
                VStack(alignment: .leading, spacing: MusicSpace.sm) { playTiles(listened); varietyTiles }
            }
            if let since = summary.since {
                Text("Since \(since.formatted(date: .long, time: .omitted))").font(.caption).foregroundStyle(MusicStyle.secondaryText)
                    .accessibilityIdentifier("localListeningSince")
            }
        }
    }
    @ViewBuilder private func tiles(_ listened: String) -> some View { playTiles(listened); varietyTiles }
    @ViewBuilder private func playTiles(_ listened: String) -> some View {
        // One element for VoiceOver, read as the sentence the totals always were.
        HStack(spacing: MusicSpace.sm) {
            LocalFigure(value: summary.plays.formatted(), label: "Plays", symbol: "play.circle.fill", prominent: true)
            LocalFigure(value: listened, label: "Listening time", symbol: "clock.fill", prominent: true)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(Text("\(summary.plays) plays · \(listened) listened"))
        .accessibilityIdentifier("localListeningTotals")
    }
    @ViewBuilder private var varietyTiles: some View {
        HStack(spacing: MusicSpace.sm) {
            LocalFigure(value: summary.songs.formatted(), label: "Songs", symbol: "music.note", prominent: false).accessibilityElement(children: .combine)
            LocalFigure(value: summary.artists.formatted(), label: "Artists", symbol: "music.mic", prominent: false).accessibilityElement(children: .combine)
        }
    }
}

private struct LocalFigure: View {
    @Environment(\.musicAccent) private var accent
    let value: String
    let label: LocalizedStringKey
    let symbol: String
    let prominent: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xxs) {
            Label(label, systemImage: symbol).font(.caption.weight(.medium)).foregroundStyle(prominent ? accent : MusicStyle.secondaryText)
            Text(verbatim: value).font(.title.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(MusicSpace.md).frame(minWidth: 120, maxWidth: .infinity, alignment: .leading).musicInsetSurface()
    }
}

/// Minutes heard on each of the last days, as bars; today is the last bar.
private struct LocalListeningDays: View {
    @Environment(\.musicAccent) private var accent
    let days: [LocalListeningSummary.Day]
    private let chartHeight: CGFloat = 96
    var body: some View {
        let peak = max(days.map(\.seconds).max() ?? 0, 1)
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            Text("Last 14 days").font(MusicPageStyle.group).accessibilityAddTraits(.isHeader)
            HStack(alignment: .bottom, spacing: MusicSpace.xxs) {
                ForEach(days) { day in
                    let isToday = day.id == days.last?.id
                    VStack(spacing: MusicSpace.xxs) {
                        ZStack(alignment: .bottom) {
                            MusicCorner.badge.shape.fill(Color.primary.opacity(0.05)).frame(height: chartHeight)
                            MusicCorner.badge.shape.fill(accent.opacity(isToday ? 1 : 0.6))
                                .frame(height: day.seconds > 0 ? max(MusicSpace.xxs, chartHeight * day.seconds / peak) : 0)
                        }
                        .frame(maxWidth: MusicSpace.lg)
                        Text(day.start.formatted(.dateTime.weekday(.narrow))).font(.caption2.weight(isToday ? .bold : .regular))
                            .foregroundStyle(isToday ? Color.primary : MusicStyle.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .help(Text(verbatim: summary(day)))
                    .accessibilityElement(children: .ignore).accessibilityLabel(Text(verbatim: summary(day)))
                }
            }
        }
        .padding(MusicSpace.md).frame(maxWidth: .infinity, alignment: .leading).musicInsetSurface()
        .accessibilityElement(children: .contain).accessibilityIdentifier("localListeningDays")
    }
    private func summary(_ day: LocalListeningSummary.Day) -> String {
        let minutes = Duration.seconds(day.seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return [day.start.formatted(date: .complete, time: .omitted), String(localized: "\(day.plays) plays"), minutes]
            .joined(separator: String(localized: "detailSeparator"))
    }
}

/// A ranked list with a bar showing each entry's share against the first.
private struct LocalRankingCard: View {
    @Environment(\.musicAccent) private var accent
    let title: LocalizedStringKey
    let symbol: String
    let entries: [LocalListeningSummary.Ranked]
    let identifier: String
    var body: some View {
        let most = max(entries.map(\.plays).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            Label(title, systemImage: symbol).font(MusicPageStyle.group).accessibilityAddTraits(.isHeader)
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                HStack(alignment: .center, spacing: MusicSpace.sm) {
                    Text((index + 1).formatted()).font(.title3.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(index == 0 ? accent : MusicStyle.secondaryText).frame(width: MusicSpace.lg, alignment: .center)
                    VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                        HStack(alignment: .firstTextBaseline, spacing: MusicSpace.xs) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(entry.name).font(.body.weight(.medium)).lineLimit(1)
                                if let detail = entry.detail { Text(verbatim: detail).font(.caption).foregroundStyle(MusicStyle.secondaryText).lineLimit(1) }
                            }
                            Spacer(minLength: MusicSpace.xs)
                            Text("\(entry.plays) plays").font(.caption.monospacedDigit()).foregroundStyle(MusicStyle.secondaryText).fixedSize()
                        }
                        GeometryReader { proxy in
                            Capsule().fill(Color.primary.opacity(0.06))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(accent.opacity(index == 0 ? 1 : 0.6)).frame(width: proxy.size.width * CGFloat(entry.plays) / CGFloat(most))
                                }
                        }.frame(height: MusicSpace.xxs).accessibilityHidden(true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(MusicSpace.md).frame(maxWidth: .infinity, alignment: .topLeading).musicInsetSurface()
        .accessibilityElement(children: .contain).accessibilityIdentifier(identifier)
    }
}

public struct RecapView: View {
    @Bindable var model: AccountSummaryModel
    let development: Bool
    public init(model: AccountSummaryModel, development: Bool = false) { self.model = model; self.development = development }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MusicPageStyle.sectionSpacing) {
                DiscoveryTitle(title: "Recap", development: development)
                SummaryStateView(state: model.recap, kind: "recap", retry: { Task { await model.loadRecap() } }) { payload in
                    VStack(alignment: .leading, spacing: MusicSpace.xs) {
                        Text(verbatim: payload.title).font(MusicPageStyle.section).accessibilityAddTraits(.isHeader)
                        if let period = payload.period { Text(verbatim: period).foregroundStyle(MusicStyle.secondaryText) }
                        ForEach(payload.entries) { entry in
                            VStack(alignment: .leading, spacing: MusicSpace.hairline) {
                                Text(verbatim: entry.title).font(.body.weight(.semibold))
                                if let value = entry.value { Text(verbatim: value).font(.title3) }
                                if let caption = entry.caption { Text(verbatim: caption).font(.caption).foregroundStyle(MusicStyle.secondaryText) }
                            }.padding(MusicSpace.md).frame(maxWidth: .infinity, alignment: .leading).musicInsetSurface().accessibilityElement(children: .combine).accessibilityIdentifier("recapEntry-" + entry.id)
                        }
                    }.accessibilityElement(children: .contain).accessibilityIdentifier("recapLoaded")
                }
            }.musicPageContent().frame(maxWidth: .infinity, alignment: .leading)
        }
        // Opening the screen reads once; an account change while it is open starts over for the new account (one read, none when signed out).
        .task(id: model.epoch) { await model.loadRecap() }
        .accessibilityElement(children: .contain).accessibilityIdentifier("recapScreen")
    }
}

/// This Mac's own listening, on its own screen under its own title: counted here from what this app played, never sent anywhere, and not YouTube Music's
/// Recap.
public struct LocalListeningView: View {
    @Bindable var model: AccountSummaryModel
    public init(model: AccountSummaryModel) { self.model = model }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MusicPageStyle.sectionSpacing) {
                DiscoveryTitle(title: "On this Mac", development: false)
                LocalListeningSection(model: model)
            }.musicPageContent().frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await model.refreshLocal() }
        .accessibilityElement(children: .contain).accessibilityIdentifier("localListeningScreen")
    }
}

public struct BadgesView: View {
    @Bindable var model: AccountSummaryModel
    let development: Bool
    public init(model: AccountSummaryModel, development: Bool = false) { self.model = model; self.development = development }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MusicPageStyle.sectionSpacing) {
                DiscoveryTitle(title: "Badges", development: development)
                SummaryStateView(state: model.badges, kind: "badges", retry: { Task { await model.loadBadges() } }) { payload in
                    VStack(alignment: .leading, spacing: MusicSpace.xs) {
                        ForEach(payload.badges) { badge in
                            VStack(alignment: .leading, spacing: MusicSpace.hairline) {
                                Label(badge.title, systemImage: "rosette").font(.body.weight(.semibold))
                                if let detail = badge.detail { Text(verbatim: detail).font(.callout).foregroundStyle(MusicStyle.secondaryText) }
                                if let earned = badge.earned { Text(verbatim: earned).font(.caption).foregroundStyle(MusicStyle.secondaryText) }
                            }.padding(MusicSpace.md).frame(maxWidth: .infinity, alignment: .leading).musicInsetSurface().accessibilityElement(children: .combine).accessibilityIdentifier("badge-" + badge.id)
                        }
                    }.accessibilityElement(children: .contain).accessibilityIdentifier("badgesLoaded")
                }
            }.musicPageContent().frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await model.loadBadges() }
        .accessibilityElement(children: .contain).accessibilityIdentifier("badgesScreen")
    }
}

/// Routes one discovery entry to its screen.
public struct DiscoveryDestinationView: View {
    let entry: DiscoveryEntry
    @Bindable var surface: DiscoverySurface
    public init(entry: DiscoveryEntry, surface: DiscoverySurface) { self.entry = entry; self.surface = surface }
    public var body: some View {
        switch entry {
        case .samples: SamplesView(model: surface.samples, development: surface.development)
        case .tuner: TunerView(model: surface.tuner, development: surface.development)
        case .recap: RecapView(model: surface.summaries, development: surface.development)
        case .badges: BadgesView(model: surface.summaries, development: surface.development)
        case .local: LocalListeningView(model: surface.summaries)
        }
    }
}
