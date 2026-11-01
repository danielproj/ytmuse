import Foundation
import Domain
import AccountSession
import CryptoKit

/// Test seam: a crash is modelled by throwing from a checkpoint; the scheduler then stops writing anything.
public struct SimulatedCrash: Error, Sendable { public init() {} }
public enum SchedulerCheckpoint: Sendable, Equatable {
    case persisted(DownloadPhase)
    case rangeRecorded
}

/// The durable download engine (OFF01-OFF13). One logical job per (account, media); jobs persist in an atomic ledger and
/// resume after any interruption. All retained bytes go into the W14 encrypted object store through a `RetentionSink`.
public actor DownloadScheduler: DownloadsControlling, AccountLifecycleParticipant {
    public nonisolated let participantID = "download-scheduler"
    public static let manualReference = "manual", smartReference = "smart", collectionPrefix = "collection:"

    public struct Configuration: Sendable {
        public var chunkBytes: Int
        public var persistEveryChunks: Int
        public var retry: RetryPolicy
        public var maxURLRefreshes: Int
        public var maxCorruptRestarts: Int
        public var quitTimeout: Duration
        /// The smallest budget the person may set. Tests lower it so quota boundaries can be exercised with small files.
        public var minimumBudget: Int64
        public init(chunkBytes: Int = 1 << 20, persistEveryChunks: Int = 4, retry: RetryPolicy = RetryPolicy(), maxURLRefreshes: Int = 3, maxCorruptRestarts: Int = 1, quitTimeout: Duration = .seconds(2), minimumBudget: Int64 = DownloadPolicy.gibibyte) {
            self.minimumBudget = minimumBudget; self.chunkBytes = max(1, chunkBytes); self.persistEveryChunks = max(1, persistEveryChunks); self.retry = retry; self.maxURLRefreshes = maxURLRefreshes; self.maxCorruptRestarts = maxCorruptRestarts; self.quitTimeout = quitTimeout
        }
    }
    public typealias WakeScheduler = @Sendable (Date, @escaping @Sendable () -> Void) -> @Sendable () -> Void

    // Dependencies
    private let ledger: DownloadLedgerRoot
    private let sink: any RetentionSink
    private let sources: [MediaOrigin: any DownloadSource]
    private let wall: any WallClock
    private let volume: any VolumeCapacityProviding
    private let configuration: Configuration
    private let random: @Sendable () -> Double
    private let wake: WakeScheduler
    private let networkProvider: (any NetworkPathProviding)?
    private let powerProvider: (any PowerStateProviding)?
    private var checkpointHook: (@Sendable (SchedulerCheckpoint) throws -> Void)?

    // State
    private var context: RequestContext?
    private var file: LedgerFile?
    private var settings = LedgerSettings()
    private var network = NetworkPathState()
    private var lowPower = false
    private var currentPlayback: String?
    private var halted = false
    private var quitting = false
    /// True while every running job is being stopped for an account change; nothing may start meanwhile.
    private var draining = false
    private var running: [UUID: Task<Void, Never>] = [:]
    private var reservations: [UUID: Int64] = [:]
    private var stopReasons: [UUID: StopReason] = [:]
    private var staging: [UUID: StagingFile] = [:]
    private var refreshes: [UUID: Int] = [:]
    private var cancelWake: (@Sendable () -> Void)?
    private var cancelObservers: [@Sendable () -> Void] = []
    private var cachedUsage: UsageSummary?
    private var lastPublished = ContinuousClock.now - .seconds(1)
    private var subscribers: [UUID: AsyncStream<DownloadsSnapshot>.Continuation] = [:]
    private var unlistedBytes: Int64 = 0
    private let suggestionsAvailable: Bool
    private let originOf: @Sendable (ServiceID) -> MediaOrigin
    /// Starts native playback of a kept item. Set by the composition; while nil no Play action is offered.
    private var playHandler: (@Sendable (PlayableDownload) async -> Bool)?

    private enum StopReason: Equatable { case userPause, userCancel, preempt, hold(DownloadPauseCause), quit, unbind }

    public init(ledgerRoot: URL, sink: any RetentionSink, sources: [MediaOrigin: any DownloadSource], wall: any WallClock = SystemWallClock(),
                network: (any NetworkPathProviding)? = nil, power: (any PowerStateProviding)? = nil, volume: any VolumeCapacityProviding = SystemVolumeCapacity(),
                configuration: Configuration = Configuration(), random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
                wake: @escaping WakeScheduler = DownloadScheduler.systemWake, checkpoint: (@Sendable (SchedulerCheckpoint) throws -> Void)? = nil,
                ledgerFault: (@Sendable (LedgerStage) throws -> Void)? = nil, suggestionsAvailable: Bool = false,
                originOf: @escaping @Sendable (ServiceID) -> MediaOrigin = { MediaOrigin.classify($0) }) throws {
        self.suggestionsAvailable = suggestionsAvailable; self.originOf = originOf
        self.ledger = try DownloadLedgerRoot(root: ledgerRoot)
        self.ledger.fault = ledgerFault
        self.sink = sink; self.sources = sources; self.wall = wall; self.volume = volume; self.configuration = configuration; self.random = random; self.wake = wake
        networkProvider = network; powerProvider = power; checkpointHook = checkpoint
        self.settings = (try? self.ledger.loadSettings()) ?? LedgerSettings()
        if let network { self.network = network.current() }
        if let power { lowPower = power.lowPowerMode() }
    }
    public static let systemWake: WakeScheduler = { date, fire in
        let task = Task { try? await Task.sleep(for: .seconds(max(0.05, date.timeIntervalSinceNow))); if !Task.isCancelled { fire() } }
        return { task.cancel() }
    }
    /// Subscribes to the system's measured network path and Low Power Mode. Called once by the composition root.
    public func startObserving() {
        guard cancelObservers.isEmpty else { return }
        if let networkProvider {
            cancelObservers.append(networkProvider.observe { [weak self] state in Task { await self?.networkChanged(state) } })
            network = networkProvider.current()
        }
        if let powerProvider {
            cancelObservers.append(powerProvider.observe { [weak self] value in Task { await self?.powerChanged(lowPower: value) } })
            lowPower = powerProvider.lowPowerMode()
        }
    }
    public func installPlayHandler(_ handler: (@Sendable (PlayableDownload) async -> Bool)?) { playHandler = handler; publish() }
    private func eligibility(_ media: ServiceID) -> DownloadEligibility {
        switch originOf(media) {
        case .youTubeMusic: .notOffered(.youTubeMusicNoMacDownloads)
        case let origin: .eligible(origin)
        }
    }
    public func installCheckpoint(_ hook: (@Sendable (SchedulerCheckpoint) throws -> Void)?) { checkpointHook = hook }

    // MARK: Account binding

    public func bind(_ context: RequestContext?) async {
        if let current = self.context {
            if let context, current.account == context.account {
                // Same account: only a newer-or-equal generation may take over; an older one is a stale caller and changes nothing.
                if context.accountGeneration >= current.accountGeneration { self.context = context; await sink.bind(context) }
                return
            }
            await unbind(discardPartials: true)
        }
        guard let context, let account = context.account else { return }
        self.context = context; quitting = false; halted = false
        await sink.bind(context)
        do { file = try ledger.load(account) }
        catch LedgerError.corrupt {
            // The retained objects the lost ledger described are still on disk: keep counting them toward the limit.
            let carried = (try? ledger.quarantine(account)) ?? UsageSummary()
            file = LedgerFile(account: DownloadLedgerRoot.directoryName(account)); unlistedBytes = carried.unlistedBytes
            persist()
        }
        catch { file = nil; self.context = nil; return }
        if unlistedBytes == 0 { unlistedBytes = ledger.loadUsage(account).unlistedBytes }
        recover()
        // A kept copy whose key or object is gone must never read Downloaded after a relaunch or a new sign-in.
        await auditRetained()
        await renewalSweep()
        pump()
    }
    /// `discardPartials`: the account is leaving (switch, sign-out). Its unfinished transfers lose their cleartext partials now; the
    /// jobs stay and start again from the first byte when the account returns. Quit and expiry keep partials to resume.
    private func unbind(discardPartials: Bool = false) async {
        draining = true; defer { draining = false }
        unlistedBytes = 0
        for id in Array(running.keys) { stopReasons[id] = .unbind }
        await settle(cancelling: true)
        if discardPartials, var current = file {
            for index in current.jobs.indices { removeStaging(&current.jobs[index]) }
            file = current
            if let account = context?.account { try? ledger.removeStagingDirectory(account) }
        }
        persist()
        staging.removeAll(); reservations.removeAll(); refreshes.removeAll(); stopReasons.removeAll()
        file = nil; context = nil
        cancelWake?(); cancelWake = nil
        publish()
    }
    public func detach(previous: RequestContext, barrier: RequestContext) async throws { await unbind(discardPartials: true) }
    /// Only a connected identity runs downloads; any other state leaves its work checkpointed and idle.
    public func restorePaused(_ identity: LocalIdentity, context: RequestContext) async throws {
        switch identity.state {
        case .connected: await bind(context)
        case .expired: await bind(nil)        // the session lapsed; keys and partials are still the account's own
        case .signedOut, .removalPending:
            // Sign-out erased the account's keys: nothing retained can be played and no partial may stay in the clear (OFF09, OFF12).
            if self.context?.account == identity.account.context { await accountRevoked() }
            await bind(nil)
            try await purgeOffline(identity.account.context)
        }
    }
    /// Revokes an account that is not bound: reads its ledger, deletes its cleartext staging and marks every job.
    private func purgeOffline(_ account: AccountContext) async throws {
        guard var offline = try? ledger.load(account) else { try? ledger.removeStagingDirectory(account); return }
        for index in offline.jobs.indices {
            offline.jobs[index].stagingName = nil; offline.jobs[index].stagingIdentity = nil; offline.jobs[index].completed.removeAll()
            offline.jobs[index].phase = .failed; offline.jobs[index].failure = .accountRevoked; offline.jobs[index].pause = nil; offline.jobs[index].storedBytes = 0
        }
        try? ledger.removeStagingDirectory(account)
        try? ledger.save(offline, account: account, usage: UsageSummary(storedBytes: 0, protectedBytes: 0, automaticBytes: 0, unlistedBytes: ledger.loadUsage(account).unlistedBytes))
        cachedUsage = nil
    }
    public func removeLocal(_ account: AccountContext, context removal: RequestContext) async throws {
        if self.context?.account == account { await unbind() }
        try ledger.removeAccount(account)
        cachedUsage = nil
        publish()
    }
    /// Sign-out/revocation (OFF12): retained bytes are erased by the store; here every job of the bound account stops,
    /// partial cleartext is removed and nothing is left looking resumable.
    public func accountRevoked() async {
        guard context != nil, var current = file else { return }
        draining = true; defer { draining = false }
        for id in Array(running.keys) { stopReasons[id] = .unbind }
        await settle(cancelling: true)
        for index in current.jobs.indices {
            removeStaging(&current.jobs[index])
            current.jobs[index].phase = .failed; current.jobs[index].failure = .accountRevoked; current.jobs[index].pause = nil
            current.jobs[index].storedBytes = 0; current.jobs[index].completed.removeAll()
        }
        file = current; persist(); publish()
    }

    // MARK: Recovery

    private func recover() {
        guard var current = file, let account = context?.account else { return }
        let directory = try? ledger.staging(account, create: false)
        var known: Set<String> = []
        for index in current.jobs.indices {
            switch current.jobs[index].phase {
            case .resolving, .downloading, .validating: current.jobs[index].phase = .queued
            case .renewing: current.jobs[index].phase = .available
            default: break
            }
            // Progress ranges and their bytes are one thing: ranges survive only beside the exact staging file that holds them,
            // for every phase. Any other job holds no ranges and no cleartext fragment.
            let resumable = [.queued, .paused].contains(current.jobs[index].phase)
            if resumable, let name = current.jobs[index].stagingName, let directory, directory.fileSize(name) != nil,
               (directory.fileSize(name) ?? 0) >= (current.jobs[index].completed.highest.map { $0 + 1 } ?? 0),
               current.jobs[index].completed.isEmpty || directory.identity(name) == current.jobs[index].stagingIdentity {
                known.insert(name)
            } else {
                if let name = current.jobs[index].stagingName { try? directory?.remove(name) }
                current.jobs[index].stagingName = nil; current.jobs[index].stagingIdentity = nil; current.jobs[index].completed.removeAll()
            }
        }
        if let directory, let names = try? directory.entries() { for name in names where !known.contains(name) { try? directory.remove(name) } }
        file = current
        persist()
    }

    // MARK: Public commands

    public enum Request: Sendable { case manual, collection(ServiceID), automatic }

    /// A manual download pins the item until it is removed (OFF04). YouTube Music items are never queued.
    @discardableResult
    public func download(_ media: ServiceID, title: String, subtitle: String? = nil, location: String? = nil, contentType: String? = nil, request: Request = .manual) async -> DownloadCommandResult {
        guard context != nil, file != nil else { return .refused(.unauthorized) }
        switch eligibility(media) {
        case .notOffered(let reason): return .notOffered(reason)
        case .eligible(let origin):
            guard sources[origin] != nil else { return .refused(.unsupported) }
            if case .automatic = request, !settings.smartDownloads { return .refused(.forbidden) }
            return await enqueue(media, title: title, subtitle: subtitle, origin: origin, location: location, contentType: contentType, request: request)
        }
    }
    private func enqueue(_ media: ServiceID, title: String, subtitle: String?, origin: MediaOrigin, location: String?, contentType: String? = nil, request: Request) async -> DownloadCommandResult {
        guard var current = file, let context else { return .refused(.unauthorized) }
        let reference: String; let manual: Bool; let automatic: Bool
        switch request {
        case .manual: reference = Self.manualReference; manual = true; automatic = false
        case .collection(let id): reference = Self.collectionPrefix + id.rawValue; manual = false; automatic = false
        case .automatic: reference = Self.smartReference; manual = false; automatic = true
        }
        if let index = current.jobs.firstIndex(where: { $0.media == media.rawValue }) {
            // Reconnect, repeat taps and overlapping collections never spawn a second job (OFF13, OFF11).
            var job = current.jobs[index]
            let before = job.references
            job.references.insert(reference)
            if manual { job.pinned = true; job.automatic = false; current.sequence += 1; job.sequence = current.sequence }
            else if !automatic { job.automatic = false }
            if job.phase == .failed, manual { job.phase = .queued; job.failure = nil; job.attempts = 0; job.pause = nil }
            if job.phase == .paused, manual, job.pause == .userPaused { job.phase = .queued; job.pause = nil }
            current.jobs[index] = job; file = current
            if job.phase == .available || job.phase == .renewing || job.phase == .expired, let variant = job.variant {
                do {
                    if job.references != before { try await sink.addReference(variant: variant, reference: reference, context: context) }
                    if manual { try await sink.setPinned(variant: variant, pinned: true, context: context) }
                } catch { return .refused((error as? DomainError) ?? .transientTransport) }
            }
            persist(); publish(); pump()
            return .done
        }
        current.sequence += 1
        var job = JobRecord(id: UUID(), media: media.rawValue, title: title, subtitle: subtitle, origin: origin, location: location, createdAt: wall.now()); job.contentType = contentType
        job.references = [reference]; job.pinned = manual; job.automatic = automatic; job.sequence = current.sequence
        current.jobs.append(job); file = current
        persist(); publish(); pump()
        return .done
    }
    /// Removes a job and every retained trace (staging, store references). Used by cancel, remove and eviction.
    private func removeJob(_ id: UUID) async {
        guard var current = file, let context, let index = current.jobs.firstIndex(where: { $0.id == id }) else { return }
        if running[id] != nil { stopReasons[id] = .userCancel; await settle(only: id) }
        guard let position = file?.jobs.firstIndex(where: { $0.id == id }) else { return }
        current = file ?? current
        var job = current.jobs[position]
        removeStaging(&job)
        if let variant = job.variant, [.available, .renewing, .expired, .validating].contains(job.phase) || job.storedBytes > 0 {
            for reference in job.references.sorted() { try? await sink.removeReference(variant: variant, reference: reference, context: context) }
            if job.pinned { try? await sink.setPinned(variant: variant, pinned: false, context: context) }
            // Removing the item removes the retained object itself, whatever else referenced it.
            try? await sink.delete(variant: variant, context: context)
        }
        current.jobs.removeAll { $0.id == id }
        file = current
        persist(); publish()
    }

    public func perform(_ action: DownloadAction, job id: UUID) async -> DownloadCommandResult {
        guard var current = file, let context, let index = current.jobs.firstIndex(where: { $0.id == id }) else { return .refused(.unavailableContent) }
        var job = current.jobs[index]
        switch action {
        case .play:
            guard job.phase == .available, let variant = job.variant, [.owned, .localFile].contains(job.origin), let playHandler,
                  let media = try? ServiceID(job.media) else { return .refused(.unsupported) }
            let playable = PlayableDownload(media: media, variant: variant, title: job.title, subtitle: job.subtitle, contentType: job.contentType, seekable: job.grantRights.contains("seek"), context: context)
            return await playHandler(playable) ? .done : .refused(.transientTransport)
        case .pause:
            guard [.queued, .resolving, .downloading, .paused].contains(job.phase) else { return .refused(.invalidInput(.invalidTransition)) }
            if running[id] != nil { stopReasons[id] = .userPause; await settle(only: id) }
            else { current = file ?? current; guard let i = current.jobs.firstIndex(where: { $0.id == id }) else { return .done }; current.jobs[i].phase = .paused; current.jobs[i].pause = .userPaused; file = current; persist(); publish() }
        case .resume:
            guard job.phase == .paused else { return .refused(.invalidInput(.invalidTransition)) }
            job.phase = .queued; job.pause = nil; job.nextAttemptAt = nil; current.jobs[index] = job; file = current; persist(); publish(); pump()
        case .retry:
            guard job.phase == .failed else { return .refused(.invalidInput(.invalidTransition)) }
            if job.failure == .corruptBytes || job.failure == .missingKey { return await perform(.downloadAgain, job: id) }
            job.phase = .queued; job.failure = nil; job.attempts = 0; job.nextAttemptAt = nil; job.pause = nil; current.jobs[index] = job; file = current; persist(); publish(); pump()
        case .cancel:
            guard ![.available, .renewing, .expired].contains(job.phase) else { return .refused(.invalidInput(.invalidTransition)) }
            await removeJob(id)
        case .remove:
            // Removing one song from a downloaded playlist keeps it out of that playlist's download until it leaves and rejoins.
            for reference in job.references where reference.hasPrefix(Self.collectionPrefix) {
                let collection = String(reference.dropFirst(Self.collectionPrefix.count))
                if let i = current.collections.firstIndex(where: { $0.id == collection }), !current.collections[i].excluded.contains(job.media) { current.collections[i].excluded.append(job.media) }
            }
            file = current
            await removeJob(id)
        case .pin:
            guard job.phase == .available || job.phase == .expired || job.phase == .renewing, let variant = job.variant else {
                job.pinned = true; job.references.insert(Self.manualReference); current.jobs[index] = job; file = current; persist(); publish(); return .done
            }
            do { try await sink.addReference(variant: variant, reference: Self.manualReference, context: context); try await sink.setPinned(variant: variant, pinned: true, context: context) }
            catch { return .refused((error as? DomainError) ?? .transientTransport) }
            guard var after = file, let i = after.jobs.firstIndex(where: { $0.id == id }) else { return .done }
            after.jobs[i].pinned = true; after.jobs[i].references.insert(Self.manualReference); after.jobs[i].automatic = false; file = after; persist(); publish()
        case .unpin:
            let others = job.references.subtracting([Self.manualReference])
            guard job.pinned, !others.isEmpty else { return .refused(.invalidInput(.invalidTransition)) }
            if let variant = job.variant, [.available, .renewing, .expired].contains(job.phase) {
                do { try await sink.setPinned(variant: variant, pinned: false, context: context); try await sink.removeReference(variant: variant, reference: Self.manualReference, context: context) }
                catch { return .refused((error as? DomainError) ?? .transientTransport) }
            }
            guard var after = file, let i = after.jobs.firstIndex(where: { $0.id == id }) else { return .done }
            after.jobs[i].pinned = false; after.jobs[i].references.remove(Self.manualReference); file = after; persist(); publish()
        case .renew:
            guard [.available, .expired, .renewing].contains(job.phase) else { return .refused(.invalidInput(.invalidTransition)) }
            await renew(id: id, force: true)
        case .downloadAgain:
            guard [.failed, .expired, .available].contains(job.phase) else { return .refused(.invalidInput(.invalidTransition)) }
            if let variant = job.variant { try? await sink.delete(variant: variant, context: context) }
            guard var after = file, let i = after.jobs.firstIndex(where: { $0.id == id }) else { return .done }
            var again = after.jobs[i]
            removeStaging(&again)
            again.variant = nil; again.validator = nil; again.length = nil; again.completed.removeAll(); again.storedBytes = 0
            again.phase = .queued; again.failure = nil; again.pause = nil; again.attempts = 0; again.corruptRestarts = 0; again.nextAttemptAt = nil
            after.sequence += 1; again.sequence = after.sequence
            after.jobs[i] = again; file = after; persist(); publish(); pump()
        case .downloadOnThisNetwork:
            guard !job.automatic, [.queued, .paused].contains(job.phase) else { return .refused(.invalidInput(.invalidTransition)) }
            job.overrideNetwork = true
            if job.phase == .paused, let cause = job.pause, cause == .constrainedNetwork || cause == .expensiveNetwork { job.phase = .queued; job.pause = nil }
            current.jobs[index] = job; file = current; persist(); publish(); pump()
        }
        return .done
    }
    public func setBudget(bytes: Int64) async -> DownloadCommandResult {
        guard bytes >= configuration.minimumBudget, bytes <= 4096 * DownloadPolicy.gibibyte else { return .refused(.invalidInput(.invalidRange)) }
        // OFF03: lowering the budget never deletes anything. It only decides what may start next.
        settings.budget = bytes
        do { try ledger.saveSettings(settings) } catch { return .refused(.transientTransport) }
        reevaluateHolds(); publish(); pump()
        return .done
    }
    public func setSmartDownloads(enabled: Bool) async -> DownloadCommandResult {
        // Nothing on this Mac supplies suggestions, so switching it on could never do anything: say so instead of accepting it.
        if enabled, !suggestionsAvailable { return .refused(.unsupported) }
        settings.smartDownloads = enabled
        do { try ledger.saveSettings(settings) } catch { return .refused(.transientTransport) }
        // Existing automatic content stays; turning Smart off only stops new automatic downloads. A pending automatic
        // download that never started has no explicit owner, so it is dropped.
        if !enabled, let current = file {
            for job in current.jobs where job.automatic && !job.pinned && ![.available, .renewing, .expired].contains(job.phase) { await removeJob(job.id) }
        }
        publish(); pump()
        return .done
    }
    /// W27 (Automatic downloads on expensive networks, default off).
    public func setAutomaticOnExpensive(enabled: Bool) async -> DownloadCommandResult {
        settings.automaticOnExpensive = enabled ? true : nil
        do { try ledger.saveSettings(settings) } catch { return .refused(.transientTransport) }
        publish(); pump()
        return .done
    }
    public var automaticOnExpensiveAllowed: Bool { settings.automaticOnExpensive == true }
    /// W27: what this account's downloads keep on disk, read from the per-account usage summary the budget itself sums (so the two cannot disagree).
    public func usage(for account: AccountContext) -> AccountDownloadUsage {
        let u = ledger.loadUsage(account)
        return AccountDownloadUsage(storedBytes: u.storedBytes + u.unlistedBytes, pinnedBytes: u.protectedBytes + u.unlistedBytes, automaticBytes: u.automaticBytes, unlistedBytes: u.unlistedBytes)
    }
    /// W27: what the ledger directories NOT owned by any of `accounts` hold (an account the roster no longer lists). Enumerated from the directories themselves.
    public func usageOutside(_ accounts: [AccountContext]) -> AccountDownloadUsage {
        let u = ledger.usageOutside(Set(accounts.map(DownloadLedgerRoot.directoryName)))
        return AccountDownloadUsage(storedBytes: u.storedBytes, pinnedBytes: u.protectedBytes, automaticBytes: u.automaticBytes, unlistedBytes: u.unlistedBytes)
    }
    /// The same sum the budget uses, across every account directory (including one no roster lists any more).
    public func usageAcrossAccounts() -> AccountDownloadUsage {
        let u = ledger.usageAcrossAccounts()
        return AccountDownloadUsage(storedBytes: u.storedBytes, pinnedBytes: u.protectedBytes, automaticBytes: u.automaticBytes, unlistedBytes: u.unlistedBytes)
    }
    public func removeAutomaticDownloads() async -> DownloadCommandResult {
        guard let current = file else { return .refused(.unauthorized) }
        for job in current.jobs where job.automatic && !job.pinned && job.references.subtracting([Self.smartReference]).isEmpty { await removeJob(job.id) }
        publish(); pump()
        return .done
    }
    public func addLocalFile(_ url: URL) async -> DownloadCommandResult {
        guard context != nil else { return .refused(.unauthorized) }
        guard url.isFileURL, let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey]), values.isRegularFile == true, (values.fileSize ?? 0) > 0,
              values.contentType?.conforms(to: .audio) == true || values.contentType?.conforms(to: .movie) == true else { return .refused(.unsupported) }
        guard let id = try? ServiceID(MediaOrigin.localFilePrefix + UUID().uuidString) else { return .refused(.malformedResponse) }
        return await download(id, title: url.deletingPathExtension().lastPathComponent, subtitle: String(localized: "File on this Mac"), location: url.path, contentType: values.contentType?.identifier)
    }

    // MARK: Collections (LIST07, OFF11)

    /// Turns "Download this playlist" on or off and reconciles retained references with its current members.
    public func setCollection(_ id: ServiceID, title: String, members: [ServiceID], downloading: Bool) async -> DownloadCommandResult {
        guard var current = file, context != nil else { return .refused(.unauthorized) }
        if downloading {
            let eligible = members.filter { if case .eligible = eligibility($0) { return true } else { return false } }
            if !members.isEmpty, eligible.isEmpty, case .notOffered(let reason) = eligibility(members[0]) { return .notOffered(reason) }
            if let index = current.collections.firstIndex(where: { $0.id == id.rawValue }) { current.collections[index].title = title; current.collections[index].excluded = [] }
            else { current.collections.append(CollectionRecord(id: id.rawValue, title: title, members: [])) }
            file = current; persist()
            return await reconcileCollection(id, members: members)
        }
        guard let index = current.collections.firstIndex(where: { $0.id == id.rawValue }) else { return .done }
        current.collections.remove(at: index); file = current
        await dropCollectionReference(id.rawValue, from: Set(current.jobs.filter { $0.references.contains(Self.collectionPrefix + id.rawValue) }.map(\.media)))
        persist(); publish(); pump()
        return .done
    }
    /// New entries join the queue; removed entries lose only THIS collection's reference (never another's, never a pin).
    @discardableResult
    public func reconcileCollection(_ id: ServiceID, members: [ServiceID]) async -> DownloadCommandResult {
        guard var current = file, context != nil, let index = current.collections.firstIndex(where: { $0.id == id.rawValue }) else { return .refused(.unavailableContent) }
        var seen: Set<String> = []
        let wanted = members.map(\.rawValue).filter { seen.insert($0).inserted }
        let previous = Set(current.collections[index].members)
        current.collections[index].members = wanted
        file = current; persist()
        let gone = previous.subtracting(wanted)
        await dropCollectionReference(id.rawValue, from: gone)
        let skip = Set(file?.collections.first { $0.id == id.rawValue }?.excluded ?? [])
        if var after = file, let i = after.collections.firstIndex(where: { $0.id == id.rawValue }) { after.collections[i].excluded = skip.intersection(wanted).sorted(); file = after }
        for raw in wanted where !skip.contains(raw) {
            guard let media = try? ServiceID(raw), case .eligible(let origin) = eligibility(media), sources[origin] != nil else { continue }
            let known = file?.jobs.first { $0.media == raw }
            _ = await enqueue(media, title: known?.title ?? raw, subtitle: known?.subtitle, origin: origin, location: known?.location, request: .collection(id))
        }
        persist(); publish(); pump()
        return .done
    }
    private func dropCollectionReference(_ collection: String, from media: Set<String>) async {
        guard let context else { return }
        let reference = Self.collectionPrefix + collection
        for raw in media {
            guard let job = file?.jobs.first(where: { $0.media == raw }), job.references.contains(reference) else { continue }
            if job.pinned || !job.references.subtracting([reference]).isEmpty {
                // Still wanted by a pin or another collection: lose only THIS reference (OFF11).
                if let variant = job.variant, [.available, .renewing, .expired].contains(job.phase) {
                    // The ledger is the record of what the person asked to keep: make the store agree BEFORE the reference goes,
                    // so a pin that the store somehow lost cannot turn this removal into a deletion.
                    if job.pinned {
                        try? await sink.addReference(variant: variant, reference: Self.manualReference, context: context)
                        try? await sink.setPinned(variant: variant, pinned: true, context: context)
                    }
                    try? await sink.removeReference(variant: variant, reference: reference, context: context)
                }
                mutate(job.id) { $0.references.remove(reference); if $0.pinned { $0.references.insert(Self.manualReference) } }
            } else {
                await removeJob(job.id)
            }
        }
        persist()
    }

    // MARK: Environment

    public func networkChanged(_ state: NetworkPathState) { network = state; reevaluateHolds(); publish(); pump() }
    public func powerChanged(lowPower value: Bool) { lowPower = value; reevaluateHolds(); publish(); pump() }
    public func setCurrentPlayback(_ media: ServiceID?) { currentPlayback = media?.rawValue; pump() }
    /// The volume's free space changed (the account holder freed space after a full disk).
    public func volumeSpaceChanged() {
        guard var current = file else { return }
        for index in current.jobs.indices where current.jobs[index].pause == .diskFull { current.jobs[index].phase = .queued; current.jobs[index].pause = nil }
        file = current; persist(); publish(); pump()
    }
    public func isAvailable(_ media: ServiceID) -> Bool { file?.jobs.contains { $0.media == media.rawValue && $0.phase == .available } ?? false }
    public func availableMedia() -> Set<ServiceID> { Set((file?.jobs ?? []).filter { $0.phase == .available }.compactMap { try? ServiceID($0.media) }) }
    public func play(job id: UUID) async -> DownloadCommandResult { await perform(.play, job: id) }
    /// The kept, playable copy of `media` for the bound account, if one is available.
    public func playable(_ media: ServiceID) -> PlayableDownload? {
        guard let context, let job = file?.jobs.first(where: { $0.media == media.rawValue }), job.phase == .available, let variant = job.variant, [.owned, .localFile].contains(job.origin) else { return nil }
        return PlayableDownload(media: media, variant: variant, title: job.title, subtitle: job.subtitle, contentType: job.contentType, seekable: job.grantRights.contains("seek"), context: context)
    }
    public func jobID(for media: ServiceID) -> UUID? { file?.jobs.first { $0.media == media.rawValue }?.id }
    /// The store identifier of a job's bound variant (diagnostics and tests).
    public func variantForTesting(_ media: ServiceID) -> String? { file?.jobs.first { $0.media == media.rawValue }?.variant }

    // MARK: Scheduling

    private func protectedReferences(_ job: JobRecord) -> Bool { job.pinned || !job.references.subtracting([Self.smartReference]).isEmpty }
    private func priority(_ job: JobRecord) -> (Int, Int64) {
        if job.media == currentPlayback { return (0, 0) }
        if job.pinned { return (1, -Int64(job.sequence)) }          // newest explicit download first
        if job.automatic { return (3, Int64(job.sequence)) }
        return (2, Int64(job.sequence))                              // collection members, in queue order
    }
    private func currentUsage() -> UsageSummary {
        if let cachedUsage { return cachedUsage }
        let value = ledger.usageAcrossAccounts(); cachedUsage = value; return value
    }
    private func usageLedger(excluding id: UUID?) -> DownloadPolicy.Ledger {
        let usage = currentUsage()
        var inFlight: Int64 = 0, inFlightAutomatic: Int64 = 0
        for job in file?.jobs ?? [] where job.id != id && ![.available, .renewing, .expired, .failed].contains(job.phase) {
            let held = running[job.id] != nil ? (reservations[job.id] ?? job.completed.coveredBytes) : job.completed.coveredBytes
            inFlight += held; if job.automatic { inFlightAutomatic += held }
        }
        return DownloadPolicy.Ledger(usedAllAccounts: usage.storedBytes, protectedBytes: usage.protectedBytes, automaticBytes: usage.automaticBytes, inFlightBytes: inFlight, inFlightAutomaticBytes: inFlightAutomatic)
    }
    private func admission(for job: JobRecord, remainingHint: Int64? = nil) -> DownloadPolicy.Admission {
        let capacity = volume.capacity(at: ledger.rootURL)
        let plain = job.length ?? (job.completed.coveredBytes + Int64(configuration.chunkBytes))
        let need = DownloadPolicy.onDiskBytes(plain: plain)
        let remaining = job.length.map { max(0, $0 - job.completed.coveredBytes) } ?? Int64(configuration.chunkBytes)
        // On the volume the staged copy and the encrypted copy briefly coexist while the object is imported.
        let volumeNeed = remainingHint ?? (remaining + DownloadPolicy.onDiskBytes(plain: plain))
        return DownloadPolicy.admission(bytes: need, volumeBytes: volumeNeed, automatic: job.automatic, ledger: usageLedger(excluding: job.id), budget: settings.budget, volumeTotal: capacity.total, volumeAvailable: capacity.available)
    }
    private func networkHold(_ job: JobRecord) -> DownloadPauseCause? {
        guard network.isAvailable else { return .offline }
        // OFF05: automatic downloads never use a constrained or expensive path; a manual one does only on explicit override.
        // W27: the person may allow automatic jobs on an EXPENSIVE path; a constrained path (Low Data Mode) always blocks them.
        if network.isMetered, job.automatic, !network.isConstrained, settings.automaticOnExpensive == true { return nil }
        if network.isMetered, job.automatic || !job.overrideNetwork { return network.isConstrained ? .constrainedNetwork : .expensiveNetwork }
        return nil
    }
    /// Why this job may not run right now, or nil. Nothing here mutates state.
    private func holdCause(_ job: JobRecord) -> DownloadPauseCause? {
        if let cause = networkHold(job) { return cause }
        switch admission(for: job) {
        case .admit, .needsEviction: return nil        // eviction happens when the job starts
        case .budgetFullOfPinned: return .storageBudgetFull
        case .volumeReserve: return .volumeReserve
        case .smartCapReached: return .smartCapReached
        }
    }
    private static let systemCauses: Set<DownloadPauseCause> = [.offline, .constrainedNetwork, .expensiveNetwork, .storageBudgetFull, .volumeReserve, .smartCapReached]
    /// Queued jobs that now have a reason to wait become paused-with-cause; paused-by-system jobs whose cause cleared requeue.
    private func reevaluateHolds() {
        guard var current = file else { return }
        var changed = false
        for index in current.jobs.indices {
            let job = current.jobs[index]
            switch job.phase {
            case .paused:
                if let cause = job.pause, Self.systemCauses.contains(cause), holdCause(job) == nil { current.jobs[index].phase = .queued; current.jobs[index].pause = nil; changed = true }
            case .queued:
                if let cause = holdCause(job) { current.jobs[index].phase = .paused; current.jobs[index].pause = cause; changed = true }
            case .resolving, .downloading:
                // A running job stops when the path turned metered/offline (unless the person overrode it) or storage ran out.
                if let cause = networkHold(job), running[job.id] != nil, stopReasons[job.id] == nil { stopReasons[job.id] = .hold(cause); running[job.id]?.cancel() }
            default: break
            }
        }
        if changed { file = current; persist() }
    }
    private func pump() {
        guard !quitting, !draining, !halted, context != nil, file != nil else { return }
        reevaluateHolds()
        guard let current = file else { return }
        let limit = DownloadPolicy.concurrencyLimit(lowPowerMode: lowPower)
        let waiting = current.jobs.filter { $0.phase == .queued && running[$0.id] == nil && ($0.nextAttemptAt.map { $0 <= wall.now() } ?? true) }.sorted { priority($0) < priority($1) }
        // Priority wins: a higher-ranked job takes a slot from the lowest-ranked running one; a smaller limit sheds the surplus.
        var active = current.jobs.filter { running[$0.id] != nil && stopReasons[$0.id] == nil }.sorted { priority($0) < priority($1) }
        while active.count > limit, let victim = active.popLast() { stopReasons[victim.id] = .preempt; running[victim.id]?.cancel() }
        var free = limit - running.count
        for candidate in waiting {
            if free > 0 { start(candidate.id); free -= 1; continue }
            guard let worst = active.last, priority(candidate) < priority(worst), candidate.media == currentPlayback else { break }
            active.removeLast(); stopReasons[worst.id] = .preempt; running[worst.id]?.cancel()
        }
        scheduleWake()
    }
    private func scheduleWake() {
        cancelWake?(); cancelWake = nil
        let due = (file?.jobs ?? []).filter { $0.phase == .queued }.compactMap(\.nextAttemptAt).filter { $0 > wall.now() }.min()
        let renewal = (file?.jobs ?? []).filter { $0.phase == .available }.compactMap(\.renewAfter).filter { $0 > wall.now() }.min()
        guard let next = [due, renewal].compactMap({ $0 }).min() else { return }
        cancelWake = wake(next) { [weak self] in Task { await self?.wakeFired() } }
    }
    public func wakeFired() async { await renewalSweep(); pump() }
    private func start(_ id: UUID) {
        guard running[id] == nil else { return }
        stopReasons[id] = nil
        running[id] = Task { [weak self] in await self?.execute(id) }
    }

    /// Waits until every running job has stopped. `cancelling` cancels them first (their stop reasons are already set).
    public func settle() async { await settle(cancelling: false) }
    /// Like `settle()` but gives up after `timeout`; returns whether everything stopped.
    public func settle(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !running.isEmpty, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        return running.isEmpty
    }
    private func settle(cancelling: Bool) async {
        if cancelling { for task in running.values { task.cancel() } }
        while let task = running.values.first { await task.value }
    }
    private func settle(only id: UUID) async {
        guard let task = running[id] else { return }
        task.cancel(); await task.value
    }

    // MARK: Execution of one job

    private func mutate(_ id: UUID, _ change: (inout JobRecord) -> Void) {
        guard var current = file, let index = current.jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&current.jobs[index]); file = current
    }
    private func job(_ id: UUID) -> JobRecord? { file?.jobs.first { $0.id == id } }
    private func stagingDirectory() throws -> PrivateDirectory {
        guard let account = context?.account else { throw DomainError.unauthorized }
        return try ledger.staging(account, create: true)
    }
    private func removeStaging(_ job: inout JobRecord) {
        staging[job.id] = nil
        if let name = job.stagingName, let account = context?.account, let directory = try? ledger.staging(account, create: false) { try? directory.remove(name) }
        // Progress ranges never outlive the bytes they describe.
        job.stagingName = nil; job.stagingIdentity = nil; job.completed.removeAll()
    }
    private func shouldStop(_ id: UUID) -> Bool { halted || Task.isCancelled || stopReasons[id] != nil }

    private func execute(_ id: UUID) async {
        defer { running[id] = nil; reservations[id] = nil; if !halted { pump() }; publish() }
        guard let context, let initial = job(id), let source = sources[initial.origin] else { return }
        do {
            try await run(id, source: source, context: context)
        } catch {
            await handle(error, id: id)
        }
    }

    private func transition(_ id: UUID, to phase: DownloadPhase, _ change: ((inout JobRecord) -> Void)? = nil) throws {
        if halted { throw SimulatedCrash() }
        mutate(id) { $0.phase = phase; $0.pause = nil; change?(&$0) }
        persist()
        do { try checkpointHook?(.persisted(phase)) } catch { halted = true; throw error }
        publish()
    }

    private func run(_ id: UUID, source: any DownloadSource, context: RequestContext) async throws {
        var urlRefreshes = 0
        resolve: while true {
            try transition(id, to: .resolving)
            guard let beforeResolve = job(id) else { return }
            let item = SourceItem(media: try ServiceID(beforeResolve.media), location: beforeResolve.location)
            let descriptor = try await source.describe(item: item, context: context)
            if shouldStop(id) { throw CancellationError() }
            guard let bound = job(id) else { return }
            // OFF07: the descriptor names the exact bytes. Different bytes mean a clean restart, never an append.
            if let variant = bound.variant, variant != descriptor.variant || bound.validator != descriptor.validator || (bound.length != nil && bound.length != descriptor.length) {
                mutate(id) { var j = $0; self.removeStaging(&j); j.completed.removeAll(); j.length = nil; j = j; $0 = j }
            } else if !descriptor.supportsRanges, !bound.completed.isEmpty {
                mutate(id) { var j = $0; self.removeStaging(&j); j.completed.removeAll(); $0 = j }
            }
            mutate(id) {
                $0.variant = descriptor.variant; $0.validator = descriptor.validator; $0.length = descriptor.length; $0.supportsRanges = descriptor.supportsRanges
                $0.expectedSHA256 = descriptor.sha256
                $0.grantValidatedAt = descriptor.permission.validatedAt; $0.grantExpires = descriptor.permission.expires; $0.renewAfter = descriptor.permission.renewAfter; $0.grantIssuer = descriptor.permission.issuer; $0.grantRights = descriptor.permission.rights
            }
            guard let ready = job(id) else { return }
            // Admission before any byte moves. Automatic content may never push anything out; manual may evict automatic.
            switch admission(for: ready) {
            case .admit: break
            case .needsEviction(let bytes): await evictAutomatic(atLeast: bytes)
            case .budgetFullOfPinned: throw StopForCause(cause: .storageBudgetFull)
            case .volumeReserve: throw StopForCause(cause: .volumeReserve)
            case .smartCapReached: throw StopForCause(cause: .smartCapReached)
            }
            reservations[id] = DownloadPolicy.onDiskBytes(plain: descriptor.length ?? (ready.completed.coveredBytes + Int64(configuration.chunkBytes)))
            try transition(id, to: .downloading)
            do {
                try await transfer(id, source: source, item: item, descriptor: descriptor, context: context)
            } catch SourceFailure.urlExpired {
                // OFF07: re-resolve and continue where the ranges stopped; bounded so a source that always expires cannot spin.
                urlRefreshes += 1
                if urlRefreshes > configuration.maxURLRefreshes { throw SourceFailure.transient(retryAfter: nil) }
                continue resolve
            }
            try await finish(id, descriptor: descriptor, source: source, item: item, context: context)
            return
        }
    }

    private struct StopForCause: Error { let cause: DownloadPauseCause }

    private func transfer(_ id: UUID, source: any DownloadSource, item: SourceItem, descriptor: SourceDescriptor, context: RequestContext) async throws {
        guard let account = context.account else { throw DomainError.unauthorized }
        let directory = try stagingDirectory()
        var name = job(id)?.stagingName
        if name == nil { let fresh = UUID().uuidString + ".part"; name = fresh; mutate(id) { $0.stagingName = fresh }; persist() }
        let stagingFile = try StagingFile(directory: directory, directoryURL: ledger.accountURL(account).appendingPathComponent(DownloadLedgerRoot.stagingDirectory, isDirectory: true), name: name!)
        staging[id] = stagingFile
        // The ranges belong to one specific file. A file of the same name that is not that file (recreated, replaced) holds none of them.
        let identity = stagingFile.identity
        mutate(id) { job in
            if !job.completed.isEmpty, job.stagingIdentity != identity || stagingFile.size < (job.completed.highest.map { $0 + 1 } ?? 0) { job.completed.removeAll() }
            job.stagingIdentity = identity
        }
        persist()
        var sinceRecorded = 0
        var length = descriptor.length
        while true {
            if shouldStop(id) { throw CancellationError() }
            guard let current = job(id) else { return }
            let offset: Int64
            let count: Int
            if let length {
                guard let gap = current.completed.missing(total: length).first else { break }
                offset = gap.lower; count = Int(min(Int64(configuration.chunkBytes), gap.upper - gap.lower + 1))
            } else {
                offset = current.completed.contiguousPrefix; count = configuration.chunkBytes
            }
            // Re-check space as bytes land: the volume shrinks under us and the budget is shared with other work.
            if sinceRecorded == 0 || length == nil {
                switch admission(for: current) {
                case .budgetFullOfPinned: throw StopForCause(cause: .storageBudgetFull)
                case .volumeReserve: throw StopForCause(cause: .volumeReserve)
                case .smartCapReached: throw StopForCause(cause: .smartCapReached)
                case .needsEviction(let bytes): await evictAutomatic(atLeast: bytes)
                case .admit: break
                }
            }
            let read = try await source.read(item: item, descriptor: descriptor, offset: offset, count: count, context: context)
            if shouldStop(id) { throw CancellationError() }
            if let length, offset + Int64(read.data.count) > length { throw SourceFailure.urlExpired }   // the bytes no longer match the described length
            if read.data.isEmpty && !read.endOfStream { throw SourceFailure.transient(retryAfter: nil) }
            if !read.data.isEmpty {
                try stagingFile.write(read.data, at: offset)
                try stagingFile.sync()
                let upper = offset + Int64(read.data.count) - 1
                mutate(id) { $0.completed.insert(lower: offset, upper: upper); $0.attempts = 0; $0.nextAttemptAt = nil }
                refreshes[id] = 0
                sinceRecorded += 1
                if let hook = checkpointHook { do { try hook(.rangeRecorded) } catch { halted = true; throw error } }
                if sinceRecorded >= configuration.persistEveryChunks { persist(); sinceRecorded = 0 }
                publishProgress()
            }
            if length == nil, read.endOfStream {
                // Total size becomes known only now; never before.
                let total = offset + Int64(read.data.count)
                length = total; mutate(id) { $0.length = total }
                persist()
            }
            if read.data.isEmpty {
                // Nothing came back. With an unknown total that is the end; with a known one the source ended early.
                if length == nil { break }
                throw SourceFailure.transient(retryAfter: nil)
            }
        }
        if sinceRecorded > 0 { persist() }
    }

    private func finish(_ id: UUID, descriptor: SourceDescriptor, source: any DownloadSource, item: SourceItem, context: RequestContext) async throws {
        guard let job = job(id), let length = job.length, let name = job.stagingName, let stagingFile = staging[id], let variant = job.variant else { throw SourceFailure.transient(retryAfter: nil) }
        try transition(id, to: .validating)
        // Completeness first: the ranges must cover every byte, and the file must be exactly that long.
        guard job.completed.isComplete(total: length), stagingFile.size >= length else { throw ValidationFailure.incomplete }
        if stagingFile.size > length { try stagingFile.truncate(to: length) }
        let digest = try stagingFile.digest(length: length)
        // What the source says it holds: a published digest, or one the source can state itself (a local file). A staged copy that
        // differs from it (for example one with a never-written gap) is corrupt, however complete its ranges look.
        let published: String? = job.expectedSHA256
        let sourceDigest: String? = published == nil ? try await source.contentDigest(item: item, descriptor: descriptor, length: length) : nil
        let expected = published ?? sourceDigest
        if let expected, expected.lowercased() != digest { throw ValidationFailure.corrupt }
        mutate(id) { $0.contentSHA256 = digest }
        let grant = descriptor.permission.grant
        let primary = job.references.contains(Self.manualReference) ? Self.manualReference : (job.references.sorted().first ?? Self.manualReference)
        try await sink.retain(file: stagingFile.url, variant: variant, grant: grant, reference: primary, context: context)
        for reference in job.references.sorted() where reference != primary { try await sink.addReference(variant: variant, reference: reference, context: context) }
        if job.pinned { try await sink.setPinned(variant: variant, pinned: true, context: context) }
        do {
            // The object the store now holds must be exactly what was staged and checked.
            if let stored = try await sink.verify(variant: variant, context: context), stored != digest { throw ValidationFailure.corrupt }
        } catch let failure as ValidationFailure { throw failure } catch { throw ValidationFailure.storedCopyCorrupt(error) }
        let retained = try await sink.retainedLength(variant: variant, context: context)
        guard Int64(retained) == length else { throw ValidationFailure.corrupt }
        try transition(id, to: .available) { record in
            record.storedBytes = DownloadPolicy.onDiskBytes(plain: length)
            record.attempts = 0; record.nextAttemptAt = nil; record.failure = nil
        }
        // Only after the available state is durable is the cleartext staging copy removed.
        mutate(id) { var j = $0; self.removeStaging(&j); $0 = j }
        persist()
    }
    private enum ValidationFailure: Error { case incomplete, corrupt, storedCopyCorrupt(Error) }

    private func evictAutomatic(atLeast bytes: Int64) async {
        guard let current = file else { return }
        var freed: Int64 = 0
        for job in current.jobs.filter({ $0.automatic && !protectedReferences($0) && $0.phase == .available }).sorted(by: { $0.sequence < $1.sequence }) {
            guard freed < bytes else { break }
            freed += job.storedBytes
            await removeJob(job.id)
        }
    }

    // MARK: Failure handling (OFF12, OFF13)

    private func handle(_ error: Error, id: UUID) async {
        guard job(id) != nil else { return }
        if error is SimulatedCrash || halted { halted = true; return }
        if let stop = error as? StopForCause { settleStopped(id, hold: stop.cause); return }
        if error is CancellationError || Task.isCancelled || stopReasons[id] != nil {
            switch stopReasons[id] ?? .preempt {
            case .userPause: settleStopped(id, hold: .userPaused)
            case .hold(let cause): settleStopped(id, hold: cause)
            case .userCancel: break      // the remover deletes the job
            case .preempt, .quit, .unbind: settleStopped(id, hold: nil)
            }
            persist(); return
        }
        switch error {
        case let failure as SourceFailure:
            switch failure {
            case .urlExpired, .transient: retryLater(id, after: (failure == .urlExpired) ? nil : transientDelay(failure))
            case .unavailable: fail(id, .sourceUnavailable)
            case .permissionDenied: fail(id, .permissionDenied)
            case .unauthorized: settleStopped(id, hold: .accountUnavailable)
            }
        case let recovery as OfflineRecovery:
            switch recovery {
            case .storageFull: settleStopped(id, hold: .diskFull)
            case .missingKey, .reconnect: fail(id, .missingKey)
            case .renewRights, .staleGrant, .clockChanged: await refreshAfterExpiredPermission(id)
            case .storageUnavailable: retryLater(id, after: nil)
            default: restartCorrupt(id)
            }
        case let validation as ValidationFailure:
            switch validation {
            case .incomplete: mutate(id) { $0.completed.removeAll() }; retryLater(id, after: nil)
            case .corrupt: restartCorrupt(id)
            case .storedCopyCorrupt(let underlying):
                if let domain = underlying as? DomainError, domain == .unauthorized { fail(id, .missingKey) } else { restartCorrupt(id) }
            }
        case let domain as DomainError:
            switch domain {
            case .unauthorized: fail(id, .missingKey)
            case .expiredMedia: await refreshAfterExpiredPermission(id)
            case .malformedResponse: restartCorrupt(id)
            case .offline: settleStopped(id, hold: .offline)
            case .staleContext: settleStopped(id, hold: nil)
            case .forbidden: fail(id, .permissionDenied)
            default: retryLater(id, after: nil)
            }
        default:
            retryLater(id, after: nil)
        }
        persist()
    }
    private func transientDelay(_ failure: SourceFailure) -> TimeInterval? { if case .transient(let after) = failure { return after }; return nil }
    private func settleStopped(_ id: UUID, hold cause: DownloadPauseCause?) {
        mutate(id) { job in
            if let cause { job.phase = .paused; job.pause = cause } else { job.phase = .queued; job.pause = nil }
        }
        persist()
    }
    private func fail(_ id: UUID, _ failure: DownloadFailure) {
        mutate(id) { var j = $0; self.removeStaging(&j); j.phase = .failed; j.failure = failure; j.pause = nil; j.nextAttemptAt = nil; $0 = j }
        persist()
    }
    /// OFF13: bounded exponential backoff with jitter. Gives up with an explicit failure the person can retry.
    private func retryLater(_ id: UUID, after serverDelay: TimeInterval?) {
        guard let job = job(id) else { return }
        let attempt = job.attempts + 1
        if configuration.retry.exhausted(attempt: attempt) { fail(id, .retriesExhausted); return }
        let delay = max(serverDelay ?? 0, configuration.retry.delay(attempt: attempt, unit: random()))
        mutate(id) { $0.phase = .queued; $0.attempts = attempt; $0.nextAttemptAt = wall.now().addingTimeInterval(delay); $0.pause = nil }
        persist()
    }
    /// Corrupt bytes: the partial and any stored copy are discarded and the variant restarts once, then it fails loudly.
    private func restartCorrupt(_ id: UUID) {
        guard let job = job(id) else { return }
        let restarts = job.corruptRestarts + 1
        mutate(id) { var j = $0; self.removeStaging(&j); j.completed.removeAll(); j.corruptRestarts = restarts; j.contentSHA256 = nil; $0 = j }
        if restarts > configuration.maxCorruptRestarts {
            if let variant = job.variant, let context { Task { try? await self.sink.delete(variant: variant, context: context) } }
            fail(id, .corruptBytes)
        } else {
            mutate(id) { $0.phase = .queued; $0.nextAttemptAt = nil }
        }
        persist()
    }
    private func refreshAfterExpiredPermission(_ id: UUID) async {
        let count = (refreshes[id] ?? 0) + 1; refreshes[id] = count
        if count > configuration.maxURLRefreshes { fail(id, .permissionDenied) } else { mutate(id) { $0.phase = .queued; $0.nextAttemptAt = nil } }
        persist()
    }

    // MARK: Entitlement and renewal (OFF08)

    public func renewalSweep() async {
        guard let current = file else { return }
        let now = wall.now()
        for job in current.jobs where job.phase == .available || job.phase == .expired {
            if let expires = job.grantExpires, now >= expires {
                await renew(id: job.id, force: false)
            } else if let renewAfter = job.renewAfter, now >= renewAfter {
                await renew(id: job.id, force: false)
            }
        }
    }
    private func renew(id: UUID, force: Bool) async {
        guard let context, let job = job(id), let variant = job.variant, let source = sources[job.origin] else { return }
        let previous = job.phase
        mutate(id) { $0.phase = .renewing }; persist(); publish()
        do {
            let item = SourceItem(media: try ServiceID(job.media), location: job.location)
            let descriptor = try await source.describe(item: item, context: context)
            // Renewal can only extend the SAME bytes. A changed variant means the copy no longer matches its source.
            guard descriptor.variant == variant else { throw SourceFailure.permissionDenied }
            let permission = try await source.renew(item: item, descriptor: descriptor, context: context)
            try await sink.updateGrant(variant: variant, grant: permission.grant, context: context)
            mutate(id) { $0.phase = .available; $0.grantValidatedAt = permission.validatedAt; $0.grantExpires = permission.expires; $0.renewAfter = permission.renewAfter; $0.failure = nil }
        } catch let failure as SourceFailure {
            // The source refuses (or no longer has the item): the retained copy is expired once its own grant lapses.
            let lapsed = job.grantExpires.map { wall.now() >= $0 } ?? true
            mutate(id) { $0.phase = (failure == .permissionDenied || lapsed) ? .expired : previous }
        } catch {
            let lapsed = job.grantExpires.map { wall.now() >= $0 } ?? true
            mutate(id) { $0.phase = lapsed ? .expired : .available }
        }
        persist(); publish()
    }
    /// Cheap integrity audit of retained copies (index and authority only); a damaged or keyless copy is reported, not hidden.
    public func auditRetained() async {
        guard let context, let current = file else { return }
        for job in current.jobs where job.phase == .available {
            guard let variant = job.variant else { continue }
            do { _ = try await sink.retainedLength(variant: variant, context: context) }
            catch let error as OfflineRecovery {
                switch error {
                case .missingKey, .reconnect: mutate(job.id) { $0.phase = .failed; $0.failure = .missingKey }
                case .renewRights, .staleGrant, .clockChanged: mutate(job.id) { $0.phase = .expired }
                default: mutate(job.id) { $0.phase = .failed; $0.failure = .corruptBytes }
                }
            } catch let domain as DomainError {
                switch domain {
                case .unauthorized: mutate(job.id) { $0.phase = .failed; $0.failure = .missingKey }
                case .expiredMedia: mutate(job.id) { $0.phase = .expired }
                default: mutate(job.id) { $0.phase = .failed; $0.failure = .corruptBytes }
                }
            } catch {}
        }
        persist(); publish()
    }

    // MARK: Safe quit (OFF13)

    /// Stops all work, checkpoints, and leaves nothing running. In-flight transfers resume from their recorded ranges on next launch.
    public func quit() async {
        quitting = true
        cancelWake?(); cancelWake = nil
        for cancel in cancelObservers { cancel() }; cancelObservers.removeAll()
        for id in Array(running.keys) { stopReasons[id] = .quit }
        let tasks = Array(running.values)
        for task in tasks { task.cancel() }
        // Bounded: a source that ignores cancellation cannot hold the quit; halting stops its writes and the ledger is final.
        let deadline = ContinuousClock.now + configuration.quitTimeout
        while !running.isEmpty, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        if !running.isEmpty { halted = true }
        guard var current = file else { return }
        for index in current.jobs.indices where [.resolving, .downloading, .validating].contains(current.jobs[index].phase) { current.jobs[index].phase = .queued }
        file = current
        let wasHalted = halted; halted = false
        persist()
        halted = wasHalted
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }
    public var isQuiescent: Bool { running.isEmpty }

    // MARK: Persistence and presentation

    private func usageSummary() -> UsageSummary {
        var usage = UsageSummary(); usage.unlistedBytes = unlistedBytes
        for job in file?.jobs ?? [] where [.available, .renewing, .expired].contains(job.phase) {
            usage.storedBytes += job.storedBytes
            if protectedReferences(job) { usage.protectedBytes += job.storedBytes } else if job.automatic { usage.automaticBytes += job.storedBytes }
        }
        return usage
    }
    private func persist() {
        guard !halted, let current = file, let account = context?.account else { return }
        cachedUsage = nil
        do { try ledger.save(current, account: account, usage: usageSummary()) } catch { /* the previous durable ledger stays authoritative */ }
    }
    public func updates() -> AsyncStream<DownloadsSnapshot> {
        let id = UUID()
        let stream = AsyncStream<DownloadsSnapshot>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.dropSubscriber(id) } }
        }
        subscribers[id]?.yield(buildSnapshot())
        return stream
    }
    private func dropSubscriber(_ id: UUID) { subscribers[id] = nil }
    /// Byte progress is shown at most four times a second; state changes always publish immediately.
    private func publishProgress() {
        guard ContinuousClock.now - lastPublished >= .milliseconds(250) else { return }
        publish()
    }
    private func publish() {
        lastPublished = ContinuousClock.now
        guard !subscribers.isEmpty else { return }
        let value = buildSnapshot()
        for continuation in subscribers.values { continuation.yield(value) }
    }
    public func snapshot() -> DownloadsSnapshot { buildSnapshot() }

    private func actions(for job: JobRecord) -> [DownloadAction] {
        switch job.phase {
        case .queued, .resolving, .downloading: return [.pause, .cancel]
        case .paused:
            var result: [DownloadAction] = []
            if let cause = job.pause {
                if cause == .userPaused || cause == .diskFull || cause == .accountUnavailable { result.append(.resume) }
                if (cause == .constrainedNetwork || cause == .expensiveNetwork), !job.automatic { result.append(.downloadOnThisNetwork) }
            }
            return result + [.cancel]
        case .validating: return []
        case .available:
            var result: [DownloadAction] = playHandler != nil && [.owned, .localFile].contains(job.origin) ? [.play] : []
            let others = job.references.subtracting([Self.manualReference])
            if job.pinned, !others.isEmpty { result.append(.unpin) } else if !job.pinned { result.append(.pin) }
            return result + [.remove]
        case .renewing: return []
        case .expired: return [.renew, .downloadAgain, .remove]
        case .failed:
            switch job.failure {
            case .corruptBytes, .missingKey: return [.downloadAgain, .remove]
            case .accountRevoked: return [.remove]
            default: return [.retry, .remove]
            }
        }
    }
    private func buildSnapshot() -> DownloadsSnapshot {
        let jobs = (file?.jobs ?? [])
        let rows = jobs.sorted { ($0.phase == .available ? 1 : 0, -Int64($0.sequence)) < ($1.phase == .available ? 1 : 0, -Int64($1.sequence)) }.map { job -> DownloadRowModel in
            let completed = [.available, .renewing, .expired].contains(job.phase) ? (job.length ?? 0) : job.completed.coveredBytes
            return DownloadRowModel(id: job.id, media: (try? ServiceID(job.media)) ?? (try! ServiceID("unknown")), title: job.title, subtitle: job.subtitle, origin: job.origin, phase: job.phase,
                                    progress: DownloadProgress(completedBytes: completed, totalBytes: job.length), pauseCause: job.pause, failure: job.failure, pinned: job.pinned, automatic: job.automatic,
                                    referenceCount: job.references.count, storedBytes: job.storedBytes, retryAt: job.phase == .queued ? job.nextAttemptAt : nil, expiresAt: job.grantExpires, actions: actions(for: job))
        }
        let activeJobs = jobs.filter { [.queued, .resolving, .downloading, .paused, .validating].contains($0.phase) }
        let unknown = activeJobs.contains { $0.length == nil }
        let aggregate: DownloadProgress? = activeJobs.isEmpty ? nil : DownloadProgress(completedBytes: activeJobs.reduce(0) { $0 + $1.completed.coveredBytes }, totalBytes: unknown ? nil : activeJobs.reduce(0) { $0 + ($1.length ?? 0) })
        let capacity = volume.capacity(at: ledger.rootURL)
        let usage = currentUsage()
        let storage = DownloadStorageSummary(usedBytes: usage.storedBytes, budgetBytes: settings.budget, reserveBytes: DownloadPolicy.reserve(volumeTotal: capacity.total), volumeAvailableBytes: capacity.available,
                                             pinnedBytes: usage.protectedBytes, automaticBytes: usage.automaticBytes, automaticCapBytes: DownloadPolicy.automaticCap(budget: settings.budget))
        var choices: [DownloadStorageChoice] = []
        let causes = Set(jobs.compactMap(\.pause))
        if causes.contains(.storageBudgetFull) || causes.contains(.smartCapReached) { choices += [.raiseBudget, .removeDownloads]; if usage.automaticBytes > 0 { choices.append(.removeAutomaticDownloads) } }
        if causes.contains(.volumeReserve) || causes.contains(.diskFull) { choices += [.freeDiskSpace, .removeDownloads] }
        let collections = (file?.collections ?? []).map { collection in
            DownloadCollectionSummary(id: (try? ServiceID(collection.id)) ?? (try! ServiceID("unknown")), title: collection.title, memberCount: collection.members.count,
                                      availableCount: collection.members.filter { member in jobs.contains { $0.media == member && $0.phase == .available } }.count)
        }
        return DownloadsSnapshot(rows: rows, collections: collections, aggregate: aggregate, activeCount: running.count, waitingCount: jobs.filter { $0.phase == .queued || $0.phase == .paused }.count, storage: storage, storageChoices: choices.reduce(into: [DownloadStorageChoice]()) { if !$0.contains($1) { $0.append($1) } },
                                 smartDownloadsEnabled: settings.smartDownloads, concurrencyLimit: DownloadPolicy.concurrencyLimit(lowPowerMode: lowPower), lowPowerMode: lowPower,
                                 networkConstrained: network.isConstrained, networkExpensive: network.isExpensive, networkAvailable: network.isAvailable, hasAccount: context != nil, smartDownloadsAvailable: suggestionsAvailable, unlistedBytes: unlistedBytes)
    }
}

private extension PrivateDirectory {
    func identity(_ name: String) -> String? {
        var st = stat()
        return fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 ? "\(st.st_dev):\(st.st_ino)" : nil
    }
    func fileSize(_ name: String) -> Int64? {
        var st = stat()
        return fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 ? Int64(st.st_size) : nil
    }
}

/// What the native player needs to play one kept item from the encrypted store.
public struct PlayableDownload: Sendable {
    public let media: ServiceID
    /// The store's identifier for the retained object (not always the media id).
    public let variant: String
    public let title: String
    public let subtitle: String?
    public let contentType: String?
    public let seekable: Bool
    public let context: RequestContext
}
