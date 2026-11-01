import Foundation
import Domain
import Testing
@testable import YouTubeMusicAdapter

final class TestTime: NetworkTime, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 0
    func now() -> TimeInterval { lock.withLock { value } }
    func advance(_ seconds: Double) { lock.withLock { value += seconds } }
    func wallNow() -> Date { Date(timeIntervalSince1970: 0).addingTimeInterval(now()) }
    func sleep(until deadline: TimeInterval) async throws { try Task.checkCancellation(); lock.withLock { value = max(value, deadline) }; await Task.yield() }
}
func owner(_ generation: UInt64 = 1, query: UInt64 = 1, account: AccountContext? = nil) -> RequestContext {
    RequestContext(account: account, accountGeneration: generation, requestGeneration: query)
}
func identity(_ channel: String = "channel", region: String = "US", id: UUID = UUID()) throws -> AccountContext {
    try AccountContext(accountID: id, channelID: ID(channel), region: region)
}
func route(_ purpose: NetworkPurpose = .metadata, replay: ReplaySafety = .knownRead, method: String = "POST") throws -> NetworkRoute {
    try NetworkRoute(host: "music.example.test", path: "/read", method: method, purpose: purpose, queryNames: ["q"], replay: replay)
}
func request(_ route: NetworkRoute, bytes: Int = 1024, credential: CredentialReference? = nil) throws -> BoundedRequest {
    try BoundedRequest(route: route, url: URL(string: "https://music.example.test/read?q=private-synthetic-query")!, bounds: ResponseBounds(bytes: bytes), credential: credential)
}
actor Probe {
    var calls = 0
    var active = 0
    var peak = 0
    var times: [Double] = []
    var waiters: [CheckedContinuation<Void, Never>] = []
    func record(_ time: Double = 0) { calls += 1; times.append(time) }
    func hold() async -> BoundedResponse {
        calls += 1; active += 1; peak = max(peak, active)
        await withCheckedContinuation { waiters.append($0) }
        active -= 1
        return BoundedResponse(status: 200, body: Data("{}".utf8))
    }
    func finished(_ count: Int) -> Bool { calls == count && active == 0 }
    func release() { let pending = waiters; waiters = []; for waiter in pending { waiter.resume() } }
}
func eventually(_ predicate: @escaping () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await predicate() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return false
}
