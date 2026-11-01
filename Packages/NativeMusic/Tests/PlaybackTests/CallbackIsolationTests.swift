import AppKit
import Foundation
import MediaPlayer
import Synchronization
import Testing
@testable import Playback
@testable import SystemIntegration
@testable import AccountSession

/// NP1 (live crash 2026-10-29): framework callbacks must never trap when delivered
/// off the main actor. Each test invokes the real callback from a background queue.
private func pngData(_ width: Int = 64, _ height: Int = 64) -> Data {
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus(); NSColor(red: 0.7, green: 0.1, blue: 0.2, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill(); image.unlockFocus()
    return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
}
private func onBackground<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in DispatchQueue.global(qos: .utility).async { continuation.resume(returning: body()) } }
}
private func offMain(_ center: NowPlayingCenter, _ command: RemoteTransportCommand?) async -> MPRemoteCommandHandlerStatus {
    await onBackground { center.respond(to: command) }
}
/// Holds a non-Sendable framework object for a background call in a test.
private struct Unchecked<Value>: @unchecked Sendable { let value: Value }

@Suite(.serialized) @MainActor struct CallbackIsolationTests {
    @Test func theArtworkRequestHandlerRunsOnMediaPlayersQueueWithoutTrapping() async throws {
        let artwork = Unchecked(value: try #require(NowPlayingArtwork.make(pngData())))
        let size = await onBackground { artwork.value.image(at: CGSize(width: 32, height: 32))?.size ?? .zero }
        #expect(size != .zero, "MediaPlayer's access queue calls this; it must not assume the main actor")
    }
    @Test func theRealNowPlayingArtworkPublishedByUpdateIsSafeOffMain() async throws {
        let center = NowPlayingCenter()
        #expect(center.activate { _ in .success }, "W23: only the owner of the media session publishes into it")
        center.update(NowPlayingItem(title: "Synthetic Song", artist: "Synthetic Artist", album: nil, artwork: pngData(),
                                     duration: 200, elapsed: 1, playing: true, advertisement: false))
        let artwork = Unchecked(value: try #require(center.artworkObject))
        let ok = await onBackground { artwork.value.image(at: CGSize(width: 16, height: 16)) != nil }
        #expect(ok)
        // Let MediaPlayer push the info (it reads the artwork on its own queue, as live).
        try await Task.sleep(for: .milliseconds(300))
        center.relinquish()
    }
    @Test func remoteCommandsDeliveredOffMainAreAdmittedFromTheSnapshotAndRunOnMain() async throws {
        let center = NowPlayingCenter()
        let calls = Mutex<[String]>([])
        #expect(await offMain(center, .toggle) == .noActionableNowPlayingItem, "inactive")
        center.activate { command in
            calls.withLock { $0.append("\(command)" + (Thread.isMainThread ? "@main" : "@background")) }
            return .success
        }
        center.update(NowPlayingItem(title: "Song", artist: nil, album: nil, artwork: nil, duration: 200, elapsed: 1, playing: true, advertisement: false))
        #expect(await offMain(center, .seek(30)) == .success)
        #expect(await offMain(center, nil) == .commandFailed)
        for _ in 0..<50 where calls.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(calls.withLock { $0 } == ["seek(30.0)@main"], "delivered on the main actor, not asserted")
        center.update(NowPlayingItem(title: "Song", artist: nil, album: nil, artwork: nil, duration: 200, elapsed: 1, playing: true, advertisement: true))
        #expect(await offMain(center, .seek(30)) == .commandFailed, "seek refused during an ad")
        #expect(await offMain(center, .next) == .commandFailed, "next refused during an ad")
        #expect(await offMain(center, .pause) == .success, "pause is allowed during an ad")
        center.relinquish()
        #expect(await offMain(center, .play) == .noActionableNowPlayingItem)
    }
    @Test func pageAndSignInCallbacksHopToTheMainActorInsteadOfAsserting() async throws {
        let ran = Mutex<[Bool]>([])
        await onBackground { WebMusicMainActor.run { ran.withLock { $0.append(Thread.isMainThread) } } }
        await onBackground { WebMusicSignIn.onMain { ran.withLock { $0.append(Thread.isMainThread) } } }
        for _ in 0..<50 where ran.withLock({ $0.count < 2 }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(ran.withLock { $0 } == [true, true])
        WebMusicMainActor.run { ran.withLock { $0.append(Thread.isMainThread) } }
        #expect(ran.withLock { $0.count } == 3, "on the main thread it runs synchronously")
    }

    /// T23 on the REAL MediaPlayer centres, inside this isolated test process: the owner takes the keys once, a second owner is refused, the system's own
    /// enable flags follow the capabilities, and relinquishing leaves nothing behind. It is a test OF THIS SUITE on purpose: the suite is `.serialized`, and
    /// the callback tests above also use the one live pair, so no other test can hold the live keys while this one asserts they are free.
    @Test func theRealCentresAreTakenOnceSwitchedPerCapabilityAndReleased() throws {
        let live = NowPlayingSystem.live
        let commands = try #require(live.commands as? LiveRemoteCommands)
        let center = NowPlayingCenter()
        #expect(commands.registrationCount == 0, "nothing held before this owner")
        #expect(center.activate { _ in .success } && commands.registrationCount == RemoteCommandKind.allCases.count)
        let refused = commands.refusedOwners
        let second = NowPlayingCenter()
        #expect(!second.activate { _ in .success } && commands.refusedOwners == refused + 1 && commands.registrationCount == RemoteCommandKind.allCases.count, "a second owner is refused, with no second registration")
        let item = NowPlayingItem(title: "Synthetic Hosted Song", artist: "Synthetic Artist", album: nil, artwork: nil, duration: 200, elapsed: 5, playing: true, advertisement: false)
        center.update(item)
        let real = MPRemoteCommandCenter.shared()
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Synthetic Hosted Song")
        #expect(real.playCommand.isEnabled && real.nextTrackCommand.isEnabled && real.changePlaybackPositionCommand.isEnabled)
        #expect(!real.likeCommand.isEnabled && !real.skipForwardCommand.isEnabled && !real.changePlaybackRateCommand.isEnabled, "no library path, not an episode: off")
        var ad = item; ad.advertisement = true
        center.update(ad)
        #expect(!real.nextTrackCommand.isEnabled && !real.changePlaybackPositionCommand.isEnabled && real.pauseCommand.isEnabled)
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == NowPlayingMapping.advertisementTitle)
        center.relinquish()
        #expect(commands.registrationCount == 0 && MPNowPlayingInfoCenter.default().nowPlayingInfo == nil && !real.playCommand.isEnabled && !real.nextTrackCommand.isEnabled)
        #expect(second.activate { _ in .success } && commands.registrationCount == RemoteCommandKind.allCases.count, "another owner can take the keys once this one let go")
        second.relinquish()
    }
}
