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

/// What a source can say about one kind of summary for the account.
public enum SummaryAnswer<Payload: Equatable & Sendable>: Equatable, Sendable {
    case payload(Payload)
    /// The route answered and carried no summary (nothing to show for this account right now).
    case noPayload
    /// The service said this account does not have the feature. This is evidence about the account, and different from a missing payload.
    case accountUnsupported(String)
}
public protocol AccountSummarySource: Sendable {
    /// nil: a route exists. Otherwise why there is none.
    var unresolved: String? { get }
    func recap() async throws -> SummaryAnswer<RecapPayload>
    func badges() async throws -> SummaryAnswer<BadgePayload>
}
/// The source of record until a Recap/badges route is verified (W38): none of the captured responses carries either. Note that the
/// "badges" those responses do carry mark an entry as explicit or live; they are not account achievements.
public struct UnresolvedSummarySource: AccountSummarySource {
    public init() {}
    public var unresolved: String? {
        String(localized: "This app can’t read this from YouTube Music yet. No response it can read carries it, so nothing is shown and nothing is made up.")
    }
    public func recap() async throws -> SummaryAnswer<RecapPayload> { throw SamplesFailure.unreadable }
    public func badges() async throws -> SummaryAnswer<BadgePayload> { throw SamplesFailure.unreadable }
}

/// The distinct states of an account summary. `payloadMissing` (the route answered with nothing) and `accountUnsupported` (the service
/// says the account lacks it) are different facts and are never shown as one.
public enum SummaryState<Payload: Equatable & Sendable>: Equatable, Sendable {
    case unresolved(String)
    case idle
    case signInRequired
    case sessionEnded
    case loading
    case loaded(Payload)
    case payloadMissing
    case accountUnsupported(String)
    case failed(SamplesFailure)
}

/// The app's own record of what it played on this Mac, from the local history. It is not YouTube Music's Recap and is never shown as it.
public struct LocalListeningSummary: Equatable, Sendable {
    public struct Ranked: Equatable, Sendable, Identifiable {
        public let name: String; public let plays: Int; public var id: String { name }
        public init(name: String, plays: Int) { self.name = name; self.plays = plays }
    }
    public let plays: Int
    public let listenedSeconds: Double
    public let since: Date?
    public let topArtists: [Ranked]
    public let topTracks: [Ranked]
    /// Always false: this is a count of this Mac's own records.
    public let isOfficial = false
    public static func make(from records: [LocalHistoryRecord], top: Int = 5) -> LocalListeningSummary {
        func rank(_ names: [String]) -> [Ranked] {
            var counts: [String: Int] = [:]; var first: [String: Int] = [:]
            for (index, name) in names.enumerated() { counts[name, default: 0] += 1; if first[name] == nil { first[name] = index } }
            let ranked = counts.map { Ranked(name: $0.key, plays: $0.value) }.sorted { left, right in
                left.plays != right.plays ? left.plays > right.plays : (first[left.name] ?? 0) < (first[right.name] ?? 0)
            }
            return Array(ranked.prefix(top))
        }
        return LocalListeningSummary(plays: records.count, listenedSeconds: records.reduce(0) { $0 + max(0, $1.listenedSeconds) },
                                     since: records.map(\.startedAt).min(), topArtists: rank(records.compactMap { $0.artist?.isEmpty == false ? $0.artist : nil }),
                                     topTracks: rank(records.map(\.title).filter { !$0.isEmpty }))
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

    public init(source: any AccountSummarySource, signedIn: @escaping @MainActor () -> SearchPlayback = { .available },
                localRecords: @escaping @MainActor () async -> [LocalHistoryRecord] = { [] }) {
        self.source = source; self.signedIn = signedIn; self.localRecords = localRecords
        let initial = source.unresolved
        recap = initial.map(SummaryState.unresolved) ?? .idle
        badges = initial.map(SummaryState.unresolved) ?? .idle
    }

    public func loadRecap() async { await read(\.recap, fetch: { try await $0.recap() }, isEmpty: { $0.entries.isEmpty }) }
    public func loadBadges() async { await read(\.badges, fetch: { try await $0.badges() }, isEmpty: { $0.badges.isEmpty }) }
    public func refreshLocal() async { let records = await localRecords(); local = records.isEmpty ? nil : LocalListeningSummary.make(from: records) }

    private func read<P: Equatable & Sendable>(_ path: ReferenceWritableKeyPath<AccountSummaryModel, SummaryState<P>>,
                                               fetch: @escaping (any AccountSummarySource) async throws -> SummaryAnswer<P>, isEmpty: (P) -> Bool) async {
        if let reason = source.unresolved { self[keyPath: path] = .unresolved(reason); return }
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
            }
        } catch let failure as SamplesFailure {
            if ticket == generation { self[keyPath: path] = .failed(failure) }
        } catch { if ticket == generation { self[keyPath: path] = .failed(.unreadable) } }
    }
    public func accountChanged() {
        generation &+= 1
        let initial = source.unresolved
        recap = initial.map(SummaryState.unresolved) ?? .idle
        badges = initial.map(SummaryState.unresolved) ?? .idle
        local = nil
    }
}
