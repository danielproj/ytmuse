import XCTest
import Foundation
import Domain
import AccountSession
import Downloads
import Playback
private func orderEqual<T:Equatable>(_ a:T,_ b:T,file:StaticString=#filePath,line:UInt=#line){XCTAssertEqual(a,b,file:file,line:line)}
private struct OrderWall:WallClock{let time:Date;func now()->Date{time}}
private struct OrderMono:MonotonicClock{func now()->Duration{.zero}}
final class GrantOrderingReworkTests:XCTestCase,@unchecked Sendable{
    func testOlderAndEqualPermissiveCallbacksCannotUndoRevocation()async throws{
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("W14-N3-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let namespace=KeychainVault.applicationNamespace+".test.N3."+UUID().uuidString;let url=root.appendingPathComponent("keychain")
        let vault=try KeychainVault(testNamespace:namespace,isolatedKeychainURL:url)
        defer{Task{try? await vault.destroyIsolatedTestKeychain();try? FileManager.default.removeItem(at:root)}}
        let now=Date(timeIntervalSince1970:floor(Date().timeIntervalSince1970));let c=RequestContext(account:OwnedMedia.account,accountGeneration:1,requestGeneration:0)
        let s=try EncryptedStore(root:root.appendingPathComponent("objects"),vault:vault,wall:OrderWall(time:now),monotonic:OrderMono());await s.bind(c)
        let file=root.appendingPathComponent("input");try Data(repeating:7,count:100000).write(to:file)
        func grant(_ offset:Double,_ rights:Set<String>)->RetentionGrant{.init(issuer:"Owned ordered authority",sourceEncryption:"none",expires:now.addingTimeInterval(3600),renewalReference:"ordered",rights:rights,validatedAt:now.addingTimeInterval(offset))}
        let old=grant(-100,["play","retain","seek"]),revoked=grant(-50,[])
        try await s.retain(file:file,variant:"v",grant:old,reference:"a",context:c)
        try await s.retain(file:file,variant:"control",grant:old,reference:"b",context:c)
        _=try await s.read(variant:"v",offset:0,count:1,context:c)
        try await s.updateGrant(variant:"v",grant:revoked,context:c)
        let before=await s.storageMetrics()
        try await s.updateGrant(variant:"v",grant:revoked,context:c)
        let after=await s.storageMetrics();XCTAssertEqual(before["indexWrites"],after["indexWrites"])
        for stale in [old,grant(-50,["play","retain","seek"])]{
            do{try await s.updateGrant(variant:"v",grant:stale,context:c);XCTFail("stale/equal permissive update accepted")}catch{orderEqual(error as? OfflineRecovery,.staleGrant)}
            do{_=try await s.read(variant:"v",offset:0,count:1,context:c);XCTFail("revoked bytes resurrected")}catch{orderEqual(error as? OfflineRecovery,.renewRights)}
        }
        let otherVault=try KeychainVault(testNamespace:namespace,reopeningIsolatedKeychainURL:url)
        let reopened=try EncryptedStore(root:root.appendingPathComponent("objects"),vault:otherVault,wall:OrderWall(time:now),monotonic:OrderMono());await reopened.bind(c)
        do{try await reopened.updateGrant(variant:"v",grant:old,context:c);XCTFail("restart accepted older update")}catch{orderEqual(error as? OfflineRecovery,.staleGrant)}
        orderEqual(try await reopened.read(variant:"control",offset:0,count:1,context:c),Data([7]))
        try await reopened.updateGrant(variant:"v",grant:grant(-10,["play","retain","seek"]),context:c)
        orderEqual(try await reopened.read(variant:"v",offset:0,count:1,context:c),Data([7]))
        let other=try AccountContext(accountID:UUID(),channelID:ID("other-owned"),region:"US")
        let bc=RequestContext(account:other,accountGeneration:2,requestGeneration:0);await reopened.bind(bc)
        try await reopened.retain(file:file,variant:"v",grant:old,reference:"other",context:bc)
        orderEqual(try await reopened.read(variant:"v",offset:0,count:1,context:bc),Data([7]))
        try await vault.destroyIsolatedTestKeychain();try FileManager.default.removeItem(at:root)
    }
}
