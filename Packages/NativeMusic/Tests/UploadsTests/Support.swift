import AccountSession
import CryptoKit
import Features
import Foundation
import Testing
@testable import YouTubeMusicAdapter

/// Everything in this target runs against scripted transports and synthetic audio written into scratch folders. Nothing reaches a
/// network, a real account, or any file the test did not make.

func packageRoot() -> URL {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { root.deleteLastPathComponent() }
    return root
}
func repositoryRoot() -> URL { packageRoot().deletingLastPathComponent().deletingLastPathComponent() }
func fixturesRoot() -> URL { repositoryRoot().appendingPathComponent("Fixtures") }
func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// A scratch folder that exists only for one test and is removed with it.
final class Scratch: @unchecked Sendable {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ytmuse-uploads-test-" + UUID().uuidString, isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    /// A small valid WAV (0.2 s of silence), written here: owned synthetic audio.
    @discardableResult func wav(_ name: String, extra: Int = 0) throws -> URL {
        let dataBytes = 3200 + extra
        func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        func le16(_ v: Int) -> [UInt8] { (0..<2).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        var bytes: [UInt8] = Array("RIFF".utf8) + le32(36 + dataBytes) + Array("WAVE".utf8) + Array("fmt ".utf8) + le32(16) + le16(1) + le16(1) + le32(8000) + le32(16000) + le16(2) + le16(16)
        bytes += Array("data".utf8) + le32(dataBytes) + [UInt8](repeating: 0, count: dataBytes)
        return try file(name, Data(bytes))
    }
    @discardableResult func file(_ name: String, _ data: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }
    func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func data(_ url: URL) throws -> Data { try Data(contentsOf: url) }
}

/// What a scripted upload does.
enum Script: Sendable {
    case succeeds
    case offline
    case refused(String?)
    /// Holds until released, reporting progress; ends with `.cancelled` when the task is cancelled.
    case hold
}

/// A scripted upload route. It records everything it is asked, never sends anything anywhere, and can hold an upload open until a test releases it.
final class ScriptedUpload: UploadTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _capability: UploadCapability
    private var scripts: [String: Script] = [:]
    private var defaultScript: Script = .succeeds
    private var processingScript: [String: [UploadProcessing]] = [:]
    private var processingErrors: [UploadTransportError] = []
    private(set) var uploads: [UploadRequest] = []
    private(set) var cancelledHandles: [String?] = []
    private(set) var processingAsked: [String] = []
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<String> = []
    private var running = 0
    private(set) var maxRunning = 0
    var runningNow: Int { lock.withLock { running } }
    private(set) var handles: [UUID: String] = [:]
    var lateReportAfterCancel = false
    private(set) var lateReports = 0
    private(set) var events: [String] = []
    /// How long `cancel(handle:)` takes, so a test can see whether anything else starts while the route is still being told.
    var cancelDelay: Duration = .zero

    init(capability: UploadCapability = UploadCapability(availability: .available)) { _capability = capability }
    var capability: UploadCapability { lock.withLock { _capability } }
    func setCapability(_ value: UploadCapability) { lock.withLock { _capability = value } }
    func script(_ name: String, _ value: Script) { lock.withLock { scripts[name] = value } }
    func setDefault(_ value: Script) { lock.withLock { defaultScript = value } }
    func processing(_ results: [UploadProcessing], for handleOf: UUID) { lock.withLock { processingScript[handleOf.uuidString] = results } }
    func defaultProcessing(_ results: [UploadProcessing]) { lock.withLock { processingScript["*"] = results } }
    func failProcessing(with errors: [UploadTransportError]) { lock.withLock { processingErrors = errors } }
    var uploadCount: Int { lock.withLock { uploads.count } }
    func handle(for id: UUID) -> String { "handle-" + id.uuidString }

    func release(_ name: String) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in released.insert(name); return gates.removeValue(forKey: name) }
        continuation?.resume()
    }
    func upload(_ request: UploadRequest, progress: @escaping @Sendable (Int64) -> Void, handle: @escaping @Sendable (String) -> Void) async throws -> String {
        let name = request.fileURL.lastPathComponent
        let script = lock.withLock { () -> Script in
            uploads.append(request); running += 1; maxRunning = max(maxRunning, running); events.append("upload:" + name)
            return scripts[name] ?? defaultScript
        }
        defer { lock.withLock { running -= 1 } }
        let id = self.handle(for: request.jobID)
        handle(id)
        switch script {
        case .succeeds:
            progress(request.byteCount / 2)
            return id
        case .offline: throw UploadTransportError.offline
        case .refused(let message): throw UploadTransportError.refused(message)
        case .hold:
            progress(request.byteCount / 4)
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let already = lock.withLock { () -> Bool in
                        if released.contains(name) { return true }
                        gates[name] = continuation; return false
                    }
                    if already { continuation.resume() }
                }
            } onCancel: {
                let continuation = lock.withLock { gates.removeValue(forKey: name) }
                continuation?.resume()
            }
            if Task.isCancelled {
                if lateReportAfterCancel { lock.withLock { lateReports += 1 }; progress(request.byteCount) }
                throw UploadTransportError.cancelled
            }
            progress(request.byteCount)
            return id
        }
    }
    func processing(handle: String) async throws -> UploadProcessing {
        let (error, next) = lock.withLock { () -> (UploadTransportError?, UploadProcessing) in
            processingAsked.append(handle)
            if !processingErrors.isEmpty { return (processingErrors.removeFirst(), .processing) }
            let key = processingScript[handle] != nil ? handle : "*"
            var list = processingScript[key] ?? [.completed]
            let first = list.count > 1 ? list.removeFirst() : list[0]
            processingScript[key] = list
            return (nil, first)
        }
        if let error { throw error }
        return next
    }
    func cancel(handle: String?) async {
        lock.withLock { events.append("cancel-begin") }
        if cancelDelay > .zero { try? await Task.sleep(for: cancelDelay) }
        lock.withLock { cancelledHandles.append(handle); events.append("cancel-end") }
    }
}

actor MemoryUploadStore: UploadJobStoring {
    private(set) var saved: [String: [UploadJob]] = [:]
    private(set) var saves = 0
    var failLoad = false
    var failSave = false
    func setFailLoad(_ value: Bool) { failLoad = value }
    func setFailSave(_ value: Bool) { failSave = value }
    func put(_ jobs: [UploadJob], account: String) { saved[account] = jobs }
    func load(account: String) throws -> [UploadJob] { if failLoad { throw CocoaError(.fileReadCorruptFile) }; return saved[account] ?? [] }
    func save(_ jobs: [UploadJob], account: String) throws { if failSave { throw CocoaError(.fileWriteUnknown) }; saved[account] = jobs; saves += 1 }
    func clear(account: String) throws { saved[account] = nil }
    func jobs(_ account: String) -> [UploadJob] { saved[account] ?? [] }
}

/// Counts every lease handed out and released, over the real file checks.
final class CountingAccess: UploadFileAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var opened = 0, released = 0
    private let inner = ScopedUploadFileAccess()
    var openedCount: Int { lock.withLock { opened } }
    var releasedCount: Int { lock.withLock { released } }
    func open(_ source: UploadSource) throws -> UploadFileLease {
        let lease = try inner.open(source)
        lock.withLock { opened += 1 }
        return UploadFileLease(url: lease.url) { [self] in lease.release(); lock.withLock { released += 1 } }
    }
}

@MainActor final class Harness {
    let scratch: Scratch
    let transport: ScriptedUpload
    let store = MemoryUploadStore()
    let access = CountingAccess()
    var account: String? = "11111111-1111-4111-8111-111111111111"
    var refreshCalls = 0
    var refreshResult = true
    var refreshedWhileProcessing: [UploadJob.Phase] = []
    var queue: UploadQueue!
    var inspector: UploadSourceInspector

    init(capability: UploadCapability = UploadCapability(availability: .available), polls: Int = 6, metadata: @escaping UploadSourceInspector.MetadataReader = { _ in nil }) throws {
        scratch = try Scratch(); transport = ScriptedUpload(capability: capability)
        inspector = UploadSourceInspector(metadata: metadata)
        queue = makeQueue(polls: polls)
    }
    func makeQueue(transport override: (any UploadTransport)? = nil, store override2: (any UploadJobStoring)? = nil, polls: Int = 6) -> UploadQueue {
        UploadQueue(transport: override ?? transport, store: override2 ?? store, access: access, inspector: inspector, accountKey: { [weak self] in self?.account },
                    refresh: { [weak self] in
                        guard let self else { return false }
                        refreshCalls += 1
                        refreshedWhileProcessing = queue.jobs.map(\.phase)
                        return refreshResult
                    },
                    pollDelays: Array(repeating: .milliseconds(1), count: polls), sleep: { _ in try await Task.sleep(for: .milliseconds(2)) })
    }
    /// A condition wait: it returns as soon as the condition holds, so the timeout is only the point at which "never" becomes a failure (TH2: 30 s, it was 5 s and failed under load).
    func until(_ what: String = "", timeout: Double = 30, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(condition(), Comment(rawValue: "timed out: \(what)"))
    }
    func phase(_ name: String) -> UploadJob.Phase? { queue.jobs.first { $0.source.displayName == name }?.phase }
    func job(_ name: String) -> UploadJob? { queue.jobs.first { $0.source.displayName == name } }
}

@MainActor final class Box<T> { var value: T; init(_ value: T) { self.value = value } }
