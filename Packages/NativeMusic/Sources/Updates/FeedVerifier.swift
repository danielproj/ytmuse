import CryptoKit
import Foundation

/// What the app trusts, fixed in the signed app bundle. The feed cannot add a key, change the repository or the channel: SEC09 "no unsigned remote
/// configuration may change trust policy". A key is rotated by shipping a new app that pins the successor beside the current key.
public struct UpdateTrustPolicy: Sendable, Equatable {
    public let publicKeys: [String: Data]        // keyID -> raw 32-byte Ed25519 public key
    public let repository: String                // "owner/name" the releases must come from
    public let channel: String
    public init?(publicKeys raw: [Data], repository: String, channel: String = "stable") {
        var keys: [String: Data] = [:]
        for key in raw {
            guard (try? Curve25519.Signing.PublicKey(rawRepresentation: key)) != nil else { return nil }
            keys[FeedFormat.keyID(forPublicKey: key)] = key
        }
        guard !keys.isEmpty, Self.isRepository(repository), !channel.isEmpty else { return nil }
        self.publicKeys = keys; self.repository = repository; self.channel = channel
    }
    static func isRepository(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        let allowed: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.count <= 100 && $0.allSatisfy(allowed) && $0 != "." && $0 != ".." }
    }
    /// The only place a release asset may be downloaded from: this repository's release downloads, https, no port, no query.
    public func assetURL(version: AppVersion) -> String { "https://github.com/\(repository)/releases/download/v\(version)/YTMuse-\(version).dmg" }
    public func notesURL(version: AppVersion) -> String { "https://github.com/\(repository)/releases/tag/v\(version)" }
}

/// The running application, as the verifier needs to know it.
public struct RunningApplication: Sendable, Equatable {
    public let version: AppVersion
    public let build: Int
    public let bundleIdentifier: String
    public let system: SystemVersion
    public init(version: AppVersion, build: Int, bundleIdentifier: String, system: SystemVersion) {
        self.version = version; self.build = build; self.bundleIdentifier = bundleIdentifier; self.system = system
    }
}

public struct VerifiedFeed: Equatable, Sendable {
    public let payload: FeedPayload
    /// The newest release this Mac may install, strictly newer than the running version. Nil is "up to date".
    public let offer: FeedRelease?
}

public enum FeedVerifier {
    /// Verifies a downloaded feed. Order matters and every step fails closed: size, envelope shape, pinned key, signature, payload shape, channel,
    /// freshness, sequence (rollback), provenance of every release, then the choice of an offer. Nothing in the payload is read before the signature holds.
    public static func verify(_ data: Data, policy: UpdateTrustPolicy, running: RunningApplication, now: Date, lastAcceptedSequence: Int) throws -> VerifiedFeed {
        guard data.count <= FeedFormat.maximumFeedBytes else { throw UpdateRejection.tooLarge }
        let envelope = try FeedParsing.envelope(data)
        guard let raw = policy.publicKeys[envelope.keyID], let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { throw UpdateRejection.unknownKey }
        guard key.isValidSignature(envelope.signature, for: FeedFormat.signedMessage(for: envelope.payload)) else { throw UpdateRejection.invalidSignature }
        let payload = try FeedParsing.payload(envelope.payload)
        guard payload.channel == policy.channel else { throw UpdateRejection.wrongChannel }
        guard now < payload.expiresAt else { throw UpdateRejection.expired }
        guard payload.issuedAt <= now.addingTimeInterval(86_400) else { throw UpdateRejection.issuedInTheFuture }   // one day of clock skew
        guard payload.sequence >= lastAcceptedSequence else { throw UpdateRejection.rollback }
        for release in payload.releases { try checkProvenance(release, policy: policy) }
        let candidates = payload.releases.filter { $0.version > running.version && $0.build > running.build && $0.minimumSystemVersion <= running.system }
        return VerifiedFeed(payload: payload, offer: candidates.max { $0.version < $1.version })
    }

    /// Release provenance (SEC09): the release comes from the pinned repository, its tag is the version, its asset is the one file name under that
    /// tag's download path, and its commit and SBOM digest are present. A release that fails any of this invalidates the whole feed.
    static func checkProvenance(_ release: FeedRelease, policy: UpdateTrustPolicy) throws {
        let p = release.provenance
        guard p.repository == policy.repository else { throw UpdateRejection.provenance("repository") }
        guard p.tag == "v\(release.version)" else { throw UpdateRejection.provenance("tag") }
        guard release.asset.url.absoluteString == policy.assetURL(version: release.version) else { throw UpdateRejection.provenance("asset location") }
        guard release.notesURL.absoluteString == policy.notesURL(version: release.version) else { throw UpdateRejection.provenance("notes location") }
    }
}

/// Signing, used by the feed tool (`FeedTool`) and by tests with throwaway keys. The app itself never holds a private key.
public enum FeedSigner {
    public static func sign(payload: Data, with key: Curve25519.Signing.PrivateKey) throws -> Data {
        let signature = try key.signature(for: FeedFormat.signedMessage(for: payload))
        let envelope: [String: Any] = [
            "format": FeedFormat.envelopeVersion,
            "keyID": FeedFormat.keyID(forPublicKey: key.publicKey.rawRepresentation),
            "payload": payload.base64EncodedString(),
            "signature": signature.base64EncodedString(),
        ]
        return try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
