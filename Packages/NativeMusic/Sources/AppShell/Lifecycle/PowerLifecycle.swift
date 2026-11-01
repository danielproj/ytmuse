import AppKit
import CoreAudio
import Foundation
import Observation
import OutputRoutes
import Playback

// W21 (WIN07, WIN08, WIN10, PLAY17). A Mac can be "away" in four different ways, and only one of them stops audio:
//   - the screen is locked        (com.apple.screenIsLocked / screenIsUnlocked)   audio keeps playing
//   - the display is asleep        (NSWorkspace.screensDidSleep / screensDidWake)   audio keeps playing
//   - the system is asleep         (NSWorkspace.willSleep / didWake)                playback is held, then resumed only if safe
// The first two stop decorative work (nothing is visible); only the third touches the transport.

enum PowerEvent: Sendable, Equatable { case screenLocked, screenUnlocked, displaySlept, displayWoke, systemWillSleep, systemDidWake }

/// Whether anything the person can see is being drawn: false while the screen is locked, the display sleeps or the system sleeps.
/// Every window's visibility reading includes it, so the transport, the status item and Now Playing stay live while artwork decoding,
/// colour work, lyric highlighting and animation stop (WIN10, MOTION04).
@MainActor @Observable final class ShellDisplayState {
    static let shared = ShellDisplayState()
    private(set) var screenLocked = false
    private(set) var displaySleeping = false
    private(set) var systemSleeping = false
    var active: Bool { !screenLocked && !displaySleeping && !systemSleeping }
    /// Posted (on the main thread) when `active` changes, so window observers re-read their visibility without polling.
    static let didChange = Notification.Name("local.native-music.shell-display-state-changed")
    init() {}
    func apply(_ event: PowerEvent) {
        let before = active
        switch event {
        case .screenLocked: screenLocked = true
        case .screenUnlocked: screenLocked = false
        case .displaySlept: displaySleeping = true
        case .displayWoke: displaySleeping = false
        case .systemWillSleep: systemSleeping = true
        case .systemDidWake: systemSleeping = false; displaySleeping = false
        }
        if active != before { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }
}

/// Everything that decides whether a wake may resume playback, as plain facts.
struct WakeFacts: Equatable, Sendable {
    /// Playback was wanted and audible when the system went to sleep.
    var held: Bool
    /// The person allows resuming after a wake (Settings; default on).
    var preference: Bool
    /// The route that was playing at the sleep is the default output again (same device, not merely "some output").
    var routeConfirmed: Bool
    /// A different output is the default now (the headphones or Bluetooth device went away): never resume on it.
    var routeChanged = false
    /// A person (or a media key) paused, played, skipped or sought since the hold: their last word stands.
    var personChangedPlayback: Bool
    /// A sleep timer ran out while the Mac slept (PLAY17).
    var timerExpired: Bool
    /// The account or the player the hold belonged to is gone (switch, sign-out, removal, quit).
    var ownerChanged: Bool
    /// W22 (ROUTE03): a route-loss pause is pending (headphones, a device or a receiver went away). It wins over every other reason, and
    /// only a person's explicit Play ends it; a reconnect or a wake never does.
    var routeLost = false
}
enum WakeStay: Sendable, Equatable { case nothingWasPlaying, routeLost, ownerChanged, personChangedPlayback, timerExpired, preferenceOff, routeNotConfirmed, routeChanged }
enum WakeDecision: Sendable, Equatable { case resume, stayPaused(WakeStay) }
enum SleepWakePolicy {
    /// Resume only an interrupted, still-wanted session once a safe route is confirmed. Every other case stays paused; the order says which reason wins.
    static func decide(_ facts: WakeFacts) -> WakeDecision {
        guard facts.held else { return .stayPaused(.nothingWasPlaying) }
        guard !facts.routeLost else { return .stayPaused(.routeLost) }
        guard !facts.ownerChanged else { return .stayPaused(.ownerChanged) }
        guard !facts.personChangedPlayback else { return .stayPaused(.personChangedPlayback) }
        guard !facts.timerExpired else { return .stayPaused(.timerExpired) }
        guard facts.preference else { return .stayPaused(.preferenceOff) }
        guard facts.routeConfirmed else { return .stayPaused(facts.routeChanged ? .routeChanged : .routeNotConfirmed) }
        return .resume
    }
}

/// What the power lifecycle needs of the playback owner. One implementation (`PlaybackModel`) serves both engines; tests supply a recorder.
@MainActor protocol PowerTransporting: AnyObject {
    /// The system is about to sleep: checkpoint, pause what a person wanted playing (without recording a person's pause). True when something was held.
    func holdForSleep() async -> Bool
    /// The facts about the held session that only the playback owner knows (route and preference are the coordinator's).
    func holdFacts() async -> (personChanged: Bool, timerExpired: Bool, ownerChanged: Bool)
    /// W22: a route-loss pause is pending, so a wake must not resume (read at the wake, after the hold).
    func routeLossPending() -> Bool
    /// W22: the route the held engine's sound leaves through (nil: not known; the wake then compares the system default, as W21 did) and whether it is a
    /// device the engine was pointed at rather than the system default. One route model for the wake check and the route-loss pause. A protocol REQUIREMENT
    /// (not only an extension method), so a conforming owner's own answer is the one called.
    func audibleRoute() -> (identity: RouteIdentity?, pinned: Bool)
    /// Resume the held session (`resume`) or let it go. Returns whether play was sent.
    func finishWake(resume: Bool) async -> Bool
    /// After a wake that did not resume: make sure nothing is audible that no person asked for.
    func silenceAfterWake() async
}
extension PowerTransporting {
    func routeLossPending() -> Bool { false }
    /// W22: the route the held engine's sound leaves through (nil: not known; the wake then compares the system default, as W21 did) and whether it is a
    /// device the engine was pointed at rather than the system default. One route model for the wake check and the route-loss pause.
    func audibleRoute() -> (identity: RouteIdentity?, pinned: Bool) { (nil, false) }
}

// `RouteIdentity` (the default output's UID, transport and built-in data source) lives in OutputRoutes since W22: one route model for the wake check,
// the route-loss pause and the picker.
enum RouteOutcome: Equatable, Sendable {
    /// The recorded route is the default output again.
    case same
    /// A live but DIFFERENT output is the default (for example the built-in speakers after headphones left).
    case changed
    /// No output at all, or nothing was recorded to compare with.
    case absent
}
/// WIN08 / addendum 6: a wake resumes only on the route that was playing. The identity is recorded at the sleep and compared at the wake.
protocol RouteConfirming: Sendable {
    func identity() -> RouteIdentity?
    /// Waits (bounded, polled, no tight loop; a Bluetooth route may take a moment after a wake) for `recorded` to be the default output.
    /// A different live output does not end the wait early: the device may still come back inside the timeout.
    func wait(for recorded: RouteIdentity?, within timeout: Duration) async -> RouteOutcome
    /// Like `wait(for:)`, for a device an engine was pointed at (not the system default): the device itself must be a live output again, with the same identity.
    func wait(forDevice recorded: RouteIdentity?, within timeout: Duration) async -> RouteOutcome
}
extension RouteConfirming {
    func wait(forDevice recorded: RouteIdentity?, within timeout: Duration) async -> RouteOutcome { await wait(for: recorded, within: timeout) }
}
struct SystemOutputRoute: RouteConfirming {
    /// The reader and the pause between polls are seams, so the polling (a device that reconnects a moment after the wake) is testable without hardware.
    var read: @Sendable () -> RouteIdentity? = { SystemOutputRoute.defaultOutput() }
    /// The live identity of one output device by UID (nil: not a live output). A seam like `read`.
    var readDevice: @Sendable (String) -> RouteIdentity? = { uid in CoreAudioOutputDirectory().snapshot().device(uid: uid)?.identity }
    var pause: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    var interval: Duration = .milliseconds(250)
    func identity() -> RouteIdentity? { read() }
    func wait(for recorded: RouteIdentity?, within timeout: Duration) async -> RouteOutcome {
        guard let recorded else { return .absent }
        let deadline = ContinuousClock.now + timeout
        while true {
            let now = read()
            if now == recorded { return .same }
            guard ContinuousClock.now < deadline else { return now == nil ? .absent : .changed }
            await pause(interval)
        }
    }
    func wait(forDevice recorded: RouteIdentity?, within timeout: Duration) async -> RouteOutcome {
        guard let recorded else { return .absent }
        let deadline = ContinuousClock.now + timeout
        while true {
            let now = readDevice(recorded.uid)
            if now == recorded { return .same }
            guard ContinuousClock.now < deadline else { return now == nil ? .absent : .changed }
            await pause(interval)
        }
    }
    /// The default output device when it exists and is alive.
    static func defaultOutput() -> RouteIdentity? { CoreAudioOutputDirectory.defaultOutputIdentity() }
}

/// Applies power events to the display state and the transport. Never prevents sleep: there is no power assertion anywhere in this type, and
/// the only activity the app holds is the hidden player's App Nap activity while it plays (C1).
@MainActor final class PowerLifecycleCoordinator {
    private let transport: any PowerTransporting
    private let route: any RouteConfirming
    private let display: ShellDisplayState
    private let resumePreference: @MainActor () -> Bool
    private let routeTimeout: Duration
    private let silenceCheck: Duration
    private let sleep: @Sendable (Duration) async -> Void
    private var held = false
    /// The default output when the system went to sleep: the only route a wake may resume on.
    private var recordedRoute: RouteIdentity?
    private var recordedPinned = false
    private var silence: Task<Void, Never>?
    /// What happened, for the tests and the diagnostics line.
    private(set) var lastDecision: WakeDecision?
    private(set) var holds = 0
    init(transport: any PowerTransporting, route: any RouteConfirming = SystemOutputRoute(), display: ShellDisplayState = .shared,
         resumePreference: @escaping @MainActor () -> Bool = { true }, routeTimeout: Duration = .seconds(5), silenceCheck: Duration = .seconds(3),
         sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.transport = transport; self.route = route; self.display = display; self.resumePreference = resumePreference
        self.routeTimeout = routeTimeout; self.silenceCheck = silenceCheck; self.sleep = sleep
    }
    func handle(_ event: PowerEvent) async {
        display.apply(event)
        switch event {
        case .screenLocked, .screenUnlocked, .displaySlept, .displayWoke:
            // Audio continues through a lock and through display sleep. Nothing here touches the transport.
            break
        case .systemWillSleep:
            silence?.cancel()
            let audible = transport.audibleRoute()
            recordedRoute = audible.identity ?? route.identity(); recordedPinned = audible.pinned
            let wasHeld = await transport.holdForSleep()
            if wasHeld { held = true; holds += 1 }
        case .systemDidWake:
            let heldBefore = held; held = false
            var facts = WakeFacts(held: heldBefore, preference: resumePreference(), routeConfirmed: false, personChangedPlayback: false, timerExpired: false, ownerChanged: false)
            if heldBefore {
                let owner = await transport.holdFacts()
                facts.personChangedPlayback = owner.personChanged; facts.timerExpired = owner.timerExpired; facts.ownerChanged = owner.ownerChanged
                facts.routeLost = transport.routeLossPending()
                // The route is only worth waiting for when nothing else already decided against resuming.
                if !facts.personChangedPlayback, !facts.timerExpired, !facts.ownerChanged, !facts.routeLost, facts.preference {
                    let outcome = recordedPinned ? await route.wait(forDevice: recordedRoute, within: routeTimeout) : await route.wait(for: recordedRoute, within: routeTimeout)
                    facts.routeConfirmed = outcome == .same; facts.routeChanged = outcome == .changed
                }
            }
            let decision = SleepWakePolicy.decide(facts)
            lastDecision = decision
            let resumed = await transport.finishWake(resume: decision == .resume)
            if !resumed { await transport.silenceAfterWake(); scheduleSilenceCheck() }
        }
    }
    /// A page that was told to stay quiet is checked once more shortly after: it must not start by itself (no surprise audio).
    private func scheduleSilenceCheck() {
        silence?.cancel()
        silence = Task { [transport, sleep, silenceCheck] in
            await sleep(silenceCheck)
            guard !Task.isCancelled else { return }
            await transport.silenceAfterWake()
        }
    }
    func stop() { silence?.cancel(); silence = nil }
}

/// Registers for the six system notifications and forwards them. Lock notifications are distributed (`com.apple.screenIsLocked`); sleep and
/// display sleep are workspace notifications. Injectable centres let a test post the same names without touching the real system.
@MainActor final class SystemPowerObserver {
    static let lockedName = Notification.Name("com.apple.screenIsLocked")
    static let unlockedName = Notification.Name("com.apple.screenIsUnlocked")
    private var tokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private let handler: @MainActor (PowerEvent) -> Void
    init(workspace: NotificationCenter = NSWorkspace.shared.notificationCenter, distributed: NotificationCenter = DistributedNotificationCenter.default(),
         handler: @escaping @MainActor (PowerEvent) -> Void) {
        self.handler = handler
        func add(_ center: NotificationCenter, _ name: Notification.Name, _ event: PowerEvent) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.handler(event) } }
            tokens.append((center, token))
        }
        add(distributed, Self.lockedName, .screenLocked)
        add(distributed, Self.unlockedName, .screenUnlocked)
        add(workspace, NSWorkspace.screensDidSleepNotification, .displaySlept)
        add(workspace, NSWorkspace.screensDidWakeNotification, .displayWoke)
        add(workspace, NSWorkspace.willSleepNotification, .systemWillSleep)
        add(workspace, NSWorkspace.didWakeNotification, .systemDidWake)
    }
    var observedCount: Int { tokens.count }
    func stop() { for entry in tokens { entry.center.removeObserver(entry.token) }; tokens.removeAll() }
    isolated deinit { for entry in tokens { entry.center.removeObserver(entry.token) } }
}
