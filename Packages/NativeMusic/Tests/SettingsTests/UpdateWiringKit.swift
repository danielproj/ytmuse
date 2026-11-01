import Testing
import CryptoKit
import Foundation
@testable import Updates

/// W30. A complete updater behind the Settings rows: a signed feed that offers 1.2.0 over a made-up disk image, an extractor that "opens" it into a bundle of that
/// version, a signature check that accepts it, a playback flag and a recording relauncher. Every key is a throwaway made here and everything lives under the rig's scratch
/// folder; nothing touches the network, the real app or a real store. The effect checks of the two update rows drive THIS controller only through the settings store.
final class KitNetwork: UpdateNetwork, @unchecked Sendable {
    private let lock = NSLock()
    private var feeds = 0, assets = 0
    var feed = Data(), asset = Data()
    var feedRequests: Int { lock.withLock { feeds } }
    var assetRequests: Int { lock.withLock { assets } }
    private func count(feed isFeed: Bool) { lock.withLock { if isFeed { feeds += 1 } else { assets += 1 } } }
    func get(_ request: URLRequest, maxBytes: Int) async throws -> Data { count(feed: true); return feed }
    func download(_ request: URLRequest, to destination: URL, maxBytes: Int) async throws { count(feed: false); try asset.write(to: destination) }
}
private struct KitExtractor: DiskImageExtracting {
    func extractApp(from image: URL, into directory: URL) throws -> URL {
        let app = directory.appendingPathComponent("YTMuse.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try writePlist(app, version: "1.2.0", build: "120")
        return app
    }
}
private struct KitSignature: CodeSignatureChecking { func verify(app: URL) throws {} }
private func writePlist(_ app: URL, version: String, build: String) throws {
    let plist: [String: Any] = ["CFBundleIdentifier": "test.settings.updates", "CFBundleShortVersionString": version, "CFBundleVersion": build]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
}
@MainActor final class KitRelauncher: AppRelaunching { var relaunched: [URL] = []; func relaunch(updatedAppAt url: URL) { relaunched.append(url) } }
final class KitPlayback: @unchecked Sendable { private let lock = NSLock(); private var on = false
    var playing: Bool { get { lock.withLock { on } } set { lock.withLock { on = newValue } } } }

@MainActor final class UpdateKit {
    let network = KitNetwork()
    let relauncher = KitRelauncher()
    let playback = KitPlayback()
    let installed: URL
    let controller: UpdateController
    static let repository = "example-owner/example-repo"
    init(defaults: UserDefaults, scratch: URL, configured: Bool = true) throws {
        let key = Curve25519.Signing.PrivateKey()
        let asset = Data("a pretend disk image".utf8)
        network.asset = asset
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        let digest = SHA256.hash(data: asset).map { String(format: "%02x", $0) }.joined()
        let release: [String: Any] = [
            "version": "1.2.0", "build": 120, "minimumSystemVersion": "27.0", "publishedAt": iso.string(from: Date().addingTimeInterval(-7200)),
            "notesURL": "https://github.com/\(Self.repository)/releases/tag/v1.2.0",
            "asset": ["url": "https://github.com/\(Self.repository)/releases/download/v1.2.0/YTMuse-1.2.0.dmg", "length": asset.count, "sha256": digest] as [String: Any],
            "provenance": ["repository": Self.repository, "tag": "v1.2.0", "commit": String(repeating: "c", count: 40), "sbomSHA256": String(repeating: "d", count: 64)] as [String: Any],
        ]
        let payload: [String: Any] = ["schema": 1, "channel": "stable", "sequence": 1, "issuedAt": iso.string(from: Date().addingTimeInterval(-3600)),
                                      "expiresAt": iso.string(from: Date().addingTimeInterval(86_400 * 30)), "releases": [release]]
        network.feed = try FeedSigner.sign(payload: JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]), with: key)
        let policy = try #require(UpdateTrustPolicy(publicKeys: [key.publicKey.rawRepresentation], repository: Self.repository))
        let configuration = UpdateConfiguration(policy: policy, feedURL: URL(string: "https://github.com/\(Self.repository)/releases/latest/download/feed.json")!)
        let applications = scratch.appendingPathComponent("Applications", isDirectory: true)
        installed = applications.appendingPathComponent("YTMuse.app")
        try FileManager.default.createDirectory(at: installed.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try writePlist(installed, version: "1.0.0", build: "100")
        let running = RunningApplication(version: AppVersion("1.0.0")!, build: 100, bundleIdentifier: "test.settings.updates", system: SystemVersion(major: 27, minor: 2))
        let stager = UpdateStager(root: scratch.appendingPathComponent("Updates", isDirectory: true), network: network, extractor: KitExtractor(), signature: KitSignature())
        let flag = playback
        controller = UpdateController(configuration: configured ? configuration : nil, running: running, installedBundle: installed, store: UserDefaultsUpdateStateStore(defaults: defaults), network: network,
                                      stager: stager, installer: BundleInstaller(signature: KitSignature()), relauncher: relauncher, playbackActive: { flag.playing })
    }
    var installedVersion: String? { (try? PlistBundleInfoReader().read(app: installed))?.version }
}
