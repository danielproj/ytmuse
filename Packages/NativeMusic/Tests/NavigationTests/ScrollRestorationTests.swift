import Testing
import Foundation
@testable import AppShell

@Suite(.serialized) @MainActor struct ScrollRestorationTests {
    private func session() -> BrowserSession { var s = BrowserSession(); s.open(.library); s.current.query = "1"; s.current.scrollOffset = 296; return s }
    @Test func temporaryClampThenGrowthRetainsOriginalTarget() {
        let key = ScrollRestorationKey(session(), generation: 1)
        var restore = ScrollRestoration(key: key, target: 296, now: 0)
        #expect(restore.sample(offset: 0, maximum: 104, height: 528, key: key, now: 0.1) == .scroll(104))
        #expect(restore.sample(offset: 104, maximum: 104, height: 528, key: key, now: 0.2) == .hold)
        #expect(restore.target == 296, "A temporary clamp must not acknowledge the original target")
        #expect(restore.sample(offset: 104, maximum: 820, height: 1244, key: key, now: 0.4) == .scroll(296))
        #expect(restore.sample(offset: 296, maximum: 820, height: 1244, key: key, now: 0.5) == .persist)
        #expect(restore.target == nil && restore.attempts == 2)
        #expect(restore.sample(offset: 310, maximum: 900, height: 1324, key: key, now: 0.7) == .persist, "Successful restoration never pins later scrolling")
    }
    @Test func userCancelAndExpiryNeverReissue() {
        let key = ScrollRestorationKey(session(), generation: 1)
        var user = ScrollRestoration(key: key, target: 296, now: 0)
        #expect(user.sample(offset: 104, maximum: 104, height: 528, key: key, now: 0.1) == .scroll(104))
        user.cancel()
        #expect(user.sample(offset: 150, maximum: 820, height: 1244, key: key, now: 0.2) == .persist)
        let userExpired = user.expire(key: key); #expect(!userExpired)
        var expired = ScrollRestoration(key: key, target: 296, now: 0)
        #expect(expired.sample(offset: 104, maximum: 820, height: 1244, key: key, now: 2.01) == .persist)
        #expect(expired.target == nil && expired.attempts == 0)
        var taskExpiry = ScrollRestoration(key: key, target: 296, now: 0)
        let first = taskExpiry.expire(key: key), second = taskExpiry.expire(key: key)
        #expect(first && !second)
    }
    @Test(arguments: ["entry", "query", "filter", "page", "owner", "generation", "window", "epoch"])
    func staleTargetsCannotScrollOrAcknowledge(kind: String) throws {
        let old = session(); var newer = old; var generation: UInt64 = 1
        switch kind {
        case "entry": newer.open(.downloads)
        case "query": newer.current.query = "2"
        case "filter": newer.current.filter = "Downloaded only"
        case "page": newer.current.page = 1
        case "owner": newer.owner = WindowOwner(try consumerAccount().context)
        case "generation": generation = 2
        case "window": newer.windowID = UUID()
        default: newer.historyEpoch = 4
        }
        let key = ScrollRestorationKey(old, generation: 1), other = ScrollRestorationKey(newer, generation: generation)
        var restore = ScrollRestoration(key: key, target: 296, now: 0)
        let staleExpiry = restore.expire(key: other); #expect(!staleExpiry)
        #expect(restore.sample(offset: 104, maximum: 820, height: 1244, key: other, now: 0.2) == .stale)
        #expect(restore.target == nil)
    }
    @Test func growthRetriesAreBoundedAndOffsetsDoNotRestartIdentity() {
        var s = session(); let key = ScrollRestorationKey(s, generation: 1)
        s.current.scrollOffset = 104; s.current.selection.insert("another")
        #expect(ScrollRestorationKey(s, generation: 1) == key)
        var restore = ScrollRestoration(key: key, target: 9999, now: 0)
        var commands = 0
        for n in 1...20 {
            if case .scroll = restore.sample(offset: 0, maximum: Double(n * 10), height: Double(400 + n * 10), key: key, now: Double(n) / 100) { commands += 1 }
        }
        #expect(commands == 8 && restore.attempts == 8 && restore.target == nil)
    }
}
