import Foundation
import Observation

/// One line of an account summary, exactly as the source supplied it. The application never computes, rounds, ranks or adds a figure.
public struct SummaryEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    /// The figure or phrase as printed by the source ("1,204 minutes"), never parsed.
    public let value: String?
    public let caption: String?
    public init(id: String, title: String, value: String? = nil, caption: String? = nil) { self.id = id; self.title = title; self.value = value; self.caption = caption }
}
/// A Recap the source supplied for the account.
public struct RecapPayload: Equatable, Sendable {
    public let title: String
    public let period: String?
    public let entries: [SummaryEntry]
    public init(title: String, period: String? = nil, entries: [SummaryEntry]) { self.title = title; self.period = period; self.entries = entries }
}
public struct BadgeEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String?
    /// When the source says it was earned, as printed.
    public let earned: String?
    public init(id: String, title: String, detail: String? = nil, earned: String? = nil) { self.id = id; self.title = title; self.detail = detail; self.earned = earned }
}
public struct BadgePayload: Equatable, Sendable {
    public let badges: [BadgeEntry]
    public init(badges: [BadgeEntry]) { self.badges = badges }
}

/// A message the service answered with in place of a summary, in its own words (read as text at run time, never written or reworded here).
/// What it means is not known: it may describe the account, or it may be an upstream fault. It is not a payload, not "nothing to show", and
/// not evidence that the account lacks the feature.
public struct SummaryServiceMessage: Equatable, Sendable {
    public let headline: String
    public let detail: String?
    public init(headline: String, detail: String? = nil) { self.headline = headline; self.detail = detail }
}

/// What a source can say about one kind of summary for the account.
public enum SummaryAnswer<Payload: Equatable & Sendable>: Equatable, Sendable {
    case payload(Payload)
    /// The route answered and carried no summary (nothing to show for this account right now).
    case noPayload
    /// The service said this account does not have the feature. This is evidence about the account, and different from a missing payload.
    case accountUnsupported(String)
    /// The service answered with a message of its own instead of the summary. Shown as the service's answer with an explicit retry.
    case serviceMessage(SummaryServiceMessage)
    /// The service did not see a signed-in session for this request.
    case signInRequired
    /// The service ended the session while answering.
    case sessionEnded
}
public protocol AccountSummarySource: Sendable {
    /// nil: a route exists. Otherwise why there is none.
    var unresolved: String? { get }
    /// The same, per kind. A source with a route for one kind and none for the other overrides these; the default is `unresolved` for both.
    var recapUnresolved: String? { get }
    var badgesUnresolved: String? { get }
    func recap() async throws -> SummaryAnswer<RecapPayload>
    func badges() async throws -> SummaryAnswer<BadgePayload>
}
public extension AccountSummarySource {
    var recapUnresolved: String? { unresolved }
    var badgesUnresolved: String? { unresolved }
}
/// The source of record when no route is composed (isolated automation) and for badges, which still have none (W38): none of the captured
/// responses carries them. Note that the "badges" those responses do carry mark an entry as explicit or live; they are not account achievements.
public struct UnresolvedSummarySource: AccountSummarySource {
    public init() {}
    public var unresolved: String? {
        String(localized: "This app can’t read this from YouTube Music yet. No response it can read carries it, so nothing is shown and nothing is made up.")
    }
    public func recap() async throws -> SummaryAnswer<RecapPayload> { throw SamplesFailure.unreadable }
    public func badges() async throws -> SummaryAnswer<BadgePayload> { throw SamplesFailure.unreadable }
}

extension SamplesFailure {
    /// The same reasons in words that name Recap (the generic ones name Samples).
    var recapMessage: String {
        switch self {
        case .offline: String(localized: "You’re offline, so Recap couldn’t be loaded.")
        case .needsSignIn: String(localized: "Sign in to YouTube Music to see what it has for your account.")
        case .sessionEnded: String(localized: "Sign in again to see what YouTube Music has for your account.")
        case .unreadable: String(localized: "YouTube Music’s answer for Recap couldn’t be read, so nothing is shown.")
        case .rateLimited: String(localized: "YouTube Music is asking for a pause. Try Recap again in a moment.")
        }
    }
}

/// The distinct states of an account summary. `payloadMissing` (the route answered with nothing), `accountUnsupported` (the service
/// says the account lacks it) and `serviceMessage` (the service sent a message whose meaning is unknown) are different facts and are never shown as one.
public enum SummaryState<Payload: Equatable & Sendable>: Equatable, Sendable {
    case unresolved(String)
    case idle
    case signInRequired
    case sessionEnded
    case loading
    case loaded(Payload)
    case payloadMissing
    case accountUnsupported(String)
    /// The service answered with a message instead of the summary. Its own state: not `payloadMissing`, not `accountUnsupported`.
    case serviceMessage(SummaryServiceMessage)
    case failed(SamplesFailure)
}

/// The app's own record of what it played on this Mac, from the local history. It is not YouTube Music's Recap and is never shown as it.
/// Every figure is counted from the records this Mac keeps; nothing is estimated.
public struct LocalListeningSummary: Equatable, Sendable {
    public struct Ranked: Equatable, Sendable, Identifiable {
        /// The video id for a song (two songs that share a title stay two songs); the credited name for an artist.
        public let id: String
        public let name: String
        /// A song's artist credit, as its most recent play recorded it.
        public let detail: String?
        public let plays: Int
        public let seconds: Double
        public init(id: String? = nil, name: String, detail: String? = nil, plays: Int, seconds: Double = 0) {
            self.id = id ?? name; self.name = name; self.detail = detail; self.plays = plays; self.seconds = seconds
        }
    }
    /// One calendar day of listening.
    public struct Day: Equatable, Sendable, Identifiable {
        public let start: Date
        public let plays: Int
        public let seconds: Double
        public var id: Date { start }
        public init(start: Date, plays: Int, seconds: Double) { self.start = start; self.plays = plays; self.seconds = seconds }
    }
    public let plays: Int
    public let listenedSeconds: Double
    /// The oldest play this Mac still keeps.
    public let since: Date?
    /// Distinct songs (by video id) and distinct artist credits played.
    public let songs: Int
    public let artists: Int
    public let topArtists: [Ranked]
    public let topTracks: [Ranked]
    /// The last `days` calendar days, oldest first, ending today; a day without a play is there with zeroes.
    public let recentDays: [Day]
    /// Always false: this is a count of this Mac's own records.
    public let isOfficial = false

    /// Records come newest first, as the store keeps them; ties keep that order (the most recently played first).
    public static func make(from records: [LocalHistoryRecord], top: Int = 5, days: Int = 14, now: Date = Date(), calendar: Calendar = .current) -> LocalListeningSummary {
        struct Tally { var name: String; var detail: String?; var plays = 0; var seconds = 0.0; var first: Int }
        func ranked(_ tallies: [String: Tally]) -> [Ranked] {
            let sorted = tallies.sorted { left, right in
                let a = left.value, b = right.value
                if a.plays != b.plays { return a.plays > b.plays }
                if a.seconds != b.seconds { return a.seconds > b.seconds }
                return a.first < b.first
            }
            return sorted.prefix(max(0, top)).map { Ranked(id: $0.key, name: $0.value.name, detail: $0.value.detail, plays: $0.value.plays, seconds: $0.value.seconds) }
        }
        var tracks: [String: Tally] = [:], artists: [String: Tally] = [:], perDay: [Date: (plays: Int, seconds: Double)] = [:]
        var total = 0.0
        for (index, record) in records.enumerated() {
            let seconds = max(0, record.listenedSeconds.isFinite ? record.listenedSeconds : 0)
            total += seconds
            if !record.title.isEmpty {
                tracks[record.videoID, default: Tally(name: record.title, detail: record.artist?.isEmpty == false ? record.artist : nil, first: index)].plays += 1
                tracks[record.videoID]?.seconds += seconds
            }
            if let artist = record.artist, !artist.isEmpty {
                artists[artist, default: Tally(name: artist, first: index)].plays += 1
                artists[artist]?.seconds += seconds
            }
            let day = calendar.startOfDay(for: record.startedAt)
            perDay[day, default: (0, 0)].plays += 1; perDay[day]?.seconds += seconds
        }
        let today = calendar.startOfDay(for: now)
        let recent: [Day] = (0..<max(0, days)).reversed().compactMap { back in
            guard let start = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            let value = perDay[start] ?? (0, 0)
            return Day(start: start, plays: value.plays, seconds: value.seconds)
        }
        return LocalListeningSummary(plays: records.count, listenedSeconds: total, since: records.map(\.startedAt).min(),
                                     songs: Set(records.map(\.videoID)).count, artists: artists.count,
                                     topArtists: ranked(artists), topTracks: ranked(tracks), recentDays: recent)
    }
}

/// DISC03 / U-S03-T01-R16: Recap and badges as the account's source supplies them, and — kept apart — this Mac's own listening.
@MainActor @Observable public final class AccountSummaryModel {
    public private(set) var recap: SummaryState<RecapPayload>
    public private(set) var badges: SummaryState<BadgePayload>
    /// This Mac's own record. Never mixed into `recap` or `badges`.
    public private(set) var local: LocalListeningSummary?
    @ObservationIgnored private let source: any AccountSummarySource
    @ObservationIgnored private let signedIn: @MainActor () -> SearchPlayback
    @ObservationIgnored private let localRecords: @MainActor () async -> [LocalHistoryRecord]
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored public private(set) var readCount = 0
    /// Counts account changes. A screen that is open when the account changes uses it to start over for the new account.
    public private(set) var epoch: UInt64 = 0

    public init(source: any AccountSummarySource, signedIn: @escaping @MainActor () -> SearchPlayback = { .available },
                localRecords: @escaping @MainActor () async -> [LocalHistoryRecord] = { [] }) {
        self.source = source; self.signedIn = signedIn; self.localRecords = localRecords
        recap = source.recapUnresolved.map(SummaryState.unresolved) ?? .idle
        badges = source.badgesUnresolved.map(SummaryState.unresolved) ?? .idle
    }

    public func loadRecap() async { await read(\.recap, unresolved: { $0.recapUnresolved }, fetch: { try await $0.recap() }, isEmpty: { $0.entries.isEmpty }) }
    public func loadBadges() async { await read(\.badges, unresolved: { $0.badgesUnresolved }, fetch: { try await $0.badges() }, isEmpty: { $0.badges.isEmpty }) }
    public func refreshLocal() async { let records = await localRecords(); local = records.isEmpty ? nil : LocalListeningSummary.make(from: records) }

    private func read<P: Equatable & Sendable>(_ path: ReferenceWritableKeyPath<AccountSummaryModel, SummaryState<P>>, unresolved: (any AccountSummarySource) -> String?,
                                               fetch: @escaping (any AccountSummarySource) async throws -> SummaryAnswer<P>, isEmpty: (P) -> Bool) async {
        if let reason = unresolved(source) { self[keyPath: path] = .unresolved(reason); return }
        switch signedIn() {
        case .needsSignIn: self[keyPath: path] = .signInRequired; return
        case .sessionExpired: self[keyPath: path] = .sessionEnded; return
        case .available: break
        }
        if case .loading = self[keyPath: path] { return }
        let ticket = generation
        self[keyPath: path] = .loading; readCount += 1
        do {
            let answer = try await fetch(source)
            guard ticket == generation else { return }
            switch answer {
            case .payload(let payload): self[keyPath: path] = isEmpty(payload) ? .payloadMissing : .loaded(payload)
            case .noPayload: self[keyPath: path] = .payloadMissing
            case .accountUnsupported(let why): self[keyPath: path] = .accountUnsupported(why)
            case .serviceMessage(let message): self[keyPath: path] = .serviceMessage(message)
            case .signInRequired: self[keyPath: path] = .signInRequired
            case .sessionEnded: self[keyPath: path] = .sessionEnded
            }
        } catch let failure as SamplesFailure {
            if ticket == generation { self[keyPath: path] = .failed(failure) }
        } catch { if ticket == generation { self[keyPath: path] = .failed(.unreadable) } }
    }
    public func accountChanged() {
        generation &+= 1; epoch &+= 1
        recap = source.recapUnresolved.map(SummaryState.unresolved) ?? .idle
        badges = source.badgesUnresolved.map(SummaryState.unresolved) ?? .idle
        local = nil
    }
}
