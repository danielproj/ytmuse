@preconcurrency import AVFoundation
import XCTest
import Foundation
import Domain
import Downloads
import Queue
import AccountSession
import Synchronization
@testable import Playback

private final class CTime: Sendable {
    let base = Date(timeIntervalSince1970:floor(Date().timeIntervalSince1970))
    let offset = Mutex(Double(0))
    func advance(_ seconds:Double) {offset.withLock{$0 += seconds}}
}
private struct CWall: WallClock {let time:CTime;func now()->Date{time.base.addingTimeInterval(time.offset.withLock{$0})}}
private struct CMono: MonotonicClock {let time:CTime;func now()->Duration{.seconds(time.offset.withLock{$0})}}
final class RetainedDSPTests: XCTestCase,@unchecked Sendable {
    func testActualRetainedDecodeSeekAndOrdinaryRevocation() async throws {
        for transition in ["expiry","revoke","signout","delete"] {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("W16-C-retained-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let vault=try KeychainVault(testNamespace:KeychainVault.applicationNamespace+".test.w16c."+UUID().uuidString,isolatedKeychainURL:root.appendingPathComponent("isolated.keychain-db"))
            let time=CTime();let wall=CWall(time:time);let mono=CMono(time:time)
            let store=try EncryptedStore(root:root.appendingPathComponent("media"),vault:vault,wall:wall,monotonic:mono)
            let request=ownedContext();await store.bind(request)
            let ctx=PlaybackContext(request:request,generation:1,occurrenceID:UUID(),route:nil)
            let media=OwnedMedia(wall:wall)
            let variant=try await media.resolve(OwnedMedia.items[0],context:ctx).outcome.get()[0]
            let input=try await media.asset(for:variant,context:ctx)
            let grant=RetentionGrant(issuer:"W16 original owned license",sourceEncryption:"none: owned PCM",expires:wall.now().addingTimeInterval(10),renewalReference:"owned-local-test",rights:["play","retain","seek"],validatedAt:wall.now().addingTimeInterval(-1))
            try await store.retain(file:input,variant:variant.id.rawValue,grant:grant,reference:"ordinary-test",context:request)
            let provider=LocalFirstOwnedAssets(store:store,fallback:media)
            let player=NativePlayer(assets:provider,clock:mono,initialGain:1,manualDecodedRendering:true,wall:wall)
            _ = try await player.prepare(variant,context:ctx).outcome.get()
            _ = try await player.configureEffects(AudioEffects(balance:1),context:ctx).outcome.get()
            _ = try await player.play(context:ctx).outcome.get()
            let rendered=try await player.renderSelected(1024,context:ctx)
            let reference=try AVAudioFile(forReading:input)
            let chunk=AVAudioPCMBuffer(pcmFormat:reference.processingFormat,frameCapacity:1024)!;try reference.read(into:chunk,frameCount:1024)
            var worst:Float=0
            for i in 0..<1024 {XCTAssertEqual(rendered.floatChannelData![0][i],0);worst=max(worst,abs(rendered.floatChannelData![1][i]-chunk.floatChannelData![1][i]))}
            XCTAssertLessThanOrEqual(worst,0.000002)
            _ = try await player.seek(to:2,context:ctx).outcome.get()
            let seeked=try await player.renderSelected(1024,context:ctx);XCTAssertEqual(seeked.frameLength,1024)
            switch transition {
            case "expiry":time.advance(11)
            case "revoke":
                let revoked=RetentionGrant(issuer:grant.issuer,sourceEncryption:grant.sourceEncryption,expires:grant.expires,renewalReference:grant.renewalReference,rights:[],validatedAt:grant.validatedAt)
                try await store.updateGrant(variant:variant.id.rawValue,grant:revoked,context:request)
            case "signout":try await store.invalidate(context:request,deleteFiles:false)
            default:_ = try await store.delete(variant.id,context:request).outcome.get()
            }
            do {_ = try await player.renderSelected(1024,context:ctx);XCTFail("queued/cached plaintext survived \(transition)")} catch {
                let typed=error as? DomainError
                XCTAssertNotNil(typed)
                XCTAssertTrue([DomainError.expiredMedia,.unauthorized,.unavailableContent,.staleContext].contains(typed!))
                print("W16-C retained transition=\(transition) typedError=\(error) maximumPCMError=\(worst)")
            }
            _ = await player.stop(context:ctx)
            try await vault.destroyIsolatedTestKeychain();try FileManager.default.removeItem(at:root)
        }
    }
    func testEncryptedQueueGaplessAndCrossfadeThroughActualOwner() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("W16-C-retained-queue-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let vault=try KeychainVault(testNamespace:KeychainVault.applicationNamespace+".test.w16c."+UUID().uuidString,isolatedKeychainURL:root.appendingPathComponent("isolated.keychain-db"))
        let request=ownedContext();let scope=PlaybackContext(request:request,generation:1,occurrenceID:nil,route:nil)
        let store=try EncryptedStore(root:root.appendingPathComponent("media"),vault:vault);await store.bind(request)
        let owned=OwnedMedia();let now=Date()
        let grant=RetentionGrant(issuer:"W16 owned queue grant",sourceEncryption:"none",expires:now.addingTimeInterval(3600),renewalReference:"owned",rights:["play","retain","seek"],validatedAt:now.addingTimeInterval(-1))
        var references:[[Float]]=[]
        for id in OwnedMedia.items {
            let variant=try await owned.resolve(id,context:scope).outcome.get()[0];let fileURL=try await owned.asset(for:variant,context:scope)
            try await store.retain(file:fileURL,variant:id.rawValue,grant:grant,reference:"owned-queue",context:request)
            let file=try AVAudioFile(forReading:fileURL);let block=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:4096)!;var values:[Float]=[]
            while file.framePosition<file.length {try file.read(into:block,frameCount:UInt32(min(4096,file.length-file.framePosition)));values.append(contentsOf:UnsafeBufferPointer(start:block.floatChannelData![0],count:Int(block.frameLength)))}
            references.append(values)
        }
        let provider=LocalFirstOwnedAssets(store:store,fallback:owned)
        let session=try await PlaybackSession.open(context:request,persistence:MemoryPersistence(),assets:provider,resolver:owned,capabilities:owned,automaticTick:false,initialGain:1,manualDecodedRendering:true,effects:AudioEffects(balance:1,gain:0.5,crossfade:4))
        try await session.startOwnedMedia(OwnedMedia.items)
        let overlap=4*48000;let start=references[0].count-overlap;let total=references[0].count+references[1].count-overlap
        var count=0;var worst:Float=0;var peakFrames=0
        while count<total {
            let buffer=try await session.renderSelected(UInt32(min(1024,total-count)))
            for i in 0..<Int(buffer.frameLength) {
                let frame=count+i;let b=frame-start
                let first=frame<references[0].count ? references[0][frame]:0
                let second=b>=0 ? references[1][b]:0
                let t=max(0,min(1,Float(b)/Float(overlap-1)))
                let expected=(frame<start ? first:(frame<references[0].count ? first*(1-t)+second*t:second))*0.5
                XCTAssertEqual(buffer.floatChannelData![0][i],0)
                worst=max(worst,abs(buffer.floatChannelData![1][i]-expected))
            }
            count+=Int(buffer.frameLength)
            peakFrames=max(peakFrames,await session.engine.decodedResourceState().peakFrames)
            await Task.yield()
        }
        XCTAssertEqual(count,768000);XCTAssertLessThanOrEqual(worst,0.000002);XCTAssertLessThanOrEqual(peakFrames,65536)
        let deadline=ContinuousClock.now.advanced(by:.seconds(3))
        while try await session.queueSnapshotForMeasurement().current != nil,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(1))}
        let final=try await session.queueSnapshotForMeasurement();XCTAssertNil(final.current);XCTAssertEqual(final.metadata.recent.count,2)
        await session.close();try await vault.destroyIsolatedTestKeychain();try FileManager.default.removeItem(at:root)
        print("W16-C encrypted selected queue: frames=\(count) overlap=192000 maxError=\(worst) peakRetainedFrames=\(peakFrames) histories=\(final.metadata.recent.count)")
    }
    func testRetainedPlayOnlyDecodingDoesNotGrantSeek() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("W16-C-play-only-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let vault=try KeychainVault(testNamespace:KeychainVault.applicationNamespace+".test.w16c."+UUID().uuidString,isolatedKeychainURL:root.appendingPathComponent("isolated.keychain-db"))
        let ctx=PlaybackContext(request:ownedContext(),generation:1,occurrenceID:UUID(),route:nil)
        let store=try EncryptedStore(root:root.appendingPathComponent("media"),vault:vault);await store.bind(ctx.request)
        let media=OwnedMedia();let variant=try await media.resolve(OwnedMedia.items[0],context:ctx).outcome.get()[0]
        let now=Date();let grant=RetentionGrant(issuer:"W16 owned play-only",sourceEncryption:"none",expires:now.addingTimeInterval(3600),renewalReference:"owned",rights:["play","retain"],validatedAt:now.addingTimeInterval(-1))
        try await store.retain(file:await media.asset(for:variant,context:ctx),variant:variant.id.rawValue,grant:grant,reference:"play-only",context:ctx.request)
        let player=NativePlayer(assets:LocalFirstOwnedAssets(store:store,fallback:media),clock:SystemMonotonicClock(),initialGain:1,manualDecodedRendering:true)
        _ = try await player.prepare(variant,context:ctx).outcome.get()
        _ = try await player.configureEffects(AudioEffects(gain:0.5),context:ctx).outcome.get()
        _ = try await player.play(context:ctx).outcome.get()
        _ = try await player.renderSelected(1024,context:ctx)
        let before=await player.nativePosition()
        let denied=await player.seek(to:3,context:ctx)
        do {try denied.outcome.get();XCTFail("play-only user seek accepted")}catch{XCTAssertEqual(error,.forbidden)}
        let after=await player.nativePosition();XCTAssertEqual(before,after)
        _ = try await player.renderSelected(1024,context:ctx)
        _ = await player.stop(context:ctx)
        try await vault.destroyIsolatedTestKeychain();try FileManager.default.removeItem(at:root)
        print("W16-C encrypted play-only: real decoded output; user seeking denied without moving position")
    }
}
