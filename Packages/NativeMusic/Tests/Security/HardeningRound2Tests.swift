import Foundation
import Testing
import Domain
import Diagnostics
import SystemIntegration
import AppKit
@testable import Features

// TH2 (hardening round 2). The redaction gaps W29's critic listed, each as an input that leaked before: JSON-escaped slashes in their other spellings, schemeless URLs,
// numeric-entity e-mail addresses, the bare OSID and AEC cookies, and an app error's own payload text. Every row also asserts the INPUT holds a canary (a control), so a
// row cannot pass because the planted text was never there, and that redacting the result changes nothing.

@Suite("TH2 redaction gaps") struct RedactionGapTests {
    static let signed = "rr4---sn-cnry7f3a.googlevideo.com/videoplayback?expire=1999999999&sig=CNRYsig7f3a&id=o-CNRYid7f3a"
    static let rows: [(name: String, input: String)] = [
        ("json single-escaped URL", #"{"u":"https:\/\/evil.example.test\/x?sig=CNRYsig7f3a"}"#),
        ("json double-escaped URL", #"{"u":"https:\\/\\/evil.example.test\\/x?sig=CNRYsig7f3a"}"#),
        ("json triple-escaped URL", #"{"u":"https:\\\/\\\/evil.example.test\\\/x?sig=CNRYsig7f3a"}"#),
        ("json unicode-escaped slashes", #"{"u":"https://evil.example.test/x?sig=CNRYsig7f3a"}"#),
        ("json unicode-escaped slashes, upper case", #"{"u":"https://evil.example.test/x?q=CNRYsearch7f3a"}"#),
        ("json unicode-escaped = and &", #"{"u":"https://evil.example.test/x?a=1&sig=CNRYsig7f3a"}"#),
        ("json unicode-escaped everything", #"{"u":"https://evil.example.test/x?sig=CNRYsig7f3a"}"#),
        ("json unicode-escaped at sign in an e-mail", #"{"m":"pat.cnry.7f3a@example.org"}"#),
        ("json unicode-escaped URL on a named host", #"{"u":"https:\u002f\u002fmusic.youtube.com\u002fwatch?v=CNRYid7f3a"}"#),
        ("json unicode-escaped e-mail next to its key", #"{"note":"mail pat.cnry.7f3a\u0040example.org sent"}"#),
        ("schemeless media URL", "fetch " + signed + " failed"),
        ("schemeless media URL in quotes", "{\"u\":\"" + signed + "\"}"),
        ("schemeless named host with a path", "music.youtube.com/watch?v=x&list=CNRYlist7f3a"),
        ("schemeless host with a port", "evil.example.test:8443/cb?code=CNRYcode7f3a"),
        ("schemeless IPv4", "192.168.4.20:8080/hook?token=CNRYtoken7f3a"),
        ("schemeless IPv4 with the canary in the path", "10.0.0.1/CNRYpath7f3a/x"),
        ("protocol-relative URL", "see //evil.example.test/x?sig=CNRYsig7f3a now"),
        ("schemeless URL after an escaped slash", #"{"u":"evil.example.test\/x?sig=CNRYsig7f3a"}"#),
        ("hex entity at sign", "from pat.cnry.7f3a&#x40;example.org today"),
        ("upper-case hex entity at sign", "from pat.cnry.7f3a&#X40;example.org today"),
        ("padded hex entity at sign", "from pat.cnry.7f3a&#x0040;example.org today"),
        ("padded decimal entity at sign", "from pat.cnry.7f3a&#0064;example.org today"),
        ("bare OSID cookie", "OSID=CNRYcookie7f3a"),
        ("bare AEC cookie", "AEC=CNRYcookie7f3a; Path=/"),
        ("OSID in JSON", #"{"OSID":"CNRYcookie7f3a"}"#),
        ("AEC in a log line", "stored aec: CNRYcookie7f3a for the page"),
        ("secure-prefixed OSID", "__Secure-OSID=CNRYcookie7f3a"),
    ]
    @Test(arguments: RedactionGapTests.rows.map(\.name)) func everyRowIsRedactedAndStable(name: String) throws {
        let input = try #require(Self.rows.first { $0.name == name }).input
        #expect(!Canaries.survivors(in: input).isEmpty, "\(name): the input holds a canary (control)")
        let once = DiagnosticRedactor.redact(input)
        #expect(Canaries.survivors(in: once).isEmpty, "\(name): survived as \(once)")
        #expect(DiagnosticRedactor.redact(once) == once, "\(name): redacting twice changes the text: \(once)")
    }
    /// What must NOT change: ordinary text with dots, slashes and the cookie names as words.
    @Test func ordinaryTextIsLeftAlone() {
        for text in ["Song.mp3 saved", "see Info.plist/Contents", "version 1.2.3/build", "e.g. this, i.e. that", "the aec module and the osid word", "tracks/album.m4a", "Artist - Title (feat. X)"] {
            #expect(DiagnosticRedactor.redact(text) == text, "unchanged: \(text)")
        }
        #expect(DiagnosticRedactor.redact("https://music.youtube.com/watch?v=x") == "https://music.youtube.com/<redacted>", "a named host keeps its name in the scheme form")
        #expect(DiagnosticRedactor.redact("music.youtube.com/watch?v=x") == "music.youtube.com/<redacted>", "and in the schemeless form")
        #expect(DiagnosticRedactor.redact("pat.cnry.7f3a@example.org/x") == "<email>/x", "an e-mail address is not a host with a path")
    }
}

@Suite("TH2 error payloads") struct ErrorPayloadTests {
    indirect enum Failing: Error { case failed(String), counted(Int), pair(String, Int), none, wrapped(Failing), maybe(String?), inner(Inner?) }
    struct Inner { let x: String }
    struct Carrier: Error { let message: String; let attempt: Int }
    @Test func aPayloadIsNeverPartOfTheText() {
        for secret in [Canaries.playlist, Canaries.search, "Mum's 60th", "plain words"] {
            let texts = [SafeErrorText.describe(Failing.failed(secret)), SafeErrorText.describe(Failing.pair(secret, 3)), SafeErrorText.describe(Failing.wrapped(.failed(secret))),
                         SafeErrorText.describe(Carrier(message: secret, attempt: 2)), SafeErrorText.describe(Failing.maybe(secret))]
            for text in texts { #expect(!text.contains(secret) && !text.lowercased().contains("cnry") && !text.contains("Mum"), "payload \(secret) survived in: \(text)") }
        }
    }
    /// An optional payload that is not a String (critic L3): the `Optional` wrapper must not print the struct inside it.
    @Test func anOptionalPayloadThatIsNotAStringIsShapedToo() {
        let text = SafeErrorText.describe(Failing.inner(Inner(x: Canaries.playlist)))
        #expect(text == "inner(Inner(x: …))", Comment(rawValue: text))
        #expect(SafeErrorText.describe(Failing.inner(nil)) == "inner(nil)")
    }
    @Test func theCaseNameLabelsAndNumbersStay() {
        #expect(SafeErrorText.describe(Failing.failed("x")) == "failed(…)")
        #expect(SafeErrorText.describe(Failing.counted(7)) == "counted(7)")
        #expect(SafeErrorText.describe(Failing.pair("x", 3)) == "pair(…, 3)")
        #expect(SafeErrorText.describe(Failing.none) == "none")
        #expect(SafeErrorText.describe(Failing.wrapped(.counted(2))) == "wrapped(counted(2))")
        #expect(SafeErrorText.describe(Failing.maybe(nil)) == "maybe(nil)")
        #expect(SafeErrorText.describe(Carrier(message: "x", attempt: 2)) == "Carrier(message: …, attempt: 2)")
    }
}

@Suite("TH2 status messages") struct StatusMessageTests {
    @Test func aStatusMessageHasNoRoomForErrorText() {
        let labels = Mirror(reflecting: StatusNotification.make(.downloadFailed, item: "Song")).children.compactMap(\.label)
        #expect(Set(labels) == ["kind", "title", "body"])
        #expect(StatusNotification.make(.downloadFailed, item: "Song").body == "Song" && StatusNotification.make(.downloadFailed).body == nil)
    }
}

@Suite("TH2 avatar decode") struct AvatarDecodeTests {
    /// A real PNG, made in memory (no file): 400 x 300, so the bounded thumbnail has to shrink it.
    static func png(width: Int = 400, height: Int = 300) throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(rep.representation(using: .png, properties: [:]))
    }
    @Test @MainActor func theAvatarIsDecodedOffTheMainThreadEvenWhenAskedFromIt() async throws {
        let data = try Self.png()
        let before = AvatarDecoding.mainThreadDecodes
        let decoded = await AvatarDecoding.load(data)
        let image = try #require(decoded.image, "a real image decodes")
        #expect(max(image.width, image.height) <= AvatarDecoding.maximumPixels, "the raster is bounded: \(image.width) x \(image.height)")
        #expect(AvatarDecoding.mainThreadDecodes == before, "load() hopped off the main thread")
        // Control: the decode function itself, called from here, IS seen as a main-thread decode, so the counter can fail.
        _ = AvatarDecoding.decode(data)
        #expect(AvatarDecoding.mainThreadDecodes == before + 1, "the counter sees a main-thread decode")
    }
    @Test func garbageOversizeAndNilDecodeToNothing() async throws {
        #expect(await AvatarDecoding.load(nil).image == nil)
        #expect(await AvatarDecoding.load(Data()).image == nil)
        #expect(await AvatarDecoding.load(Data("not an image".utf8)).image == nil)
        #expect(await AvatarDecoding.load(Data(count: AvatarDecoding.maximumInputBytes + 1)).image == nil, "more bytes than the bound are not decoded")
    }
    @Test func theAccountCardNoLongerDecodesInItsBody() throws {
        let source = Repo.code(try Repo.text("Packages/NativeMusic/Sources/Features/MusicSignInSheet.swift"))
        #expect(!source.contains("NSImage(data"), "no NSImage(data:) in a view")
        // The view's task must go through `load` (which leaves the main actor). `decode` is the synchronous worker: called from the view's task it would run on the main actor,
        // and neither the main-actor sweep (it is a function call, not an image API) nor the tests of `load` would see it.
        let view = try #require(source.range(of: "private struct AvatarImage: View {")).upperBound
        let end = try #require(source.range(of: "enum AvatarDecoding {", range: view..<source.endIndex)).lowerBound
        let body = String(source[view..<end])
        #expect(body.contains("AvatarDecoding.load("), "the avatar view loads through AvatarDecoding.load")
        #expect(!body.contains("AvatarDecoding.decode(") && !body.contains("CGImageSource"), "and never decodes itself")
    }
}

/// TH2 (W29 L5): the deadline helper of the hostile probes must really give up on a body that blocks a thread, and must hand back a body that returns.
/// A synchronous wait, in a plain function so the async closure above only calls it.
private func blockThread(on gate: DispatchSemaphore) -> Int { gate.wait(); return 1 }

@Suite("TH2 probe deadline") struct ProbeDeadlineTests {
    @Test func aBodyThatBlocksItsThreadIsGivenUpOnAndABodyThatReturnsIsKept() async {
        let probes = HostileProbeTests()
        let gate = DispatchSemaphore(value: 0)
        let started = ContinuousClock.now
        let blocked: Int? = await probes.withinDeadline(0.3) { blockThread(on: gate) }   // blocks a thread synchronously
        #expect(blocked == nil, "a synchronously blocking body is abandoned at the deadline")
        #expect(ContinuousClock.now - started < .seconds(20), "and the caller was not held for it")
        gate.signal()   // let the abandoned thread finish
        let quick: Int? = await probes.withinDeadline(30) { 7 }
        #expect(quick == 7, "a body that returns is returned")
    }
}
