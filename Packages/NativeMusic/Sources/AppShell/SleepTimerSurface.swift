import DesignSystem
import Foundation
import OutputRoutes
import Playback
import SwiftUI

// P17-WEB (PLAY17). One sleep timer for the application session. The native session keeps its own timer (`PlaybackSession.setTimer`, owned and local
// media) and the hidden YouTube Music player has its own (`WebMusicPlayer.setSleepTimer`); this file is the single place that reads either one for
// the surfaces (Now Playing, the popover, the mini-player, the bar), sets the player's through the output gate, and carries a running timer over
// when the playback owner changes engines. Nothing here fades or pauses anything: the engines do, each on its own terms.

/// What a surface shows of the timer, whichever engine runs it. The hidden player's timer counts down to a wall `deadline` (a surface derives the
/// remaining time from it, once a second, without anything being published every second); the native session reports the seconds left at its last
/// snapshot.
struct SleepTimerDisplay: Equatable {
    var deadline: Date?
    var reportedRemaining: Double?
    var endOfItem: Bool
    var fading: Bool

    /// Whole seconds left (rounded up so the last second reads 0:01, never 0:00 before it ends), nil for End of item.
    func remaining(at now: Date) -> Int? {
        let seconds = deadline.map { $0.timeIntervalSince(now) } ?? reportedRemaining
        return seconds.map { Int(max(0, $0).rounded(.up)) }
    }
    static func clock(_ seconds: Int) -> String {
        seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    /// The line a surface shows. `episode` words End of item as End of episode.
    func text(at now: Date, episode: Bool) -> String {
        if fading { return String(localized: "Sleep timer: fading out") }
        if endOfItem { return episode ? String(localized: "Sleep timer: end of episode") : String(localized: "Sleep timer: end of track") }
        return String(localized: "Sleep timer: \(Self.clock(remaining(at: now) ?? 0)) left")
    }
    var ticks: Bool { deadline != nil && !fading }
}

/// The result of setting the timer on the engine that plays.
enum SleepTimerResult: Equatable {
    case set, cleared
    case refused(SleepTimerRefusal)
}

extension PlaybackModel {
    /// The timer of whichever engine plays now, for the surfaces. Reading it subscribes a view to the timer's changes (set, fade, end), not to the clock.
    var sleepTimerDisplay: SleepTimerDisplay? {
        if let player = music, !player.isClosed {
            return player.sleepTimerState.map { SleepTimerDisplay(deadline: $0.deadline, reportedRemaining: nil, endOfItem: $0.endOfItem, fading: $0.fading) }
        }
        if music == nil, let timer = state?.timer {
            return SleepTimerDisplay(deadline: nil, reportedRemaining: timer.remaining, endOfItem: timer.endOfItem, fading: timer.fading)
        }
        return nil
    }
    /// Whether the item that plays is a podcast episode (the timer then says "episode").
    func playingEpisode(_ episodes: (any RemoteEpisodeControlling)?) -> Bool {
        guard let id = music?.snapshot.videoID, let episodes else { return false }
        return episodes.remoteEpisode(for: id) != nil
    }

    /// Sets (or, with nil, cancels) the hidden player's timer, through the output gate every timer goes through. The hidden player follows the Mac's
    /// output, so its route can always fade (`RouteCapabilities`); a remote receiver's pause-only note belongs to the native engine.
    @discardableResult func setMusicSleepTimer(_ timer: SleepTimer?) async -> SleepTimerResult {
        guard let player = music, !player.isClosed else { return .refused(.nothingPlaying) }
        var outcome: SleepTimerOutcome = .refused(.nothingPlaying)
        let apply: @MainActor () async -> Void = { outcome = await player.setSleepTimer(timer) }
        if timer != nil, let outputs { await outputs.gate(.enableTimer, engine: .youTubeMusic, apply) } else { await apply() }
        switch outcome {
        case .set: return .set
        case .cleared: return .cleared
        case .refused(let reason): return .refused(reason)
        }
    }

    /// The timer to carry across a change of engine: what is left of a running one, or End of item. A timer already fading is not carried (it is ending).
    /// Captured BEFORE the authority closes the engine being left; applied by `carrySleepTimer` once the new engine has started.
    func sleepTimerToCarry(leavingYouTubeMusic: Bool) -> SleepTimer? {
        if leavingYouTubeMusic {
            guard let player = music, !player.isClosed, let state = player.sleepTimerState, !state.fading else { return nil }
            if state.endOfItem { return .endOfItem }
            return player.sleepTimerRemaining().map { .custom(max(1, $0)) }
        }
        guard music == nil, let timer = state?.timer, !timer.fading else { return nil }
        if timer.endOfItem { return .endOfItem }
        return timer.remaining.map { .custom(max(1, $0)) }
    }
}

// MARK: Views

/// The timer's line: its remaining time (counting down once a second), "fading out", or the item it waits for. Nothing when there is no timer.
struct SleepTimerLine: View {
    let model: PlaybackModel
    var episode = false
    var identifier = "sleepTimerLine"
    /// The clock the remaining time is drawn against: moved once a second while a length timer counts down and this line is on screen (the task ends with
    /// the view, so a hidden window costs nothing), never by the player.
    @State private var now = Date()
    var body: some View {
        if let display = model.sleepTimerDisplay {
            Text(display.text(at: display.ticks ? now : Date(), episode: episode))
                .font(.caption).foregroundStyle(MusicStyle.secondaryText).lineLimit(1).monospacedDigit()
                .accessibilityElement(children: .combine).accessibilityIdentifier(identifier)
                .task(id: display.ticks) {
                    guard display.ticks else { return }
                    while !Task.isCancelled { now = Date(); try? await Task.sleep(for: .seconds(1)) }
                }
        }
    }
}

/// The sleep-timer choices of the YouTube Music transport: the presets, End of track / End of episode, a custom length and Cancel. Every choice goes through
/// the playback owner (`setMusicSleepTimer`), the same call the App Intent makes. Used by the menu below and by the capsule's ⋯ menu.
struct MusicSleepTimerItems: View {
    let model: PlaybackModel
    var episode = false
    /// The engine's reason when it refused (nil when the last choice was accepted).
    var refused: (String?) -> Void = { _ in }
    @State private var customMinutes = 10.0
    var body: some View {
        let running = model.sleepTimerDisplay != nil
        ForEach([5, 15, 30, 60], id: \.self) { minutes in
            Button("\(minutes) minutes") { set(.minutes(minutes)) }
        }
        Button(LocalizedStringKey(episode ? "End of episode" : "End of track")) { set(.endOfItem) }
        Button("Custom: \(Int(customMinutes)) minutes") { set(.custom(customMinutes * 60)) }
        ControlGroup { Stepper("Custom minutes", value: $customMinutes, in: 1...1440) }
        Divider()
        Button("Cancel timer") { set(nil) }.disabled(!running)
    }
    private func set(_ timer: SleepTimer?) {
        Task {
            let result = await model.setMusicSleepTimer(timer)
            if case .refused(let reason) = result { refused(reason.message) } else { refused(nil) }
        }
    }
}

/// The sleep-timer menu of the YouTube Music transport (the expanded player's accessories).
struct MusicSleepTimerMenu: View {
    let model: PlaybackModel
    var episode = false
    @State private var refusal: String?
    var body: some View {
        let running = model.sleepTimerDisplay != nil
        Menu {
            MusicSleepTimerItems(model: model, episode: episode) { refusal = $0 }
        } label: { Label("Sleep timer", systemImage: running ? "moon.zzz.fill" : "moon.zzz") }
            .labelStyle(.iconOnly).help(Text(refusal ?? String(localized: "Sleep timer"))).accessibilityIdentifier("musicSleepTimerMenu")
    }
}

/// The capsule's chip: a moon and the time left (or what the timer waits for), beside the ⋯ menu. It says the same sentence as `SleepTimerLine` to
/// VoiceOver and keeps that line's identifier. Nothing when there is no timer.
struct SleepTimerChip: View {
    let model: PlaybackModel
    var episode = false
    var identifier = "sleepTimerLine"
    @State private var now = Date()
    var body: some View {
        if let display = model.sleepTimerDisplay {
            let at = display.ticks ? now : Date()
            HStack(spacing: MusicSpace.xxs) {
                Image(systemName: "moon.zzz.fill")
                Text(verbatim: Self.short(display, at: at))
            }.musicCapsuleChip()
                .accessibilityElement(children: .ignore).accessibilityAddTraits(.isStaticText)
                .accessibilityLabel(Text(display.text(at: at, episode: episode)))
                .accessibilityIdentifier(identifier)
                .help(Text(display.text(at: at, episode: episode)))
                .task(id: display.ticks) {
                    guard display.ticks else { return }
                    while !Task.isCancelled { now = Date(); try? await Task.sleep(for: .seconds(1)) }
                }
        }
    }
    /// What the chip prints after the moon: the clock, or a word for fading and End of item.
    static func short(_ display: SleepTimerDisplay, at now: Date) -> String {
        if display.fading { return String(localized: "Fading") }
        if display.endOfItem { return String(localized: "End") }
        return SleepTimerDisplay.clock(display.remaining(at: now) ?? 0)
    }
}
