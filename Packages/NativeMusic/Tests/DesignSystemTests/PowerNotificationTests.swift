import Combine
import Foundation
import Synchronization
import Testing
@testable import DesignSystem

/// C2: a Low Power Mode change posted off the main thread reaches the glass
/// handlers on the main thread only.
@Suite @MainActor struct PowerNotificationTests {
    @Test func powerStateChangesPostedOffMainAreDeliveredOnMain() async throws {
        let threads = Mutex<[Bool]>([])
        let subscription = MusicGlassPower.changes.sink { _ in threads.withLock { $0.append(Thread.isMainThread) } }
        defer { subscription.cancel() }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                NotificationCenter.default.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
                done.resume()
            }
        }
        for _ in 0..<200 where threads.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(threads.withLock { $0 } == [true], "delivered once, on the main thread")
    }
    @Test func everyGlassHandlerUsesTheMainQueuePublisher() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/DesignSystem/DesignSystem.swift").standardizedFileURL, encoding: .utf8)
        #expect(source.components(separatedBy: "MusicGlassPower.changes").count - 1 == 3)
        #expect(source.components(separatedBy: "publisher(for: .NSProcessInfoPowerStateDidChange)").count - 1 == 1, "only the hopped one")
    }
}
