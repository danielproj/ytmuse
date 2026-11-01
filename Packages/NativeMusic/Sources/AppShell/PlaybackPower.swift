import Foundation
import OutputRoutes
import Playback

/// What a system sleep held: the hidden player's hold (with the player it belongs to), or a native session that was (or was not) wanted playing.
enum PowerSleepHold {
    case music(WebMusicPlayer, WebMusicPlayer.SystemSleepHold)
    case native(PlaybackSession, wanted: Bool)
}

/// W21: both engines behind the one playback owner answer the power lifecycle through the same four calls (PLAY01, ARCH03).
extension PlaybackModel: PowerTransporting {
    func holdForSleep() async -> Bool {
        sleepHold = nil
        // F9: the audible part first (the pause), then the file write; the window macOS gives `willSleep` is spent on the sound.
        if let player = music, !player.isClosed {
            guard let hold = await player.holdForSystemSleep() else { return false }
            sleepHold = .music(player, hold)
            await checkpointForSleep?()
            return true
        }
        if let session, !(await session.isClosed()) {
            let wanted = (try? await session.snapshot())?.playback.intent == .play
            // `sleep` checkpoints the queue and pauses with the sleep reason; wake only resumes a session that was playing.
            await session.sleep()
            sleepHold = .native(session, wanted: wanted)
            await checkpointForSleep?()
            return wanted
        }
        return false
    }
    func routeLossPending() -> Bool { outputs.map { $0.lossPending(for: $0.subject) } ?? false }
    /// The route the held engine is audible on: the hidden player's is the system default, the local engine's is its chosen device or the default.
    func audibleRoute() -> (identity: RouteIdentity?, pinned: Bool) { outputs.map { $0.coordinator.audibleRoute(for: $0.subject) } ?? (nil, false) }
    func holdFacts() async -> (personChanged: Bool, timerExpired: Bool, ownerChanged: Bool) {
        switch sleepHold {
        case .music(let player, let hold)?:
            let current = await authority.currentMusic()
            // P17-WEB: the hidden player's own sleep timer counts like the native one: a timer that ran out (or ended the playback) keeps the wake from resuming.
            return (personChanged: player.commandRevision != hold.commandRevision, timerExpired: !player.isClosed && player.sleepTimerHasExpired(), ownerChanged: player.isClosed || current !== player || music !== player)
        case .native(let session, _)?:
            let closed = await session.isClosed()
            let timer = closed ? false : await session.timerHasExpired()
            let intent = closed ? nil : (try? await session.snapshot())?.playback.intent
            // The hold left the session paused for the sleep; any other intent means a person changed it since.
            let changed = intent != nil && intent != .pause(.sleep)
            return (personChanged: changed, timerExpired: timer, ownerChanged: closed || self.session !== session)
        case nil:
            return (false, false, false)
        }
    }
    func finishWake(resume: Bool) async -> Bool {
        defer { sleepHold = nil }
        switch sleepHold {
        case .music(let player, let hold)?:
            guard resume else { return false }
            return await player.resumeAfterSystemWake(hold)
        case .native(let session, let wanted)?:
            // Always told, so the session's own rules run (an expired timer pauses and clears itself) and its sleep bookkeeping clears.
            guard !(await session.isClosed()) else { return false }
            await session.wake(safeRoute: resume, resumeEnabled: resume)
            await refresh()
            return resume && wanted
        case nil:
            return false
        }
    }
    func silenceAfterWake() async {
        if let player = music, !player.isClosed { await player.silencePageAgainstIntent() }
    }
}
