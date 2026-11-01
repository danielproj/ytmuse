import CryptoKit
import Foundation

// The signed static feed (SEC09, BUILD06). A feed is an envelope around payload bytes: the signature covers those exact bytes (with a domain
// prefix), so nothing is canonicalised and nothing outside the signature is read. The payload is DATA ONLY: every object has an exact key set, so
// a field that would carry a script, a URL to run, a trust change or a credential request is not "ignored", it makes the feed invalid.

public struct FeedAsset: Equatable, Sendable {
    public let url: URL
    public let length: Int
    public let sha256: String
}
public struct FeedProvenance: Equatable, Sendable {
    public let repository: String   // "owner/name"
    public let tag: String
    public let commit: String       // 40 lowercase hex
    public let sbomSHA256: String
}
public struct FeedRelease: Equatable, Sendable {
    public let version: AppVersion
    public let build: Int
    public let minimumSystemVersion: SystemVersion
    public let publishedAt: Date
    public let notesURL: URL
    public let asset: FeedAsset
    public let provenance: FeedProvenance
}
public struct FeedPayload: Equatable, Sendable {
    public let channel: String
    public let sequence: Int
    public let issuedAt: Date
    public let expiresAt: Date
    public let releases: [FeedRelease]
}

/// Why a feed or an update was refused. Every case is a refusal; none installs anything. `code` is stable and carries no feed content.
public enum UpdateRejection: Error, Equatable, Sendable {
    case notConfigured
    case tooLarge
    case malformed(String)
    case unknownKey
    case invalidSignature
    case expired
    case issuedInTheFuture
    case wrongChannel
    case rollback                    // the feed's sequence is older than one already accepted
    case provenance(String)
    case assetLengthMismatch
    case assetHashMismatch
    case notNewer                    // downgrade or same version, in the feed or in the staged bundle
    case bundleMismatch(String)      // the staged app is not the release the feed described
    case codeSignature(String)
    case playbackActive
    case restartNotRequested
    case installLocationNotWritable
    case notStaged
    case transport(String)
    public var code: String {
        switch self {
        case .notConfigured: "notConfigured"
        case .tooLarge: "tooLarge"
        case .malformed: "malformed"
        case .unknownKey: "unknownKey"
        case .invalidSignature: "invalidSignature"
        case .expired: "expired"
        case .issuedInTheFuture: "issuedInTheFuture"
        case .wrongChannel: "wrongChannel"
        case .rollback: "rollback"
        case .provenance: "provenance"
        case .assetLengthMismatch: "assetLengthMismatch"
        case .assetHashMismatch: "assetHashMismatch"
        case .notNewer: "notNewer"
        case .bundleMismatch: "bundleMismatch"
        case .codeSignature: "codeSignature"
        case .playbackActive: "playbackActive"
        case .restartNotRequested: "restartNotRequested"
        case .installLocationNotWritable: "installLocationNotWritable"
        case .notStaged: "notStaged"
        case .transport: "transport"
        }
    }
}

public enum FeedFormat {
    public static let envelopeVersion = 1
    public static let maximumFeedBytes = 256 * 1024
    public static let maximumAssetBytes = 2 * 1024 * 1024 * 1024
    /// Prefixed to the payload before signing so a signature over feed bytes can never be replayed as a signature over anything else.
    public static let signingDomain = Data("YTMuse-update-feed-v1\n".utf8)
    public static func signedMessage(for payload: Data) -> Data { signingDomain + payload }
    public static func keyID(forPublicKey raw: Data) -> String {
        "ed25519:" + SHA256.hash(data: raw).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    static let envelopeKeys: Set<String> = ["format", "keyID", "payload", "signature"]
    static let payloadKeys: Set<String> = ["schema", "channel", "sequence", "issuedAt", "expiresAt", "releases"]
    static let releaseKeys: Set<String> = ["version", "build", "minimumSystemVersion", "publishedAt", "notesURL", "asset", "provenance"]
    static let assetKeys: Set<String> = ["url", "length", "sha256"]
    static let provenanceKeys: Set<String> = ["repository", "tag", "commit", "sbomSHA256"]
}

/// Strict reading of the envelope and the payload. Throws `.malformed` for anything that is not exactly the documented shape.
enum FeedParsing {
    struct Envelope { let keyID: String; let payload: Data; let signature: Data }

    static func envelope(_ data: Data) throws -> Envelope {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UpdateRejection.malformed("envelope") }
        guard Set(object.keys) == FeedFormat.envelopeKeys else { throw UpdateRejection.malformed("envelope keys") }
        guard integer(object["format"]) == FeedFormat.envelopeVersion else { throw UpdateRejection.malformed("format") }
        guard let keyID = object["keyID"] as? String, let payload = canonicalBase64(object["payload"]), let signature = canonicalBase64(object["signature"]) else { throw UpdateRejection.malformed("envelope fields") }
        guard signature.count == 64 else { throw UpdateRejection.malformed("signature length") }
        return Envelope(keyID: keyID, payload: payload, signature: signature)
    }

    /// Base64 that re-encodes to the same text (no stray characters, no alternative padding): two spellings of one signature are not accepted.
    static func canonicalBase64(_ value: Any?) -> Data? {
        guard let text = value as? String, !text.isEmpty, let data = Data(base64Encoded: text), data.base64EncodedString() == text else { return nil }
        return data
    }

    static func payload(_ bytes: Data) throws -> FeedPayload {
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw UpdateRejection.malformed("payload") }
        guard Set(object.keys) == FeedFormat.payloadKeys else { throw UpdateRejection.malformed("payload keys") }
        guard integer(object["schema"]) == 1 else { throw UpdateRejection.malformed("schema") }
        guard let channel = object["channel"] as? String, !channel.isEmpty, channel.count <= 32, channel.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { throw UpdateRejection.malformed("channel") }
        guard let sequence = integer(object["sequence"]), sequence >= 0 else { throw UpdateRejection.malformed("sequence") }
        guard let issued = date(object["issuedAt"]), let expires = date(object["expiresAt"]), expires > issued else { throw UpdateRejection.malformed("dates") }
        guard let list = object["releases"] as? [[String: Any]], list.count <= 64 else { throw UpdateRejection.malformed("releases") }
        var seen = Set<AppVersion>()
        var releases: [FeedRelease] = []
        for entry in list {
            let release = try release(entry)
            guard seen.insert(release.version).inserted else { throw UpdateRejection.malformed("duplicate version") }
            releases.append(release)
        }
        return FeedPayload(channel: channel, sequence: sequence, issuedAt: issued, expiresAt: expires, releases: releases)
    }

    private static func release(_ entry: [String: Any]) throws -> FeedRelease {
        guard Set(entry.keys) == FeedFormat.releaseKeys else { throw UpdateRejection.malformed("release keys") }
        guard let versionText = entry["version"] as? String, let version = AppVersion(versionText),
              let build = integer(entry["build"]), build > 0,
              let minimum = (entry["minimumSystemVersion"] as? String).flatMap(SystemVersion.init),
              let published = date(entry["publishedAt"]),
              let notes = (entry["notesURL"] as? String).flatMap(httpsURL),
              let asset = entry["asset"] as? [String: Any], Set(asset.keys) == FeedFormat.assetKeys,
              let assetURL = (asset["url"] as? String).flatMap(httpsURL),
              let length = integer(asset["length"]), length > 0, length <= FeedFormat.maximumAssetBytes,
              let digest = asset["sha256"] as? String, isHex(digest, count: 64),
              let provenance = entry["provenance"] as? [String: Any], Set(provenance.keys) == FeedFormat.provenanceKeys,
              let repository = provenance["repository"] as? String, let tag = provenance["tag"] as? String,
              let commit = provenance["commit"] as? String, isHex(commit, count: 40),
              let sbom = provenance["sbomSHA256"] as? String, isHex(sbom, count: 64)
        else { throw UpdateRejection.malformed("release fields") }
        return FeedRelease(version: version, build: build, minimumSystemVersion: minimum, publishedAt: published, notesURL: notes,
                           asset: FeedAsset(url: assetURL, length: length, sha256: digest),
                           provenance: FeedProvenance(repository: repository, tag: tag, commit: commit, sbomSHA256: sbom))
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double == double.rounded(), abs(double) < 1e15 else { return nil }
        return number.intValue
    }
    static func isHex(_ text: String, count: Int) -> Bool {
        text.utf8.count == count && text.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
    /// "YYYY-MM-DDTHH:MM:SSZ" only, UTC.
    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, text.utf8.count == 20, text.hasSuffix("Z") else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let parsed = formatter.date(from: text), formatter.string(from: parsed) == text else { return nil }
        return parsed
    }
    static func httpsURL(_ text: String) -> URL? {
        guard text.utf8.count <= 512, text.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 }), let url = URL(string: text),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else { return nil }
        return url
    }
}
