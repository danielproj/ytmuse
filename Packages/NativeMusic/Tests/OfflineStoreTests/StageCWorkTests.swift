import XCTest
import Foundation
import Synchronization
import CryptoKit
import Domain
import AccountSession
import Downloads
import Playback

private func ceq<T:Equatable>(_ a:T,_ b:T,file:StaticString=#filePath,line:UInt=#line){XCTAssertEqual(a,b,file:file,line:line)}
private final class CWall:WallClock,Sendable { let value:Mutex<Date>;init(_ date:Date){value=Mutex(date)};func now()->Date{value.withLock{$0}};func jump(_ n:Double){value.withLock{$0=$0.addingTimeInterval(n)}} }
private struct CMono:MonotonicClock {func now()->Duration{.zero}}
private actor CGate {
    var arrived=false;var open=false;var waits:[CheckedContinuation<Void,Never>]=[];var arrivals:[CheckedContinuation<Void,Never>]=[]
    func wait()async{arrived=true;for c in arrivals{c.resume()};arrivals=[];if open{return};await withCheckedContinuation{waits.append($0)}}
    func entered()async{if arrived{return};await withCheckedContinuation{arrivals.append($0)}}
    func release(){open=true;for c in waits{c.resume()};waits=[]}
}
private struct CF {
    let root:URL;let time:Date
    let namespace:String
    let ctx=RequestContext(account:OwnedMedia.account,accountGeneration:1,requestGeneration:0)
    init(root:URL?=nil,time:Date?=nil,namespace:String?=nil)throws{self.root=root ?? FileManager.default.temporaryDirectory.appendingPathComponent("W14-C-work-"+UUID().uuidString);self.time=time ?? Date(timeIntervalSince1970:floor(Date().timeIntervalSince1970));self.namespace=namespace ?? KeychainVault.applicationNamespace+".test.C-work."+UUID().uuidString;try FileManager.default.createDirectory(at:self.root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}
    func vault()throws->KeychainVault{try KeychainVault(testNamespace:namespace,isolatedKeychainURL:root.appendingPathComponent("keychain"))}
    func grant(_ at:Date?=nil)->RetentionGrant{.init(issuer:"Owned C authority",sourceEncryption:"none",expires:(at ?? time).addingTimeInterval(3600),renewalReference:"owned-C",rights:["play","retain","seek"],validatedAt:(at ?? time).addingTimeInterval(-1))}
    func input()throws->URL{let url=root.appendingPathComponent("8MiB");FileManager.default.createFile(atPath:url.path,contents:nil);let h=try FileHandle(forWritingTo:url);for _ in 0..<128{try h.write(contentsOf:Data(repeating:0x5a,count:65536))};try h.close();return url}
    func store(_ v:KeychainVault,_ clock:CWall,step:(@Sendable(Int)async throws->Void)?=nil)async throws->EncryptedStore{let s=try EncryptedStore(root:root.appendingPathComponent("objects"),vault:v,wall:clock,monotonic:CMono(),importStep:step);await s.bind(ctx);return s}
}
private actor CHeldVault:ScopedProtectedRecords {
    func replace(_ reference: CredentialReference, with bytes: Data, context: RequestContext) async throws { try await real.replace(reference, with: bytes, context: context) }
    let real:KeychainVault;let gate=CGate();var once=true
    init(_ v:KeychainVault){real=v}
    func bind(_ c:RequestContext)async{await real.bind(c)}
    func insert(_ b:Data,for a:AccountContext)async throws->CredentialReference{try await real.insert(b,for:a)}
    func read(_ r:CredentialReference,context:RequestContext)async throws->Data{try await real.read(r,context:context)}
    func delete(_ r:CredentialReference,for a:AccountContext)async throws{try await real.delete(r,for:a)}
    func deleteAll(for a:AccountContext)async throws{try await real.deleteAll(for:a)}
    func acquireProtectedLease(context:RequestContext)async throws->ProtectedRecordLease?{try await real.acquireProtectedLease(context:context)}
    func releaseProtectedLease(_ l:ProtectedRecordLease)async throws{try await real.releaseProtectedLease(l)}
    func protectedRecordStamp(_ n:String,lease:ProtectedRecordLease,context:RequestContext)async throws->ProtectedRecordStamp?{if once{once=false;await gate.wait()};return try await real.protectedRecordStamp(n,lease:lease,context:context)}
    func protectedRecord(_ n:String,lease:ProtectedRecordLease,context:RequestContext)async throws->Data?{try await real.protectedRecord(n,lease:lease,context:context)}
    func replaceProtectedRecord(_ n:String,value:Data?,lease:ProtectedRecordLease,context:RequestContext)async throws{try await real.replaceProtectedRecord(n,value:value,lease:lease,context:context)}
    func eraseProtectedAccount(_ a:AccountContext,barrier:RequestContext,cleanup:@Sendable()throws->Void)async throws{try await real.eraseProtectedAccount(a,barrier:barrier,cleanup:cleanup)}
}
final class StageCWorkTests:XCTestCase,@unchecked Sendable {
    func testChildMutation()async throws{
        let env=ProcessInfo.processInfo.environment
        guard let path=env["W14_C_ROOT"],let namespace=env["W14_C_NAMESPACE"],let seconds=env["W14_C_TIME"] else{return}
        let f=try CF(root:URL(fileURLWithPath:path),time:Date(timeIntervalSince1970:Double(seconds)!),namespace:namespace)
        let v=try KeychainVault(testNamespace:namespace,reopeningIsolatedKeychainURL:f.root.appendingPathComponent("keychain"));let s=try await f.store(v,CWall(f.time))
        let g=f.grant();let revoked=RetentionGrant(issuer:g.issuer,sourceEncryption:g.sourceEncryption,expires:g.expires,renewalReference:g.renewalReference,rights:[],validatedAt:g.validatedAt)
        try await s.updateGrant(variant:"v",grant:revoked,context:f.ctx)
        print("STAGE_C_CHILD_MUTATION_COMMITTED")
    }
    func testSuccessfulChildMutationInvalidatesWarmReader()async throws{
        let f=try CF();let v=try f.vault();let s=try await f.store(v,CWall(f.time));let file=try f.input()
        defer{Task{try? await v.destroyIsolatedTestKeychain();try? FileManager.default.removeItem(at:f.root)}}
        try await s.retain(file:file,variant:"v",grant:f.grant(),reference:"a",context:f.ctx);_=try await s.read(variant:"v",offset:0,count:1,context:f.ctx)
        let before=await v.protectedMetrics()
        let child=Process();child.executableURL=URL(fileURLWithPath:"/usr/bin/xcrun");child.arguments=["xctest","-XCTest","OfflineStoreTests.StageCWorkTests/testChildMutation",Bundle(for:Self.self).bundlePath]
        var env=ProcessInfo.processInfo.environment;env["W14_C_ROOT"]=f.root.path;env["W14_C_NAMESPACE"]=f.namespace;env["W14_C_TIME"]=String(f.time.timeIntervalSince1970);child.environment=env
        let log=f.root.appendingPathComponent("child.log");FileManager.default.createFile(atPath:log.path,contents:nil);let handle=try FileHandle(forWritingTo:log);child.standardOutput=handle;child.standardError=handle
        try child.run();waitForOwnedTestProcess(child);try handle.close();let text=try String(contentsOf:log,encoding:.utf8);print(text);XCTAssertEqual(child.terminationStatus,0);XCTAssertTrue(text.contains("STAGE_C_CHILD_MUTATION_COMMITTED"))
        do{_=try await s.read(variant:"v",offset:0,count:1,context:f.ctx);XCTFail("warm grant survived successful other-process revoke")}catch{ceq(error as? OfflineRecovery,.renewRights)}
        let after=await v.protectedMetrics();print("STAGE_C_WARM_CROSS_PROCESS master retrieval delta=\((after["masterRetrievals"] ?? 0)-(before["masterRetrievals"] ?? 0))")
        try await v.destroyIsolatedTestKeychain();try FileManager.default.removeItem(at:f.root)
    }
    func testFreshSourceTimeRecoveryAndRestartStickyFault()async throws{
        let f=try CF();let v=try f.vault();let clock=CWall(f.time);let s=try await f.store(v,clock);let file=try f.input()
        defer{Task{try? await v.destroyIsolatedTestKeychain();try? FileManager.default.removeItem(at:f.root)}}
        try await s.retain(file:file,variant:"v",grant:f.grant(),reference:"a",context:f.ctx)
        clock.jump(10)
        do{_=try await s.read(variant:"v",offset:0,count:1,context:f.ctx);XCTFail("jump accepted")}catch{ceq(error as? OfflineRecovery,.clockChanged)}
        let restarted=try await f.store(v,clock)
        do{_=try await restarted.length(variant:"v",context:f.ctx);XCTFail("restart cleared fault")}catch{ceq(error as? OfflineRecovery,.clockChanged)}
        do{try await s.revalidate(variant:"v",grant:f.grant(),sourceTime:clock.now(),context:f.ctx);XCTFail("same grant renewed")}catch{ceq(error as? OfflineRecovery,.clockChanged)}
        let fresh=f.grant(clock.now().addingTimeInterval(1))
        try await s.revalidate(variant:"v",grant:fresh,sourceTime:clock.now(),context:f.ctx)
        ceq(try await s.read(variant:"v",offset:0,count:1,context:f.ctx),Data([0x5a]))
        clock.jump(-10)
        do{_=try await s.length(variant:"v",context:f.ctx);XCTFail("rollback below floor")}catch{ceq(error as? OfflineRecovery,.clockChanged)}
        do{try await s.revalidate(variant:"v",grant:f.grant(f.time.addingTimeInterval(1)),sourceTime:f.time,context:f.ctx);XCTFail("lowered source time")}catch{ceq(error as? OfflineRecovery,.clockChanged)}
        clock.jump(11)
        try await s.revalidate(variant:"v",grant:f.grant(clock.now().addingTimeInterval(1)),sourceTime:clock.now(),context:f.ctx)
        _=try await s.length(variant:"v",context:f.ctx)
        try await v.destroyIsolatedTestKeychain();try FileManager.default.removeItem(at:f.root)
    }
    func testImportCancellationReadBarrierAndFreshRetry()async throws{
        let f=try CF();let v=try f.vault();let clock=CWall(f.time);let base=try await f.store(v,clock);let file=try f.input()
        defer{Task{try? await v.destroyIsolatedTestKeychain();try? FileManager.default.removeItem(at:f.root)}}
        try await base.retain(file:file,variant:"existing",grant:f.grant(),reference:"a",context:f.ctx)
        for cancel in [true,false] {
            let gate=CGate();let s=try await f.store(v,clock,step:{if $0==2{await gate.wait()}})
            let work=Task{try await s.retain(file:file,variant:"new-\(cancel)",grant:f.grant(),reference:"a",context:f.ctx)}
            await gate.entered()
            // A different instance and the same actor can read while preparation is held.
            ceq(try await s.read(variant:"existing",offset:0,count:1,context:f.ctx),Data([0x5a]))
            ceq(try await base.read(variant:"existing",offset:0,count:1,context:f.ctx),Data([0x5a]))
            let partials=FileManager.default.enumerator(at:f.root,includingPropertiesForKeys:nil)!.compactMap{$0 as? URL}.filter{$0.pathExtension=="partial"}
            ceq(partials.count,1)
            let staged=try Data(contentsOf:partials[0].appendingPathComponent("chunk-0"));XCTAssertNotEqual(staged.prefix(32),Data(repeating:0x5a,count:32))
            if cancel{work.cancel()}else{try await s.detach(previous:f.ctx,barrier:RequestContext(account:nil,accountGeneration:2,requestGeneration:0))}
            await gate.release()
            do{try await work.value;XCTFail("cancel/stale import published")}catch{XCTAssertTrue(error is CancellationError || (error as? OfflineRecovery) == .reconnect)}
            let remaining=FileManager.default.enumerator(at:f.root,includingPropertiesForKeys:nil)!.compactMap{$0 as? URL}.filter{$0.pathExtension=="partial"};XCTAssertTrue(remaining.isEmpty)
            if !cancel{await s.bind(RequestContext(account:OwnedMedia.account,accountGeneration:3,requestGeneration:0))}
        }
        let fresh=try await f.store(v,clock);let next=RequestContext(account:OwnedMedia.account,accountGeneration:4,requestGeneration:0);await fresh.bind(next)
        try await fresh.retain(file:file,variant:"retry",grant:f.grant(),reference:"a",context:next)
        ceq(try await fresh.read(variant:"retry",offset:65536,count:1,context:next),Data([0x5a]))
        try await v.destroyIsolatedTestKeychain();try FileManager.default.removeItem(at:f.root)
    }
    func testStaleImportCannotOverwriteDeleteAndSourceMutationIsRejected()async throws{
        let f=try CF();let v=try f.vault();let clock=CWall(f.time);let file=try f.input();let gate=CGate()
        defer{Task{try? await v.destroyIsolatedTestKeychain();try? FileManager.default.removeItem(at:f.root)}}
        let s=try await f.store(v,clock,step:{if $0==2{await gate.wait()}})
        let work=Task{try await s.retain(file:file,variant:"v",grant:f.grant(),reference:"a",context:f.ctx)}
        await gate.entered();try await s.delete(ServiceID("v"),context:f.ctx).outcome.get();await gate.release()
        do{try await work.value;XCTFail("stale import restored delete")}catch{ceq(error as? DomainError,.reconciliationRequired)}
        let mutateGate=CGate();let m=try await f.store(v,clock,step:{if $0==2{await mutateGate.wait()}})
        let mutation=Task{try await m.retain(file:file,variant:"changed",grant:f.grant(),reference:"a",context:f.ctx)}
        await mutateGate.entered();let handle=try FileHandle(forWritingTo:file);try handle.seek(toOffset:0);try handle.write(contentsOf:Data([1]));try handle.close();await mutateGate.release()
        do{try await mutation.value;XCTFail("changed input accepted")}catch{ceq(error as? OfflineRecovery,.redownload)}
        try await v.destroyIsolatedTestKeychain();try FileManager.default.removeItem(at:f.root)
    }
    func testHeldMissingReadDoesNotPoisonFirstImportAndRemovalCancelsWork()async throws{
        let f=try CF();let v=try f.vault();let held=CHeldVault(v);let clock=CWall(f.time);let file=try f.input()
        defer{Task{try? await v.destroyIsolatedTestKeychain();try? FileManager.default.removeItem(at:f.root)}}
        let s=try EncryptedStore(root:f.root.appendingPathComponent("objects"),vault:held,wall:clock,monotonic:CMono());await s.bind(f.ctx)
        let missing=Task{try? await s.read(variant:"missing",offset:0,count:1,context:f.ctx)}
        await held.gate.entered()
        let first=Task{try await s.retain(file:file,variant:"first",grant:f.grant(),reference:"a",context:f.ctx)}
        await held.gate.release();_=await missing.value;try await first.value
        ceq(try await s.read(variant:"first",offset:0,count:1,context:f.ctx),Data([0x5a]))
        let gate=CGate();let importing=try await f.store(v,clock,step:{if $0==2{await gate.wait()}})
        let work=Task{try await importing.retain(file:file,variant:"large",grant:f.grant(),reference:"a",context:f.ctx)}
        await gate.entered()
        let barrier=RequestContext(account:nil,accountGeneration:2,requestGeneration:0)
        let removal=Task{try await importing.removeLocal(OwnedMedia.account,context:barrier)}
        // Observe the barrier without waiting for the deliberately held worker to finish.
        while true { do{_=try await importing.read(variant:"first",offset:0,count:1,context:f.ctx);await Task.yield()}catch{break} }
        await gate.release();try await removal.value
        do{try await work.value;XCTFail("removed import published")}catch{}
        let all=try FileManager.default.contentsOfDirectory(atPath:f.root.appendingPathComponent("objects").path);XCTAssertTrue(all.isEmpty)
        try await v.destroyIsolatedTestKeychain();try FileManager.default.removeItem(at:f.root)
    }
    func testWarmKeyStillChecksCurrentAuthorityAndMissingKey()async throws{
        let f=try CF();let v=try f.vault();let clock=CWall(f.time);let file=try f.input();let s=try await f.store(v,clock)
        defer{Task{try? await v.destroyIsolatedTestKeychain();try? FileManager.default.removeItem(at:f.root)}}
        try await s.retain(file:file,variant:"v",grant:f.grant(),reference:"a",context:f.ctx)
        _=try await s.read(variant:"v",offset:0,count:1,context:f.ctx)
        let other=try await f.store(v,clock)
        let g=f.grant();let revoked=RetentionGrant(issuer:g.issuer,sourceEncryption:g.sourceEncryption,expires:g.expires,renewalReference:g.renewalReference,rights:[],validatedAt:g.validatedAt)
        try await other.updateGrant(variant:"v",grant:revoked,context:f.ctx)
        do{_=try await s.read(variant:"v",offset:0,count:1,context:f.ctx);XCTFail("warm cache granted revoked rights")}catch{ceq(error as? OfflineRecovery,.renewRights)}
        let newer=RetentionGrant(issuer:g.issuer,sourceEncryption:g.sourceEncryption,expires:g.expires,renewalReference:g.renewalReference,rights:g.rights,validatedAt:f.time)
        try await other.updateGrant(variant:"v",grant:newer,context:f.ctx)
        _=try await s.read(variant:"v",offset:0,count:1,context:f.ctx)
        let maybe=try await v.acquireProtectedLease(context:f.ctx);let lease=try XCTUnwrap(maybe)
        try await v.replaceProtectedRecord("offline.master.v2",value:nil,lease:lease,context:f.ctx);try await v.releaseProtectedLease(lease)
        do{_=try await s.read(variant:"v",offset:0,count:1,context:f.ctx);XCTFail("warm missing key used")}catch{ceq(error as? OfflineRecovery,.missingKey)}
        try await v.destroyIsolatedTestKeychain();try FileManager.default.removeItem(at:f.root)
    }

}
