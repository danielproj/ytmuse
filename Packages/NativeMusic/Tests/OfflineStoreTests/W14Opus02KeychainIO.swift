// W14 opus-02 temporary probe: does a single retained range read (inside the 1 s time-floor throttle)
// mutate the persistent (isolated test) Keychain database file? Archived and removed afterwards.
import XCTest
import Foundation
import Darwin
import Domain
import Downloads
import AccountSession
import Playback

final class W14Opus02KeychainIO: XCTestCase, @unchecked Sendable {
    func testO6PerRangeLeaseMutatesKeychainDatabase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("W14-opus02-kio-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appendingPathComponent("test.keychain-db")
        let vault = try KeychainVault(testNamespace: KeychainVault.applicationNamespace + ".test.opus02-kio." + UUID().uuidString, isolatedKeychainURL: db)
        let ctx = RequestContext(account: OwnedMedia.account, accountGeneration: 1, requestGeneration: 0)
        let store = try EncryptedStore(root: root.appendingPathComponent("objects"), vault: vault); await store.bind(ctx)
        let input = root.appendingPathComponent("input"); try Data(repeating: 7, count: 200_000).write(to: input)
        try await store.retain(file: input, variant: "v", grant: .init(issuer: "x", sourceEncryption: "none", expires: Date().addingTimeInterval(3600), renewalReference: "r", rights: ["play", "retain", "seek"], validatedAt: Date().addingTimeInterval(-1)), reference: "a", context: ctx)
        _ = try await store.read(variant: "v", offset: 0, count: 16, context: ctx) // may write the 1 s time floor
        func stamp() -> String { var st = stat(); _ = stat(db.path, &st); return "\(st.st_size)@\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)" }
        var changed = 0; var samples: [String] = []
        let k0 = await vault.protectedMetrics()
        for n in 1...10 {
            let before = stamp()
            _ = try await store.read(variant: "v", offset: n * 1000, count: 16, context: ctx)
            let after = stamp(); if before != after { changed += 1 }; if n <= 3 { samples.append("\(before)->\(after)") }
        }
        let k1 = await vault.protectedMetrics()
        let d = k1.reduce(into: [String: Int]()) { $0[$1.key] = $1.value - (k0[$1.key] ?? 0) }
        print("OPUS02 O6 rangeReads=10 keychainDbFileChangedOn=\(changed)/10 samples=\(samples) keychainDelta=\(d)")
        try await vault.destroyIsolatedTestKeychain()
    }
}
