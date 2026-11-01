import AccountSession
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
    public init(id: String, title: String, selected: Bool = false, playlistID: String? = nil, params: String? = nil) {
        self.id = id; self.title = title; self.selected = selected; self.playlistID = playlistID; self.params = params
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
    func controls(for context: RadioContext) async -> [TunerControl]
}
/// The application's source until a radio's queue (`next`) response can be read: no capture of one exists on `main`, so the tuner cannot tell
/// whether a radio has tuning controls. Says so; shows none; invents none.
public struct UnresolvedRadioControlsSource: RadioControlsSource {
    public init() {}
    public var unresolved: String? {
        String(localized: "This app doesn’t read a radio’s queue from YouTube Music yet, so it can’t tell whether the radio has tuning controls. None are shown, and none are made up.")
    }
    public func controls(for context: RadioContext) async -> [TunerControl] { [] }
}
/// Controls from a radio's queue response: the service's own queue-filter chips ("Popular"), each carrying the radio playlist and the parameters
/// that select it. `reader` is the seam where the queue request is made and parsed (typed `MusicRadioQueue`); it returns nil when the queue
/// could not be read, which is unresolved for that radio, not "no controls".
public struct QueueRadioControlsSource: RadioControlsSource {
    public typealias Reader = @Sendable (RadioContext) async -> MusicRadioQueue?
    private let reader: Reader
    public init(reader: @escaping Reader) { self.reader = reader }
    public var unresolved: String? { nil }
    public func controls(for context: RadioContext) async -> [TunerControl] {
        guard let queue = await reader(context), !queue.chips.isEmpty else { return [] }
        let options = queue.chips.map { TunerOption(id: $0.playlistID + "|" + $0.params, title: $0.title, selected: $0.isSelected, playlistID: $0.playlistID, params: $0.params) }
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
    public init(seed: RadioSeed, playlistID: String, params: String?, choices: [String: String]) {
        self.seed = seed; self.playlistID = playlistID; self.params = params; self.choices = choices
    }
}

public enum TunerCapability: Equatable, Sendable {
    /// No radio has been started.
    case noRadio
    /// A radio is playing and this app cannot read its queue, so whether it has tuning controls is not known.
    case unresolved(String)
    /// A radio is playing, its queue was read, and it carried no tuning controls.
    case noControlsSupplied
    case controlsSupplied(Int)
}
public enum TunerFailure: Equatable, Sendable {
    case needsSignIn, sessionEnded, notStarted, controlNotSupplied
    public var message: String {
        switch self {
        case .needsSignIn: String(localized: "Sign in to YouTube Music to start a radio.")
        case .sessionEnded: String(localized: "Your YouTube Music session ended. Sign in again to start a radio.")
        case .notStarted: String(localized: "The radio could not start. What was playing is unchanged.")
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
    public private(set) var failure: TunerFailure?
    public private(set) var busy = false
    @ObservationIgnored private let source: any RadioControlsSource
    @ObservationIgnored private let signedIn: @MainActor () -> SearchPlayback
    @ObservationIgnored private weak var performer: (any SearchActionPerformer)?
    @ObservationIgnored private var generation: UInt64 = 0
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
    /// Chooses an option of a control the service supplied. The radio restarts for the same seed with what that option published;
    /// anything not supplied is refused.
    public func choose(option optionID: String, in controlID: String) async {
        guard !busy, let context else { return }
        guard let control = controls.first(where: { $0.id == controlID }), let option = control.options.first(where: { $0.id == optionID }) else { failure = .controlNotSupplied; return }
        var choices = context.choices; choices[controlID] = optionID
        await run(seed: context.seed, playlistID: option.playlistID ?? context.playlistID, params: option.params ?? context.params, choices: choices)
    }
    private func run(seed: RadioSeed, playlistID: String, params: String?, choices: [String: String]) async {
        guard let performer else { failure = .notStarted; return }
        busy = true; failure = nil; let ticket = generation
        defer { busy = false }
        startCount += 1
        let outcome = await performer.play(playlistID: playlistID, title: seed.title, videoID: seed.videoID, params: params)
        guard ticket == generation else { return }
        guard outcome == .started else { failure = outcome == .stale ? .sessionEnded : .notStarted; return }
        let started = RadioContext(seed: seed, playlistID: playlistID, params: params, choices: choices)
        context = started
        guard source.unresolved == nil else { controls = []; return }
        let supplied = await source.controls(for: started)
        guard ticket == generation else { return }
        controls = Self.applying(choices, to: supplied)
    }
    /// The supplied controls with the person's choices marked, never adding, removing or renaming a control or option.
    public static func applying(_ choices: [String: String], to controls: [TunerControl]) -> [TunerControl] {
        controls.map { control in
            guard let chosen = choices[control.id], control.options.contains(where: { $0.id == chosen }) else { return control }
            return TunerControl(id: control.id, title: control.title, options: control.options.map {
                TunerOption(id: $0.id, title: $0.title, selected: $0.id == chosen, playlistID: $0.playlistID, params: $0.params)
            })
        }
    }
    public func dismissFailure() { failure = nil }
    public func accountChanged() { generation &+= 1; context = nil; controls = []; failure = nil; busy = false; seedBook.accountChanged() }
}
