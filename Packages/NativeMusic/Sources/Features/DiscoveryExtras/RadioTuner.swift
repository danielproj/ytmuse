import AccountSession
import Domain
import Foundation
import Observation

/// A thing the service itself offers a radio for. Only a radio the service **presents as a radio** is a seed: the page's own radio action, or
/// the "Start mix" action in an entry's own menu. An id's prefix proves nothing (curated and editorial playlists share the `RD` prefix and
/// are not radios), and no radio is derived from a title, an artist name or a catalog id.
public struct RadioSeed: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case song, artist, album, playlist, page }
    /// The radio playlist the service's action names; it is also the seed's identity.
    public let id: String
    public let kind: Kind
    public let title: String
    public let subtitle: String?
    /// For a song: the track the radio starts from, as the action named it.
    public let videoID: String?
    /// The parameters the action's endpoint carried. They are sent unchanged when the radio starts.
    public let params: String?
    public init(id: String, kind: Kind, title: String, subtitle: String? = nil, videoID: String? = nil, params: String? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.subtitle = subtitle; self.videoID = videoID; self.params = params
    }
}

/// The seeds the person has met while browsing: collected from pages and entries the catalog already read, newest first, bounded.
/// Nothing is requested for them.
@MainActor @Observable public final class RadioSeedBook {
    public private(set) var seeds: [RadioSeed] = []
    @ObservationIgnored private let limit: Int
    public init(limit: Int = 40) { self.limit = max(1, limit) }

    /// A page whose own header published a radio (an artist's Radio, a playlist's Mix) — the action itself, with its parameters.
    public func note(page: MusicBrowsePage) {
        guard let header = page.header, let action = header.actions.radioAction, !header.title.isEmpty else { return }
        add(RadioSeed(id: action.playlistID, kind: .page, title: header.title, subtitle: header.subtitle.first, videoID: action.videoID, params: action.params))
    }
    /// Entries whose own menu offers a radio ("Start mix"). An entry without that action is not a seed, whatever its play button starts.
    public func note(items: [MusicCatalogItem]) {
        for item in items where !item.title.isEmpty {
            guard let action = item.radio else { continue }
            let kind: RadioSeed.Kind
            switch item.kind {
            case .song, .video: kind = .song
            case .artist: kind = .artist
            case .album: kind = .album
            case .playlist: kind = .playlist
            case .podcast, .episode, .category: continue
            }
            add(RadioSeed(id: action.playlistID, kind: kind, title: item.title, subtitle: item.details.first, videoID: action.videoID, params: action.params))
        }
    }
    private func add(_ seed: RadioSeed) {
        seeds.removeAll { $0.id == seed.id }
        seeds.insert(seed, at: 0)
        if seeds.count > limit { seeds.removeLast(seeds.count - limit) }
    }
    public func accountChanged() { seeds = [] }
}

/// One choice inside a control the service supplied.
public struct TunerOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let selected: Bool
    /// What choosing it asks of the service: the radio playlist and/or parameters it published for this choice.
    public let playlistID: String?
    public let params: String?
    public let playerParams: String?
    public let queueCommand: MusicQueueFilterCommand?
    public init(id: String, title: String, selected: Bool = false, playlistID: String? = nil, params: String? = nil, playerParams: String? = nil, queueCommand: MusicQueueFilterCommand? = nil) {
        self.id = id; self.title = title; self.selected = selected; self.playlistID = playlistID; self.params = params; self.playerParams = playerParams; self.queueCommand = queueCommand
    }
}
/// A diversity or discovery control a radio supplied for itself. The application never makes one up: the list below is exactly what
/// a `RadioControlsSource` returned.
public struct TunerControl: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let options: [TunerOption]
    public init(id: String, title: String, options: [TunerOption]) { self.id = id; self.title = title; self.options = options }
    public var selectedOption: TunerOption? { options.first(where: \.selected) }
}
public protocol RadioControlsSource: Sendable {
    /// nil: this source reads a radio's queue. Otherwise why it cannot, shown where the controls would be. An unread queue is *unresolved*;
    /// it is never reported as the service having no controls.
    var unresolved: String? { get }
    /// The controls the service supplied for this radio. Empty is a real answer only when `unresolved` is nil (a queue was read).
    func controls(for context: RadioContext) async throws -> [TunerControl]
}
/// Fallback for isolated automation and compositions without a queue reader. Never claims a queue was read.
public struct UnresolvedRadioControlsSource: RadioControlsSource {
    public init() {}
    public var unresolved: String? {
        String(localized: "This app doesn’t read a radio’s queue from YouTube Music yet, so it can’t tell whether the radio has tuning controls. None are shown, and none are made up.")
    }
    public func controls(for context: RadioContext) async throws -> [TunerControl] { [] }
}
/// Controls from a radio's queue response: the service's own queue-filter chips ("Popular"), each carrying the radio playlist and the parameters
/// that select it. `reader` is the seam where the queue request is made and parsed (typed `MusicRadioQueue`); it throws when the queue
/// could not be read; failure is never "no controls".
public struct QueueRadioControlsSource: RadioControlsSource {
    public typealias Reader = @Sendable (RadioContext) async throws -> MusicRadioQueue
    private let reader: Reader
    public init(reader: @escaping Reader) { self.reader = reader }
    public var unresolved: String? { nil }
    public func controls(for context: RadioContext) async throws -> [TunerControl] {
        let queue = try await reader(context)
        guard !queue.chips.isEmpty else { return [] }
        let options = try queue.chips.map { chip in
            guard let command = MusicQueueFilterCommand(playlistID: chip.playlistID, params: chip.params, playerParams: chip.playerParams, section: chip.section) else { throw MusicSessionError.unrecognised }
            return TunerOption(id: chip.playlistID + "|" + chip.params, title: chip.title, selected: chip.isSelected,
                               playlistID: chip.playlistID, params: chip.params, playerParams: chip.playerParams, queueCommand: command)
        }
        return [TunerControl(id: "queue-filter", title: String(localized: "Radio filter"), options: options)]
    }
}

/// The radio that is playing and the service context it came with. Changing a control keeps the seed and the playlist family.
public struct RadioContext: Equatable, Sendable {
    public let seed: RadioSeed
    public let playlistID: String
    public let params: String?
    /// control id → option id, for the choices made since the radio started.
    public let choices: [String: String]
    /// Metadata fetch target is distinct from the unchanged active playback radio.
    public let queueFetchCommand: MusicQueueFilterCommand?
    public var queueReadAction: MusicRadioAction {
        if let command = queueFetchCommand {
            return MusicRadioAction(playlistID: command.playlistID, params: command.params, playerParams: command.playerParams)
        }
        return MusicRadioAction(playlistID: playlistID, videoID: choices.isEmpty ? seed.videoID : nil, params: params)
    }
    public init(seed: RadioSeed, playlistID: String, params: String?, choices: [String: String], queueFetchCommand: MusicQueueFilterCommand? = nil) {
        self.seed = seed; self.playlistID = playlistID; self.params = params; self.choices = choices; self.queueFetchCommand = queueFetchCommand
    }
}

public enum TunerCapability: Equatable, Sendable {
    /// No radio has been started.
    case noRadio
    /// A radio is playing and this app cannot read its queue, so whether it has tuning controls is not known.
    case unresolved(String)
    /// A radio is playing, its queue was read, and it carried no tuning controls.
    case loadingControls
    case controlsFailed
    case noControlsSupplied
    case controlsSupplied(Int)
}
public enum TunerFailure: Equatable, Sendable {
    case needsSignIn, sessionEnded, notStarted, controlNotSupplied, unsupportedFilter, filterUnconfirmed
    public var message: String {
        switch self {
        case .needsSignIn: String(localized: "Sign in to YouTube Music to start a radio.")
        case .sessionEnded: String(localized: "Your YouTube Music session ended. Sign in again to start a radio.")
        case .notStarted: String(localized: "YouTube Music did not confirm the radio start. Playback may have changed.")
        case .filterUnconfirmed: String(localized: "YouTube Music did not take that change.")
        case .unsupportedFilter: String(localized: "This filter needs playback options this app can’t apply yet.")
        case .controlNotSupplied: String(localized: "YouTube Music didn’t supply that control for this radio.")
        }
    }
}

/// DISC03: the music tuner. Artist/seed selection over radios the service published, and — only when the service supplied them —
/// its diversity and discovery controls. Starting a radio goes to the shared playback session with the service's own playlist and
/// parameters.
@MainActor @Observable public final class TunerModel {
    public let seedBook: RadioSeedBook
    public private(set) var context: RadioContext?
    public private(set) var controls: [TunerControl] = []
    /// Captured by the rendered action, before a native callback or Task can be delayed.
    public private(set) var controlsIdentity = UUID()
    public private(set) var failure: TunerFailure?
    public private(set) var busy = false
    public private(set) var controlsLoaded = false
    public private(set) var controlsFailed = false
    public var selectionUnconfirmed: Bool {
        guard controlsLoaded, let context else { return false }
        return context.choices.contains { id, choice in controls.first(where: { $0.id == id })?.selectedOption?.id != choice }
    }
    @ObservationIgnored private let source: any RadioControlsSource
    @ObservationIgnored private let signedIn: @MainActor () -> SearchPlayback
    @ObservationIgnored private weak var performer: (any SearchActionPerformer)?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var queueScope: UUID?
    /// Requests sent to the shared playback session by this model (a measurement: one press is one request).
    @ObservationIgnored public private(set) var startCount = 0

    public init(seedBook: RadioSeedBook, performer: (any SearchActionPerformer)?, source: any RadioControlsSource = UnresolvedRadioControlsSource(),
                signedIn: @escaping @MainActor () -> SearchPlayback = { .available }) {
        self.seedBook = seedBook; self.performer = performer; self.source = source; self.signedIn = signedIn
    }
    public var seeds: [RadioSeed] { seedBook.seeds }
    public var capability: TunerCapability {
        guard context != nil else { return .noRadio }
        if let reason = source.unresolved { return .unresolved(reason) }
        if controlsFailed { return .controlsFailed }
        guard controlsLoaded else { return .loadingControls }
        return controls.isEmpty ? .noControlsSupplied : .controlsSupplied(controls.count)
    }

    /// Starts the seed's radio. Only a seed the book holds, and only from a press.
    public func start(_ seed: RadioSeed) async {
        guard !busy, seedBook.seeds.contains(seed) else { return }
        switch signedIn() {
        case .needsSignIn: failure = .needsSignIn; return
        case .sessionExpired: failure = .sessionEnded; return
        case .available: break
        }
        await run(seed: seed, playlistID: seed.id, params: seed.params, choices: [:])
    }
    /// Chooses an option of a control the service supplied. Queue filters update the existing radio's autoplay section;
    /// anything not supplied is refused.
    public func choose(option optionID: String, in controlID: String, suppliedBy identity: UUID) async {
        guard identity == controlsIdentity, !busy, let context else { return }
        guard let control = controls.first(where: { $0.id == controlID }), let option = control.options.first(where: { $0.id == optionID }) else { failure = .controlNotSupplied; return }
        guard canApply(option) else { failure = .unsupportedFilter; return }
        var choices = context.choices; choices[controlID] = optionID
        if let command = option.queueCommand {
            guard let performer, let scope = queueScope, performer.radioQueueScopeIsCurrent(scope) else { failure = .controlNotSupplied; return }
            busy = true; failure = nil; let ticket = generation
            defer { if ticket == generation { busy = false } }
            let result = await performer.applyRadioFilter(command, scope: scope)
            guard ticket == generation, !Task.isCancelled else { return }
            guard result == .started else { failure = .filterUnconfirmed; return }
            let updated = RadioContext(seed: context.seed, playlistID: context.playlistID, params: context.params, choices: choices, queueFetchCommand: command)
            self.context = updated
            await loadControls(updated, ticket: ticket)
            return
        }
        await run(seed: context.seed, playlistID: option.playlistID ?? context.playlistID, params: option.params ?? context.params, choices: choices)
    }
    public func canApply(_ option: TunerOption) -> Bool {
        if let command = option.queueCommand {
            return performer?.supportsRadioQueueUpdates == true && queueScope.map { performer?.radioQueueScopeIsCurrent($0) == true } == true && option.playlistID == command.playlistID
                && option.params == command.params && option.playerParams == command.playerParams
        }
        return option.playerParams == nil
    }
    private func run(seed: RadioSeed, playlistID: String, params: String?, choices: [String: String]) async {
        guard let performer else { failure = .notStarted; return }
        generation &+= 1; controlsIdentity = UUID()
        busy = true; failure = nil; let ticket = generation
        defer { if ticket == generation { busy = false } }
        startCount += 1
        let outcome = await performer.play(playlistID: playlistID, title: seed.title, videoID: choices.isEmpty ? seed.videoID : nil, params: params, intent: .endpoint)
        guard ticket == generation, !Task.isCancelled else { return }
        guard outcome == .started else { failure = outcome == .stale ? .sessionEnded : .notStarted; return }
        let started = RadioContext(seed: seed, playlistID: playlistID, params: params, choices: choices)
        context = started
        queueScope = performer.captureRadioQueueScope(playlistID: playlistID)
        controls = []; controlsLoaded = false; controlsFailed = false
        await loadControls(started, ticket: ticket)
    }
    /// Reads only metadata. Retrying never sends a playback request.
    public func retryControls() async {
        guard !busy, let context, source.unresolved == nil else { return }
        generation &+= 1; controlsIdentity = UUID()
        let ticket = generation
        busy = true; controlsLoaded = false; controlsFailed = false; controls = []
        defer { if ticket == generation { busy = false } }
        await loadControls(context, ticket: ticket)
    }
    private func loadControls(_ context: RadioContext, ticket: UInt64) async {
        guard source.unresolved == nil else { return }
        do {
            let supplied = try await source.controls(for: context)
            try Task.checkCancellation()
            guard ticket == generation else { return }
            controlsIdentity = UUID()
            controls = supplied
            controlsLoaded = true
        } catch {
            guard ticket == generation else { return }
            // Bounded local text in the view; never expose transport bodies, endpoints or credentials.
            controls = []; controlsLoaded = false; controlsFailed = true
        }
    }
    public func dismissFailure() { failure = nil }
    public func accountChanged() { generation &+= 1; controlsIdentity = UUID(); queueScope = nil; context = nil; controls = []; controlsLoaded = false; controlsFailed = false; failure = nil; busy = false; seedBook.accountChanged() }
}
