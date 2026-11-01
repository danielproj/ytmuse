import AVFoundation
import Domain
import Foundation
import Queue
import Testing
@testable import Playback

private func videoContext(_ generation: UInt64 = 1) -> PlaybackContext {
    PlaybackContext(request: .init(account: OwnedMedia.account, accountGeneration: generation, requestGeneration: 0), generation: 1, occurrenceID: UUID(), route: nil)
}
/// Owned synthetic video on the real NativePlayer: video-only (no audio track), so these runs make no sound; app gain is 0.001 regardless.
@Suite(.serialized) struct NativeVideoTests {
    private func prepared() async throws -> (NativePlayer, PlaybackContext) {
        let media = OwnedMedia()
        let player = NativePlayer(assets: media, clock: SystemMonotonicClock(), initialGain: 0.001, maximumStartGain: 0.001)
        let context = videoContext()
        let variant = try await media.resolve(OwnedMedia.videoItem, context: context).outcome.get()[0]
        _ = try await player.stop(context: context).outcome.get()
        _ = try await player.prepare(variant, context: context).outcome.get()
        _ = try await player.setGain(0.001, context: context).outcome.get()
        return (player, context)
    }
    /// T17.2: audio-only STOPS the decoder (the video track is disabled), it does not cover a decoding picture.
    @Test func audioOnlyStopsTheVideoDecoderAndVideoResumesIt() async throws {
        let (player, context) = try await prepared()
        let handle = try #require(await player.videoHandle(context: context))
        #expect(handle.hasVideoTrack && handle.decoding)
        #expect(handle.presentationSize == CGSize(width: 480, height: 270))
        _ = try await player.startVideoMeasurement(context: context).outcome.get()
        _ = try await player.play(context: context).outcome.get()
        try await Task.sleep(for: .milliseconds(1200))
        let decoding = await player.videoFramesDelivered()
        print("T17.2 native frames after 1.2 s of video: \(decoding)")
        #expect(decoding >= 10, "the decoder delivers frames while video is selected")
        let positionBefore = await player.nativePosition()
        _ = try await player.setVideoDecoding(false, context: context).outcome.get()
        #expect(try #require(await player.videoHandle(context: context)).decoding == false)
        try await Task.sleep(for: .milliseconds(400))
        let stopped = await player.videoFramesDelivered()
        try await Task.sleep(for: .milliseconds(1200))
        let after = await player.videoFramesDelivered()
        print("T17.2 native frames while audio-only: \(stopped) -> \(after)")
        #expect(after - stopped <= 1, "no frames are produced while audio-only")
        #expect(await player.nativePosition() > positionBefore + 1, "the media keeps playing: only the decoder stopped")
        _ = try await player.setVideoDecoding(true, context: context).outcome.get()
        try await Task.sleep(for: .milliseconds(1000))
        let resumed = await player.videoFramesDelivered()
        print("T17.2 native frames after returning to video: \(after) -> \(resumed)")
        #expect(resumed - after >= 8, "selecting video decodes again")
        _ = try await player.stop(context: context).outcome.get()
    }
}
