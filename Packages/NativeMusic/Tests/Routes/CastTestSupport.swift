import Foundation
import Darwin
import Testing
@testable import OutputRoutes

// W39 test support. NOTHING here browses, resolves or connects to anything but 127.0.0.1 inside this process: receivers are `SimulatedCastReceiver`,
// the relay listens on loopback, and the one client below only ever connects to a loopback address (it refuses anything else).

enum CastFixtures {
    static let livingRoom = CastDevice(id: CastDeviceID("SYNTH-CAST-LIVING")!, friendlyName: "Living Room", model: "Synthetic Cast", capabilityBits: 5)
    /// Same friendly name, a different device (two receivers called "Living Room").
    static let otherLivingRoom = CastDevice(id: CastDeviceID("SYNTH-CAST-OTHER")!, friendlyName: "Living Room", model: "Synthetic Cast", capabilityBits: 5)
    static let kitchen = CastDevice(id: CastDeviceID("SYNTH-CAST-KITCHEN")!, friendlyName: "Kitchen", model: "Synthetic Cast", capabilityBits: 4)
    static let videoOnly = CastDevice(id: CastDeviceID("SYNTH-CAST-TV")!, friendlyName: "TV", model: "Synthetic", capabilityBits: 1)

    /// A synthetic WAV-named file of deterministic bytes (the relay serves files by extension and never reads their content).
    static func audioFile(bytes count: Int = 4_096, name: String = "tone", ext: String = "wav", in directory: URL? = nil) throws -> URL {
        let folder = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("ytmuse-w39-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(name).\(ext)")
        try Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }).write(to: url)
        return url
    }
    static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

/// A blocking HTTP/1.1 client for loopback only.
enum LoopbackHTTP {
    struct Reply { let status: Int; let headers: [String: String]; let body: Data; let raw: Data }
    enum Failure: Error { case notLoopback, connect, closedWithoutReply }

    static func connected(port: UInt16, host: String = "127.0.0.1") throws -> Int32 {
        guard host == "127.0.0.1" else { throw Failure.notLoopback }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.connect }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { Darwin.close(descriptor); throw Failure.connect }
        return descriptor
    }
    static func send(_ descriptor: Int32, _ bytes: Data) { bytes.withUnsafeBytes { _ = Darwin.send(descriptor, $0.baseAddress, bytes.count, 0) } }
    static func readAll(_ descriptor: Int32) -> Data {
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }
    static func parse(_ raw: Data) -> Reply? {
        guard let split = raw.range(of: Data("\r\n\r\n".utf8)), let head = String(data: raw[raw.startIndex..<split.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let status = lines.removeFirst().split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
        var headers: [String: String] = [:]
        for line in lines { if let colon = line.firstIndex(of: ":") { headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) } }
        return Reply(status: status, headers: headers, body: Data(raw[split.upperBound...]), raw: raw)
    }
    /// One request on one connection; nil when the server closed it without a reply.
    static func request(port: UInt16, raw: String) throws -> Reply? {
        let descriptor = try connected(port: port)
        defer { Darwin.close(descriptor) }
        send(descriptor, Data(raw.utf8))
        return parse(readAll(descriptor))
    }
    static func get(port: UInt16, path: String, headers: [String: String] = [:], method: String = "GET") throws -> Reply? {
        var text = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        return try request(port: port, raw: text + "\r\n")
    }
    /// Whether anything accepts connections on the port.
    static func isListening(port: UInt16) -> Bool { (try? connected(port: port)).map { Darwin.close($0); return true } ?? false }
}

func waitUntil(_ seconds: Double = 3, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// The native session as the driver sees it: a recorder with settable state. `log` is shared with the receiver simulation so the ORDER of local and
/// receiver actions can be asserted.
@MainActor final class FakeLocal: CastLocalTransport {
    var state: CastLocalState
    var confirmsSilence = true
    private(set) var silenced = false
    private(set) var log: [String] = []
    let sharedLog: SharedLog
    init(item: CastLocalItem?, playing: Bool = true, position: Double = 0, sharedLog: SharedLog = SharedLog()) {
        state = CastLocalState(item: item, playing: playing, position: position); self.sharedLog = sharedLog
    }
    private func note(_ entry: String) { log.append(entry); sharedLog.append("local:" + entry) }
    func localState() async -> CastLocalState { state }
    func setSilenced(_ on: Bool) async -> Bool { note(on ? "silence" : "unsilence"); if confirmsSilence { silenced = on }; return confirmsSilence }
    func pauseLocal() async { note("pause"); state = CastLocalState(item: state.item, playing: false, position: state.position) }
    func resumeLocal() async { note("resume"); state = CastLocalState(item: state.item, playing: true, position: state.position) }
    func seekLocal(_ seconds: Double) async { note("seek:\(seconds)"); state = CastLocalState(item: state.item, playing: state.playing, position: seconds) }
    /// The person's own action on the session.
    func person(playing: Bool) { state = CastLocalState(item: state.item, playing: playing, position: state.position) }
    func moveTo(_ item: CastLocalItem?, playing: Bool? = nil, position: Double = 0) { state = CastLocalState(item: item, playing: playing ?? state.playing, position: position) }
}
final class SharedLog: @unchecked Sendable {
    private let lock = NSLock(); private var entries: [String] = []
    func append(_ entry: String) { lock.withLock { entries.append(entry) } }
    var all: [String] { lock.withLock { entries } }
}

/// The local engine as the coordinator sees it, backed by `FakeLocal` (so a route-loss pause really pauses the session).
@MainActor final class CastTestEngine: OutputEngine {
    let kind = OutputEngineKind.localMedia
    let backend = OutputBackend.avPlayer
    let local: FakeLocal
    private(set) var lossPauses = 0
    init(local: FakeLocal) { self.local = local }
    var isAudibleOrWanted: Bool { local.state.playing }
    func pauseForRouteLoss() async -> Bool { lossPauses += 1; await local.pauseLocal(); return true }
    func stopForHandoff() async -> Bool { await local.pauseLocal(); return true }
    func apply(output uid: String?) async -> Bool { true }
}

@MainActor struct CastRig {
    let coordinator: OutputRouteCoordinator
    let store: MemoryPreferredRoute
    let quit: MemoryCastQuitChoice
    let receiver: SimulatedCastReceiver
    let local: FakeLocal
    let engine: CastTestEngine
    let music: RecordingEngine
    let driver: CastRouteDriver
    let file: URL
    let log: SharedLog

    static func item(_ key: String = "item-1", file: URL, title: String = "Synthetic tone", duration: Double? = 120) -> CastLocalItem {
        CastLocalItem(key: key, source: .file(file), title: title, artist: "Synthetic", duration: duration)
    }
    static func make(devices: [CastDevice] = [CastFixtures.livingRoom], preferred: OutputRouteID? = nil, playing: Bool = true, position: Double = 12, item makeItem: ((URL) -> CastLocalItem?)? = nil,
                     factory: (@MainActor (SimulatedCastReceiver) -> any CastChannelFactory)? = nil, driverConfiguration: CastDriverConfiguration? = nil,
                     quitChoice: CastQuitChoice? = nil, withDevicesListed: Bool = true) async throws -> CastRig {
        let file = try CastFixtures.audioFile()
        let log = SharedLog()
        let directory = ScriptedDirectory([Synthetic.speakers], defaultUID: Synthetic.speakers.uid)
        let store = MemoryPreferredRoute(preferred)
        let coordinator = OutputRouteCoordinator(directory: directory, store: store)
        coordinator.start()
        let local = FakeLocal(item: makeItem?(file) ?? item(file: file), playing: playing, position: position, sharedLog: log)
        let engine = CastTestEngine(local: local), music = RecordingEngine(.youTubeMusic)
        await coordinator.register(music); await coordinator.register(engine)
        let receiver = SimulatedCastReceiver()
        var configuration = driverConfiguration ?? CastDriverConfiguration()
        configuration.session.runsHeartbeat = false
        let quit = MemoryCastQuitChoice(quitChoice)
        let driver = CastRouteDriver(coordinator: coordinator, factory: factory?(receiver) ?? receiver, local: local, quitChoice: quit, configuration: configuration)
        if withDevicesListed { coordinator.castDirectoryChanged(devices) }
        return CastRig(coordinator: coordinator, store: store, quit: quit, receiver: receiver, local: local, engine: engine, music: music, driver: driver, file: file, log: log)
    }
    func cleanup() { CastFixtures.remove(file) }
}
