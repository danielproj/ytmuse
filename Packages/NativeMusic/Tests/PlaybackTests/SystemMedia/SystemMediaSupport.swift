import AppKit
import AccountSession
import Domain
import Foundation
import MediaPlayer
import OutputRoutes
import Testing
@testable import Features
@testable import Playback
@testable import SystemIntegration
@testable import AppShell

// W23 test support. The Now Playing centre and the remote commands are RECORDING stand-ins (`NowPlayingSystem.recording()`): nothing here reaches the
// Mac's media session, takes its media keys or changes a system media setting. One hosted test (`HostedSystemMediaTests`) uses the real centres.

/// A library the remote layer can ask, with the answer set per command and every press recorded. The real conformer is the shell.
@MainActor final class FakeRemoteLibrary: RemoteLibraryControlling {
    var states: [RemoteCommandKind: RemoteLibraryControlState] = [:]
    private(set) var pressed: [LibraryControl] = []
    private(set) var asked: [RemoteCommandKind] = []
    func remoteLibraryControl(_ kind: RemoteCommandKind) -> RemoteLibraryControlState {
        asked.append(kind)
        return states[kind] ?? .unavailable("not offered")
    }
    func remoteLibraryPress(_ control: LibraryControl) async { pressed.append(control) }
    static func control(_ kind: LibraryControl.Kind, on: Bool = false, video: String = lifecycleVideo) -> LibraryControl {
        let like = MusicItemControls.Like(videoID: video, status: .indifferent, dislikeExposed: true)
        return LibraryControl(kind: kind, key: .rating(videoID: video), isOn: on, intent: .rate(like, to: kind == .dislike ? .dislike : .like), title: kind.rawValue, symbol: "heart")
    }
}

/// The podcast controls, scripted.
@MainActor final class FakeRemoteEpisodes: RemoteEpisodeControlling {
    var episode: RemoteEpisode?
    private(set) var jumps: [Bool] = []
    private(set) var rates: [Double] = []
    func remoteEpisode(for videoID: String) -> RemoteEpisode? { episode?.videoID == videoID ? episode : nil }
    func remoteJump(forward: Bool) async -> Bool { jumps.append(forward); return true }
    func remoteSetRate(_ rate: Double, for episode: RemoteEpisode) async -> Bool { rates.append(rate); return true }
}

/// The one playback owner with a fake hidden page, a RECORDING Now Playing system, and (optionally) a scripted output directory.
@MainActor struct MediaRig {
    let log: PageLog
    let authority: AppPlaybackAuthority
    let model: PlaybackModel
    let system: RecordingNowPlayingSystem
    let identity: LocalIdentity
    let context: RequestContext
    let library: FakeRemoteLibrary
    let episodes: FakeRemoteEpisodes
    let directory: PlaybackScriptedDirectory?
    let controller: OutputController?
    var info: RecordingNowPlayingInfo { system.info }
    var commands: RecordingRemoteCommands { system.commands }
    static func make(outputs: Bool = false, timing: ManualSleepTiming? = nil) async throws -> MediaRig {
        let log = PageLog()
        var clocks: (@MainActor () -> any SleepTimerTiming)?
        if let timing { clocks = { timing } }
        let authority = AppPlaybackAuthority(makeMusicPage: { delegate in let page = FakeMusicPage(delegate: delegate); log.pages.append(page); return page }, makeSleepTiming: clocks)
        await authority.configureMusic { _ in FakeCookieSource() }
        let (identity, context) = try lifecycleIdentity()
        try await authority.restorePaused(identity, context: context)
        let system = NowPlayingSystem.recording()
        let model = PlaybackModel(authority: authority, nowPlaying: NowPlayingCenter(system: system.system))
        let library = FakeRemoteLibrary(), episodes = FakeRemoteEpisodes()
        model.remoteLibrary = library; model.episodes = episodes
        var directory: PlaybackScriptedDirectory?, controller: OutputController?
        if outputs {
            let scripted = PlaybackScriptedDirectory([routeSpeakers, routeBuds], defaultUID: routeBuds.uid)
            let built = OutputController(coordinator: OutputRouteCoordinator(directory: scripted, store: MemoryPreferredRoute()), applier: NoOutputApplier())
            await built.bind(to: model)
            directory = scripted; controller = built
        }
        return MediaRig(log: log, authority: authority, model: model, system: system, identity: identity, context: context, library: library, episodes: episodes,
                        directory: directory, controller: controller)
    }
    /// An explicit Play and the page's first reports.
    @discardableResult func play(state: [String: Any] = lifecycleState()) async throws -> (WebMusicPlayer, FakeMusicPage) {
        _ = await model.playMusic(playlistID: "PLsyntheticLife", title: "Synthetic Mix", request: authority.requestOwnedStart())
        let page = try #require(log.pages.first)
        page.commitLast(); page.send(state)
        return (try #require(model.music), page)
    }
    /// A switch of account: the authority's own barrier.
    func detach() async throws {
        try await authority.detach(previous: context, barrier: RequestContext(account: nil, accountGeneration: 9, requestGeneration: 0))
    }
    func wait(seconds: Double = 1.5, _ condition: @MainActor () -> Bool) async {
        for _ in 0..<Int(seconds * 200) where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

/// A live report from the hidden page: no length, a rewindable window.
func systemMediaLiveBody(video: String = lifecycleVideo) -> [String: Any] {
    ["type": "media", "doc": 1, "load": 1, "kind": "live", "width": 1280, "height": 720, "frames": 0, "pip": "unsupported", "isolated": false,
     "videoId": video, "seekStart": 0.0, "seekEnd": 600.0]
}

func systemMediaPNG(_ edge: Int = 32) -> Data {
    let image = NSImage(size: NSSize(width: edge, height: edge))
    image.lockFocus(); NSColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: edge, height: edge).fill(); image.unlockFocus()
    return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
}

extension Dictionary where Key == String, Value == Any {
    func double(_ key: String) -> Double? { self[key] as? Double }
}
