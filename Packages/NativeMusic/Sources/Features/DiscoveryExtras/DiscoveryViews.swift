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
        ContentUnavailableView { Label(title, systemImage: symbol) } description: { Text(message) }
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
            CatalogArtworkView(thumbnails: clip.thumbnails, edge: 64, corner: .thumbnail)
            VStack(alignment: .leading, spacing: MusicSpace.hairline) {
                Text(clip.title).font(.body.weight(.semibold)).lineLimit(2)
                if let artist = clip.artist { Text(artist).font(.callout).foregroundStyle(MusicStyle.secondaryText).lineLimit(1) }
                if previewing { Label("Previewing", systemImage: "waveform").font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("samplePreviewing-" + clip.id) }
            }
            Spacer()
            MusicGlassGroup {
                HStack(spacing: MusicSpace.xs) {
                    if previewing {
                        Button { Task { await model.stopPreview() } } label: { Label("Stop Preview", systemImage: "stop.fill") }
                            .musicPageAction().accessibilityIdentifier("sampleStop-" + clip.id)
                    } else {
                        Button { Task { await model.preview(clip.id) } } label: { Label("Preview", systemImage: "play.circle") }
                            .musicPageAction().accessibilityIdentifier("samplePreview-" + clip.id)
                    }
                    Button { Task { await model.play(clip.id) } } label: { Label("Play", systemImage: "play.fill") }
                        .musicPageAction(prominent: true).accessibilityIdentifier("samplePlay-" + clip.id)
                }
            }
        }
        // The previewing clip's picture, in the one native surface the player owns (nothing else shows it while this does).
        if previewing, let surface { surface(clip).accessibilityIdentifier("samplePicture-" + clip.id) }
        }
        .padding(.vertical, MusicSpace.xxs).tag(clip.id)
        .accessibilityElement(children: .contain).accessibilityLabel(Text(clip.title)).accessibilityIdentifier("sampleClip-" + clip.id)
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
            MusicGlassGroup {
                HStack(spacing: MusicSpace.xs) {
                    Picker("Previews that start by themselves", selection: $arbiter.preference) {
                        Text("Automatic").tag(PreviewAutoplayPreference.automatic)
                        Text("Off").tag(PreviewAutoplayPreference.off)
                        Text("On").tag(PreviewAutoplayPreference.on)
                    }.pickerStyle(.menu).accessibilityIdentifier("samplesAutoplayPreference")
                    Spacer()
                }
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
            ProgressView().controlSize(.small).accessibilityLabel(Text("Loading Samples")).frame(maxWidth: .infinity)
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
        case .started: Label("Playing in the player. The preview ended first.", systemImage: "checkmark.circle").font(.callout).accessibilityIdentifier("samplesHandoff-started")
        case .nothingToPlay: Label("This Sample names nothing to play.", systemImage: "nosign").font(.callout).accessibilityIdentifier("samplesHandoff-nothing")
        case .notStarted: Label("YouTube Music could not start this. Try Play again.", systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(MusicStyle.errorText).accessibilityIdentifier("samplesHandoff-failed")
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
            VStack(alignment: .leading, spacing: MusicSpace.md) {
                DiscoveryTitle(title: "Music tuner", development: development)
                Text("Pick something to start its radio. Only radios YouTube Music offers are listed, and the tuner shows only controls it supplies.")
                    .font(.callout).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("tunerIntro")
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
                Text("Radio").font(.headline).accessibilityAddTraits(.isHeader)
                Label("Radio from “\(context.seed.title)”", systemImage: "dot.radiowaves.left.and.right").accessibilityIdentifier("tunerContext")
                switch model.capability {
                case .controlsSupplied:
                    ForEach(model.controls) { control in
                        let identity = model.controlsIdentity
                        HStack {
                            Text(control.title).accessibilityIdentifier("tunerControlTitle-" + control.id)
                            Picker(control.title, selection: Binding(get: { control.selectedOption?.id ?? "" }, set: { id in Task { await model.choose(option: id, in: control.id, suppliedBy: identity) } })) {
                                if control.selectedOption == nil { Text("Not chosen").tag("") }
                                ForEach(control.options) { Text($0.title).tag($0.id).disabled(!model.canApply($0)) }
                            }.pickerStyle(.menu).disabled(model.busy).accessibilityIdentifier("tunerControl-" + control.id)
                        }
                    }
                    if model.selectionUnconfirmed {
                        Text("YouTube Music hasn’t confirmed the requested filter. The selection shown comes from its queue.")
                            .font(.callout).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("tunerSelectionUnconfirmed")
                    }
                    if model.controls.contains(where: { $0.options.contains(where: { !model.canApply($0) }) }) {
                        Text("Filters require this radio’s active player, readable queue and supported playback options. Restart the radio to reload its controls.").font(.callout).foregroundStyle(MusicStyle.secondaryText)
                    }
                case .unresolved(let reason):
                    Label(reason, systemImage: "clock.arrow.circlepath").font(.callout).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("tunerControlsUnresolved")
                case .loadingControls:
                    ProgressView("Loading radio filters…").accessibilityIdentifier("tunerFiltersLoading")
                case .controlsFailed:
                    Text("Radio filters couldn’t load. The radio has started.").foregroundStyle(MusicStyle.secondaryText)
                    Button("Retry radio filters") { Task { await model.retryControls() } }.disabled(model.busy)
                        .accessibilityIdentifier("tunerFiltersRetry")
                case .noControlsSupplied:
                    Label("This radio’s queue was read and carried no tuning controls.", systemImage: "slider.horizontal.3")
                        .font(.callout).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("tunerNoControls")
                case .noRadio:
                    EmptyView()
                }
            }
        } else {
            Label("No radio started. Tuning controls can be shown here only once this app can read a radio’s queue.", systemImage: "slider.horizontal.3")
                .font(.callout).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("tunerNoRadio")
        }
    }
    @ViewBuilder private var seeds: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            Text("Start a radio from").font(.headline).accessibilityAddTraits(.isHeader)
            if model.seeds.isEmpty {
                Label("Nothing to start from yet. Open songs, artists and playlists in Home and Explore; the radios YouTube Music offers for them are listed here.", systemImage: "music.note.list")
                    .font(.callout).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("tunerNoSeeds")
            } else {
                ForEach(model.seeds) { seed in
                    HStack {
                        VStack(alignment: .leading, spacing: MusicSpace.hairline) {
                            Text(seed.title).font(.body.weight(.semibold)).lineLimit(1)
                            if let subtitle = seed.subtitle { Text(subtitle).font(.caption).foregroundStyle(MusicStyle.secondaryText).lineLimit(1) }
                        }
                        Spacer()
                        Button { Task { await model.start(seed) } } label: { Label("Start Radio", systemImage: "play.fill") }
                            .musicPageAction(prominent: model.context?.seed == seed).disabled(model.busy).accessibilityLabel(Text("Start radio from \(seed.title)"))
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
            ProgressView().controlSize(.small).accessibilityLabel(Text("Loading")).frame(maxWidth: .infinity)
        case .signInRequired:
            CapabilityNote(symbol: "person.crop.circle.badge.questionmark", title: "Sign in to see this", message: String(localized: "Sign in to YouTube Music to see what it has for your account."), identifier: kind + "SignIn")
        case .sessionEnded:
            CapabilityNote(symbol: "person.crop.circle.badge.exclamationmark", title: "Your session ended", message: String(localized: "Sign in again to see what YouTube Music has for your account."), identifier: kind + "SessionEnded")
        case .payloadMissing:
            CapabilityNote(symbol: "tray", title: "Nothing to show yet", message: String(localized: "YouTube Music answered, but sent nothing for your account here. Nothing is estimated in its place."), identifier: kind + "PayloadMissing")
        case .accountUnsupported(let why):
            CapabilityNote(symbol: "person.crop.circle.badge.xmark", title: "Not available for this account", message: why, identifier: kind + "AccountUnsupported")
        case .failed(let failure):
            ErrorState(title: "This couldn’t be loaded", message: LocalizedStringKey(failure.message), recovery: "Retry", action: retry).accessibilityIdentifier(kind + "Failed")
        case .loaded(let payload):
            loaded(payload)
        }
    }
}

struct LocalListeningSection: View {
    @Bindable var model: AccountSummaryModel
    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            Text("Counted by YTMuse from what it played on this Mac. This is not YouTube Music’s Recap, and it never leaves this Mac.")
                .font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("localListeningNote")
            if let local = model.local {
                let listened = Duration.seconds(local.listenedSeconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
                Text("\(local.plays) plays · \(listened) listened").accessibilityIdentifier("localListeningTotals")
                if !local.topArtists.isEmpty {
                    Text("Most played artists on this Mac").font(.subheadline.weight(.semibold))
                    ForEach(local.topArtists) { Text("\($0.name) · \($0.plays)").font(.callout) }
                }
                if !local.topTracks.isEmpty {
                    Text("Most played songs on this Mac").font(.subheadline.weight(.semibold))
                    ForEach(local.topTracks) { Text("\($0.name) · \($0.plays)").font(.callout) }
                }
            } else {
                Text("Nothing has been played in YTMuse on this Mac yet.").font(.callout).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("localListeningNone")
            }
        }
        .padding(MusicSpace.md).frame(maxWidth: .infinity, alignment: .leading).musicInsetSurface()
        .accessibilityElement(children: .contain).accessibilityIdentifier("localListening")
    }
}

public struct RecapView: View {
    @Bindable var model: AccountSummaryModel
    let development: Bool
    public init(model: AccountSummaryModel, development: Bool = false) { self.model = model; self.development = development }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MusicSpace.md) {
                DiscoveryTitle(title: "Recap", development: development)
                SummaryStateView(state: model.recap, kind: "recap", retry: { Task { await model.loadRecap() } }) { payload in
                    VStack(alignment: .leading, spacing: MusicSpace.xs) {
                        Text(payload.title).font(MusicPageStyle.section).accessibilityAddTraits(.isHeader)
                        if let period = payload.period { Text(period).foregroundStyle(MusicStyle.secondaryText) }
                        ForEach(payload.entries) { entry in
                            VStack(alignment: .leading, spacing: MusicSpace.hairline) {
                                Text(entry.title).font(.body.weight(.semibold))
                                if let value = entry.value { Text(value).font(.title3) }
                                if let caption = entry.caption { Text(caption).font(.caption).foregroundStyle(MusicStyle.secondaryText) }
                            }.padding(MusicSpace.md).frame(maxWidth: .infinity, alignment: .leading).musicInsetSurface().accessibilityElement(children: .combine).accessibilityIdentifier("recapEntry-" + entry.id)
                        }
                    }.accessibilityElement(children: .contain).accessibilityIdentifier("recapLoaded")
                }
            }.musicPageContent().frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await model.loadRecap() }
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
            VStack(alignment: .leading, spacing: MusicSpace.md) {
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
            VStack(alignment: .leading, spacing: MusicSpace.md) {
                DiscoveryTitle(title: "Badges", development: development)
                SummaryStateView(state: model.badges, kind: "badges", retry: { Task { await model.loadBadges() } }) { payload in
                    VStack(alignment: .leading, spacing: MusicSpace.xs) {
                        ForEach(payload.badges) { badge in
                            VStack(alignment: .leading, spacing: MusicSpace.hairline) {
                                Label(badge.title, systemImage: "rosette").font(.body.weight(.semibold))
                                if let detail = badge.detail { Text(detail).font(.callout).foregroundStyle(MusicStyle.secondaryText) }
                                if let earned = badge.earned { Text(earned).font(.caption).foregroundStyle(MusicStyle.secondaryText) }
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
