import Foundation
import Testing

// W29 support. Canaries are fixed strings that stand for the things a log, an error, an export, a notification, a widget, a Spotlight entry, a Handoff activity or a
// shared link must never carry. Every canary contains the marker "cnry", which survives percent-encoding, JSON escaping and case folding, so ONE lowercase search finds
// any survivor in any encoding. Base64 forms are checked separately because they do not contain the marker.

enum CanaryKind: String, CaseIterable, Sendable { case cookie, token, email, playlist, search, signedURL }

enum Canaries {
    static let cookie = "CNRYcookie7f3a91c2d4e5b6a7"
    // synthetic canary, not a real credential
    static let token = "ya29.a0CNRYtoken_9b2e7d41a8c6f03d5e1b7c4d2a9f8e6b3c1d0a5f7e9b2c4d6a8f0e1b3c5d7"
    static let email = "pat.cnry.7f3a@example.org"
    static let playlist = "Zebra Cnry Mixtape 7f3a"
    static let search = "quiet cnry whale songs 7f3a"
    static let signedURL = "https://rr4---sn-cnry7f3a.googlevideo.com/videoplayback?expire=1999999999&sig=CNRYsig7f3a&id=o-CNRYid7f3a"
    static func value(_ kind: CanaryKind) -> String {
        switch kind {
        case .cookie: cookie
        case .token: token
        case .email: email
        case .playlist: playlist
        case .search: search
        case .signedURL: signedURL
        }
    }
    static let all: [String] = CanaryKind.allCases.map(value)
    /// Every text form a canary takes on its way through a URL, a header, JSON or an HTML page.
    static func forms(of text: String) -> [String] {
        var result = [text]
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        if let once = text.addingPercentEncoding(withAllowedCharacters: unreserved) {
            result.append(once)
            if let twice = once.addingPercentEncoding(withAllowedCharacters: unreserved) { result.append(twice) }
            result.append(once.replacingOccurrences(of: "%20", with: "+"))
        }
        if let data = try? JSONEncoder().encode(text), let json = String(data: data, encoding: .utf8) { result.append(String(json.dropFirst().dropLast())) }
        result.append(text.uppercased())
        return Array(Set(result))
    }
    /// What is left of any canary in `text`: the marker in any encoding or case, a canary's base64 form, or a hex form.
    static func survivors(in text: String) -> [String] {
        let lowered = text.lowercased()
        var found: [String] = []
        if lowered.contains("cnry") { found.append("cnry") }
        if lowered.contains("7f3a") { found.append("7f3a") }
        for canary in all {
            let base64 = Data(canary.utf8).base64EncodedString()
            if text.contains(base64) { found.append("base64:" + canary) }
            let hex = canary.utf8.map { String(format: "%02x", $0) }.joined()
            if lowered.contains(hex) { found.append("hex:" + canary) }
        }
        return found
    }
    /// Every textual rendering Swift can produce for a value: description, debug description, reflection, `dump` and `localizedDescription` for errors.
    static func renderings(of value: Any) -> [String] {
        var out = [String(describing: value), String(reflecting: value)]
        var dumped = ""; dump(value, to: &dumped); out.append(dumped)
        if let error = value as? any Error { out.append(error.localizedDescription); out.append((error as NSError).description) }
        return out
    }
}

/// What one path of the canary sweep did. `delivered` is what the fake input proves reached the code under test (not what the test merely planted); `outputs` is every
/// text the path produced for a person, a log, a file or another process; `control` is, where the lower layer has a raw rendering, a text that MUST still hold a canary,
/// which proves the protection (not the absence of the input) is what removed it.
struct PathOutcome: Sendable {
    let path: String
    let delivered: Set<CanaryKind>
    let outputs: [String]
    let control: String?
}

/// The counted ledger of a run: how many canaries were seeded, delivered and checked on every path. Read by the final test, so a path that stops delivering fails.
final class CanaryLedger: @unchecked Sendable {
    static let shared = CanaryLedger()
    private let lock = NSLock()
    private var rows: [String: (delivered: Int, outputs: Int)] = [:]
    func record(_ outcome: PathOutcome) { lock.withLock { rows[outcome.path] = (outcome.delivered.count, outcome.outputs.count) } }
    var snapshot: [String: (delivered: Int, outputs: Int)] { lock.withLock { rows } }
}

/// A scratch directory for one test, removed by its owner. Never a shared prefix.
struct SecurityScratch {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ytmuse-w29-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func cleanup() { try? FileManager.default.removeItem(at: url) }
}
/// The repository root, found from this file, for source sweeps.
enum Repo {
    static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("toolchain.json").path) { return url }
        }
        fatalError("repository root not found")
    }()
    static func text(_ relative: String) throws -> String { try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8) }
    static func swiftFiles(under relative: String) -> [URL] {
        let base = root.appendingPathComponent(relative)
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }
    /// Code with comments removed (line comments, not inside strings that contain `://`).
    static func code(_ text: String) -> String {
        text.components(separatedBy: "\n").map { $0.replacingOccurrences(of: #"(?<!:)//.*$"#, with: "", options: .regularExpression) }.joined(separator: "\n")
    }
}
