import XCTest
import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import Domain
import Downloads
import AccountSession
import Playback

private func cEqual<T: Equatable>(_ a: T,_ b: T,file: StaticString = #filePath,line: UInt = #line) { XCTAssertEqual(a,b,file:file,line:line) }
private struct CTrap: NativeAssetProvider {
    func asset(for variant: MediaVariant, context: PlaybackContext) async throws -> URL { XCTFail("fallback"); throw DomainError.offline }
}
final class StageCReadTests: XCTestCase, @unchecked Sendable {
    /// TH2: the half of the old test that depended on the clock. With the product's own one-second lifetime, a cached key is gone after 1.1 s. The wait is for a time to PASS, so a loaded
    /// machine can only make it later than the lifetime, never earlier.
    func testTheDecryptedKeyDoesNotOutliveItsSecond() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("W14-C-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        let vault = try KeychainVault(testNamespace: KeychainVault.applicationNamespace+".test.stage-c-ttl."+UUID().uuidString, isolatedKeychainURL: root.appendingPathComponent("keychain-db"))
        defer { Task { try? await vault.destroyIsolatedTestKeychain(); try? FileManager.default.removeItem(at: root) } }
        let context = RequestContext(account: OwnedMedia.account, accountGeneration: 1, requestGeneration: 0)
        let playback = PlaybackContext(request:context,generation:1,occurrenceID:nil,route:nil)
        let store = try EncryptedStore(root:root.appendingPathComponent("objects"),vault:vault); await store.bind(context)
        let variant = try await OwnedMedia().resolve(OwnedMedia.items[0],context:playback).outcome.get()[0]
        let input = try await OwnedMedia().asset(for:variant,context:playback)
        let grant = RetentionGrant(issuer:"Owned C authority",sourceEncryption:"none",expires:Date().addingTimeInterval(3600),renewalReference:"owned-C",rights:["play","retain","seek"],validatedAt:Date().addingTimeInterval(-1))
        try await store.retain(file:input,variant:variant.id.rawValue,grant:grant,reference:"a",context:context)
        _ = try await store.read(variant:variant.id.rawValue,offset:0,count:1,context:context)
        // (That the read cached a key at all is asserted, free of the clock, by the long-lifetime test above: its count is 1.)
        try await Task.sleep(for:.milliseconds(1100))
        cEqual(await store.readCacheCount(),0)
    }

    func testFullDecodeCountersAndReadonly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("W14-C-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        let vault = try KeychainVault(testNamespace: KeychainVault.applicationNamespace+".test.stage-c."+UUID().uuidString, isolatedKeychainURL: root.appendingPathComponent("keychain-db"))
        let context = RequestContext(account: OwnedMedia.account, accountGeneration: 1, requestGeneration: 0)
        let playback = PlaybackContext(request:context,generation:1,occurrenceID:nil,route:nil)
        let store = try EncryptedStore(root:root.appendingPathComponent("objects"),vault:vault); await store.bind(context)
        // TH2: the product keeps a decrypted master key for one second, so a count of key retrievals during a whole decode grows with how long the decode takes (it failed 4 of 4
        // under load). The count is a property of the code path, so it is measured with a lifetime that no decode outlasts; the one-second expiry has its own test below.
        await store.setKeyLifetimeForTests(.seconds(3600))
        let variant = try await OwnedMedia().resolve(OwnedMedia.items[0],context:playback).outcome.get()[0]
        let input = try await OwnedMedia().asset(for:variant,context:playback)
        let grant = RetentionGrant(issuer:"Owned C authority",sourceEncryption:"none",expires:Date().addingTimeInterval(3600),renewalReference:"owned-C",rights:["play","retain","seek"],validatedAt:Date().addingTimeInterval(-1))
        try await store.retain(file:input,variant:variant.id.rawValue,grant:grant,reference:"a",context:context)
        let index = FileManager.default.enumerator(at:root,includingPropertiesForKeys:nil)!.compactMap{$0 as? URL}.first{$0.lastPathComponent=="index"}!
        defer { try? FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:index.deletingLastPathComponent().path); Task { try? await vault.destroyIsolatedTestKeychain(); try? FileManager.default.removeItem(at:root) } }
        for readonly in [false,true] {
            if readonly { try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:index.deletingLastPathComponent().path) }
            await store.clearReadCaches(context:context)
            let beforeIO = await store.storageMetrics(); let beforeKeys = await vault.protectedMetrics()
            let provider = LocalFirstOwnedAssets(store:store,fallback:CTrap())
            let asset = try await provider.nativeAsset(for:variant,context:playback)
            let tracks = try await asset.loadTracks(withMediaType:.audio)
            let reader = try AVAssetReader(asset:asset)
            let output = AVAssetReaderTrackOutput(track:tracks[0],outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM])
            reader.add(output); XCTAssertTrue(reader.startReading())
            var frames=0;while let sample=output.copyNextSampleBuffer(){frames+=CMSampleBufferGetNumSamples(sample)}
            cEqual(reader.status,.completed);cEqual(frames,576000)
            let afterIO = await store.storageMetrics();let afterKeys=await vault.protectedMetrics()
            let deltaIO=afterIO.mapValues{$0}.reduce(into:[String:Int]()){r,v in r[v.key]=v.key=="maxValidationUnits" ? v.value : v.value-(beforeIO[v.key] ?? 0)}
            let deltaKeys=afterKeys.reduce(into:[String:Int]()){r,v in r[v.key]=v.value-(beforeKeys[v.key] ?? 0)}
            print("STAGE_C_COUNTER readonly=\(readonly) IO=\(deltaIO) Keychain=\(deltaKeys)")
            XCTAssertLessThanOrEqual(afterIO["maxValidationUnits"] ?? 0,64)
            cEqual(deltaIO["indexWrites"] ?? 0,0);cEqual(deltaIO["fsyncCalls"] ?? 0,0)
            XCTAssertLessThan(deltaKeys["masterRetrievals"] ?? 0,8)
            withExtendedLifetime((provider,asset)){}
            if readonly {
                do { try await store.reference(variant:variant.id.rawValue,reference:"no-write",context:context); XCTFail("readonly mutation succeeded") } catch { cEqual(error as? OfflineRecovery,.storageUnavailable) }
                _ = try await store.read(variant:variant.id.rawValue,offset:0,count:1,context:context)
            }
            cEqual(await store.readCacheCount(),1)   // the key is cached for the duration of the long lifetime: the decode did not hammer the keychain
        }
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:index.deletingLastPathComponent().path)
        try await vault.destroyIsolatedTestKeychain();try FileManager.default.removeItem(at:root)
    }
}
