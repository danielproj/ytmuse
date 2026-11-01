import AccountSession
import AppKit
import Domain
import Foundation
@testable import AppShell
@testable import Playback

// Synthetic, sanitized values only: no real session, cookie, page or network.
let musicFrame = WebMusicFrame(isMainFrame: true, scheme: "https", host: "music.youtube.com", port: 0)
let videoA = "SYNTHvidA01", songA = "SYNTHsngA01", other = "SYNTHother1"

func stateBody(doc: Int = 1, load: Int = 1, playing: Bool = true, position: Double = 10, duration: Double = 200, video: String = videoA, ad: Bool = false) -> [String: Any] {
    ["type": "state", "doc": doc, "load": load, "playing": playing, "buffering": false, "position": position, "duration": duration,
     "videoId": video, "title": "Synthetic", "artist": "Synthetic Artist", "artwork": "", "ad": ad]
}
func mediaBody(doc: Int = 1, load: Int = 1, video: String? = videoA, kind: String = "video", start: Double? = nil, end: Double? = nil, counterpart: String? = nil,
               width: Int = 1920, height: Int = 1080, frames: Int = 0, pip: String = "available", isolated: Bool = false) -> [String: Any] {
    var body: [String: Any] = ["type": "media", "doc": doc, "load": load, "kind": kind, "width": width, "height": height, "frames": frames, "pip": pip, "isolated": isolated]
    if let video { body["videoId"] = video }
    if let start { body["seekStart"] = start }
    if let end { body["seekEnd"] = end }
    if let counterpart { body["counterpart"] = counterpart }
    return body
}
func message(_ body: [String: Any], doc: UInt64 = 1, load: UInt64 = 1) throws -> WebMusicMessage {
    try WebMusicBridge.validate(body, frame: musicFrame, document: doc, load: load).get()
}

/// A page that records every command, load, host change and teardown, in order, so a test can prove what did NOT happen.
@MainActor final class RecordingPage: WebMusicPage {
    weak var delegate: (any WebMusicPageDelegate)?
    var events: [String] = []
    var loads: [URL] = []
    var commands: [WebMusicCommand.Invocation] = []
    var hosts: [NSView?] = []
    var pictureInPictureReply: WebMusicCommandReply = .ok
    var tornDown = 0
    init(delegate: any WebMusicPageDelegate) { self.delegate = delegate }
    func install(cookies: [HTTPCookie]) async { events.append("install") }
    func load(_ url: URL) { loads.append(url); events.append("load") }
    func run(_ invocation: WebMusicCommand.Invocation) async -> WebMusicCommandReply {
        commands.append(invocation)
        switch invocation.body {
        case WebMusicScripts.loadTarget, WebMusicScripts.loadPlaylist: events.append("router"); return .router
        case WebMusicScripts.play: events.append("play"); return .ok
        case WebMusicScripts.pause: events.append("pause"); return .ok
        case WebMusicScripts.seek: events.append("seek"); return .ok
        case WebMusicScripts.goLive: events.append("goLive"); return .ok
        case WebMusicScripts.presentVideo: events.append("present:\(invocation.arguments["on"] as? Bool ?? false)"); return .ok
        case WebMusicScripts.pictureInPicture: events.append("pip:\(invocation.arguments["on"] as? Bool ?? false)"); return pictureInPictureReply
        default: events.append("other"); return .ok
        }
    }
    func setThrottled(_ throttled: Bool) {}
    func teardown() async { tornDown += 1; events.append("teardown") }
    func attachVideo(to host: NSView?) { hosts.append(host); events.append(host == nil ? "hidden" : "host") }
    func commitLast() { delegate?.pageCommitted(document: WebMusicNavigation.document(of: loads.last)) }
    func send(_ body: [String: Any]) { delegate?.page(received: body, from: musicFrame) }
    /// Commands that could start, stop, move or restart the media (everything but the presentation/attachment).
    var mediaCommands: [String] { events.filter { ["load", "router", "play", "pause", "seek", "goLive", "teardown"].contains($0) } }
}
struct SilentArtwork: WebMusicArtworkLoading { func artwork(_ url: URL) async -> Data? { nil } }
actor StubCookies: WebMusicCookieSource {
    func playerCookies() async throws -> [HTTPCookie] { [HTTPCookie(properties: [.name: "SAPISID", .value: "SYNTHETIC-PLAYER-SAPISID", .domain: ".youtube.com", .path: "/", .secure: "TRUE"])!] }
    func recordRotation(_ cookies: [HTTPCookie]) async {}
}

@MainActor func makePlayer(timeout: Duration = .seconds(60)) -> (WebMusicPlayer, () -> RecordingPage?) {
    var created: RecordingPage?
    let player = WebMusicPlayer(cookies: StubCookies(), artwork: SilentArtwork(), loadTimeout: timeout, rotationDelay: .milliseconds(20)) { delegate in
        let page = RecordingPage(delegate: delegate); created = page; return page
    }
    return (player, { created })
}
/// A player that is playing a video with a published song counterpart, as the page would report it.
@MainActor func playingVideo(kind: String = "video", pip: String = "available", counterpart: String? = songA, current: String = videoA) async throws -> (WebMusicPlayer, RecordingPage) {
    let (player, page) = makePlayer()
    await player.play(playlistID: "PLsyntheticV", title: "Synthetic Mix")
    let fake = try unwrap(page())
    fake.commitLast(); fake.send(stateBody(video: current)); fake.send(mediaBody(video: current, kind: kind, counterpart: counterpart, pip: pip))
    return (player, fake)
}
@MainActor func settle(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
}
struct Missing: Error {}
func unwrap<T>(_ value: T?) throws -> T { guard let value else { throw Missing() }; return value }

func musicIdentity() throws -> (LocalIdentity, RequestContext) {
    let id = UUID()
    let context = try AccountContext(accountID: id, channelID: ID("UCsyntheticVideo"), region: "US")
    let account = try Account(id: id, serviceIdentity: ServiceID("UCsyntheticVideo"), context: context, displayName: "Synthetic Listener", credential: try CredentialReference("synthetic-ref"))
    return (LocalIdentity(account: account, state: .connected), RequestContext(account: context, accountGeneration: 4, requestGeneration: 0))
}
