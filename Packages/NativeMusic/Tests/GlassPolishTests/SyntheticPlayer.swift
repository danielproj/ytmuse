import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Playback

/// A hidden-player stand-in for the audit: a fake page fed validated state messages, a fake cookie source and generated
/// artwork. No network, no account, no WebKit. Every title and name is plainly synthetic.
@MainActor final class SyntheticPage: WebMusicPage {
    weak var delegate: (any WebMusicPageDelegate)?
    var loads: [URL] = []
    init(delegate: any WebMusicPageDelegate) { self.delegate = delegate }
    func install(cookies: [HTTPCookie]) async {}
    func load(_ url: URL) { loads.append(url) }
    func run(_ invocation: WebMusicCommand.Invocation) async -> WebMusicCommandReply { .ok }
    func setThrottled(_ throttled: Bool) {}
    func teardown() async {}
    func commitLast() { delegate?.pageCommitted(document: WebMusicNavigation.document(of: loads.last)) }
    func send(_ body: [String: Any]) {
        delegate?.page(received: body, from: WebMusicFrame(isMainFrame: true, scheme: "https", host: "music.youtube.com", port: 0))
    }
}
actor SyntheticCookies: WebMusicCookieSource {
    func playerCookies() async throws -> [HTTPCookie] { [] }
    func recordRotation(_ cookies: [HTTPCookie]) async {}
}
/// A warm gradient generated here; never a real cover.
struct SyntheticArtwork: WebMusicArtworkLoading {
    let top: (Double, Double, Double), bottom: (Double, Double, Double)
    func artwork(_ url: URL) async -> Data? {
        let edge = 512
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: space, colors: [CGColor(red: top.0, green: top.1, blue: top.2, alpha: 1), CGColor(red: bottom.0, green: bottom.1, blue: bottom.2, alpha: 1)] as CFArray, locations: [0, 1])
        else { return nil }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: edge, y: edge), options: [])
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
        context.fillEllipse(in: CGRect(x: 96, y: 96, width: 320, height: 320))
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

struct SyntheticTrack {
    var title = "Synthetic Song"; var artist = "Synthetic Artist"; var position = 83.0; var duration = 215.0; var ad = false; var playing = true
    /// A live stream behind the live edge: the widest accessory set (LIVE badge and Go Live beside volume and queue).
    var live = false
    var colors: ((Double, Double, Double), (Double, Double, Double)) = ((0.96, 0.45, 0.20), (0.62, 0.12, 0.45))
    /// What the page's own player bar reports for shuffle and repeat (nil: it does not say).
    var shuffle: Bool? = nil
    var repeatMode: String? = nil
    static let playing = SyntheticTrack()
    /// Shuffle on and repeat-one: both accent glyphs with their dots.
    static let shuffledRepeating = SyntheticTrack(shuffle: true, repeatMode: "one")
    static let advertisement = SyntheticTrack(title: "Advertisement", artist: "", position: 6, duration: 15, ad: true)
    static let liveStream = SyntheticTrack(title: "Synthetic Live Stream", artist: "Synthetic Channel", position: 83, duration: 0, live: true, colors: ((0.1, 0.7, 0.6), (0.05, 0.25, 0.4)))
    static let longTitle = SyntheticTrack(title: "A Synthetic Title Long Enough To Test Truncation Across Every Supported Window Width", artist: "Synthetic Artist With A Long Name And Featured Guests", position: 12, duration: 640, playing: false,
                                          colors: ((0.2, 0.55, 0.95), (0.05, 0.15, 0.45)))
}

@MainActor enum SyntheticPlayback {
    /// A player already playing `track`, as the hidden page would report it.
    static func player(_ track: SyntheticTrack) async -> WebMusicPlayer {
        var page: SyntheticPage?
        let player = WebMusicPlayer(cookies: SyntheticCookies(), artwork: SyntheticArtwork(top: track.colors.0, bottom: track.colors.1), loadTimeout: .seconds(60)) { delegate in
            let created = SyntheticPage(delegate: delegate); page = created; return created
        }
        await player.play(playlistID: "PLsynthetic", title: "Synthetic Mix")
        page?.commitLast()
        var state: [String: Any] = ["type": "state", "doc": 1, "load": 1, "playing": track.playing, "buffering": false, "position": track.position, "duration": track.duration,
                                    "videoId": "SYNTHvid001", "title": track.title, "artist": track.artist, "artwork": "https://lh3.googleusercontent.com/synthetic-art", "ad": track.ad]
        if let shuffle = track.shuffle { state["shuffle"] = shuffle }
        if let repeatMode = track.repeatMode { state["repeat"] = repeatMode }
        page?.send(state)
        if track.live {
            page?.send(["type": "media", "doc": 1, "load": 1, "videoId": "SYNTHvid001", "kind": "live", "seekStart": 0.0, "seekEnd": 120.0, "width": 0, "height": 0, "frames": 0, "pip": "unsupported", "isolated": false])
        }
        for _ in 0..<200 where player.artwork == nil { try? await Task.sleep(for: .milliseconds(10)) }
        return player
    }
}
