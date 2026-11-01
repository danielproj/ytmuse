import CryptoKit
import Foundation
import Testing
@testable import Updates

/// T30.2: the native updater rejects a tampered feed, an invalid or foreign signature, a downgrade, a replayed (older) feed, bad provenance and any
/// field that is not data. Each test breaks exactly one thing in an otherwise valid, signed feed.
@Suite struct FeedVerificationTests {
    func verify(_ data: Data, policy: UpdateTrustPolicy, running: RunningApplication = runningApp, last: Int = 0, now: Date = testNow) throws -> VerifiedFeed {
        try FeedVerifier.verify(data, policy: policy, running: running, now: now, lastAcceptedSequence: last)
    }
    func rejection(_ data: Data, policy: UpdateTrustPolicy, running: RunningApplication = runningApp, last: Int = 0, now: Date = testNow) -> UpdateRejection? {
        do { _ = try verify(data, policy: policy, running: running, last: last, now: now); return nil } catch { return error as? UpdateRejection }
    }

    @Test func aValidSignedFeedOffersTheNewerRelease() throws {
        let b = FeedBuilder()
        let result = try verify(b.signed(), policy: b.policy)
        #expect(result.offer?.version == AppVersion("1.2.0"))
        #expect(result.offer?.build == 120)
        #expect(result.payload.sequence == 10)
    }

    // MARK: signatures

    @Test func aChangedPayloadByteIsAnInvalidSignature() throws {
        let b = FeedBuilder()
        var object = envelopeObject(b.signed())
        var payload = Data(base64Encoded: object["payload"] as! String)!
        let index = payload.firstIndex(of: UInt8(ascii: "2"))!          // 1.2.0 -> 1.3.0, say: any change at all
        payload[index] = UInt8(ascii: "3")
        object["payload"] = payload.base64EncodedString()
        #expect(rejection(envelopeData(object), policy: b.policy) == .invalidSignature)
    }
    @Test func aFlippedSignatureBitIsAnInvalidSignature() throws {
        let b = FeedBuilder()
        var object = envelopeObject(b.signed())
        var signature = Data(base64Encoded: object["signature"] as! String)!
        signature[0] ^= 0x01
        object["signature"] = signature.base64EncodedString()
        #expect(rejection(envelopeData(object), policy: b.policy) == .invalidSignature)
    }
    @Test func aFeedSignedByAnotherKeyIsUnknownOrInvalid() throws {
        let b = FeedBuilder()
        var other = b; other.key = Curve25519.Signing.PrivateKey()
        #expect(rejection(other.signed(), policy: b.policy) == .unknownKey)                  // honest key id: not pinned
        var object = envelopeObject(other.signed())
        object["keyID"] = FeedFormat.keyID(forPublicKey: b.key.publicKey.rawRepresentation)   // claims the pinned key
        #expect(rejection(envelopeData(object), policy: b.policy) == .invalidSignature)
    }
    @Test func aSignatureWithoutTheDomainPrefixIsNotAFeedSignature() throws {
        let b = FeedBuilder()
        var object = envelopeObject(b.signed())
        object["signature"] = (try b.key.signature(for: b.payloadBytes())).base64EncodedString()   // a signature over the bare payload
        #expect(rejection(envelopeData(object), policy: b.policy) == .invalidSignature)
    }
    @Test func aSignatureSpelledAnotherWayIsRefused() throws {
        let b = FeedBuilder()
        var object = envelopeObject(b.signed())
        object["signature"] = (object["signature"] as! String) + "\n"
        #expect(rejection(envelopeData(object), policy: b.policy) == .malformed("envelope fields"))
        object["signature"] = Data(repeating: 1, count: 63).base64EncodedString()
        #expect(rejection(envelopeData(object), policy: b.policy) == .malformed("signature length"))
    }
    @Test func garbageAndOversizedFeedsAreRefused() {
        let b = FeedBuilder()
        #expect(rejection(Data("not json".utf8), policy: b.policy) == .malformed("envelope"))
        #expect(rejection(Data(), policy: b.policy) == .malformed("envelope"))
        #expect(rejection(Data(repeating: 0x20, count: FeedFormat.maximumFeedBytes + 1), policy: b.policy) == .tooLarge)
    }

    // MARK: no unsigned configuration, and nothing executable in the data

    @Test func unsignedKeysAtEveryLevelMakeAFeedInvalid() throws {
        let b = FeedBuilder()
        for extra in ["trustedKeys", "script", "command", "url", "credentials"] {
            var object = envelopeObject(b.signed()); object[extra] = "x"
            #expect(rejection(envelopeData(object), policy: b.policy) == .malformed("envelope keys"), "envelope \(extra)")
            #expect(rejection(b.signed { $0[extra] = "x" }, policy: b.policy) == .malformed("payload keys"), "payload \(extra)")
            #expect(rejection(b.signed { var r = ($0["releases"] as! [[String: Any]]); r[0][extra] = "x"; $0["releases"] = r }, policy: b.policy) == .malformed("release keys"), "release \(extra)")
            #expect(rejection(b.signed { var r = ($0["releases"] as! [[String: Any]]); var a = r[0]["asset"] as! [String: Any]; a[extra] = "x"; r[0]["asset"] = a; $0["releases"] = r }, policy: b.policy) == .malformed("release fields"), "asset \(extra)")
            #expect(rejection(b.signed { var r = ($0["releases"] as! [[String: Any]]); var a = r[0]["provenance"] as! [String: Any]; a[extra] = "x"; r[0]["provenance"] = a; $0["releases"] = r }, policy: b.policy) == .malformed("release fields"), "provenance \(extra)")
        }
    }
    @Test func theFeedCannotChangeThePinnedTrust() throws {
        // A correctly signed feed that names another repository or channel is refused; it cannot move the pin.
        var b = FeedBuilder()
        b.releases = [FeedBuilder.release(version: "1.2.0", build: 120, repository: "attacker/other")]
        #expect(rejection(b.signed(), policy: b.policy) == .provenance("repository"))
        var c = FeedBuilder(); c.channel = "beta"
        #expect(rejection(c.signed(), policy: c.policy) == .wrongChannel)
    }

    // MARK: downgrade, replay, freshness

    @Test func aDowngradeIsNeverOffered() throws {
        for (version, build) in [("0.9.0", 90), ("1.0.0", 100), ("1.0.0", 200), ("0.9.9", 500)] {
            var b = FeedBuilder(); b.releases = [FeedBuilder.release(version: version, build: build)]
            #expect(try verify(b.signed(), policy: b.policy).offer == nil, "\(version)/\(build)")
        }
        // newer version number but an older build is inconsistent: not offered either
        var c = FeedBuilder(); c.releases = [FeedBuilder.release(version: "1.5.0", build: 50)]
        #expect(try verify(c.signed(), policy: c.policy).offer == nil)
    }
    @Test func aPreReleaseOfTheRunningVersionIsADowngrade() throws {
        var b = FeedBuilder(); b.releases = [FeedBuilder.release(version: "1.0.0-beta.3", build: 150)]
        #expect(try verify(b.signed(), policy: b.policy).offer == nil)
    }
    @Test func theNewestSuitableReleaseIsOfferedAndOlderOnesAreIgnored() throws {
        var b = FeedBuilder()
        b.releases = [FeedBuilder.release(version: "0.9.0", build: 90), FeedBuilder.release(version: "1.1.0", build: 110), FeedBuilder.release(version: "1.3.0", build: 130, minimumSystem: "99.0"), FeedBuilder.release(version: "1.2.0", build: 120)]
        let offer = try verify(b.signed(), policy: b.policy).offer
        #expect(offer?.version == AppVersion("1.2.0"))   // 1.3.0 needs a newer macOS than this Mac
    }
    @Test func aReplayedOlderFeedIsARollback() throws {
        var b = FeedBuilder(); b.sequence = 4
        #expect(rejection(b.signed(), policy: b.policy, last: 5) == .rollback)
        #expect(rejection(b.signed(), policy: b.policy, last: 4) == nil)   // the same feed fetched again is fine
    }
    @Test func anExpiredOrFutureDatedFeedIsRefused() throws {
        var b = FeedBuilder()
        #expect(rejection(b.signed(), policy: b.policy, now: b.expires) == .expired)
        b.issued = testNow.addingTimeInterval(86_400 * 3)
        b.expires = testNow.addingTimeInterval(86_400 * 30)
        #expect(rejection(b.signed(), policy: b.policy) == .issuedInTheFuture)
    }

    // MARK: provenance

    @Test func provenanceMustMatchTheRepositoryTagAndAssetLocation() throws {
        let good = FeedBuilder.release(version: "1.2.0", build: 120)
        func broken(_ edit: (inout [String: Any]) -> Void) -> UpdateRejection? {
            var b = FeedBuilder(); var r = good; edit(&r); b.releases = [r]
            return rejection(b.signed(), policy: b.policy)
        }
        func setAsset(_ r: inout [String: Any], _ key: String, _ value: Any) { var a = r["asset"] as! [String: Any]; a[key] = value; r["asset"] = a }
        func setProv(_ r: inout [String: Any], _ key: String, _ value: Any) { var a = r["provenance"] as! [String: Any]; a[key] = value; r["provenance"] = a }
        #expect(broken { setProv(&$0, "tag", "v9.9.9") } == .provenance("tag"))
        #expect(broken { setProv(&$0, "repository", "someone/else") } == .provenance("repository"))
        #expect(broken { setAsset(&$0, "url", "https://github.com/someone/else/releases/download/v1.2.0/YTMuse-1.2.0.dmg") } == .provenance("asset location"))
        #expect(broken { setAsset(&$0, "url", "https://github.com/\(repository)/releases/download/v1.2.0/Other.dmg") } == .provenance("asset location"))
        #expect(broken { setAsset(&$0, "url", "https://evil.example/\(repository)/releases/download/v1.2.0/YTMuse-1.2.0.dmg") } == .provenance("asset location"))
        #expect(broken { setAsset(&$0, "url", "http://github.com/\(repository)/releases/download/v1.2.0/YTMuse-1.2.0.dmg") } == .malformed("release fields"))
        #expect(broken { setAsset(&$0, "url", "https://github.com/\(repository)/releases/download/v1.2.0/YTMuse-1.2.0.dmg?token=1") } == .malformed("release fields"))
        #expect(broken { setAsset(&$0, "url", "https://user" + "@github.com/\(repository)/releases/download/v1.2.0/YTMuse-1.2.0.dmg") } == .malformed("release fields"))
        #expect(broken { $0["notesURL"] = "https://github.com/someone/else/releases/tag/v1.2.0" } == .provenance("notes location"))
        #expect(broken { setProv(&$0, "commit", "abc123") } == .malformed("release fields"))
        #expect(broken { setProv(&$0, "commit", String(repeating: "C", count: 40)) } == .malformed("release fields"))   // upper-case is not the canonical spelling
        #expect(broken { setAsset(&$0, "sha256", "zz" + String(repeating: "a", count: 62)) } == .malformed("release fields"))
        #expect(broken { setAsset(&$0, "length", -5) } == .malformed("release fields"))
        #expect(broken { setAsset(&$0, "length", FeedFormat.maximumAssetBytes + 1) } == .malformed("release fields"))
        #expect(broken { _ in } == nil)   // control: the unedited release is accepted
    }
    @Test func oneBadReleaseInvalidatesTheWholeFeed() throws {
        var b = FeedBuilder()
        b.releases = [FeedBuilder.release(version: "1.2.0", build: 120), FeedBuilder.release(version: "1.1.0", build: 110, repository: "attacker/other")]
        #expect(rejection(b.signed(), policy: b.policy) == .provenance("repository"))
        b.releases = [FeedBuilder.release(version: "1.2.0", build: 120), FeedBuilder.release(version: "1.2.0", build: 121)]
        #expect(rejection(b.signed(), policy: b.policy) == .malformed("duplicate version"))
    }

    // MARK: version ordering

    @Test func versionsAreParsedStrictlyAndOrderedBySemver() {
        for bad in ["", "1", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "1.2.x", "v1.2.3", " 1.2.3", "1.2.3 ", "1.2.3+build", "1.2.3-", "1.2.3-a..b", "1.2.3-01", "-1.2.3", "１.2.3", "1.2.3-é", "9999999999.0.0"] {
            #expect(AppVersion(bad) == nil, "\(bad)")
        }
        // The length limit: 64 bytes is the longest accepted, 65 is refused.
        let core = "1.2.3-"
        #expect(AppVersion(core + String(repeating: "a", count: 64 - core.utf8.count)) != nil)
        #expect(AppVersion(core + String(repeating: "a", count: 65 - core.utf8.count)) == nil)
        let ordered = ["0.9.9", "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1.0", "2.0.0", "10.0.0"].map { AppVersion($0)! }
        for (a, b) in zip(ordered, ordered.dropFirst()) { #expect(a < b, "\(a) < \(b)"); #expect(!(b < a)) }
        #expect(AppVersion("1.2.3")! == AppVersion("1.2.3")!)
        #expect(SystemVersion("27.0")! < SystemVersion("27.0.1")!)
        #expect(SystemVersion("27") == nil)
    }
    @Test func malformedFieldTypesAreRefused() throws {
        let b = FeedBuilder()
        #expect(rejection(b.signed { $0["sequence"] = "10" }, policy: b.policy) == .malformed("sequence"))
        #expect(rejection(b.signed { $0["sequence"] = true }, policy: b.policy) == .malformed("sequence"))
        #expect(rejection(b.signed { $0["schema"] = 2 }, policy: b.policy) == .malformed("schema"))
        #expect(rejection(b.signed { $0["issuedAt"] = "2027-01-15" }, policy: b.policy) == .malformed("dates"))
        #expect(rejection(b.signed { $0["issuedAt"] = "2027-02-31T00:00:00Z" }, policy: b.policy) == .malformed("dates"))
        #expect(rejection(b.signed { $0["releases"] = "none" }, policy: b.policy) == .malformed("releases"))
    }
}
