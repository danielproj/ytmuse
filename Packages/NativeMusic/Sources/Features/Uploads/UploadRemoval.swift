import AccountSession
import Foundation
import Observation

/// Removing one upload from the person's Music locker (MEDIA06). This is a real account write, so it happens only through an explicit
/// two-step action on one upload: `request` names the upload and waits, `confirm` sends exactly that one removal. Choosing, dropping
/// or uploading a file never reaches this type, and this type has no way to touch a file on the Mac: the dialog says so, and nothing
/// here holds a file URL.
///
/// Success needs the service's positive answer. An answer that is neither refusal nor confirmation is "not confirmed", and the Uploads
/// list is read before anything is sent again (the upload being gone from the list is the evidence).
@MainActor @Observable public final class UploadRemovalModel {
    public struct Target: Equatable, Sendable {
        public let entityID: String
        public let title: String
        public let artist: String?
        public let kind: MusicEntityKind
        /// The row this was asked from, so the line can be shown at that row.
        public let itemID: String
        /// Every stable identifier the row carried (its item id, video id, page id): a read-back counts the upload as still listed if a row
        /// matches the removal target **or** any of these, so a list that lost its menus can't read as "removed".
        public let stableIDs: Set<String>
        public var description: String { artist.map { "\(title) — \($0)" } ?? title }
    }
    public enum State: Equatable, Sendable {
        case idle
        /// Waiting for the person to confirm or cancel. Nothing has been sent.
        case confirming(Target)
        case removing(Target)
        /// The service confirmed it.
        case removed(Target)
        case failed(Target, LibraryWriteFailure)
        /// The request left but the outcome is unknown; `checkedUnreadable` once a look at the list could not tell.
        case unconfirmed(Target, checkedUnreadable: Bool)
    }
    public typealias Remover = LibraryWriteLedger.Writer
    /// Whether the upload is still in the service's Uploads list (read now), or nil when the list cannot be read.
    public typealias Lister = @MainActor (Target) async -> Bool?

    public private(set) var state: State = .idle
    /// Requests handed to the remover since this model was made (a measurement for tests: one confirmed action is one request).
    @ObservationIgnored public private(set) var sentCount = 0
    @ObservationIgnored private let remover: Remover
    @ObservationIgnored private let listing: Lister
    @ObservationIgnored private let accountScope: @MainActor () -> String
    @ObservationIgnored private let signedIn: @MainActor () -> SearchPlayback
    @ObservationIgnored private let removed: @MainActor () async -> Void
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var sending = false

    public init(remover: @escaping Remover, listing: @escaping Lister = { _ in nil }, accountScope: @escaping @MainActor () -> String = { "" },
                signedIn: @escaping @MainActor () -> SearchPlayback = { .available }, removed: @escaping @MainActor () async -> Void = {}) {
        self.remover = remover; self.listing = listing; self.accountScope = accountScope; self.signedIn = signedIn; self.removed = removed
    }

    /// An upload offers removal only if its own listing published the service's removal target.
    public func offers(_ item: MusicCatalogItem) -> Bool {
        guard let id = item.uploadEntityID else { return false }
        return MusicWriteRequest.removeUpload(entityID: id).isWellFormed
    }
    public func target(for item: MusicCatalogItem) -> Target? {
        guard offers(item), let id = item.uploadEntityID else { return nil }
        return Target(entityID: id, title: item.title, artist: item.links.first { $0.kind == .artist }?.title ?? item.details.first, kind: item.kind, itemID: item.id,
                      stableIDs: Set([item.id, item.videoID, item.browseID].compactMap { $0 }))
    }
    public func target(itemID: String) -> Target? {
        switch state {
        case .idle: nil
        case .confirming(let t), .removing(let t), .removed(let t), .failed(let t, _), .unconfirmed(let t, _): t.itemID == itemID ? t : nil
        }
    }
    public var confirming: Target? { if case .confirming(let target) = state { target } else { nil } }
    public var isBusy: Bool { if case .removing = state { true } else { false } }
    /// Whether `request(removing:)` would start a question now (it refuses while a removal is in flight or unsettled).
    public var canRequest: Bool { switch state { case .removing, .unconfirmed: false; default: true } }

    /// Step one: names the upload and asks. Sends nothing. Refused while another removal is in flight or unsettled.
    public func request(removing item: MusicCatalogItem) {
        guard canRequest else { return }
        guard let target = target(for: item) else { return }
        state = .confirming(target)
    }
    /// The person said no (or closed the question). Nothing was sent.
    public func cancel() { if case .confirming = state { state = .idle } }
    /// Step two, in two parts so a button can take the decision synchronously: `begin` accepts the confirmation (nothing else can now
    /// cancel it), `complete` sends the one removal that was named, once.
    @discardableResult public func begin() -> Bool {
        guard case .confirming(let target) = state else { return false }
        switch signedIn() {
        case .needsSignIn: state = .failed(target, .needsSignIn); return false
        case .sessionExpired: state = .failed(target, .sessionEnded); return false
        case .available: break
        }
        state = .removing(target)
        return true
    }
    public func complete() async {
        guard case .removing(let target) = state, !sending else { return }
        await send(target)
    }
    public func confirm() async { if begin() { await complete() } }
    /// After a failure the service refused or that never left: the same removal again, by the person's explicit action.
    public func retry() async {
        guard case .failed(let target, let failure) = state, failure != .needsSignIn, failure != .sessionEnded, failure != .notOffered else { return }
        state = .removing(target)
        await send(target)
    }
    /// After an unknown outcome: read the Uploads list. Gone → removed; still there → not applied; unreadable → still unknown.
    public func check() async {
        guard case .unconfirmed(let target, _) = state else { return }
        let ticket = generation, scope = accountScope()
        let stillListed = await listing(target)
        guard ticket == generation, accountScope() == scope, case .unconfirmed = state else { return }
        switch stillListed {
        case false?: state = .removed(target); await removed()
        case true?: state = .failed(target, .notApplied)
        case nil: state = .unconfirmed(target, checkedUnreadable: true)
        }
    }
    /// Sends the removal again after a check that could not read the list.
    public func retryUnconfirmed() async {
        guard case .unconfirmed(let target, true) = state else { return }
        state = .removing(target)
        await send(target)
    }
    public func dismiss() { switch state { case .failed, .removed, .unconfirmed: state = .idle; default: break } }
    /// A switch of account drops everything and ignores any late answer.
    public func accountChanged() { generation &+= 1; state = .idle }

    private func send(_ target: Target) async {
        let ticket = generation, scope = accountScope()
        sentCount += 1; sending = true
        defer { sending = false }
        let next: State
        do {
            let reply = try await remover(.removeUpload(entityID: target.entityID))
            switch reply.outcome {
            case .confirmed: next = .removed(target)
            case .rejected(.service): next = .failed(target, .refused)
            case .rejected(.rateLimited): next = .failed(target, .rateLimited)
            // A 5xx comes back after the request left: the service may have applied the removal, so nothing proves "nothing was changed".
            // It is unknown, and the list is read before anything is sent again. Only an `error` answer and a rate limit (turned away
            // before any processing) are refusals.
            case .rejected(.unavailable): next = .unconfirmed(target, checkedUnreadable: false)
            case .indeterminate: next = .unconfirmed(target, checkedUnreadable: false)
            }
        } catch let error as MusicSessionError {
            switch error {
            case .stale, .cancelled: return
            case .signedOut: next = .failed(target, .sessionEnded)
            case .notSignedIn: next = .failed(target, .needsSignIn)
            case .network, .timedOut: next = .failed(target, .offline)
            case .rateLimited: next = .failed(target, .rateLimited)
            case .policy: next = .failed(target, .notOffered)
            default: next = .failed(target, .unavailable)
            }
        } catch is CancellationError { return } catch { next = .failed(target, .unavailable) }
        guard ticket == generation, accountScope() == scope else { return }
        state = next
        if case .removed = next { await removed() }
    }
}
