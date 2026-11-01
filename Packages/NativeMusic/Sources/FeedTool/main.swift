import CryptoKit
import Foundation
import Updates

// ytmuse-feed: the release tooling for the signed update feed (Docs/Distribution.md). It never runs inside the app and is not an app dependency.
//   keygen        make a signing key pair OUTSIDE any git work tree (the private key is a secret: the operator creates the real one at release time)
//   make-payload  describe one release from the asset file (computes its length and SHA-256)
//   sign          sign a payload with a private key file
//   verify        verify a feed exactly as the app does, for a given running version

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}
func options(_ arguments: [String]) -> [String: String] {
    var result: [String: String] = [:]
    var index = 0
    while index < arguments.count {
        let name = arguments[index]
        guard name.hasPrefix("--"), index + 1 < arguments.count else { fail("bad arguments near \(name)", code: 64) }
        result[String(name.dropFirst(2))] = arguments[index + 1]
        index += 2
    }
    return result
}
func required(_ o: [String: String], _ name: String) -> String { o[name] ?? { fail("missing --\(name)", code: 64) }() }
func insideGitWorkTree(_ url: URL) -> Bool {
    var directory = url.deletingLastPathComponent().resolvingSymlinksInPath()
    while true {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) { return true }
        let parent = directory.deletingLastPathComponent()
        if parent.path == directory.path { return false }
        directory = parent
    }
}
func isoString(_ date: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.string(from: date) }
func isoDate(_ text: String) -> Date {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
    guard let d = f.date(from: text) else { fail("not a UTC time like 2026-01-01T00:00:00Z: \(text)", code: 64) }
    return d
}
func sha256(of file: URL) -> (String, Int) {
    guard let handle = try? FileHandle(forReadingFrom: file) else { fail("cannot read \(file.path)") }
    defer { try? handle.close() }
    var hasher = SHA256(); var count = 0
    while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk); count += chunk.count }
    return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), count)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail("usage: ytmuse-feed keygen|make-payload|sign|verify ...", code: 64) }
let o = options(Array(arguments.dropFirst()))

switch command {
case "keygen":
    let privateURL = URL(fileURLWithPath: required(o, "private-out")), publicURL = URL(fileURLWithPath: required(o, "public-out"))
    if insideGitWorkTree(privateURL) { fail("refusing to write a private key inside a git work tree", code: 65) }
    guard !FileManager.default.fileExists(atPath: privateURL.path) else { fail("refusing to overwrite \(privateURL.lastPathComponent)", code: 65) }
    let key = Curve25519.Signing.PrivateKey()
    guard FileManager.default.createFile(atPath: privateURL.path, contents: Data((key.rawRepresentation.base64EncodedString() + "\n").utf8), attributes: [.posixPermissions: 0o600]) else { fail("cannot write the private key") }
    try Data((key.publicKey.rawRepresentation.base64EncodedString() + "\n").utf8).write(to: publicURL)
    print("key id: \(FeedFormat.keyID(forPublicKey: key.publicKey.rawRepresentation))")
case "make-payload":
    let asset = URL(fileURLWithPath: required(o, "asset")), sbom = URL(fileURLWithPath: required(o, "sbom"))
    guard let version = AppVersion(required(o, "version")) else { fail("bad --version", code: 64) }
    let repository = required(o, "repository")
    let (assetDigest, length) = sha256(of: asset)
    let (sbomDigest, _) = sha256(of: sbom)
    let published = o["published"] ?? isoString(Date())
    let payload: [String: Any] = [
        "schema": 1, "channel": o["channel"] ?? "stable", "sequence": Int(required(o, "sequence")) ?? { fail("bad --sequence", code: 64) }(),
        "issuedAt": o["issued"] ?? isoString(Date()), "expiresAt": required(o, "expires"),
        "releases": [[
            "version": version.description, "build": Int(required(o, "build")) ?? { fail("bad --build", code: 64) }(),
            "minimumSystemVersion": o["minimum-system"] ?? "27.0", "publishedAt": published,
            "notesURL": "https://github.com/\(repository)/releases/tag/v\(version)",
            "asset": ["url": "https://github.com/\(repository)/releases/download/v\(version)/YTMuse-\(version).dmg", "length": length, "sha256": assetDigest],
            "provenance": ["repository": repository, "tag": "v\(version)", "commit": required(o, "commit"), "sbomSHA256": sbomDigest],
        ] as [String: Any]],
    ]
    try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: URL(fileURLWithPath: required(o, "out")))
case "sign":
    let text = try String(contentsOf: URL(fileURLWithPath: required(o, "key")), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw = Data(base64Encoded: text), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("not a private key file") }
    let payload = try Data(contentsOf: URL(fileURLWithPath: required(o, "payload")))
    try FeedSigner.sign(payload: payload, with: key).write(to: URL(fileURLWithPath: required(o, "out")))
case "verify":
    let feed = try Data(contentsOf: URL(fileURLWithPath: required(o, "feed")))
    let keyText = try String(contentsOf: URL(fileURLWithPath: required(o, "public-key")), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw = Data(base64Encoded: keyText), let policy = UpdateTrustPolicy(publicKeys: [raw], repository: required(o, "repository")) else { fail("bad public key or repository", code: 64) }
    guard let current = AppVersion(required(o, "current-version")), let system = SystemVersion(o["system"] ?? "27.0") else { fail("bad version", code: 64) }
    let running = RunningApplication(version: current, build: Int(o["current-build"] ?? "1") ?? 1, bundleIdentifier: "feed-tool", system: system)
    do {
        let result = try FeedVerifier.verify(feed, policy: policy, running: running, now: o["now"].map(isoDate) ?? Date(), lastAcceptedSequence: Int(o["last-sequence"] ?? "0") ?? 0)
        if let offer = result.offer { print("OFFER \(offer.version) build \(offer.build) sequence \(result.payload.sequence)") } else { print("UP-TO-DATE sequence \(result.payload.sequence)") }
    } catch let rejection as UpdateRejection {
        print("REJECTED \(rejection.code)")
        exit(2)
    }
default:
    fail("unknown command \(command)", code: 64)
}
