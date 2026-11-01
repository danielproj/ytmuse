import Foundation

// P17-WEB (PLAY17). The sleep timer of the hidden YouTube Music player.
//
// What it does at expiry: it lowers the page `<video>` element's own volume over 5 seconds (`WebMusicCommand.fadeVolume`, a fixed script run through
// the same bridge and the same document/load generation as every other command), pauses through the existing `pause()` command path, and puts the
// element's volume back so the next Play starts at the level the person had. It never seeks, skips or changes the queue.
//
// The advertising rule (`Docs/Playback-Addendum.md`): an advertisement is never faded. A fade of an ad is a mute in effect. The rule is enforced twice:
// natively (the snapshot says an ad shows: the fade is not started, or is abandoned and the level put back) and in the page, at the instant of each
// step (the script answers `ad` and leaves the level alone). While an ad shows at expiry the timer pauses, honestly, and does nothing else.
//
// End of track / End of episode pauses at the item boundary the PAGE reports: the page's own duration and position, extrapolated at the element's
// real speed between reports, and its `ended` event. A page that reports no duration (a live stream, an item not yet known) has no boundary, and
// nothing is invented for it.

/// The timer's clocks. The wall clock decides the deadline (time asleep counts: a timer that ran out while the Mac slept has run out); the monotonic
/// clock paces the fade, so a changed wall clock can neither stretch nor skip it. A test supplies manual ones.
@MainActor public protocol SleepTimerTiming: AnyObject {
    func wall() -> Date
    /// Seconds on a clock that only moves forward.
    func monotonic() -> Double
    /// Returns after about `seconds`, or at once when the calling task is cancelled.
    func wait(_ seconds: Double) async
    /// False for a test that drives the evaluation itself with `sleepTimerTick()`.
    var runsLoop: Bool { get }
}
public extension SleepTimerTiming { var runsLoop: Bool { true } }

@MainActor public final class SystemSleepTimerTiming: SleepTimerTiming {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant
    public init() { origin = clock.now }
    public func wall() -> Date { Date() }
    public func monotonic() -> Double { let d = clock.now - origin; return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
    public func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(max(0, seconds))) }
}

public enum SleepTimerFade {
    /// PLAY17: the fade lasts 5 seconds.
    public static let duration = 5.0
    /// How often a step is sent while fading.
    public static let step = 0.25
    /// End of item: the pause is sent this many seconds (of media, scaled by the element's speed) before the reported end, so it lands at the boundary
    /// and not in the first moments of the next item. The fade has reached silence by then.
    public static let endMargin = 0.3
    /// The longest custom length: a day.
    public static let longest = 86_400.0
}

/// What the timer is doing, for every surface. Changes only when the timer is set, starts to fade or ends; the remaining time is derived from `deadline`.
public struct WebSleepTimerState: Sendable, Equatable {
    public let timer: SleepTimer
    /// The wall instant the timer runs out; nil for End of item (the page decides).
    public let deadline: Date?
    public let fading: Bool
    public var endOfItem: Bool { timer == .endOfItem }
    public func remaining(at now: Date) -> Double? { deadline.map { max(0, $0.timeIntervalSince(now)) } }
}

public enum SleepTimerRefusal: Sendable, Equatable {
    case nothingPlaying, invalidLength, noEnd
    public var message: String {
        switch self {
        case .nothingPlaying: String(localized: "Nothing is playing, so there is no timer to set.")
        case .invalidLength: String(localized: "Choose a length between a second and 24 hours.")
        case .noEnd: String(localized: "A live stream has no end, so the timer can only count minutes.")
        }
    }
}
public enum SleepTimerOutcome: Sendable, Equatable { case set, cleared, refused(SleepTimerRefusal) }

/// The armed timer and, while it fades, the fade. Internal to the player.
struct WebSleepPlan {
    struct Fade {
        var start: Double
        var load: UInt64
        var document: UInt64
        var revision: UInt64
        var videoID: String?
        /// The element's level has been lowered by this fade and must be put back.
        var lowered = false
    }
    let token: UInt64
    let timer: SleepTimer
    let deadline: Date?
    var fade: Fade?
}

extension WebMusicPlayer {
    // MARK: Setting and clearing

    /// Arms (or, with nil, cancels) the player's sleep timer. A running timer is replaced; a fade that had lowered the volume puts it back first.
    @discardableResult public func setSleepTimer(_ timer: SleepTimer?) async -> SleepTimerOutcome {
        guard !isClosed else { return .refused(.nothingPlaying) }
        guard let timer else {
            await cancelSleepTimerAndRestore()
            sleepExpiredRevision = nil
            return .cleared
        }
        guard snapshot.phase != .idle, !snapshot.isFailed else { return .refused(.nothingPlaying) }
        if let seconds = timer.seconds { guard seconds.isFinite, seconds > 0, seconds <= SleepTimerFade.longest else { return .refused(.invalidLength) } }
        if timer == .endOfItem, snapshot.isLive { return .refused(.noEnd) }
        await cancelSleepTimerAndRestore()
        guard !isClosed else { return .refused(.nothingPlaying) }
        sleepTokens &+= 1
        let plan = WebSleepPlan(token: sleepTokens, timer: timer, deadline: timer.seconds.map { sleepTiming.wall().addingTimeInterval($0) }, fade: nil)
        sleepPlan = plan; sleepExpiredRevision = nil; sleepRepauses = 0
        publishSleepState()
        startSleepLoop(plan.token)
        return .set
    }

    /// Account switch, sign-out, removal or quit: the timer ends with the player. Nothing is sent to the page (it is being dropped).
    func cancelSleepTimerForTeardown() {
        sleepTask?.cancel(); sleepTask = nil
        sleepPlan = nil; sleepExpiredRevision = nil
        if sleepTimerState != nil { sleepTimerState = nil }
    }

    private func cancelSleepTimerAndRestore() async {
        sleepTask?.cancel(); sleepTask = nil
        let plan = sleepPlan
        sleepPlan = nil
        publishSleepState()
        if let fade = plan?.fade, fade.lowered { await restoreVolume(fade) }
    }

    /// Seconds until a length timer runs out, on the timer's own clock; nil without one or for End of item.
    public func sleepTimerRemaining() -> Double? { sleepTimerState?.remaining(at: sleepTiming.wall()) }

    /// Whether the timer has run out: its wall deadline passed, it is fading, or it ended the playback and no command has come since. A wake never
    /// resumes after this, however the timer's own pause and the wake's check are ordered.
    public func sleepTimerHasExpired() -> Bool {
        if let plan = sleepPlan {
            if plan.fade != nil { return true }
            if let deadline = plan.deadline, sleepTiming.wall() >= deadline { return true }
        }
        return sleepExpiredRevision == commandRevision
    }

    // MARK: The loop

    private func startSleepLoop(_ token: UInt64) {
        sleepTask?.cancel(); sleepTask = nil
        guard sleepTiming.runsLoop else { return }
        sleepTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.sleepPlan?.token == token {
                await self.sleepTimerTick()
                guard !Task.isCancelled, self.sleepPlan?.token == token else { break }
                await self.sleepTiming.wait(self.nextSleepInterval())
            }
        }
    }
    private func nextSleepInterval() -> Double {
        guard let plan = sleepPlan else { return 1 }
        if plan.fade != nil || plan.timer == .endOfItem { return SleepTimerFade.step }
        guard let deadline = plan.deadline else { return 1 }
        return min(1, max(0.05, deadline.timeIntervalSince(sleepTiming.wall())))
    }

    /// One evaluation of the timer. Serialised: a call that arrives while one is awaiting the page asks it to look again when it is done.
    public func sleepTimerTick() async {
        if sleepTicking { sleepRecheck = true; return }
        sleepTicking = true; defer { sleepTicking = false }
        repeat {
            sleepRecheck = false
            await evaluateSleepTimer()
        } while sleepRecheck && sleepPlan != nil
    }
    /// A report that matters to the timer arrived (the item ended, or an advertisement appeared while fading): look now, not at the next step.
    func sleepTimerNeedsLookNow() {
        guard sleepPlan != nil else { return }
        Task { @MainActor in await self.sleepTimerTick() }
    }
    /// Remembers the newest position the page reported and when, so the end of the item can be tracked between reports.
    func noteSleepReport() {
        guard sleepPlan?.timer == .endOfItem else { return }
        sleepReport = (position: transport.snapshot.position, at: sleepTiming.monotonic(), videoID: transport.snapshot.videoID)
    }

    private func evaluateSleepTimer() async {
        guard let plan = sleepPlan else { return }
        guard !isClosed else { cancelSleepTimerForTeardown(); return }
        guard let page = livePage else {
            // Nothing is loaded behind the timer (a restored item, or the page was dropped): a timer that has run out has nothing to pause.
            if let deadline = plan.deadline, sleepTiming.wall() >= deadline { endSleepTimer(expired: true) }
            return
        }
        if let fade = plan.fade { await continueFade(plan, fade, page); return }
        switch plan.timer {
        case .minutes, .custom:
            guard let deadline = plan.deadline, sleepTiming.wall() >= deadline else { return }
            await expire(plan, page)
        case .endOfItem:
            await evaluateEndOfItem(plan, page)
        }
    }

    // MARK: Expiry after a length

    private func expire(_ plan: WebSleepPlan, _ page: any WebMusicPage) async {
        let snap = transport.snapshot
        if !snap.intent {
            // Nobody wants sound right now (a person's pause, a route loss, or the hold for a system sleep, whose page may not have reported it yet):
            // there is nothing to fade or pause, and the timer has done its job.
            endSleepTimer(expired: true)
        } else if snap.isAd {
            // Never faded. Pause only, so the timer still does what it was asked to; the level was never touched.
            await finishByPausing(plan, lowered: nil)
        } else if snap.phase == .playing {
            beginFade(plan)
            if let current = sleepPlan, let fade = current.fade { await continueFade(current, fade, page) }
        } else if isAudibleOrWanted {
            // Loading or buffering toward sound: there is nothing to fade yet; the pause keeps it from starting.
            await finishByPausing(plan, lowered: nil)
        } else {
            // Already paused (a person's pause, a route loss, or a hold for sleep): nothing to do but end the timer.
            endSleepTimer(expired: true)
        }
    }

    private func beginFade(_ plan: WebSleepPlan) {
        var next = plan
        next.fade = .init(start: sleepTiming.monotonic(), load: transport.load, document: committedDocumentForSleep, revision: commandRevision, videoID: transport.snapshot.videoID)
        sleepPlan = next
        publishSleepState()
    }

    // MARK: Fading

    private func continueFade(_ plan: WebSleepPlan, _ fade: WebSleepPlan.Fade, _ page: any WebMusicPage) async {
        // A new request or a replaced document is not this fade's: nothing is sent to a document that was never faded.
        if transport.load != fade.load || committedDocumentForSleep != fade.document {
            await endFadeWithoutPause(plan, fade, restore: committedDocumentForSleep == fade.document, keepArmed: false)
            return
        }
        // A person acted while it faded (pause, play, seek, next).
        if commandRevision != fade.revision {
            await endFadeWithoutPause(plan, fade, restore: true, keepArmed: plan.timer == .endOfItem)
            return
        }
        let snap = transport.snapshot
        let now = sleepTiming.monotonic()
        if snap.isAd { await finishByPausing(plan, lowered: fade); return }

        let factor: Double
        var conclude = false
        if plan.timer == .endOfItem {
            let rate = max(0.25, confirmedRate)
            let window = SleepTimerFade.duration * rate, margin = SleepTimerFade.endMargin * rate
            if snap.videoID != fade.videoID {
                // The page moved on without us having paused at the boundary (late report, or YouTube was quicker): pause now, quietly.
                await finishByPausing(plan, lowered: fade); return
            }
            guard let remaining = estimatedRemaining(now: now) else { await endFadeWithoutPause(plan, fade, restore: true, keepArmed: true); return }
            if snap.phase == .ended || remaining <= margin { factor = 0; conclude = true }
            else if remaining > window + 1 { await endFadeWithoutPause(plan, fade, restore: true, keepArmed: true); return }   // sought back
            else { factor = max(0, min(1, (remaining - margin) / max(0.001, window - margin))) }
        } else {
            let elapsed = now - fade.start
            factor = max(0, 1 - elapsed / SleepTimerFade.duration)
            conclude = elapsed >= SleepTimerFade.duration
        }

        var lowered = fade.lowered
        if factor < 1 || lowered {
            let reply = await run(.fadeVolume(factor), on: page)
            guard let current = sleepPlan, current.token == plan.token, !isClosed else { return }
            switch reply {
            case .ok:
                if factor < 1 { lowered = true }
            case .ad:
                // The page saw an advertisement before we did: it left (or put back) the level. Pause only.
                await finishByPausing(current, lowered: nil); return
            default:
                // The page cannot be faded (no media, no volume control, not answering): pause without a fade rather than pretend.
                await finishByPausing(current, lowered: lowered ? fade : nil); return
            }
            var updated = current
            updated.fade?.lowered = lowered
            sleepPlan = updated
        }
        if conclude, let current = sleepPlan, let fade = current.fade { await finishByPausing(current, lowered: fade.lowered ? fade : nil) }
    }

    /// The fade stops without the timer pausing anything: a person took over, the item changed under it, or the request was replaced.
    private func endFadeWithoutPause(_ plan: WebSleepPlan, _ fade: WebSleepPlan.Fade, restore: Bool, keepArmed: Bool) async {
        if restore, fade.lowered { await restoreVolume(fade) }
        guard let current = sleepPlan, current.token == plan.token else { return }
        if keepArmed {
            var updated = current; updated.fade = nil; sleepPlan = updated
            publishSleepState()
        } else {
            sleepTask?.cancel(); sleepTask = nil
            sleepPlan = nil; publishSleepState()
        }
    }

    /// Pauses through the existing command path, puts the level back if a fade lowered it, and ends the timer.
    private func finishByPausing(_ plan: WebSleepPlan, lowered: WebSleepPlan.Fade?) async {
        var restored = false
        if let lowered, lowered.lowered, transport.snapshot.isAd { await restoreVolume(lowered); restored = true }   // an ad must hear the level it had
        guard sleepPlan?.token == plan.token, !isClosed else { return }
        await pause()
        guard sleepPlan?.token == plan.token, !isClosed else { return }
        if let lowered, lowered.lowered, !restored { await restoreVolume(lowered) }
        guard sleepPlan?.token == plan.token, !isClosed else { return }
        endSleepTimer(expired: true)
    }

    /// Puts the element's level back. Skipped when the document it was lowered in is gone (a new document starts at the page's own level).
    private func restoreVolume(_ fade: WebSleepPlan.Fade) async {
        guard let page = livePage, committedDocumentForSleep == fade.document else { return }
        _ = await run(.fadeVolume(1), on: page)
    }

    private func endSleepTimer(expired: Bool) {
        sleepTask?.cancel(); sleepTask = nil
        sleepPlan = nil
        if expired { sleepExpiredRevision = commandRevision; sleepRepauses = 0 }
        publishSleepState()
    }

    // MARK: End of item

    private func evaluateEndOfItem(_ plan: WebSleepPlan, _ page: any WebMusicPage) async {
        let snap = transport.snapshot
        // The boundary of an item is the page's: no duration, no boundary. An advertisement is not the item; its end is not this timer's.
        guard snap.intent, !snap.isAd, !snap.isLive, snap.duration > 0, snap.phase == .playing || snap.phase == .ended else { return }
        let rate = max(0.25, confirmedRate)
        let now = sleepTiming.monotonic()
        if snap.phase == .ended { await finishByPausing(plan, lowered: nil); return }
        guard let remaining = estimatedRemaining(now: now) else { return }
        if remaining <= SleepTimerFade.endMargin * rate { await finishByPausing(plan, lowered: nil); return }
        guard remaining <= SleepTimerFade.duration * rate else { return }
        beginFade(plan)
        if let current = sleepPlan, let fade = current.fade { await continueFade(current, fade, page) }
    }

    /// Media seconds left in the playing item: the page's duration less its last reported position carried forward at the element's speed.
    private func estimatedRemaining(now: Double) -> Double? {
        let snap = transport.snapshot
        guard snap.duration > 0 else { return nil }
        var position = snap.position
        if let report = sleepReport, report.videoID == snap.videoID, snap.phase == .playing {
            position = report.position + max(0, now - report.at) * max(0.25, confirmedRate)
        }
        return max(0, snap.duration - min(position, snap.duration))
    }

    // MARK: Publication

    func publishSleepState() {
        let next = sleepPlan.map { WebSleepTimerState(timer: $0.timer, deadline: $0.deadline, fading: $0.fade != nil) }
        if next != sleepTimerState { sleepTimerState = next }
    }

    // MARK: After the timer paused

    /// The page reports playing after the timer paused it (YouTube restarted by itself, or the report was in flight): paused again, a bounded number
    /// of times, until a person's command ends the timer's hold. The page must not resume by itself.
    func repauseAfterSleepTimerIfNeeded() {
        guard let recorded = sleepExpiredRevision, recorded == commandRevision, transport.snapshot.phase == .playing, !transport.snapshot.intent,
              sleepRepauses < 3, let page = livePage, !isClosed else { return }
        sleepRepauses += 1
        Task { _ = await self.run(.pause, on: page) }
    }
}
