import CryptoKit
import Foundation
@testable import Updates

/// Test support (W30). Every key here is a throwaway generated in the test process; every file lives in a per-test temporary folder removed afterwards.
/// No real feed, no real key, no network.
let repository = "example-owner/example-repo"
let testNow = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15

func iso(_ date: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.string(from: date) }

/// TH2 (W30 D-L4): a class, so the folder goes away when its owner does. It was a struct created as a stored property of the suite, i.e. once for EVERY test in the suite, but removed
/// only by the tests that remembered `defer { scratch.remove() }`; every other test (and every test that threw first) left an empty `ytmuse-w30-<uuid>` folder in the temporary directory.
/// Swift Testing makes a fresh suite instance per test and releases it afterwards, so `deinit` removes the folder for all of them. `remove()` stays for a test that wants it earlier.
final class ScratchFolder: @unchecked Sendable {
    let url: URL
    init() { url = FileManager.default.temporaryDirectory.appendingPathComponent("ytmuse-w30-" + UUID().uuidString, isDirectory: true); try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    func remove() { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path); try? FileManager.default.removeItem(at: url) }
    deinit { remove() }
}

/// A feed made by hand so that each test can break exactly one thing.
struct FeedBuilder {
    var key = Curve25519.Signing.PrivateKey()
    var channel = "stable"
    var sequence = 10
    var issued = testNow.addingTimeInterval(-3600)
    var expires = testNow.addingTimeInterval(86_400 * 30)
    var releases: [[String: Any]] = [FeedBuilder.release(version: "1.2.0", build: 120)]

    static func release(version: String, build: Int, repository: String = repository, minimumSystem: String = "27.0") -> [String: Any] {
        [
            "version": version, "build": build, "minimumSystemVersion": minimumSystem, "publishedAt": iso(testNow.addingTimeInterval(-7200)),
            "notesURL": "https://github.com/\(repository)/releases/tag/v\(version)",
            "asset": ["url": "https://github.com/\(repository)/releases/download/v\(version)/YTMuse-\(version).dmg", "length": 1000, "sha256": String(repeating: "ab", count: 32)] as [String: Any],
            "provenance": ["repository": repository, "tag": "v\(version)", "commit": String(repeating: "c", count: 40), "sbomSHA256": String(repeating: "de", count: 32)] as [String: Any],
        ]
    }
    var payloadObject: [String: Any] {
        ["schema": 1, "channel": channel, "sequence": sequence, "issuedAt": iso(issued), "expiresAt": iso(expires), "releases": releases]
    }
    func payloadBytes() -> Data { try! JSONSerialization.data(withJSONObject: payloadObject, options: [.sortedKeys, .withoutEscapingSlashes]) }
    func signed() -> Data { try! FeedSigner.sign(payload: payloadBytes(), with: key) }
    /// A signed feed whose payload object was changed after the fact by `edit`.
    func signed(editing edit: (inout [String: Any]) -> Void) -> Data {
        var object = payloadObject
        edit(&object)
        return try! FeedSigner.sign(payload: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), with: key)
    }
    var policy: UpdateTrustPolicy { UpdateTrustPolicy(publicKeys: [key.publicKey.rawRepresentation], repository: repository)! }
}

let runningApp = RunningApplication(version: AppVersion("1.0.0")!, build: 100, bundleIdentifier: "test.ytmuse.updates", system: SystemVersion(major: 27, minor: 2))

func envelopeObject(_ feed: Data) -> [String: Any] { try! JSONSerialization.jsonObject(with: feed) as! [String: Any] }
func envelopeData(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) }

// MARK: fakes

final class FakeNetwork: UpdateNetwork, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    var feed: Data
    var asset = Data()
    var failure: (any Error)?
    var onDownload: (() -> Void)?
    init(feed: Data = Data()) { self.feed = feed }
    func get(_ request: URLRequest, maxBytes: Int) async throws -> Data {
        record(request)
        if let failure { throw failure }
        return feed
    }
    func download(_ request: URLRequest, to destination: URL, maxBytes: Int) async throws {
        record(request)
        onDownload?()
        if let failure { throw failure }
        try asset.write(to: destination)
    }
    private func record(_ request: URLRequest) { lock.lock(); requests.append(request); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
}

/// Writes a bundle tree that carries an Info.plist and a marker file naming its version.
func makeApp(at url: URL, identifier: String = runningApp.bundleIdentifier, version: String, build: Int) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    try fm.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version, "CFBundleVersion": String(build), "CFBundleExecutable": "YTMuse", "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
    try? fm.removeItem(at: url.appendingPathComponent("Contents/MacOS/YTMuse"))
    try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: url.appendingPathComponent("Contents/MacOS/YTMuse"))
    try Data("version \(version)".utf8).write(to: url.appendingPathComponent("Contents/Resources/marker.txt"))
}
func marker(of app: URL) -> String? { try? String(contentsOf: app.appendingPathComponent("Contents/Resources/marker.txt"), encoding: .utf8) }

/// Extractor that "opens" the asset by building the app the test says it contains.
final class FakeExtractor: DiskImageExtracting, @unchecked Sendable {
    var calls = 0
    var version = "1.2.0", build = 120, identifier = runningApp.bundleIdentifier
    func extractApp(from image: URL, into directory: URL) throws -> URL {
        calls += 1
        let app = directory.appendingPathComponent("YTMuse.app")
        try makeApp(at: app, identifier: identifier, version: version, build: build)
        return app
    }
}
final class FakeSignature: CodeSignatureChecking, @unchecked Sendable {
    var calls = 0
    var failing = false
    func verify(app: URL) throws { calls += 1; if failing { throw UpdateRejection.codeSignature("invalid") } }
}
final class RecordingRelauncher: AppRelaunching, @unchecked Sendable {
    var relaunched: [URL] = []
    @MainActor func relaunch(updatedAppAt url: URL) { relaunched.append(url) }
}
final class PlaybackFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    var playing = false
    /// Answers `playing`, but after `flipAfter` asks it starts answering `true`: playback began between two checks.
    var flipAfter: Int?
    private var asks = 0
    func ask() -> Bool {
        lock.lock(); defer { lock.unlock() }
        asks += 1
        if let flipAfter, asks > flipAfter { return true }
        return playing
    }
    var asked: Int { lock.lock(); defer { lock.unlock() }; return asks }
}
