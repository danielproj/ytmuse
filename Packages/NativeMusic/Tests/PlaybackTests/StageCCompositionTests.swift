import XCTest
import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import Domain
import Downloads
import AccountSession
@testable import Playback
@testable import AppShell

private actor CCloseGate {
    var first=true;var entered=false;var held:CheckedContinuation<Void,Never>?;var observer:CheckedContinuation<Void,Never>?
    func pause()async{guard first else{return};first=false;entered=true;observer?.resume();observer=nil;await withCheckedContinuation{held=$0}}
    func waiting()async{if entered{return};await withCheckedContinuation{observer=$0}}
    func release(){held?.resume();held=nil}
}
private func eqC<T:Equatable>(_ a:T,_ b:T,file:StaticString=#filePath,line:UInt=#line){XCTAssertEqual(a,b,file:file,line:line)}
final class StageCCompositionTests:XCTestCase,@unchecked Sendable {
    private func prepare(_ session:PlaybackSession)async throws {
        let request = try await session.snapshot().playback.context.request
        let context=PlaybackContext(request:request,generation:0,occurrenceID:nil,route:nil)
        let v=try await OwnedMedia().resolve(OwnedMedia.items[0],context:context).outcome.get()[0]
        try await session.engine.prepare(v,context:context).outcome.get()
        let info=await session.engine.mediaInfo();XCTAssertNotNil(info)
        let assetSession=try await session.engine.assets.assetSession(for:v,context:context)
        let tracks=try await assetSession.asset.loadTracks(withMediaType:.audio)
        let reader=try AVAssetReader(asset:assetSession.asset)
        let output=AVAssetReaderTrackOutput(track:tracks[0],outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM])
        reader.add(output);XCTAssertTrue(reader.startReading());var frames=0
        while let sample=output.copyNextSampleBuffer(){frames+=CMSampleBufferGetNumSamples(sample)}
        XCTAssertEqual(frames,576000);XCTAssertEqual(reader.status,.completed)
        assetSession.dispose();_=await session.engine.stop(context:context)
    }
    func testActualOwnerOldTeardownCannotClearNewStore()async throws {
        for quit in [true,false] {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("W14-C-owner-"+UUID().uuidString)
            defer{try? FileManager.default.removeItem(at:root)}
            let gate=CCloseGate();let owner=AppPlaybackAuthority(directory:root,beforeTeardown:{await gate.pause()},offlineVault:try isolatedOwnedVault(in:root))
            let old=try await owner.owned(request:owner.requestOwnedStart(),initialGain:0.001,maximumStartGain:0.001)
            let oldID=await owner.retainedStoreID();XCTAssertNotNil(oldID)
            let closing=Task{if quit{await owner.quit()}else{try await owner.detach(previous:RequestContext(account:OwnedMedia.account,accountGeneration:1,requestGeneration:0),barrier:RequestContext(account:nil,accountGeneration:2,requestGeneration:0))}}
            await gate.waiting()
            let new=try await owner.owned(request:owner.requestOwnedStart(),initialGain:0.001,maximumStartGain:0.001)
            let newID=await owner.retainedStoreID();XCTAssertNotNil(newID);XCTAssertNotEqual(oldID,newID)
            await gate.release();try await closing.value
            eqC(await owner.retainedStoreID(),newID)
            try await prepare(new)
            await old.close();await new.close();await owner.quit()
        }
    }
    func testUnsafeRootActuallyDecodesBundledAndRetainedRefusalNeverFallsBack()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("W14-C-fallback-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer{try? FileManager.default.removeItem(at:root)}
        let target=root.appendingPathComponent("target");try FileManager.default.createDirectory(at:target,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("retained"),withDestinationURL:target)
        let fallback=AppPlaybackAuthority(directory:root,offlineVault:try isolatedOwnedVault(in:root))
        let bundled=try await fallback.owned(request:fallback.requestOwnedStart(),initialGain:0.001,maximumStartGain:0.001)
        try await prepare(bundled);await bundled.close();await fallback.quit()
        try FileManager.default.removeItem(at:root.appendingPathComponent("retained"))
        let vault=try KeychainVault(testNamespace:KeychainVault.applicationNamespace+".test.C-composition."+UUID().uuidString,isolatedKeychainURL:root.appendingPathComponent("isolated-keychain"))
        let ctx=RequestContext(account:OwnedMedia.account,accountGeneration:1,requestGeneration:0)
        let pc=PlaybackContext(request:ctx,generation:0,occurrenceID:nil,route:nil)
        let store=try EncryptedStore(root:root.appendingPathComponent("retained"),vault:vault);await store.bind(ctx)
        let variant=try await OwnedMedia().resolve(OwnedMedia.items[0],context:pc).outcome.get()[0]
        let input=try await OwnedMedia().asset(for:variant,context:pc)
        let now=Date();let grant=RetentionGrant(issuer:"Owned composition",sourceEncryption:"none",expires:now.addingTimeInterval(3600),renewalReference:"owned",rights:["play","retain","seek"],validatedAt:now.addingTimeInterval(-1))
        try await store.retain(file:input,variant:variant.id.rawValue,grant:grant,reference:"a",context:ctx)
        let owner=AppPlaybackAuthority(directory:root,offlineVault:vault)
        let retained=try await owner.owned(request:owner.requestOwnedStart(),initialGain:0.001,maximumStartGain:0.001)
        try await prepare(retained)
        let revoked=RetentionGrant(issuer:grant.issuer,sourceEncryption:grant.sourceEncryption,expires:grant.expires,renewalReference:grant.renewalReference,rights:[],validatedAt:grant.validatedAt)
        try await store.updateGrant(variant:variant.id.rawValue,grant:revoked,context:ctx)
        let result=await retained.engine.prepare(variant,context:pc)
        do{try result.outcome.get();XCTFail("revoked retained asset silently used bundled license")}catch{XCTAssertEqual(error,.expiredMedia)}
        let fresh=RetentionGrant(issuer:grant.issuer,sourceEncryption:grant.sourceEncryption,expires:grant.expires,renewalReference:grant.renewalReference,rights:grant.rights,validatedAt:Date())
        try await store.updateGrant(variant:variant.id.rawValue,grant:fresh,context:ctx)
        let chunk=FileManager.default.enumerator(at:root.appendingPathComponent("retained"),includingPropertiesForKeys:nil)!.compactMap{$0 as? URL}.first{$0.lastPathComponent=="chunk-0"}!
        var bytes=try Data(contentsOf:chunk);bytes[60] ^= 1;try bytes.write(to:chunk)
        let corrupt=await retained.engine.prepare(variant,context:pc)
        do{try corrupt.outcome.get();XCTFail("corrupt retained asset used bundled fallback")}catch{XCTAssertEqual(error,.malformedResponse)}
        await retained.close();await owner.quit();try await vault.destroyIsolatedTestKeychain()
    }
}
