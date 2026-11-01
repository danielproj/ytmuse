import AppKit
import Foundation
import Testing
import Domain
import Downloads
import SystemIntegration
import WidgetShared
@testable import Artwork
@testable import AppShell

// T29.5. No blocking network, disk, hash or decode on the main actor or on an audio callback. Three kinds of evidence, none of them a timing guess:
//  1. a deterministic detector: every I/O seam is replaced by a recording wrapper that notes `Thread.isMainThread` at the moment the work runs, and the scenario is driven
//     FROM the main actor, which is where a missing hop would run it;
//  2. the pipelines that already count main-thread work (artwork decode and disk) driven with hostile input from the main actor;
//  3. source sweeps: blocking APIs inside main-actor code (`MainActorSweep` walks the whole product) and app-owned audio-thread callbacks.

final class ThreadLog: @unchecked Sendable {
    private let lock = NSLock(); private var rows: [(op: String, main: Bool)] = []
    func note(_ op: String) { lock.withLock { rows.append((op, Thread.isMainThread)) } }
    var all: [(op: String, main: Bool)] { lock.withLock { rows } }
    func ops(onMain: Bool) -> [String] { lock.withLock { rows.filter { $0.main == onMain }.map(\.op) } }
    func count(_ op: String) -> Int { lock.withLock { rows.filter { $0.op == op }.count } }
    func reset() { lock.withLock { rows = [] } }
}
/// The publisher's real disk and image work, recorded.
struct RecordingWidgetIO: WidgetSnapshotIO {
    let inner: DiskWidgetSnapshotIO
    let log: ThreadLog
    func write(_ snapshot: WidgetSnapshot) throws { log.note("write"); try inner.write(snapshot) }
    func read() -> WidgetReadResult { log.note("read"); return inner.read() }
    func delete() throws { log.note("delete"); try inner.delete() }
    func thumbnail(from data: Data) -> Data? { log.note("thumbnail"); return inner.thumbnail(from: data) }
}

@Suite("T29.5 the main actor does no blocking work", .serialized) struct ThreadAffinityTests {
    @MainActor final class Scope { var value: IntentScope?; init(_ value: IntentScope?) { self.value = value } }
    @Test @MainActor func theWidgetPublisherDecodesAndTouchesTheFileOnlyOffTheMainActor() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ytmuse-w29-threads-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = ThreadLog()
        let store = WidgetSnapshotStore(directory: dir)
        let center = NowPlayingCenter(system: NowPlayingSystem.recording().system)
        let account = UUID()
        let scope = Scope(IntentScope(accountID: account, generation: 2))
        let publisher = WidgetSnapshotPublisher(store: store, io: RecordingWidgetIO(inner: DiskWidgetSnapshotIO(store: store), log: log), reloader: RecordingTimelineReloader(), nowPlaying: center, liveScope: { scope.value }, reloadInterval: .milliseconds(1))
        center.onChange = { [publisher] in publisher.changed() }
        _ = center.activate { _ in .success }
        // A large picture, a change of item, a pause, then a sign-out, a removal and the quit barrier: every operation the publisher performs.
        let picture = Crafted.realImage(width: 2400, height: 2400)
        func item(_ title: String, id: String, playing: Bool = true) -> NowPlayingItem { NowPlayingItem(title: title, artist: "Artist", album: nil, artwork: picture, duration: 100, elapsed: 1, playing: playing, advertisement: false, itemID: id) }
        center.update(item("One", id: "1"), capabilities: nil); await publisher.settle()
        center.update(item("Two", id: "2"), capabilities: nil); await publisher.settle()
        center.update(item("Two", id: "2", playing: false), capabilities: nil); await publisher.settle()
        await publisher.barrier(.init(reason: .detach, departing: (account: account, generation: 2)))
        scope.value = IntentScope(accountID: account, generation: 3); publisher.scopeBound()
        center.update(item("Three", id: "3"), capabilities: nil); await publisher.settle()
        await publisher.barrier(.init(reason: .removal, departing: (account: account, generation: 3)))
        scope.value = nil
        await publisher.barrier(.init(reason: .quit, departing: nil))
        let rows = log.all
        #expect(log.count("thumbnail") >= 2 && log.count("write") >= 3 && log.count("read") >= 1 && log.count("delete") >= 1, "every kind of operation really ran: \(rows.map(\.op))")
        #expect(log.ops(onMain: true).isEmpty, "these ran on the main thread: \(log.ops(onMain: true))")
        // The whole run was driven from the main actor (this test is @MainActor), so a missing hop could only have shown up as a main-thread row.
    }
    /// The privacy reset is the one place the main actor waits for the file queue; it is named, explicit and one unlink.
    @Test @MainActor func onlyTheExplicitPrivacyResetWaitsForTheFileQueue() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ytmuse-w29-erase-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = ThreadLog()
        let store = WidgetSnapshotStore(directory: dir)
        let center = NowPlayingCenter(system: NowPlayingSystem.recording().system)
        let publisher = WidgetSnapshotPublisher(store: store, io: RecordingWidgetIO(inner: DiskWidgetSnapshotIO(store: store), log: log), reloader: RecordingTimelineReloader(), nowPlaying: center, liveScope: { IntentScope(accountID: UUID(), generation: 1) }, reloadInterval: .milliseconds(1))
        center.onChange = { [publisher] in publisher.changed() }
        _ = center.activate { _ in .success }
        center.update(NowPlayingItem(title: "T", artist: "A", album: nil, artwork: nil, duration: 10, elapsed: 0, playing: true, advertisement: false, itemID: "x"), capabilities: nil); await publisher.settle()
        log.reset()
        try publisher.eraseSnapshot()
        // TH2 (W29 L5): the first line here was `ops(onMain: false) == [] || count("delete") == 1`, which the next line already implies. The documented claim is that the reset is ONE
        // unlink that the main actor waits for. Which thread performs it is not asserted: `DispatchQueue.sync` may run the closure on the calling (main) thread, which is why
        // Security-Model.md describes the wait as an explicit, single exception rather than as a file-queue operation.
        #expect(log.all.map(\.op) == ["delete"], "the reset performed exactly one operation, the unlink: \(log.all.map(\.op))")
        #expect(log.count("delete") == 1 && store.read() == .missing, "the reset deleted the file in order, after any queued write")
    }

    // MARK: the pipelines that already count their own main-thread work, driven from the main actor with hostile input
    @Test @MainActor func artworkDecodeAndDiskCacheRunOffTheMainActorEvenForABomb() async throws {
        struct Source: ArtworkSource {
            let bytes: Data
            func load(resource: ArtworkResource, owner: ArtworkOwner, generation: UInt64, maximumBytes: Int) async throws -> ArtworkSourceData { ArtworkSourceData(bytes: bytes, policy: .disk(until: Date(timeIntervalSince1970: 4_000_000_000))) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ytmuse-w29-art-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = ArtworkOwner(account: try AccountContext(accountID: UUID(), channelID: ID("w29"), region: "US"))
        func request(_ id: String) throws -> ArtworkRequest {
            ArtworkRequest(resource: try ArtworkResource(namespace: "owned-test", identifier: id, revision: "1"), size: try ArtworkSize(pointsWidth: 64, pointsHeight: 64, scale: 2),
                           policy: .disk(until: Date(timeIntervalSince1970: 4_000_000_000)), context: RequestContext(account: owner.account, accountGeneration: 1, requestGeneration: 1))
        }
        let good = ArtworkPipeline(source: Source(bytes: Crafted.realImage(width: 3000, height: 2000)), diskDirectory: root.appendingPathComponent("good"))
        try await good.setAccountGeneration(owner: owner, generation: 1)
        _ = try await good.image(for: request("a"))
        let bomb = ArtworkPipeline(source: Source(bytes: Crafted.pngHeaderOnly(width: 40_000, height: 40_000)), diskDirectory: root.appendingPathComponent("bomb"))
        try await bomb.setAccountGeneration(owner: owner, generation: 1)
        await #expect(throws: (any Error).self) { _ = try await bomb.image(for: request("b")) }
        for pipeline in [good, bomb] {
            let general = await pipeline.snapshot(), native = await pipeline.nativeSnapshot(), disk = await pipeline.diskSnapshot()
            #expect(general.mainThreadWorkViolations == 0 && native.mainThreadWorkViolations == 0 && disk.mainThreadWorkViolations == 0)
        }
        let goodNative = await good.nativeSnapshot(), bombNative = await bomb.nativeSnapshot()
        #expect(goodNative.completedDecodes == 1 && bombNative.completedDecodes == 0, "the good image decoded and the bomb did not")
    }
    @Test @MainActor func aDownloadsReadsAndRetentionRunOffTheMainActor() async throws {
        let log = ThreadLog()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ytmuse-w29-dl-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let source = ThreadSource(log: log), sink = ThreadSink(log: log)
        let scheduler = try DownloadScheduler(ledgerRoot: root.appendingPathComponent("jobs"), sink: sink, sources: [.owned: source], wall: SystemWallClock(), volume: VolumeStub(),
                                              configuration: .init(chunkBytes: 1024, persistEveryChunks: 1, minimumBudget: 1024), wake: { _, _ in { } }, suggestionsAvailable: true,
                                              originOf: { $0.rawValue.hasPrefix("owned-") ? .owned : MediaOrigin.classify($0) })
        let account = try AccountContext(accountID: UUID(), channelID: ID("w29-threads"), region: "US")
        await scheduler.bind(RequestContext(account: account, accountGeneration: 1, requestGeneration: 0))
        let media = try ServiceID("owned-thread-probe")
        _ = await scheduler.download(media, title: "Probe", request: .manual)
        var done = false
        for _ in 0..<500 { if await scheduler.isAvailable(media) { done = true; break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(done, "the download finished")
        #expect(log.count("describe") >= 1 && log.count("read") >= 8 && log.count("retain") >= 1, "the source and the store were really used: \(log.all.map(\.op))")
        #expect(log.ops(onMain: true).isEmpty, "these ran on the main thread: \(Set(log.ops(onMain: true)))")
    }

    // MARK: sweeps
    /// Blocking APIs inside code the compiler isolates to the main actor. It walks every Swift file of the product; the named exceptions are the reviewed ones, each with its reason.
    @Test func noMainActorTypeCallsABlockingAPI() throws {
        let findings = try MainActorSweep.run()
        #expect(findings.scanned > 120, "the sweep looked at \(findings.scanned) main-actor declarations")
        #expect(findings.hits.isEmpty, "\(findings.hits.joined(separator: "\n"))")
        // The sweep fires on its own plants and passes the near miss.
        #expect(!MainActorSweep.hits(in: "@MainActor final class V { func f() { let d = try! Data(contentsOf: url) } }", file: "planted").isEmpty)
        #expect(!MainActorSweep.hits(in: "@MainActor struct V { func f() { _ = SHA256.hash(data: big) } }", file: "planted").isEmpty)
        #expect(!MainActorSweep.hits(in: "@MainActor final class V { func f() { _ = CGImageSourceCreateWithData(d, nil) } }", file: "planted").isEmpty)
        #expect(MainActorSweep.hits(in: "final class V { func f() { let d = try! Data(contentsOf: url) } }", file: "planted").isEmpty, "not main-actor code")
        #expect(MainActorSweep.hits(in: "@MainActor final class V { func f() { Task.detached { _ = try? Data(contentsOf: url) } } }", file: "planted").isEmpty, "work handed to a detached task is not main-actor work")
        #expect(MainActorSweep.hits(in: "@MainActor final class V { func f() async { try? await sleep(for: .seconds(1)) } }", file: "planted").isEmpty, "an awaited sleep suspends, it does not block")
        #expect(!MainActorSweep.hits(in: "@MainActor final class V { func f() { sleep(2) } }", file: "planted").isEmpty)
        // TH2: a SwiftUI view is main-actor without the attribute (the avatar decoded in a view body went unseen).
        #expect(!MainActorSweep.hits(in: "struct V: View { var body: some View { if let i = NSImage(data: d) { Image(nsImage: i) } } }", file: "planted").isEmpty)
        #expect(!MainActorSweep.hits(in: "private struct Card<A: View>: Equatable, View {\n  var body: some View { Text(\"x\") }\n  func f() { _ = CGImageSourceCreateWithData(d, nil) }\n}", file: "planted").isEmpty, "a generic view with several conformances")
        #expect(!MainActorSweep.hits(in: "struct W: NSViewRepresentable { func makeNSView(context: Context) -> NSView { _ = NSImage(data: d); return NSView() } }", file: "planted").isEmpty)
        #expect(!MainActorSweep.hits(in: "struct M: ViewModifier { func body(content: Content) -> some View { let x = try? Data(contentsOf: u); return content } }", file: "planted").isEmpty)
        #expect(MainActorSweep.hits(in: "struct V: View { var body: some View { Text(\"x\") } }\nstruct Decoder { func f() { _ = NSImage(data: d) } }", file: "planted").isEmpty, "a type that is not a view is not main-actor work")
        #expect(MainActorSweep.hits(in: "struct V: View { var body: some View { Text(\"x\").task { await Task.detached { _ = NSImage(data: d) }.value } } }", file: "planted").isEmpty, "detached work inside a view runs elsewhere")
        #expect(!MainActorSweep.allowed.isEmpty && MainActorSweep.allowed.allSatisfy { !$0.reason.isEmpty })
    }
    @Test func appOwnedAudioThreadCodeIsOnlyTheOptInMeasurementTap() throws {
        let banned = ["AVAudioSourceNode", "AVAudioSinkNode", "installTap", "internalRenderBlock", "AUInternalRenderBlock", "AURenderCallback", "AURenderCallbackStruct", "kAudioUnitProperty_SetRenderCallback", "AUAudioUnit.inputHandler", "outputProvider", "MTAudioProcessingTapCallbacks", "AudioQueueNewOutput", "AudioDeviceCreateIOProcID"]
        var holders: Set<String> = []
        var scanned = 0
        for file in Repo.swiftFiles(under: "Packages/NativeMusic/Sources") + Repo.swiftFiles(under: "App/Sources") {
            scanned += 1
            let code = Repo.code(try String(contentsOf: file, encoding: .utf8))
            for word in banned where code.contains(word) { holders.insert(file.lastPathComponent) }
        }
        #expect(scanned > 300)
        #expect(holders == ["RenderProbe.swift"], "audio-thread callbacks live only in the measurement tap: \(holders)")
        // The tap exists only when a test asks for it, and nothing in the product turns the flag on.
        let player = Repo.code(try Repo.text("Packages/NativeMusic/Sources/Playback/NativePlayer.swift"))
        #expect(player.contains("probe = observeRendering ? RenderProbe() : nil"))
        for file in Repo.swiftFiles(under: "Packages/NativeMusic/Sources") + Repo.swiftFiles(under: "App/Sources") {
            let code = Repo.code(try String(contentsOf: file, encoding: .utf8))
            if file.lastPathComponent != "NativePlayer.swift" { #expect(!code.contains("observeRendering: true"), "\(file.lastPathComponent) turns the measurement tap on") }
        }
        // Buffers are scheduled with no completion handler, so no app code runs on the audio framework's queue.
        for name in ["DecodedAudio.swift", "IncrementalDecodedPlayer.swift"] {
            let code = Repo.code(try Repo.text("Packages/NativeMusic/Sources/Playback/" + name))
            #expect(!code.contains("completionHandler") && !code.contains("completionCallbackType"), "\(name) schedules audio with a completion handler")
        }
        // And the tap's own process block touches no disk, network or allocation-heavy API (its lock guards a counter the test reads afterwards).
        let tap = Repo.code(try Repo.text("Packages/NativeMusic/Sources/Playback/RenderProbe.swift"))
        for word in ["FileManager", "URLSession", "Data(contentsOf", "DispatchQueue", "Task {", "Task.detached", "print(", "Logger", "NSLog", "malloc", "Array(repeating", "[UInt8](repeating"] { #expect(!tap.contains(word), "RenderProbe.swift names \(word)") }
    }
}
actor ThreadSource: DownloadSource {
    let log: ThreadLog
    let bytes = Data((0..<8192).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    init(log: ThreadLog) { self.log = log }
    func describe(item: SourceItem, context: RequestContext) async throws -> SourceDescriptor {
        log.note("describe"); let now = Date()
        return SourceDescriptor(variant: "v-thread", validator: "v1", length: Int64(bytes.count), supportsRanges: true, urlExpiresAt: now.addingTimeInterval(60), sha256: nil,
                                permission: DownloadPermission(issuer: "Owned synthetic", sourceEncryption: "none", validatedAt: now, expires: now.addingTimeInterval(3600), renewAfter: nil, renewalReference: "r"))
    }
    func read(item: SourceItem, descriptor: SourceDescriptor, offset: Int64, count: Int, context: RequestContext) async throws -> SourceRead {
        log.note("read")
        guard offset < Int64(bytes.count) else { return SourceRead(data: Data(), endOfStream: true) }
        let end = min(Int(offset) + count, bytes.count)
        return SourceRead(data: bytes.subdata(in: Int(offset)..<end), endOfStream: end >= bytes.count)
    }
    func renew(item: SourceItem, descriptor: SourceDescriptor, context: RequestContext) async throws -> DownloadPermission { throw SourceFailure.permissionDenied }
    func contentDigest(item: SourceItem, descriptor: SourceDescriptor, length: Int64) async throws -> String? { log.note("digest"); return nil }
}
actor ThreadSink: RetentionSink {
    let log: ThreadLog
    private var objects: [String: Data] = [:]
    init(log: ThreadLog) { self.log = log }
    func retain(file: URL, variant: String, grant: RetentionGrant, reference: String, context: RequestContext) throws { log.note("retain"); objects[variant] = try Data(contentsOf: file) }
    func addReference(variant: String, reference: String, context: RequestContext) { log.note("addReference") }
    func removeReference(variant: String, reference: String, context: RequestContext) { log.note("removeReference") }
    func setPinned(variant: String, pinned: Bool, context: RequestContext) {}
    func retainedLength(variant: String, context: RequestContext) throws -> Int { log.note("length"); guard let o = objects[variant] else { throw OfflineRecovery.notRetained }; return o.count }
    func verify(variant: String, context: RequestContext) throws -> String? { log.note("verify"); return nil }
    func updateGrant(variant: String, grant: RetentionGrant, context: RequestContext) {}
    func delete(variant: String, context: RequestContext) { objects[variant] = nil }
    func bind(_ context: RequestContext) {}
}

/// Finds blocking calls inside main-actor declarations: a `@MainActor` type, extension or function, brace-matched on comment- and string-free text.
enum MainActorSweep {
    static let blocking: [(String, String)] = [
        (#"Data\(contentsOf"#, "reads a file or URL synchronously"), (#"String\(contentsOf"#, "reads a file or URL synchronously"), (#"NSData\(contentsOf"#, "reads a file synchronously"), (#"NSImage\(contentsOf"#, "reads and decodes an image"),
        (#"\.contents\(atPath"#, "reads a file"), (#"contentsOfDirectory"#, "lists a directory"), (#"\.write\(to:"#, "writes a file"), (#"createFile\(atPath"#, "writes a file"), (#"FileHandle\("#, "opens a file"),
        (#"SHA256\.hash\(data"#, "hashes a buffer"), (#"CGImageSourceCreate"#, "decodes an image"), (#"CGImageDestinationFinalize"#, "encodes an image"), (#"NSImage\(data"#, "decodes an image"),
        (#"DispatchSemaphore"#, "waits on a semaphore"), (#"Thread\.sleep"#, "sleeps the thread"), (#"\busleep\("#, "sleeps the thread"), (#"(?<![\w.])(?<!await )sleep\(\s*\d"#, "sleeps the thread"), (#"\.wait\(\)"#, "blocks on a wait"),
        (#"DispatchQueue\.main\.sync"#, "main-queue sync"), (#"URLSession\.shared\.(data|bytes)"#, "makes a network request"), (#"sqlite3_"#, "calls SQLite"), (#"JSONDecoder\(\)\.decode\([^)]*contentsOf"#, "decodes a file"),
    ]
    /// Reviewed exceptions: `file:pattern-prefix` pairs with the reason in the sweep's report. Each is bounded, explicit or already behind a hop.
    static let allowed: [(file: String, pattern: String, reason: String)] = [
        ("LocalAccountComposition.swift", #"DispatchQueue\.main\.sync"#, "the diagnostic log's context provider runs on whatever thread logs; it takes the main-queue branch only OFF the main thread (the main thread answers directly), so the main thread never waits on itself"),
        ("WidgetViews.swift", #"NSImage\(data"#, "TH2: a widget view is rendered once per timeline entry in the widget extension, which has no interactive main thread and cannot await; its input is the publisher's own thumbnail, bounded at 32 KB (`WidgetSnapshot.artworkByteLimit`)"),
        ("DevelopmentUploads.swift", #"\.write\(to:"#, "design-mode fixture: four 3 KB synthetic WAV files, written only under the Debug development flags in an isolated session"),
    ]
    struct Result { var scanned = 0; var hits: [String] = [] }
    /// Removes comments and string literals so braces and words inside them do not count.
    static func strip(_ text: String) -> String {
        var out = "", i = text.startIndex
        while i < text.endIndex {
            let c = text[i], next = text.index(after: i) < text.endIndex ? text[text.index(after: i)] : Character(" ")
            if c == "/" && next == "/" { while i < text.endIndex && text[i] != "\n" { i = text.index(after: i) }; continue }
            if c == "/" && next == "*" { i = text.index(i, offsetBy: 2); while i < text.endIndex && !(text[i] == "*" && text.index(after: i) < text.endIndex && text[text.index(after: i)] == "/") { i = text.index(after: i) }; i = text.index(i, offsetBy: min(2, text.distance(from: i, to: text.endIndex))); continue }
            if c == "\"" {
                if text[i...].hasPrefix("\"\"\"") { var j = text.index(i, offsetBy: 3); while j < text.endIndex && !text[j...].hasPrefix("\"\"\"") { j = text.index(after: j) }; i = j < text.endIndex ? text.index(j, offsetBy: 3) : text.endIndex; out += "\"\""; continue }
                var j = text.index(after: i)
                while j < text.endIndex && text[j] != "\"" { if text[j] == "\\" && text.index(after: j) < text.endIndex { j = text.index(after: j) }; if text[j] == "\n" { break }; j = text.index(after: j) }
                i = j < text.endIndex ? text.index(after: j) : text.endIndex; out += "\"\""; continue
            }
            out.append(c); i = text.index(after: i)
        }
        return out
    }
    /// The text of every declaration annotated `@MainActor` (type, extension, protocol or function), through its matching closing brace.
    static func mainActorBodies(_ code: String) -> [(name: String, body: String)] {
        var result: [(String, String)] = []
        var search = code.startIndex
        while let at = code.range(of: "@MainActor", range: search..<code.endIndex) {
            search = at.upperBound
            guard let open = code[at.upperBound...].firstIndex(of: "{") else { break }
            // A single-line attribute on a closure type or a stored property has no body before the next declaration; skip when a `;` or `=` ends the line first.
            let head = code[at.upperBound..<open]
            if head.contains("\n\n") || head.contains("=") && !head.contains("func") && !head.contains("class") && !head.contains("struct") && !head.contains("enum") && !head.contains("extension") { continue }
            var depth = 0, end = open
            for index in code[open...].indices { let ch = code[index]; if ch == "{" { depth += 1 } else if ch == "}" { depth -= 1; if depth == 0 { end = index; break } } }
            let name = head.split(whereSeparator: { $0 == "\n" }).last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            result.append((name, String(code[open...end])))
        }
        return result + swiftUIBodies(code)
    }
    /// TH2: a SwiftUI view (and a view modifier or a representable) is main-actor without the attribute: its `body` and everything declared in the type run there. The
    /// declaration is found by its conformance, brace-matched like the attributed ones.
    static let viewConformance = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]*(?:(?:public|private|fileprivate|internal|final|indirect)\s+)*(?:struct|class|enum|extension)\s+[\w.]+(?:<[^{>]*>)?\s*:\s*[^{\n]*\b(?:View|ViewModifier|NSViewRepresentable|NSViewControllerRepresentable|ToolbarContent|Commands|Scene|App)\b[^{]*\{"#)
    static func swiftUIBodies(_ code: String) -> [(name: String, body: String)] {
        var result: [(String, String)] = []
        for match in viewConformance.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            guard let range = Range(match.range, in: code) else { continue }
            let open = code.index(before: range.upperBound)
            var depth = 0, end = open
            for index in code[open...].indices { let ch = code[index]; if ch == "{" { depth += 1 } else if ch == "}" { depth -= 1; if depth == 0 { end = index; break } } }
            result.append((String(code[range].prefix(80)), String(code[open...end])))
        }
        return result
    }
    static func hits(in text: String, file: String) -> [String] {
        let code = strip(text)
        var out: [String] = []
        for body in mainActorBodies(code).map(\.body) {
            // Work handed to a detached task or a nonisolated function runs elsewhere.
            let scrubbed = body.replacingOccurrences(of: #"Task\.detached[^{]*\{(?:[^{}]|\{[^{}]*\})*\}"#, with: "", options: .regularExpression)
            for (pattern, why) in blocking where scrubbed.range(of: pattern, options: .regularExpression) != nil {
                if allowed.contains(where: { $0.file == file && $0.pattern == pattern }) { continue }
                out.append("\(file): a main-actor declaration \(why) (\(pattern))")
            }
        }
        return Array(Set(out)).sorted()
    }
    static func run() throws -> Result {
        var result = Result()
        for base in ["Packages/NativeMusic/Sources", "App/Sources", "Extensions/Sources"] {
            for file in Repo.swiftFiles(under: base) {
                let text = try String(contentsOf: file, encoding: .utf8)
                // A file-level `@MainActor` attribute is rare; the same walker sees it as a declaration.
                result.scanned += mainActorBodies(strip(text)).count
                result.hits += hits(in: text, file: file.lastPathComponent)
            }
        }
        return result
    }
}
