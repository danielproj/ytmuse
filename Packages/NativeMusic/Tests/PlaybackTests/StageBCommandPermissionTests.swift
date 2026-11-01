import XCTest
import Foundation
import Domain
import Playback

private actor BCommandLifecycle: PlaybackLifecycleSink {
    func checkpoint(_ snapshot: PlaybackSnapshot) {}
    func advance(context: PlaybackContext) {}
}
final class StageBCommandPermissionTests: XCTestCase, @unchecked Sendable {
    private func commands(_ engine: TestEngine) -> (PlaybackCommands, RequestContext) {
        let context = RequestContext(account: OwnedMedia.account, accountGeneration: 1, requestGeneration: 0)
        let owned = OwnedMedia(wall: FixedWall(date: testWall))
        let commands = PlaybackCommands(request: context, engine: engine, resolver: owned, capabilities: owned, wall: FixedWall(date: testWall), monotonic: FixedMonotonic(), lifecycle: BCommandLifecycle())
        return (commands, context)
    }
    func testSharedSeekDenialDoesNotPublishRequestedPositionOrStopPlayback() async throws {
        // No AVPlayer or audio: actual shared command layer with an injected permission engine.
        for lateDenial in [false, true] {
            let engine = TestEngine(); let (commands, context) = commands(engine)
            _ = try await commands.execute(.select(media: OwnedMedia.items[0], occurrence: UUID()), context: context, origin: .userInterface).outcome.get()
            let before = await commands.snapshot(); let callsBefore = await engine.recorded()
            await engine.setSeekErrors(validation: lateDenial ? nil : .forbidden, application: lateDenial ? .forbidden : nil)
            let response = await commands.execute(.seek(4), context: context, origin: .menu)
            do { _ = try response.outcome.get(); XCTFail("Denied seek reported success") } catch { XCTAssertEqual(error, .forbidden) }
            let after = await commands.snapshot(); let callsAfter = await engine.recorded()
            XCTAssertEqual(after.position, before.position); XCTAssertEqual(after.state, before.state)
            XCTAssertEqual(after.intent, before.intent); XCTAssertNil(after.error)
            XCTAssertEqual(callsAfter.filter { $0 == "stop" }.count, callsBefore.filter { $0 == "stop" }.count)
            await engine.setSeekErrors()
            let success = try await commands.execute(.seek(4), context: context, origin: .mediaKey).outcome.get()
            XCTAssertEqual(success.position, 4)
        }
    }
    func testSharedHeldSeekPermissionCannotMoveReplacementSelection() async throws {
        let engine = TestEngine(); let (commands, context) = commands(engine)
        _ = try await commands.execute(.select(media: OwnedMedia.items[0], occurrence: UUID()), context: context, origin: .userInterface).outcome.get()
        await engine.holdNextSeekPermission()
        let old = Task { await commands.execute(.seek(5), context: context, origin: .appleScript) }
        await engine.waitForSeekPermission()
        let current = try await commands.execute(.select(media: OwnedMedia.items[1], occurrence: UUID()), context: context, origin: .userInterface).outcome.get()
        await engine.releaseSeekPermission()
        do { _ = try await old.value.outcome.get(); XCTFail("Old permission moved new selection") } catch { XCTAssertEqual(error, .staleContext) }
        let after = await commands.snapshot(); let calls = await engine.recorded()
        XCTAssertEqual(after.context, current.context); XCTAssertEqual(after.item, OwnedMedia.items[1]); XCTAssertEqual(after.position, 0)
        XCTAssertFalse(calls.contains("seek:5.0"))
    }
}
