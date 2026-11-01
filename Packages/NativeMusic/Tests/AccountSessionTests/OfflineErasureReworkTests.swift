import XCTest
import Foundation
import Security
import Darwin
import Domain
import AccountSession
import Downloads

private func nEqual<T:Equatable>(_ a:T,_ b:T,file:StaticString=#filePath,line:UInt=#line){XCTAssertEqual(a,b,file:file,line:line)}
final class OfflineErasureReworkTests:XCTestCase,@unchecked Sendable{
    func testActualLifecycleErasesCredentialsWhileOfflineLeaseHeld()async throws{
        for remove in [false,true]{
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("W14-N1-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let namespace=KeychainVault.applicationNamespace+".test.N1."+UUID().uuidString
            let url=root.appendingPathComponent("keychain")
            let vault=try KeychainVault(testNamespace:namespace,isolatedKeychainURL:url)
            let offline=try EncryptedStore(root:root.appendingPathComponent("objects"),vault:vault)
            let directory=MemoryDirectory();let lifecycle=try AccountLifecycle(directory:.init(),vault:vault,store:directory,participants:[offline])
            let a=try identity("erase"),b=try identity("keep")
            try await connect(lifecycle,a);try await connect(lifecycle,b);try await lifecycle.switchIdentity(to:a.context)
            let state=await lifecycle.snapshot();let context=state.context
            let credential=try XCTUnwrap(state.directory.identities.first{$0.id==a.context}?.account.credential)
            let keep=try XCTUnwrap(state.directory.identities.first{$0.id==b.context}?.account.credential)
            let input=root.appendingPathComponent("input");try Data(repeating:9,count:100000).write(to:input)
            let now=Date();let grant=RetentionGrant(issuer:"owned N1",sourceEncryption:"none",expires:now.addingTimeInterval(3600),renewalReference:"owned",rights:["play","retain","seek"],validatedAt:now.addingTimeInterval(-1))
            try await offline.retain(file:input,variant:"v",grant:grant,reference:"a",context:context)
            let maybe=try await vault.acquireProtectedLease(context:context);let lease=try XCTUnwrap(maybe)
            if remove{
                do{try await lifecycle.remove(a.context);XCTFail("private cleanup should remain retryable while a genuine lease is held")}
                catch{guard case LifecycleError.cleanupFailed(let labels)=error else{throw error};XCTAssertTrue(labels.contains("encrypted-offline-store"));XCTAssertFalse(labels.contains("keychain"))}
                let pending=await lifecycle.snapshot();XCTAssertEqual(pending.directory.identities.first{$0.id==a.context}?.state,.removalPending)
            }else{do{try await lifecycle.signOut(a.context)}catch{XCTFail("signout credential erasure blocked: \(error)")}}
            let reader=try KeychainVault(testNamespace:namespace,reopeningIsolatedKeychainURL:url)
            await reader.bind(context)
            do{_=try await reader.read(credential,context:context);XCTFail("credential survived actual lifecycle erasure")}
            catch{XCTAssertEqual(error as? LifecycleError,.keychain(errSecItemNotFound))}
            do{_=try await vault.protectedRecord("offline.master.v2",lease:lease,context:context);XCTFail("old lease authorized protected read") }catch{}
            do{_=try await offline.read(variant:"v",offset:0,count:1,context:context);XCTFail("old byte delivery survived barrier") }catch{XCTAssertEqual(error as? OfflineRecovery,.reconnect)}
            try await vault.releaseProtectedLease(lease)
            if remove{try await lifecycle.remove(a.context);let removed=await lifecycle.snapshot();XCTAssertNil(removed.directory.identities.first{$0.id==a.context})}
            let keptContext=RequestContext(account:b.context,accountGeneration:context.accountGeneration+100,requestGeneration:0)
            await reader.bind(keptContext);nEqual(try await reader.read(keep,context:keptContext),Data("synthetic-disposable-session".utf8))
            try await vault.destroyIsolatedTestKeychain();try FileManager.default.removeItem(at:root)
        }
    }
    func testIncarnationRecoveryAndGenuineActiveOwnerControl()async throws{
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("W14-N1-incarnation-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let namespace=KeychainVault.applicationNamespace+".test.N1."+UUID().uuidString;let url=root.appendingPathComponent("keychain")
        let v=try KeychainVault(testNamespace:namespace,isolatedKeychainURL:url);let a=try identity("owned-incarnation")
        let c=RequestContext(account:a.context,accountGeneration:1,requestGeneration:0);await v.bind(c)
        var kc:SecKeychain?;XCTAssertEqual(SecKeychainOpen(url.path,&kc),errSecSuccess)
        let account=a.context;let service=namespace+":"+account.accountID.uuidString+":\(account.channelID.rawValue.utf8.count):"+account.channelID.rawValue+":"+account.region
        let token=UUID()
        func plant(pid:Int32,incarnation:String)throws{
            let bytes=try JSONSerialization.data(withJSONObject:["pid":pid,"token":token.uuidString,"incarnation":incarnation])
            let q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"protected.record.v2:protected.lock.v2",kSecAttrSynchronizable as String:false,kSecUseKeychain as String:kc!,kSecValueData as String:bytes,kSecAttrGeneric as String:Data(token.uuidString.utf8)]
            XCTAssertEqual(SecItemAdd(q as CFDictionary,nil),errSecSuccess)
        }
        try plant(pid:getpid(),incarnation:"different-boot-or-process-start")
        let recovered=try await v.acquireProtectedLease(context:c);let lease=try XCTUnwrap(recovered);try await v.releaseProtectedLease(lease)
        var dead:Int32=99990;while kill(dead,0)==0 || errno != ESRCH{dead -= 1}
        try plant(pid:dead,incarnation:"old-start")
        let deadRecovered=try await v.acquireProtectedLease(context:c);let deadLease=try XCTUnwrap(deadRecovered);try await v.releaseProtectedLease(deadLease)
        let real=try await v.acquireProtectedLease(context:c);let live=try XCTUnwrap(real)
        let other=try KeychainVault(testNamespace:namespace,reopeningIsolatedKeychainURL:url);await other.bind(c)
        let blocked=try await other.acquireProtectedLease(context:c);XCTAssertNil(blocked)
        try await v.deleteAll(for:a.context)
        do{_=try await v.protectedRecord("offline.master.v2",lease:live,context:c);XCTFail("erased epoch accepted old lease") }catch{}
        // Fresh authentication is explicit; the live writer lock remains exclusive.
        _=try await other.insert(Data("new-owned-session".utf8),for:a.context)
        let stillBlocked=try await other.acquireProtectedLease(context:c);XCTAssertNil(stillBlocked)
        try await v.releaseProtectedLease(live)
        let fresh=try await other.acquireProtectedLease(context:c);let freshLease=try XCTUnwrap(fresh);try await other.releaseProtectedLease(freshLease)
        try await v.destroyIsolatedTestKeychain();try FileManager.default.removeItem(at:root)
    }
}
