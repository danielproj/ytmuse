import XCTest
import Foundation
import Domain
import Playback
import AccountSession
@testable import AppShell

final class OfflineCompositionReworkTests: XCTestCase, @unchecked Sendable {
    func testUnsafeOptionalRetainedRootDoesNotDenyBundledOwnedLicense() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("W14-composition-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("retained"), withDestinationURL: target)
        let authority = AppPlaybackAuthority(directory: root, offlineVault: try isolatedOwnedVault(in: root))
        let session = try await authority.owned(request: authority.requestOwnedStart(), initialGain: 0.001, maximumStartGain: 0.001)
        // No Play action. This validates composition, without foreground UI or audible output.
        await session.close()
        await authority.quit()
    }
}
