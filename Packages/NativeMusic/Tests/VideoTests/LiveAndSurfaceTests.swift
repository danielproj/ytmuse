import AccountSession
import AppKit
import Domain
import Foundation
import Testing
@testable import AppShell
@testable import Playback

// MARK: T17.3 live

@Suite struct LiveWindowTests {
    @Test func seekTargetsClampIntoTheWindowThePlayerCanReach() throws {
        let window = try #require(LiveWindow(start: 0, end: 120))
        #expect(window.clamp(60) == 60 && window.clamp(-30) == 0 && window.clamp(10_000) == 120)
        #expect(window.clamp(.nan) == nil && window.clamp(.infinity) == nil, "a non-finite target is not a position")
        let shifted = try #require(LiveWindow(start: 30, end: 150))
        #expect(shifted.clamp(0) == 30 && shifted.clamp(200) == 150)
    }
    @Test func aStreamWithoutAWindowCannotBeSoughtAndGoLiveIsTheOnlyMotion() throws {
        let none = try #require(LiveWindow(start: 120, end: 120.4))
        #expect(!none.isRewindable && none.clamp(60) == nil)
        #expect(LiveWindow(start: 10, end: 5) == nil && LiveWindow(start: -1, end: 5) == nil && LiveWindow(start: .nan, end: 5) == nil)
    }
    @Test func theLiveEdgeToleranceIsTenSeconds() throws {
        let window = try #require(LiveWindow(start: 0, end: 600))
        #expect(window.isAtLiveEdge(position: 600) && window.isAtLiveEdge(position: 590.5) && !window.isAtLiveEdge(position: 589))
        #expect(window.isAtLiveEdge(position: 590), "exactly ten seconds behind still counts as live")
        #expect(!window.isAtLiveEdge(position: 589.99))
        #expect(window.behindLive(position: 540) == 60 && window.behindLive(position: 700) == 0)
    }
}

@Suite struct WebMusicLiveTransportTests {
    private func liveTransport(end: Double = 600, position: Double = 600, rewindable: Bool = true, ad: Bool = false) throws -> WebMusicTransport {
        var transport = WebMusicTransport()
        _ = transport.begin(playlistID: "PLsyntheticL", title: nil); _ = transport.reserveDocument()
        transport.apply(try message(stateBody(position: position, duration: 0, video: videoA)))
        transport.apply(try message(mediaBody(kind: "live", start: 0, end: rewindable ? end : 0.2, width: 1280, height: 720, pip: "unsupported")))
        if ad { transport.apply(try message(stateBody(position: position, duration: 0, video: videoA, ad: true))) }
        return transport
    }
    @Test func aLiveStreamHasNoDurationAndOffersItsWindow() throws {
        let transport = try liveTransport()
        #expect(transport.snapshot.isLive && transport.snapshot.duration == 0 && transport.snapshot.liveRewindable && transport.snapshot.atLiveEdge)
        #expect(transport.snapshot.canSeek, "a rewindable live stream can be sought although it has no duration")
        #expect(!transport.snapshot.canGoLive, "Go live is not offered at the live edge")
        #expect(!transport.previousRestarts, "Previous never 'restarts' a live stream")
    }
    @Test func seekClampsToTheWindowAndNeverPastTheLiveEdge() throws {
        let transport = try liveTransport(end: 600, position: 300)
        #expect(try transport.admitSeek(10_000).get() == 600)
        #expect(try transport.admitSeek(-5).get() == 0)
        #expect(try transport.admitSeek(250).get() == 250)
        #expect(transport.admitSeek(.nan) == .failure(.invalidTarget))
    }
    @Test func goLiveJumpsToTheEdgeOnlyWhenBehindIt() throws {
        let behind = try liveTransport(end: 600, position: 200)
        #expect(behind.snapshot.canGoLive && !behind.snapshot.atLiveEdge)
        #expect(try behind.admitGoLive().get() == 600)
        let live = try liveTransport()
        #expect(live.admitGoLive() == .failure(.alreadyLive))
    }
    @Test func aStreamWithoutAWindowRefusesSeekingWithTheActualReason() throws {
        let transport = try liveTransport(rewindable: false)
        #expect(!transport.snapshot.canSeek)
        #expect(transport.admitSeek(30) == .failure(.liveNotSeekable))
        #expect(WebMusicRefusal.liveNotSeekable.message.contains("no earlier part"))
    }
    @Test func goLiveAndSeekAreRefusedDuringAnAdvertisementAndOutsideLive() throws {
        let ad = try liveTransport(position: 200, ad: true)
        #expect(ad.admitSeek(10) == .failure(.advertisement) && ad.admitGoLive() == .failure(.advertisement))
        var vod = WebMusicTransport()
        _ = vod.begin(playlistID: "PLsyntheticV", title: nil); _ = vod.reserveDocument()
        vod.apply(try message(stateBody()))
        vod.apply(try message(mediaBody(kind: "video")))
        #expect(vod.admitGoLive() == .failure(.notLive))
        #expect(!vod.snapshot.isLive && vod.snapshot.canSeek)
    }
    @Test func mediaFactsBelongToTheConfirmedLoadAndTheirOwnVideo() throws {
        var transport = WebMusicTransport()
        _ = transport.begin(playlistID: "PLsyntheticV", title: nil); _ = transport.reserveDocument()
        // The media message may arrive in the same report as the first state sample, but before it: it waits for the confirmation.
        transport.apply(try message(mediaBody(kind: "video", width: 640, height: 360)))
        #expect(transport.snapshot.representation == nil)
        transport.apply(try message(stateBody()))
        #expect(transport.snapshot.representation == .video && transport.snapshot.pictureSize == CGSize(width: 640, height: 360), "held media facts apply once confirmed")
        // A lagging report for another video is not applied to this one.
        transport.apply(try message(mediaBody(video: other, kind: "live", start: 0, end: 100)))
        #expect(transport.snapshot.representation == .video && !transport.snapshot.isLive)
    }
    @Test func anAdvertisementsPictureIsShownButItDoesNotChangeWhatTheContentIs() throws {
        var transport = WebMusicTransport()
        _ = transport.begin(playlistID: "PLsyntheticV", title: nil); _ = transport.reserveDocument()
        transport.apply(try message(stateBody())); transport.apply(try message(mediaBody(kind: "audio", width: 0, height: 0)))
        #expect(transport.snapshot.representation == .audio && !transport.snapshot.hasPicture)
        transport.apply(try message(stateBody(ad: true)))
        transport.apply(try message(mediaBody(kind: "video", width: 1280, height: 720)))
        #expect(transport.snapshot.isAd && transport.snapshot.hasPicture, "the ad creative's picture is available to be shown (ads are never hidden)")
        #expect(transport.snapshot.representation == .audio, "but the content's presentation is not replaced by the ad's")
    }
    @Test func aCounterpartIsPublishedForTheVideoItBelongsToAndInTheRightDirection() throws {
        var transport = WebMusicTransport()
        _ = transport.begin(playlistID: "PLsyntheticV", title: nil); _ = transport.reserveDocument()
        transport.apply(try message(stateBody())); transport.apply(try message(mediaBody(kind: "video", counterpart: songA)))
        #expect(transport.snapshot.counterpartVideoID == songA && transport.snapshot.counterpartRepresentation == .audio && transport.catalog.count == 1)
        let target = RepresentationTransition.Target(asset: .youTubeMusic(songA), representation: .audio)
        #expect(RepresentationTransition.plan(current: transport.current(), target: target, catalog: transport.catalog) == .continued(at: 10))
        transport.apply(try message(stateBody(video: songA), doc: 1, load: 1))
        #expect(transport.snapshot.counterpartVideoID == nil && transport.snapshot.representation == nil, "a new track starts with no facts of the old one")
    }
    @Test func nothingIsLeftOfTheOldTrackWhenTheNextOneStarts() throws {
        var transport = try liveTransport()
        transport.apply(try message(stateBody(video: other)))
        #expect(!transport.snapshot.isLive && transport.behindLive == nil && !transport.snapshot.liveRewindable)
    }
}

@Suite struct WebMusicMediaBridgeTests {
    @Test func acceptsABoundedMediaMessageAndRejectsTheMalformedOnes() throws {
        let ok = try message(mediaBody(kind: "live", start: 0, end: 120, counterpart: songA, frames: 1234))
        guard case .media(let sample) = ok.event else { Issue.record("not media"); return }
        #expect(sample.representation == .live && sample.liveEnd == 120 && sample.decodedFrames == 1234 && sample.counterpartID == songA)
        func rejected(_ body: [String: Any]) -> Bool { if case .failure(.malformed) = WebMusicBridge.validate(body, frame: musicFrame, document: 1, load: 1) { true } else { false } }
        #expect(rejected(mediaBody(kind: "video", start: 0, end: 120)), "a seekable window belongs to a live stream only")
        #expect(rejected(mediaBody(kind: "live", start: 50, end: 10)) && rejected(mediaBody(kind: "live", start: -1, end: 10)))
        #expect(rejected(mediaBody(kind: "live", start: 0)), "the window is a pair")
        #expect(rejected(mediaBody(kind: "movie")) && rejected(mediaBody(pip: "maybe")))
        #expect(rejected(mediaBody(width: -1)) && rejected(mediaBody(width: 20_000)) && rejected(mediaBody(frames: 3_000_000_000)))
        #expect(rejected(mediaBody(counterpart: "not-an-id")))
        var extra = mediaBody(); extra["title"] = "page text"
        #expect(rejected(extra), "unknown keys never pass")
        var oversize = mediaBody(); oversize["videoId"] = String(repeating: "x", count: 5000)
        #expect(WebMusicBridge.validate(oversize, frame: musicFrame, document: 1, load: 1) == .failure(.oversized) || rejected(oversize))
        #expect(WebMusicBridge.validate(mediaBody(), frame: musicFrame, document: 2, load: 1) == .failure(.staleDocument))
        #expect(WebMusicBridge.validate(mediaBody(), frame: WebMusicFrame(isMainFrame: false, scheme: "https", host: "music.youtube.com", port: 0), document: 1, load: 1) == .failure(.subframe))
    }
}

@Suite struct MediaCapabilityTests {
    @Test func liveStreamsCannotBeDownloadedOrCrossfadedAndTheReasonIsSpecific() {
        let download = MediaCapabilityPolicy.availability(of: .download, representation: .live, hiddenPlayer: true)
        let crossfade = MediaCapabilityPolicy.availability(of: .crossfade, representation: .live, hiddenPlayer: true)
        #expect(!download.isAvailable && !crossfade.isAvailable)
        #expect(download.reason?.contains("no fixed length") == true && crossfade.reason?.contains("no end to overlap") == true)
        #expect(download.reason != crossfade.reason)
    }
    @Test func theHiddenPlayerHasItsOwnReasonAndOwnedMediaIsUnaffected() {
        let hidden = MediaCapabilityPolicy.availability(of: .download, representation: .video, hiddenPlayer: true)
        #expect(hidden.reason?.contains("YouTube's own player") == true)
        #expect(MediaCapabilityPolicy.availability(of: .crossfade, representation: .video, hiddenPlayer: true).reason?.contains("own player") == true)
        #expect(MediaCapabilityPolicy.availability(of: .download, representation: .video, hiddenPlayer: false).isAvailable)
        #expect(MediaCapabilityPolicy.availability(of: .crossfade, representation: nil, hiddenPlayer: false).isAvailable)
        #expect(MediaCapabilityPolicy.availability(of: .download, representation: .live, hiddenPlayer: false).reason?.contains("no fixed length") == true, "live is never downloadable, whichever player")
    }
}

@Suite struct VideoDecoderMeterTests {
    @Test func aDecoderThatStopsAdvancingIsReportedStoppedAfterTheStaleWindow() {
        var meter = VideoDecoderMeter()
        for step in 0..<10 { meter.record(frames: step * 12, at: Double(step) * 0.5) }
        #expect(meter.isDecoding(at: 4.6) && meter.advances == 9)
        for step in 0..<6 { meter.record(frames: 108, at: 5 + Double(step) * 0.5) }
        #expect(!meter.isDecoding(at: 7.6), "no advance for longer than the stale window")
        #expect(meter.isDecoding(at: 5.5), "but not before it")
    }
    @Test func aSmallerCounterIsANewElementNotAnAdvance() {
        var meter = VideoDecoderMeter()
        meter.record(frames: 100, at: 0); meter.record(frames: 120, at: 0.5)
        meter.record(frames: 0, at: 1)
        #expect(!meter.isDecoding(at: 1.1) && meter.frames == 0)
        meter.record(frames: 24, at: 1.5)
        #expect(meter.isDecoding(at: 1.6))
    }
}

@Suite struct VideoGeometryTests {
    @Test func aPictureIsScaledToFitWithItsAspectRatioAndCentred() {
        let wide = VideoGeometry(picture: CGSize(width: 1920, height: 1080), in: CGSize(width: 400, height: 400)).fitted
        #expect(wide == CGRect(x: 0, y: 87.5, width: 400, height: 225))
        let tall = VideoGeometry(picture: CGSize(width: 1080, height: 1920), in: CGSize(width: 640, height: 360)).fitted
        #expect(abs(tall.width / tall.height - 1080.0 / 1920.0) < 1e-9 && tall.height == 360 && tall.midX == 320)
        #expect(VideoGeometry(picture: CGSize(width: 480, height: 270), in: CGSize(width: 640, height: 360)).fitted == CGRect(x: 0, y: 0, width: 640, height: 360))
        #expect(VideoGeometry(picture: .zero, in: CGSize(width: 10, height: 10)).fitted == .zero && VideoGeometry(picture: .zero, in: .zero).aspectRatio == nil)
    }
}

// MARK: T17.4 ownership

@Suite struct VideoSurfaceOwnershipTests {
    @Test func atMostOneSurfaceHoldsThePictureAndAHandoffIsOneStep() {
        var owner = VideoSurfaceOwnership()
        let steps = [owner.request(.inline), owner.request(.window), owner.request(.window), owner.request(.fullScreen), owner.request(.pictureInPicture)]
        #expect(steps == [.attached(.inline), .moved(from: .inline, to: .window), .unchanged, .moved(from: .window, to: .fullScreen), .moved(from: .fullScreen, to: .pictureInPicture)])
        #expect(owner.activeSurfaces == 1 && owner.holder == .pictureInPicture && owner.handoffs == 3)
    }
    @Test func onlyTheHoldersReleaseCounts() {
        var owner = VideoSurfaceOwnership()
        owner.request(.window)
        let strangers = [owner.release(.inline), owner.release(.fullScreen)]
        #expect(strangers == [false, false] && owner.holder == .window)
        let own = owner.release(.window), again = owner.release(.window)
        #expect(own && !again && owner.holder == nil && owner.activeSurfaces == 0)
        owner.request(.fullScreen); owner.releaseAll()
        #expect(owner.holder == nil)
    }
}

@Suite @MainActor struct WebMusicSurfaceTests {
    @Test func movingThePictureNeverLoadsPlaysPausesOrSeeksTheMedia() async throws {
        let (player, page) = try await playingVideo()
        let before = page.mediaCommands
        let inline = NSView(), window = NSView(), full = NSView()
        #expect(await player.presentVideo(on: .inline, host: inline) == .attached(.inline))
        #expect(await player.presentVideo(on: .window, host: window) == .moved(from: .inline, to: .window))
        #expect(await player.presentVideo(on: .fullScreen, host: full) == .moved(from: .window, to: .fullScreen))
        await player.releaseVideo(.window)
        #expect(player.surfaces.holder == .fullScreen, "a surface letting go of a picture it does not hold changes nothing")
        await player.releaseVideo(.fullScreen)
        #expect(page.mediaCommands == before, "moves and closes ran only presentation commands: no load, router, play, pause, seek or teardown")
        #expect(page.loads.count == 1 && page.tornDown == 0)
        #expect(page.hosts.compactMap { $0 }.count == 3 && page.hosts.last! == nil, "three surfaces took the same page; the last one returned it to the hidden host")
        #expect(player.surfaces.holder == nil && player.snapshot.phase == .playing)
    }
    @Test func aSurfaceThatDoesNotHoldThePictureNeverSendsAnythingToThePage() async throws {
        let (player, page) = try await playingVideo()
        _ = await player.presentVideo(on: .window, host: NSView())
        let before = page.events
        await player.releaseVideo(.pictureInPicture)
        await player.releaseVideo(.inline)
        await player.releaseVideo(.fullScreen)
        #expect(page.events == before && player.surfaces.holder == .window, "no Picture in Picture off, no presentation off, no host change")
    }
    @Test func closingTheVideoWindowReturnsThePictureWithoutChangingPlayback() async throws {
        let (player, page) = try await playingVideo()
        _ = await player.presentVideo(on: .window, host: NSView())
        await player.pause()
        await player.releaseVideo(.window)
        #expect(player.snapshot.intent == false, "closing a window does not resume, restart or stop what the user paused")
        #expect(page.events.suffix(2) == ["present:false", "hidden"])
        #expect(page.loads.count == 1)
    }
    @Test func pictureInPictureIsRefusedWithAReasonWhereWebKitDoesNotSupportIt() async throws {
        let (player, page) = try await playingVideo(pip: "unsupported")
        #expect(await player.presentVideo(on: .pictureInPicture, host: nil) == nil)
        #expect(player.videoNotice?.contains("not available") == true && player.surfaces.holder == nil)
        #expect(!page.events.contains("pip:true"), "the page was never asked")
    }
    @Test func pictureInPictureTakesThePictureAndGivesItBackWhenTheSystemEndsIt() async throws {
        let (player, page) = try await playingVideo()
        _ = await player.presentVideo(on: .window, host: NSView())
        #expect(await player.presentVideo(on: .pictureInPicture, host: nil) == .moved(from: .window, to: .pictureInPicture))
        #expect(page.events.contains("pip:true") && player.surfaces.activeSurfaces == 1)
        page.send(mediaBody(frames: 4, pip: "active"))
        #expect(player.surfaces.holder == .pictureInPicture, "WebKit confirmed it")
        // The system's own return/close button ends it; the page reports the element left the picture-in-picture mode.
        page.send(mediaBody(frames: 5, pip: "available"))
        #expect(player.surfaces.holder == .window, "the picture returns to the surface that had it, not to nowhere and not to two places")
    }
    /// Rework F4: the page keeps reporting `available` while WebKit is still entering the mode; that is not "the system ended it".
    @Test func aLaggingAvailableReportDuringTheEnteringTransitionDoesNotEndPictureInPicture() async throws {
        let (player, page) = try await playingVideo()
        _ = await player.presentVideo(on: .window, host: NSView())
        _ = await player.presentVideo(on: .pictureInPicture, host: nil)
        for frames in 1...3 { page.send(mediaBody(frames: frames, pip: "available")) }
        #expect(player.surfaces.holder == .pictureInPicture, "still entering: three lagging reports change nothing")
        page.send(mediaBody(frames: 9, pip: "active"))
        page.send(mediaBody(frames: 10, pip: "available"))
        #expect(player.surfaces.holder == .window, "only active -> not active ends it")
    }
    @Test func aPictureInPictureThatNeverBecomesActiveIsReleasedWithAStatedReason() async throws {
        var created: RecordingPage?
        let player = WebMusicPlayer(cookies: StubCookies(), artwork: SilentArtwork(), loadTimeout: .seconds(60), rotationDelay: .milliseconds(20), pictureInPictureTimeout: .milliseconds(60)) { delegate in
            let page = RecordingPage(delegate: delegate); created = page; return page
        }
        await player.play(playlistID: "PLsyntheticV", title: "Mix")
        let page = try unwrap(created)
        page.commitLast(); page.send(stateBody()); page.send(mediaBody())
        _ = await player.presentVideo(on: .window, host: NSView())
        _ = await player.presentVideo(on: .pictureInPicture, host: nil)
        await settle { player.surfaces.holder != .pictureInPicture }
        #expect(player.surfaces.holder == .window && player.videoNotice?.contains("did not enter") == true && page.events.contains("pip:false"))
    }
    @Test func startingAWindowWhilePictureInPictureHoldsItEndsPictureInPictureFirst() async throws {
        let (player, page) = try await playingVideo()
        _ = await player.presentVideo(on: .pictureInPicture, host: nil)
        _ = await player.presentVideo(on: .window, host: NSView())
        let log = page.events
        let off = try #require(log.firstIndex(of: "pip:false")), host = try #require(log.lastIndex(of: "host"))
        #expect(off < host && player.surfaces.holder == .window)
    }
    @Test func aPictureInPictureThatWebKitRefusesLeavesTheOwnerUnchanged() async throws {
        let (player, page) = try await playingVideo()
        page.pictureInPictureReply = .rejected
        _ = await player.presentVideo(on: .window, host: NSView())
        #expect(await player.presentVideo(on: .pictureInPicture, host: nil) == nil)
        #expect(player.surfaces.holder == .window && player.videoNotice != nil)
    }
    @Test func teardownLetsEverySurfaceGoWithThePage() async throws {
        let (player, page) = try await playingVideo()
        _ = await player.presentVideo(on: .window, host: NSView())
        await player.teardown()
        #expect(player.surfaces.holder == nil && player.surfaces.activeSurfaces == 0 && !player.hasPage)
        #expect(page.tornDown == 1 && page.hosts.last! == nil, "the page is detached from the surface before it is torn down")
        #expect(await player.presentVideo(on: .window, host: NSView()) == nil, "nothing can take a picture from a closed player")
    }
    @Test func aFailureLetsTheSurfaceGo() async throws {
        let (player, page) = try await playingVideo()
        _ = await player.presentVideo(on: .window, host: NSView())
        player.pageFailed(.playerStopped)
        await settle { page.tornDown == 1 }
        #expect(player.surfaces.holder == nil && page.tornDown == 1)
    }
    @Test func audioOnlyLetsTheSurfaceGoBeforeSwitchingToTheSongAndCarriesThePosition() async throws {
        let (player, page) = try await playingVideo()
        _ = await player.presentVideo(on: .window, host: NSView())
        let result = await player.selectAudioOnly()
        #expect(result.planValue == .continued(at: 10))
        let log = page.events
        let released = try #require(log.lastIndex(of: "hidden")), routed = try #require(log.lastIndex(of: "router"))
        #expect(released < routed, "the picture is let go BEFORE the song is requested: never a cover over a decoding video")
        let route = try #require(page.commands.last(where: { $0.body == WebMusicScripts.loadTarget }))
        #expect(route.arguments["videoId"] as? String == songA && route.arguments["playlistId"] as? String == "PLsyntheticV")
        // The song starts; its length agrees; the carried position is applied.
        page.send(stateBody(load: 2, position: 0.2, duration: 201, video: songA)); page.send(mediaBody(load: 2, video: songA, kind: "audio", width: 0, height: 0))
        await settle { page.events.last == "seek" }
        let seek = try #require(page.commands.last(where: { $0.body == WebMusicScripts.seek }))
        #expect(seek.arguments["seconds"] as? Double == 10 && player.snapshot.restart == nil && !player.snapshot.hasPicture)
    }
    @Test func aSongWhoseLengthDiffersStartsFromTheBeginningAndSaysWhy() async throws {
        let (player, page) = try await playingVideo()
        _ = await player.selectAudioOnly()
        page.send(stateBody(load: 2, position: 0.2, duration: 330, video: songA)); page.send(mediaBody(load: 2, video: songA, kind: "audio", width: 0, height: 0))
        await settle { player.snapshot.restart != nil }
        #expect(player.snapshot.restart == .timelinesDiffer && !page.commands.contains(where: { $0.body == WebMusicScripts.seek }))
    }
    @Test func audioOnlyWithoutAPublishedAudioVersionKeepsTheVideoAndSaysSo() async throws {
        let (player, page) = try await playingVideo(counterpart: nil)
        _ = await player.presentVideo(on: .window, host: NSView())
        let before = page.events
        let result = await player.selectAudioOnly()
        #expect(result.failureReason == .noAudioVersionPublished && player.videoNotice?.contains("not hidden") == true)
        #expect(page.events == before && player.surfaces.holder == .window, "nothing was covered, switched or reloaded")
    }
    @Test func anUnrelatedAssetRestartsAndNeverCarriesThePosition() async throws {
        let (player, page) = try await playingVideo()
        let plan = await player.switchRepresentation(to: .init(asset: .youTubeMusic(other), representation: .audio))
        #expect(plan == .restart(.noPublishedCounterpart))
        page.send(stateBody(load: 2, position: 0.1, duration: 200, video: other))
        await settle { player.snapshot.restart != nil }
        #expect(player.snapshot.restart == .noPublishedCounterpart && !page.commands.contains(where: { $0.body == WebMusicScripts.seek }))
    }
    @Test func aSwitchIsRefusedDuringAnAdvertisement() async throws {
        let (player, page) = try await playingVideo()
        page.send(stateBody(ad: true))
        let before = page.events
        let result = await player.selectAudioOnly()
        #expect(result.planValue == .refused(.advertisement) && page.events == before)
    }
    @Test func liveCommandsGoThroughTheFixedBodiesAndClamp() async throws {
        let (player, page) = makePlayer()
        await player.play(playlistID: "PLsyntheticL", title: "Live")
        let fake = try unwrap(page())
        fake.commitLast(); fake.send(stateBody(position: 100, duration: 0)); fake.send(mediaBody(kind: "live", start: 0, end: 600))
        await player.seek(99_999)
        #expect(fake.commands.last?.body == WebMusicScripts.seek && fake.commands.last?.arguments["seconds"] as? Double == 600)
        await player.goLive()
        #expect(fake.commands.last?.body == WebMusicScripts.goLive, "behind the edge, Go live runs")
        fake.send(stateBody(position: 599, duration: 0)); fake.send(mediaBody(kind: "live", start: 0, end: 600))
        let count = fake.commands.count
        await player.goLive()
        #expect(fake.commands.count == count && player.refusal == .alreadyLive, "at the edge, nothing is sent")
        await player.previous()
        #expect(fake.commands.last?.body == WebMusicScripts.skip, "Previous on a live stream goes to the previous item, it does not seek")
    }
}
private extension Result where Success == RepresentationTransition.Plan {
    var planValue: RepresentationTransition.Plan? { if case .success(let plan) = self { plan } else { nil } }
}
private extension Result where Failure == RepresentationTransition.AudioOnlyUnavailable {
    var failureReason: RepresentationTransition.AudioOnlyUnavailable? { if case .failure(let reason) = self { reason } else { nil } }
}

// MARK: T17.4 account barrier with a surface attached

@Suite @MainActor struct VideoAuthorityTests {
    @Test func anAccountSwitchWithAVideoSurfaceAttachedStopsThePageAndLeavesNoSurface() async throws {
        var created: [RecordingPage] = []
        let owner = AppPlaybackAuthority(makeMusicPage: { delegate in let page = RecordingPage(delegate: delegate); created.append(page); return page })
        await owner.configureMusic { _ in StubCookies() }
        let (identity, context) = try musicIdentity()
        try await owner.restorePaused(identity, context: context)
        let model = PlaybackModel(authority: owner)
        await model.playMusic(playlistID: "PLsyntheticV", title: "Mix", request: owner.requestOwnedStart())
        let page = try unwrap(created.first), player = try unwrap(model.music)
        page.commitLast(); page.send(stateBody()); page.send(mediaBody())
        _ = await player.presentVideo(on: .window, host: NSView())
        #expect(player.surfaces.holder == .window)
        try await owner.detach(previous: context, barrier: RequestContext(account: nil, accountGeneration: 5, requestGeneration: 0))
        #expect(page.tornDown == 1 && player.surfaces.holder == nil && player.isClosed)
        #expect(model.music == nil, "the playback model released the player")
        #expect(created.count == 1, "no second page was ever created: nothing can play twice")
        let permit = owner.requestOwnedStart()
        let reopened = try? await owner.youtubeMusic(request: permit)
        #expect(reopened == nil, "after the barrier there is no active identity until one is restored")
    }
    @Test func startingOwnedAudioWhileAVideoSurfaceIsAttachedTearsTheYouTubeMusicPlayerDownFirst() async throws {
        var created: [RecordingPage] = []
        // Real-data safety: a scratch directory and an ISOLATED keychain file; the production vault and stores are never opened.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ytmuse-w17-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let vault = try KeychainVault(testNamespace: KeychainVault.applicationNamespace + ".test.video-" + UUID().uuidString.lowercased(),
                                      isolatedKeychainURL: directory.appendingPathComponent("isolated-" + UUID().uuidString + ".keychain-db"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = AppPlaybackAuthority(directory: directory, offlineVault: vault, makeMusicPage: { delegate in let page = RecordingPage(delegate: delegate); created.append(page); return page })
        await owner.configureMusic { _ in StubCookies() }
        let (identity, context) = try musicIdentity()
        try await owner.restorePaused(identity, context: context)
        let model = PlaybackModel(authority: owner, controlledAudioTest: true)
        await model.playMusic(playlistID: "PLsyntheticV", title: "Mix", request: owner.requestOwnedStart())
        let page = try unwrap(created.first), player = try unwrap(model.music)
        page.commitLast(); page.send(stateBody()); page.send(mediaBody())
        _ = await player.presentVideo(on: .fullScreen, host: NSView())
        let ownedVideo = try? await owner.owned(request: owner.requestOwnedStart(), initialGain: 0.001, maximumStartGain: 0.001)
        #expect(ownedVideo != nil)
        #expect(page.tornDown == 1 && player.surfaces.holder == nil && player.isClosed, "one owner: the hidden player and its picture are gone before native playback exists")
        await owner.quit()
        try await vault.destroyIsolatedTestKeychain()
    }
}

// MARK: commands, quality and captions

@Suite @MainActor struct WebMusicVideoCommandTests {
    @Test func everyVideoCommandRunsAFixedBodyWithTypedArgumentsOnly() throws {
        let goLive = try WebMusicCommand.goLive.invocation(), present = try WebMusicCommand.presentVideo(true).invocation(), pip = try WebMusicCommand.pictureInPicture(false).invocation()
        let quality = try WebMusicCommand.quality("hd720").invocation(), captions = try WebMusicCommand.captions(true).invocation()
        #expect(goLive.body == WebMusicScripts.goLive && goLive.arguments.isEmpty)
        #expect(present.body == WebMusicScripts.presentVideo && present.arguments as? [String: Bool] == ["on": true])
        #expect(pip.body == WebMusicScripts.pictureInPicture && pip.arguments as? [String: Bool] == ["on": false])
        #expect(quality.body == WebMusicScripts.quality && quality.arguments as? [String: String] == ["level": "hd720"])
        #expect(captions.body == WebMusicScripts.captions && captions.arguments as? [String: Bool] == ["on": true])
        for hostile in ["HD720", "hd 720", "hd720;alert(1)", "a", "thirteenchars", "", "hd720\n"] {
            #expect(throws: WebMusicCommandError.invalidArgument) { try WebMusicCommand.quality(hostile).invocation() }
        }
    }
    /// The advertising rule, structurally: no W17 script mutes, speeds up, skips or removes anything about an ad.
    @Test func noVideoScriptMutesSpeedsUpSkipsOrHidesAnAd() {
        for (name, body) in [("presentVideo", WebMusicScripts.presentVideo), ("goLive", WebMusicScripts.goLive), ("pictureInPicture", WebMusicScripts.pictureInPicture),
                             ("quality", WebMusicScripts.quality), ("captions", WebMusicScripts.captions), ("seek", WebMusicScripts.seek), ("measure", WebMusicScripts.measureVideo)] {
            for forbidden in ["playbackRate", ".muted =", ".muted=", "skipAd", "ytp-ad-skip", "ytp-ad-overlay-close", "display: none", "display:none", "removeChild"] {
                #expect(!body.contains(forbidden), "\(name) must not contain \(forbidden)")
            }
        }
        #expect(WebMusicScripts.presentVideo.contains("ytp-ad") && WebMusicScripts.presentVideo.contains("video-ads"), "ad overlays are explicitly exempted from hiding")
        #expect(WebMusicScripts.presentVideo.components(separatedBy: "matches(keep)").count == 3, "both sibling passes exempt them")
        #expect(WebMusicScripts.goLive.contains("ytmuseAdShowing()") && WebMusicScripts.seek.contains("ytmuseAdShowing()"), "seeking and Go live are refused inside the page during an ad")
    }
    @Test func qualityAndCaptionsFollowOnlyWhatThePageOffered() async throws {
        let (player, page) = makePlayer()
        await player.play(playlistID: "PLsyntheticV", title: "Mix")
        let fake = try unwrap(page())
        fake.commitLast(); fake.send(stateBody())
        var body = mediaBody(kind: "video"); body["quality"] = "hd720"; body["qualities"] = "hd1080,hd720,large"; body["captions"] = "off"
        fake.send(body)
        #expect(player.snapshot.quality == "hd720" && player.snapshot.qualities == ["hd1080", "hd720", "large"] && player.snapshot.captions == .off)
        let before = fake.commands.count
        await player.setQuality("hd2160")
        #expect(fake.commands.count == before && player.videoNotice?.contains("not one this video offers") == true, "a level the page did not offer is never sent")
        await player.setQuality("large")
        #expect(fake.commands.last?.body == WebMusicScripts.quality && fake.commands.last?.arguments["level"] as? String == "large")
        await player.setCaptions(true)
        #expect(fake.commands.last?.body == WebMusicScripts.captions && fake.commands.last?.arguments["on"] as? Bool == true)
        fake.send(mediaBody(kind: "video"))
        let count = fake.commands.count
        await player.setCaptions(true)
        #expect(fake.commands.count == count && player.videoNotice?.contains("no captions") == true, "no captions offered: nothing is sent")
    }
    @Test func theBridgeBoundsQualityAndCaptions() throws {
        func rejected(_ body: [String: Any]) -> Bool { if case .failure(.malformed) = WebMusicBridge.validate(body, frame: musicFrame, document: 1, load: 1) { true } else { false } }
        var ok = mediaBody(); ok["quality"] = "hd1080"; ok["qualities"] = "hd1080,hd720"; ok["captions"] = "on"
        guard case .media(let sample) = try message(ok).event else { Issue.record("not media"); return }
        #expect(sample.quality == "hd1080" && sample.qualities.count == 2 && sample.captions == .on)
        for (key, value) in [("quality", "HD1080"), ("quality", "hd 1080"), ("qualities", "hd1080,"), ("qualities", "hd1080,BAD"), ("captions", "maybe"), ("quality", String(repeating: "a", count: 13))] {
            var body = mediaBody(); body[key] = value
            #expect(rejected(body), "\(key)=\(value)")
        }
        var many = mediaBody(); many["qualities"] = (0..<13).map { "q\($0 + 10)" }.joined(separator: ",")
        #expect(rejected(many), "more than twelve levels is not a quality list")
        var number = mediaBody(); number["captions"] = 3
        #expect(rejected(number), "a non-string captions state is malformed, not 'unavailable'")
    }
}

// MARK: owned video through the real session (the path the app and its UI test use)

@Suite(.serialized) @MainActor struct OwnedVideoSessionTests {
    /// T17.2 through `PlaybackSession`: the owned video starts from the queue, holds a native handle, audio only stops the decoder through the
    /// session, and an account barrier closes it (the picture and the audio output go with the one owner). Isolated keychain file, gain 0.001.
    @Test func ownedVideoPlaysThroughTheSessionAudioOnlyStopsTheDecoderAndTheBarrierEndsIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ytmuse-w17-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let vault = try KeychainVault(testNamespace: KeychainVault.applicationNamespace + ".test.video-" + UUID().uuidString.lowercased(),
                                      isolatedKeychainURL: directory.appendingPathComponent("isolated-" + UUID().uuidString + ".keychain-db"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = AppPlaybackAuthority(directory: directory, offlineVault: vault)
        let session = try await owner.owned(request: owner.requestOwnedStart(), initialGain: 0.001, maximumStartGain: 0.001)
        try await session.startVideoMeasurement()
        try await session.startOwnedMedia([OwnedMedia.videoItem])
        var handle: NativeVideoHandle?
        for _ in 0..<200 where handle == nil { handle = await session.videoHandle(); try await Task.sleep(for: .milliseconds(50)) }
        let native = try unwrap(handle)
        #expect(native.hasVideoTrack && native.decoding && native.presentationSize == CGSize(width: 480, height: 270))
        try await Task.sleep(for: .milliseconds(1500))
        let playing = await session.videoFramesDelivered()
        #expect(playing >= 10, "frames reach the decoder output while the owned video plays (\(playing))")
        #expect(try await session.snapshot().appliedGain <= 0.001 + 1e-6, "the owned video never exceeds the quiet gain")
        try await session.setVideoDecoding(false)
        try await Task.sleep(for: .milliseconds(500))
        let stopped = await session.videoFramesDelivered()
        try await Task.sleep(for: .milliseconds(1200))
        #expect(await session.videoFramesDelivered() - stopped <= 1, "audio only through the session stops the decoder")
        #expect(try #require(await session.videoHandle()).decoding == false)
        try await session.setVideoDecoding(true)
        try await Task.sleep(for: .milliseconds(1200))
        #expect(await session.videoFramesDelivered() - stopped >= 8, "and video decodes again")
        // The account barrier closes the one native owner: no handle, no frames, nothing left to hold a surface.
        try await owner.detach(previous: ownedContext(), barrier: RequestContext(account: nil, accountGeneration: 9, requestGeneration: 0))
        #expect(await session.isClosed())
        #expect(await session.videoHandle() == nil)
        let after = await session.videoFramesDelivered()
        try await Task.sleep(for: .milliseconds(600))
        #expect(await session.videoFramesDelivered() == after, "no decoder runs after the barrier")
        await owner.quit()
        try await vault.destroyIsolatedTestKeychain()
    }
    private func ownedContext() -> RequestContext { RequestContext(account: OwnedMedia.account, accountGeneration: 1, requestGeneration: 0) }
}

// MARK: rework 1: reasons, decoder positive control, audio version with a picture, song -> video

@Suite @MainActor struct WebMusicReworkTests {
    @Test func aPageThatDidNotSayWhatThisIsGetsItsOwnReasonNotNothingPlaying() async throws {
        let (player, page) = makePlayer()
        await player.play(playlistID: "PLsyntheticV", title: "Mix")
        let fake = try unwrap(page())
        fake.commitLast(); fake.send(stateBody())   // no media message: kind unknown
        #expect(player.snapshot.representation == nil && player.snapshot.audioOnlyUnavailable == .presentationUnknown)
        let before = fake.events
        let result = await player.selectAudioOnly()
        #expect(result.failureReason == .presentationUnknown && player.videoNotice?.contains("did not say") == true)
        #expect(!(player.videoNotice ?? "").contains("Nothing is playing") && fake.events == before)
        // The other states each carry their own reason.
        fake.send(mediaBody(kind: "video", counterpart: nil))
        #expect(player.snapshot.audioOnlyUnavailable == .noAudioVersionPublished)
        fake.send(mediaBody(kind: "video", counterpart: songA))
        #expect(player.snapshot.audioOnlyUnavailable == nil)
        #expect(WebMusicSnapshot().audioOnlyUnavailable == .nothingPlaying)
    }
    /// Rework F3: web decoding is reported TRUE when frames advance and FALSE once they go stale. A hard-coded value fails one of the two.
    @Test func decodingFollowsTheFrameCounterBothWays() async throws {
        var clock = 100.0
        let (player, page) = try await playingVideo()
        player.monotonicSeconds = { clock }
        let fake = page
        for (step, frames) in [0, 12, 24, 36].enumerated() { clock = 100 + Double(step) * 0.5; fake.send(mediaBody(frames: frames)) }
        #expect(player.videoActivity.decoding && player.videoActivity.advances >= 3 && player.videoActivity.frames == 36, "advancing frames: decoding")
        clock = 104; player.refreshVideoActivity()
        #expect(!player.videoActivity.decoding, "no advance for longer than the stale window: not decoding")
        clock = 105; fake.send(mediaBody(frames: 48))
        #expect(player.videoActivity.decoding, "advancing again: decoding again")
        fake.send(mediaBody(frames: 0, pip: "available"))
        #expect(!player.videoActivity.decoding, "a counter that restarts is a new element, not an advance")
    }
    /// A zero counter alone is NOT evidence of anything: without a presented document no frame is ever counted.
    @Test func aCounterThatNeverAdvancesIsNeverReportedAsDecoding() async throws {
        var clock = 10.0
        let (player, page) = try await playingVideo()
        player.monotonicSeconds = { clock }
        for step in 0..<4 { clock = 10 + Double(step); page.send(mediaBody(frames: 0)) }
        #expect(!player.videoActivity.decoding && player.videoActivity.frames == 0)
    }
    @Test func anAudioVersionThatStillCarriesAPictureSaysTheDecoderMayNotHaveStopped() async throws {
        let (player, page) = try await playingVideo()
        _ = await player.selectAudioOnly()
        page.send(stateBody(load: 2, position: 0.2, duration: 201, video: songA))
        page.send(mediaBody(load: 2, video: songA, kind: "audio", width: 640, height: 360))
        #expect(player.videoNotice?.contains("still carries a picture") == true && player.snapshot.hasPicture)
    }
    @Test func anAudioVersionWithoutAPictureRaisesNoNotice() async throws {
        let (player, page) = try await playingVideo()
        _ = await player.selectAudioOnly()
        page.send(stateBody(load: 2, position: 0.2, duration: 201, video: songA))
        page.send(mediaBody(load: 2, video: songA, kind: "audio", width: 0, height: 0))
        #expect(player.videoNotice == nil && !player.snapshot.hasPicture)
    }
    /// Rework F8: from the song back to the published video version, carrying the position for a published pair.
    @Test func aSongCanGoBackToItsPublishedVideo() async throws {
        let (player, page) = try await playingVideo(kind: "audio", counterpart: videoA, current: songA)
        #expect(player.snapshot.counterpartRepresentation == .video)
        let plan = await player.selectVideo()
        #expect(plan == .continued(at: 10))
        let route = try unwrap(page.commands.last(where: { $0.body == WebMusicScripts.loadTarget }))
        #expect(route.arguments["videoId"] as? String == videoA)
        let none = try await playingVideo(kind: "audio", counterpart: nil, current: songA)
        #expect(await none.0.selectVideo() == nil && none.0.videoNotice?.contains("no video version") == true)
    }
}
private extension Result where Failure == RepresentationTransition.AudioOnlyUnavailable {
    var failureReason2: RepresentationTransition.AudioOnlyUnavailable? { if case .failure(let reason) = self { reason } else { nil } }
}

// MARK: rework 1 (F2): the surface is not interactive (real AppKit)

private final class RecordingChild: NSView {
    var received: [String] = []
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { received.append("mouseDown") }
    override func rightMouseDown(with event: NSEvent) { received.append("rightMouseDown") }
    override func keyDown(with event: NSEvent) { received.append("keyDown") }
    override func scrollWheel(with event: NSEvent) { received.append("scroll") }
    override func menu(for event: NSEvent) -> NSMenu? { received.append("menu"); return NSMenu() }
}

@Suite @MainActor struct VideoSurfaceInputTests {
    private func window() -> (NSWindow, VideoPictureView, RecordingChild) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let host = VideoPictureView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let child = RecordingChild(frame: host.bounds); host.addSubview(child)
        window.contentView = host
        return (window, host, child)
    }
    @Test func theSurfaceAnswersNoHitTestAcceptsNoFirstResponderAndOffersNoMenu() {
        let (window, host, child) = window()
        for point in [NSPoint(x: 160, y: 90), NSPoint(x: 1, y: 1), NSPoint(x: 319, y: 179)] { #expect(host.hitTest(point) == nil, "no point of the surface hits anything") }
        #expect(!host.acceptsFirstResponder && !host.acceptsFirstMouse(for: nil) && host.menu == nil)
        _ = child
    }
    @Test func syntheticClicksKeysAndScrollsSentToTheWindowNeverReachTheContent() throws {
        let (window, host, child) = window()
        _ = host
        let centre = NSPoint(x: 160, y: 90)
        func mouse(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: centre, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
        }
        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown] { if let event = mouse(type) { window.sendEvent(event) } }
        if let key = NSEvent.keyEvent(with: .keyDown, location: centre, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49) {
            window.sendEvent(key)
        }
        #expect(child.received.isEmpty, "nothing reached the content: \(child.received)")
    }
}
