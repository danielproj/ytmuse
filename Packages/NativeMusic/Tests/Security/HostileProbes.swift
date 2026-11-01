import Foundation
import Testing
import Domain
import Downloads
import Features

// T29.2, probes: a file the app is asked to look at is a regular file of finite size or it is refused, and a read is never larger than the app's own chunk. Nothing here blocks:
// every probe of a special file runs under a deadline, because a FIFO opened for reading with no writer blocks forever unless the code refuses it first.

@Suite("T29.2 probes of files that are not what they claim to be") struct HostileProbeTests {
    func scratch() throws -> SecurityScratch { try SecurityScratch() }
    func item(_ url: URL) throws -> SourceItem { SourceItem(media: try ServiceID("owned-probe"), location: url.path) }
    let context = RequestContext(account: nil, accountGeneration: 1, requestGeneration: 0)
    /// Runs `body` with a deadline; a probe that does not return in time fails the test instead of hanging the run. TH2 (W29 L5): the previous form raced two child tasks in a task
    /// group, and a group waits for ALL its children, so a body that blocked a thread synchronously (an `open()` on a FIFO) was never abandoned: the run hung. The body now runs in its
    /// own detached task and the deadline is a dispatch timer on another thread; whichever finishes first resumes the caller once. A body that really blocks leaves its thread blocked
    /// until the process ends, which is the cost of reporting the failure instead of hanging.
    func withinDeadline<T: Sendable>(_ seconds: Double = 5, _ body: @escaping @Sendable () async -> T) async -> T? {
        let once = ResumeOnce<T?>()
        return await withCheckedContinuation { continuation in
            once.install(continuation)
            Task.detached { once.finish(await body()) }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { once.finish(nil) }
        }
    }
    func fifo(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("pipe.wav")
        #expect(mkfifo(url.path, 0o600) == 0)
        return url
    }
    func sparse(_ url: URL, bytes: Int64) throws {
        FileManager.default.createFile(atPath: url.path, contents: Data([0x52, 0x49, 0x46, 0x46]), attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: url); try handle.truncate(atOffset: UInt64(bytes)); try handle.close()
    }

    @Test func theLocalFileSourceRefusesEverythingThatIsNotARegularFileWithoutBlocking() async throws {
        let dir = try scratch(); defer { dir.cleanup() }
        let regular = dir.url.appendingPathComponent("a.wav"); try Data(repeating: 7, count: 4096).write(to: regular)
        let link = dir.url.appendingPathComponent("link.wav"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        let folder = dir.url.appendingPathComponent("folder.wav", isDirectory: true); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let empty = dir.url.appendingPathComponent("empty.wav"); FileManager.default.createFile(atPath: empty.path, contents: Data())
        let hostile: [(String, URL)] = [("symlink", link), ("directory", folder), ("empty", empty), ("fifo", try fifo(in: dir.url)), ("/dev/zero", URL(fileURLWithPath: "/dev/zero")), ("/dev/random", URL(fileURLWithPath: "/dev/random")),
                                         ("missing", dir.url.appendingPathComponent("nothing.wav"))]
        for (name, url) in hostile {
            let source = LocalFileDownloadSource(issuer: "w29") { _ in url }
            let target = try item(url)
            let ctx = context
            let outcome = await withinDeadline { () -> String in
                do { _ = try await source.describe(item: target, context: ctx); return "described" } catch let failure as SourceFailure { return "\(failure)" } catch { return "other" }
            }
            #expect(outcome == "unavailable", "\(name): \(outcome ?? "did not return within the deadline")")
        }
        // The control: the regular file is described, so the refusals above are about the file and not about the harness.
        let ok = LocalFileDownloadSource(issuer: "w29") { _ in regular }
        let descriptor = try await ok.describe(item: try item(regular), context: context)
        #expect(descriptor.length == Int64(4096))
    }
    @Test func aReadIsNeverLargerThanTheAppsOwnChunkWhateverTheCallerAsks() async throws {
        let dir = try scratch(); defer { dir.cleanup() }
        let big = dir.url.appendingPathComponent("big.wav"); try sparse(big, bytes: 256 * 1024 * 1024)
        let source = LocalFileDownloadSource(issuer: "w29") { _ in big }
        let target = try item(big)
        let descriptor = try await source.describe(item: target, context: context)
        #expect(descriptor.length == Int64(256 * 1024 * 1024))
        for ask in [1 << 20, 1 << 28, Int.max, Int.max / 2] {
            let read = try await source.read(item: target, descriptor: descriptor, offset: 0, count: ask, context: context)
            #expect(read.data.count <= LocalFileDownloadSource.maximumRead, "asked for \(ask), received \(read.data.count)")
        }
        let past = try await source.read(item: target, descriptor: descriptor, offset: descriptor.length ?? 0, count: 4096, context: context)
        #expect(past.data.isEmpty && past.endOfStream)
        let negative = try? await source.read(item: target, descriptor: descriptor, offset: -1, count: 4096, context: context)
        #expect(negative == nil || (negative?.data.count ?? 0) <= 4096, "a negative offset cannot read before the file")
    }
    @Test func theUploadInspectorReadsAHeaderOnlyAndRefusesSpecialFiles() async throws {
        let dir = try scratch(); defer { dir.cleanup() }
        let inspector = UploadSourceInspector(maximumFileBytes: nil, testRoot: dir.url)
        let big = dir.url.appendingPathComponent("huge.wav"); try sparse(big, bytes: 4 * 1024 * 1024 * 1024)
        let started = Date()
        let result = await withinDeadline(10) { await inspector.inspect(big) }
        #expect(Date().timeIntervalSince(started) < 10 && result != nil, "a 4 GiB file is inspected from its header, not read")
        let folder = dir.url.appendingPathComponent("folder", isDirectory: true); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let pipe = try fifo(in: dir.url)
        for (name, url) in [("folder", folder), ("fifo", pipe)] {
            let outcome = await withinDeadline { () -> Bool in if case .failure = await inspector.inspect(url) { true } else { false } }
            #expect(outcome == true, "\(name) is refused without blocking")
        }
        let limited = UploadSourceInspector(maximumFileBytes: 1024, testRoot: dir.url)
        let outcome = await limited.inspect(big)
        if case .failure(let reason) = outcome { #expect("\(reason)".hasPrefix("tooLarge")) } else { Issue.record("a file above the published limit was accepted") }
        // Outside the one folder a test may use, nothing is read at all.
        if case .success = await inspector.inspect(URL(fileURLWithPath: "/dev/zero")) { Issue.record("a file outside the test folder was inspected") }
    }
}

/// Resumes one continuation, once, with the first value offered.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var done = false
    func install(_ continuation: CheckedContinuation<T, Never>) { lock.withLock { self.continuation = continuation } }
    func finish(_ value: T) {
        let resume: CheckedContinuation<T, Never>? = lock.withLock { if done { return nil }; done = true; return continuation }
        resume?.resume(returning: value)
    }
}
