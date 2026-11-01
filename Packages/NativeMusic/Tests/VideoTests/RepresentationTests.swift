import Foundation
import Testing
@testable import Playback

// Synthetic ids only. Titles, artists and durations are deliberately NOT part of the mapping model: that is the rule under test.
private let song = MediaAssetIdentity.youTubeMusic("SONGaaaaaa1")
private let video = MediaAssetIdentity.youTubeMusic("VIDEOaaaaa1")
private let lookalike = MediaAssetIdentity.youTubeMusic("SONGaaaaaa2")   // "the same title" as `song`, a different recording
private func catalog(_ pairs: PublishedCounterpart...) -> RepresentationCatalog { var value = RepresentationCatalog(); pairs.forEach { value.publish($0) }; return value }
private func pair(_ audio: MediaAssetIdentity = song, _ video: MediaAssetIdentity = video) -> PublishedCounterpart { PublishedCounterpart(audio: audio, video: video)! }
private func playing(_ asset: MediaAssetIdentity, _ representation: MediaRepresentation, at position: Double = 61, of duration: Double? = 200, ad: Bool = false) -> RepresentationTransition.Current {
    .init(asset: asset, representation: representation, position: position, duration: duration, isAdvertisement: ad)
}

@Suite struct RepresentationTransitionTests {
    /// T17.1: known corresponding recordings keep the position, in both directions.
    @Test func aPublishedPairKeepsThePositionInBothDirections() {
        let known = catalog(pair())
        #expect(RepresentationTransition.plan(current: playing(video, .video), target: .init(asset: song, representation: .audio), catalog: known) == .continued(at: 61))
        #expect(RepresentationTransition.plan(current: playing(song, .audio, at: 12.5), target: .init(asset: video, representation: .video), catalog: known) == .continued(at: 12.5))
    }
    /// T17.1: same-title unrelated assets must not silently map. The model has no title, so the only thing that can map is a published pair.
    @Test func anAssetWithTheSameTitleButNoPublishedRelationRestarts() {
        let known = catalog(pair())
        let plan = RepresentationTransition.plan(current: playing(video, .video), target: .init(asset: lookalike, representation: .audio), catalog: known)
        #expect(plan == .restart(.noPublishedCounterpart))
        #expect(RepresentationTransition.plan(current: playing(video, .video), target: .init(asset: lookalike, representation: .audio), catalog: RepresentationCatalog()) == .restart(.noPublishedCounterpart),
                "with nothing published, nothing maps")
    }
    @Test func theTargetMustBeTheOtherHalfOfTheSamePair() {
        let other = MediaAssetIdentity.youTubeMusic("VIDEObbbbb2"), otherSong = MediaAssetIdentity.youTubeMusic("SONGbbbbbb2")
        let known = catalog(pair(), pair(otherSong, other))
        #expect(RepresentationTransition.plan(current: playing(video, .video), target: .init(asset: otherSong, representation: .audio), catalog: known) == .restart(.noPublishedCounterpart),
                "another recording's song is not this recording's song, even though both pairs are published")
        #expect(RepresentationTransition.plan(current: playing(video, .video), target: .init(asset: song, representation: .video), catalog: known) == .restart(.noPublishedCounterpart),
                "the right asset in the wrong presentation is not the published relation")
    }
    @Test func aPairNeedsOneSourceAndTwoDifferentAssets() {
        #expect(PublishedCounterpart(audio: song, video: song) == nil)
        #expect(PublishedCounterpart(audio: song, video: MediaAssetIdentity(source: "another-service", assetID: "VIDEOaaaaa1")) == nil)
        #expect(PublishedCounterpart(audio: MediaAssetIdentity(source: "youtube-music", assetID: ""), video: video) == nil)
    }
    @Test func versionsThatDifferRestartAndUnstatedVersionsDoNot() {
        let v1 = MediaAssetIdentity.youTubeMusic("SONGaaaaaa1", version: "2019-remaster"), v2 = MediaAssetIdentity.youTubeMusic("VIDEOaaaaa1", version: "2007-original")
        #expect(RepresentationTransition.plan(current: playing(v2, .video), target: .init(asset: v1, representation: .audio), catalog: catalog(PublishedCounterpart(audio: v1, video: v2)!)) == .restart(.versionDiffers))
        let same = MediaAssetIdentity.youTubeMusic("VIDEOaaaaa1", version: "2019-remaster")
        #expect(RepresentationTransition.plan(current: playing(same, .video), target: .init(asset: v1, representation: .audio), catalog: catalog(PublishedCounterpart(audio: v1, video: same)!)) == .continued(at: 61))
        #expect(RepresentationTransition.plan(current: playing(video, .video), target: .init(asset: v1, representation: .audio), catalog: catalog(PublishedCounterpart(audio: v1, video: video)!)) == .continued(at: 61))
    }
    @Test func liveStreamsNeverCarryAPosition() {
        let known = catalog(pair())
        #expect(RepresentationTransition.plan(current: playing(video, .live, of: nil), target: .init(asset: song, representation: .audio), catalog: known) == .restart(.liveStream))
        #expect(RepresentationTransition.plan(current: playing(song, .audio), target: .init(asset: video, representation: .live), catalog: known) == .restart(.liveStream))
    }
    @Test func anAdvertisementAndNothingPlayingRefuseTheSwitch() {
        let known = catalog(pair())
        #expect(RepresentationTransition.plan(current: playing(video, .video, ad: true), target: .init(asset: song, representation: .audio), catalog: known) == .refused(.advertisement))
        #expect(RepresentationTransition.plan(current: nil, target: .init(asset: song, representation: .audio), catalog: known) == .refused(.nothingPlaying))
        #expect(RepresentationTransition.plan(current: playing(song, .audio), target: .init(asset: song, representation: .audio), catalog: known) == .keep)
    }
    /// The published pair is necessary, not sufficient: once the target's length is known the two timelines must agree.
    @Test func aCarriedPositionMustSurviveTheLengthCheck() {
        let current = playing(video, .video, at: 100, of: 200)
        let plan = RepresentationTransition.Plan.continued(at: 100)
        #expect(RepresentationTransition.settle(plan, current: current, targetDuration: 201.5) == .continued(at: 100))
        #expect(RepresentationTransition.settle(plan, current: current, targetDuration: 207) == .restart(.timelinesDiffer), "a version with an intro is not the same timeline")
        #expect(RepresentationTransition.settle(plan, current: current, targetDuration: nil) == .restart(.timelinesDiffer), "an unknown length cannot confirm one")
        #expect(RepresentationTransition.settle(.continued(at: 199.9), current: current, targetDuration: 199) == .continued(at: 198.5), "never past the end of the target")
        #expect(RepresentationTransition.settle(.restart(.noPublishedCounterpart), current: current, targetDuration: 200) == .restart(.noPublishedCounterpart))
    }
    @Test func nonFinitePositionsBecomeTheStart() {
        #expect(RepresentationTransition.plan(current: playing(video, .video, at: .nan), target: .init(asset: song, representation: .audio), catalog: catalog(pair())) == .continued(at: 0))
        #expect(RepresentationTransition.plan(current: playing(video, .video, at: -4), target: .init(asset: song, representation: .audio), catalog: catalog(pair())) == .continued(at: 0))
    }
    /// Audio only asks the service for its audio version; it is never a cover over a decoding picture.
    @Test func audioOnlyNeedsAPublishedAudioVersionAndSaysWhyOtherwise() throws {
        let known = catalog(pair())
        let target = try RepresentationTransition.audioOnlyTarget(for: playing(video, .video), catalog: known).get()
        #expect(target.asset == song && target.representation == .audio)
        for (current, reason) in [(playing(video, .video), RepresentationTransition.AudioOnlyUnavailable.noAudioVersionPublished), (playing(song, .audio), .alreadyAudio), (playing(video, .live, of: nil), .liveStream)] {
            let result = RepresentationTransition.audioOnlyTarget(for: current, catalog: current.representation == .video ? RepresentationCatalog() : known)
            #expect(result.failureValue == reason)
            #expect(!reason.message.isEmpty)
        }
        #expect(RepresentationTransition.audioOnlyTarget(for: nil, catalog: known).failureValue == .nothingPlaying)
        #expect(RepresentationTransition.AudioOnlyUnavailable.noAudioVersionPublished.message.contains("not hidden"), "the refusal says the picture is not hidden to fake audio only")
    }
}
private extension Result { var failureValue: Failure? { if case .failure(let error) = self { error } else { nil } } }
