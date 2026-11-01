@preconcurrency import AVFoundation
import Domain
import Queue
import Persistence
import CryptoKit
import Synchronization
import XCTest
@testable import Playback

struct SequenceAssets: NativeAssetProvider, PlaybackResolver, CapabilityProvider {
    let files: [URL]
    let kinds: [NativeAssetSession.ContentKind]
    var unavailableNext = false
    var nextExpiry: Date? = nil
    var wall: any WallClock = SystemWallClock()
    func capabilities(context: RequestContext) async -> ServiceResult<AccountCapabilities> { await OwnedMedia(wall:wall).capabilities(context: context) }
    func validateEligibility(_ media: ServiceID, context: PlaybackContext) async -> PlaybackResult<Capability> { await OwnedMedia(wall:wall).validateEligibility(media, context: context) }
    func resolve(_ media: ServiceID, context: PlaybackContext) async -> PlaybackResult<[MediaVariant]> {
        do {
            if unavailableNext && media == OwnedMedia.items[1] { throw DomainError.unavailableContent }
            guard let index = OwnedMedia.items.firstIndex(of: media) else { throw DomainError.unavailableContent }
            let file = try AVAudioFile(forReading: files[index]); let format = file.fileFormat.streamDescription.pointee
            let codec = format.mFormatID == kAudioFormatMPEG4AAC ? "AAC" : (format.mFormatID == kAudioFormatOpus ? "Opus" : "PCM")
            return .init(context: context, outcome: .success([try MediaVariant(id: media, codec: codec, container: files[index].pathExtension, bitrate: nil, sampleRate: Int(format.mSampleRate), expiresAt: index == 1 ? nextExpiry:nil, seekable: true, authorization: ID("owned-bundle-only"))]))
        } catch { return .init(context: context, outcome: .failure(.unavailableContent)) }
    }
    func refresh(_ variant: MediaVariant, context: PlaybackContext) async -> PlaybackResult<MediaVariant> { await OwnedMedia().refresh(variant, context: context) }
    func report(_ event: ServicePlaybackEvent, context: PlaybackContext) async -> PlaybackResult<Void> { .init(context: context, outcome: .success(())) }
    func asset(for variant: MediaVariant, context: PlaybackContext) async throws -> URL {
        guard context.request.account == OwnedMedia.account, let index = OwnedMedia.items.firstIndex(of: variant.id) else { throw DomainError.forbidden }
        return files[index]
    }
    func assetSession(for variant: MediaVariant, context: PlaybackContext) async throws -> NativeAssetSession {
        let index = OwnedMedia.items.firstIndex(of: variant.id)!
        return NativeAssetSession(asset: AVURLAsset(url: try await asset(for: variant, context: context)), userSeekable: true, decodedAccess: .authorizedNative, contentKind: kinds[index], authorizeUserSeek: {})
    }
}
final class CExpiryWall: WallClock,Sendable {
    let value=Mutex(Date())
    func now()->Date{value.withLock{$0}}
    func advance(_ seconds:Double){value.withLock{$0=$0.addingTimeInterval(seconds)}}
}
actor CPreparationGate {
    var entered = false
    var held: CheckedContinuation<Void,Never>?
    func hold() async { entered=true;await withCheckedContinuation{held=$0} }
    func waiting() -> Bool { entered }
    func release() {held?.resume();held=nil}
}
struct HeldSequenceAssets: NativeAssetProvider {
    let base: SequenceAssets; let gate: CPreparationGate
    func asset(for variant: MediaVariant,context:PlaybackContext) async throws -> URL {try await base.asset(for:variant,context:context)}
    func assetSession(for variant:MediaVariant,context:PlaybackContext) async throws -> NativeAssetSession {
        if variant.id == OwnedMedia.items[1] {await gate.hold()}
        return try await base.assetSession(for:variant,context:context)
    }
}
actor CDurablePersistence: QueuePersistence {
    let underlying: SQLiteQueuePersistence
    let gate: CPreparationGate
    var held = false
    var saved: QueueSnapshot?
    init(store: SQLiteStore,gate:CPreparationGate) {underlying=SQLiteQueuePersistence(store:store);self.gate=gate}
    func enable() {held=true}
    func load(context:RequestContext) async throws -> QueueSnapshot? {try await underlying.load(context:context)}
    func save(_ snapshot:QueueSnapshot,context:RequestContext) async throws {
        if held, let previous=saved, previous.metadata.handoff != nil, previous.current?.id != snapshot.current?.id {held=false;await gate.hold()}
        try await underlying.save(snapshot,context:context);saved=snapshot
    }
}
final class QueueNativeHandoffTests: XCTestCase, @unchecked Sendable {
    func awaitReady(_ session: PlaybackSession) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await session.nextReadyForMeasurement()), ContinuousClock.now < deadline { await session.tick(); await Task.yield() }
        let ready = await session.nextReadyForMeasurement()
        XCTAssertTrue(ready, "eligible short next item must become ready within bounded gate")
    }
    func wave(frames: Int, rate: Double, level: Float, hz: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("W16-C-"+UUID().uuidString+".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        for offset in stride(from: 0, to: frames, by: 4096) {
            let count = min(4096, frames-offset); let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(count))!; buffer.frameLength = UInt32(count)
            for c in 0..<2 { for i in 0..<count { buffer.floatChannelData![c][i] = level * Float(sin(Double(offset+i)*2*Double.pi*hz/rate)) } }
            try file.write(from: buffer)
        }
        file.close(); return url
    }
    func encode(_ source: URL, codec: AudioFormatID, suffix: String) throws -> URL {
        let input = try AVAudioFile(forReading: source)
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("W16-C-"+UUID().uuidString+"."+suffix)
        let output = try AVAudioFile(forWriting: result, settings:[AVFormatIDKey:codec,AVSampleRateKey:input.processingFormat.sampleRate,AVNumberOfChannelsKey:2,AVEncoderBitRateKey:192000],commonFormat:.pcmFormatFloat32,interleaved:false)
        let buffer=AVAudioPCMBuffer(pcmFormat:input.processingFormat,frameCapacity:4096)!
        while input.framePosition<input.length { try input.read(into:buffer,frameCount:UInt32(min(4096,input.length-input.framePosition)));try output.write(from:buffer) }
        output.close();return result
    }
    func reference(_ url: URL) throws -> [Float] {
        let file=try AVAudioFile(forReading:url);let buffer=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:4096)!
        var samples:[Float]=[]
        while file.framePosition<file.length { try file.read(into:buffer,frameCount:UInt32(min(4096,file.length-file.framePosition)));samples.append(contentsOf:UnsafeBufferPointer(start:buffer.floatChannelData![0],count:Int(buffer.frameLength))) }
        return samples
    }
    func testQueuedAACAndOpusNativeTrimming() async throws {
        for (codec,suffix) in [(kAudioFormatMPEG4AAC,"m4a"),(kAudioFormatOpus,"caf")] {
            let a=try wave(frames:96000,rate:48000,level:0.2,hz:317);let b=try wave(frames:96123,rate:48000,level:0.15,hz:701)
            let encodedA=try encode(a,codec:codec,suffix:suffix);let encodedB=try encode(b,codec:codec,suffix:suffix)
            defer { for url in [a,b,encodedA,encodedB] {try? FileManager.default.removeItem(at:url)} }
            let first=try reference(encodedA);let second=try reference(encodedB)
            XCTAssertEqual(first.count,96000);XCTAssertEqual(second.count,96123)
            for url in [encodedA,encodedB] {
                var handle:AudioFileID?;XCTAssertEqual(AudioFileOpenURL(url as CFURL,.readPermission,0,&handle),0)
                var table=AudioFilePacketTableInfo();var size=UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
                XCTAssertEqual(AudioFileGetProperty(handle!,kAudioFilePropertyPacketTableInfo,&size,&table),0);AudioFileClose(handle!)
                let digest=SHA256.hash(data:try Data(contentsOf:url)).map{String(format:"%02x",$0)}.joined()
                print("W16-C corpus codec=\(codec) valid=\(table.mNumberValidFrames) priming=\(table.mPrimingFrames) remainder=\(table.mRemainderFrames) sha256=\(digest)")
            }
            if let directory=ProcessInfo.processInfo.environment["W16_CORPUS_OUTPUT"] {
                let folder=URL(fileURLWithPath:directory).appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                for (name,url) in [("source-a.wav",a),("source-b.wav",b),("encoded-a."+suffix,encodedA),("encoded-b."+suffix,encodedB)] {try FileManager.default.copyItem(at:url,to:folder.appendingPathComponent(name))}
            }
            let expected=first+second+first
            let provider=SequenceAssets(files:[encodedA,encodedB],kinds:[.music,.music])
            let session=try await PlaybackSession.open(context:ownedContext(),persistence:MemoryPersistence(),assets:provider,resolver:provider,capabilities:provider,automaticTick:false,initialGain:1,manualDecodedRendering:true)
            try await session.startOwnedMedia([OwnedMedia.items[0],OwnedMedia.items[1],OwnedMedia.items[0]])
            await awaitReady(session)
            var count=0;var worst:Float=0
            while count<expected.count {
                let buffer=try await session.renderSelected(UInt32(min(1024,expected.count-count)))
                XCTAssertGreaterThan(buffer.frameLength,0)
                for i in 0..<Int(buffer.frameLength) {worst=max(worst,abs(buffer.floatChannelData![0][i]-expected[count+i]))}
                count+=Int(buffer.frameLength);await Task.yield()
            }
            XCTAssertEqual(count,expected.count);XCTAssertLessThanOrEqual(worst,0.000002)
            print("W16-C compressed codec=\(codec) exactFrames=\(count) native/reference maximumError=\(worst) boundaries=[96000,192123]")
            await session.close()
        }
    }
    func testQueueCrossfadeTwelveSecondsAndSpokenExclusion() async throws {
        for spoken in [false,true] {
            let frames=24*48000;let overlap=spoken ? 0:12*48000
            let a=try wave(frames:frames,rate:48000,level:0.2,hz:317);let b=try wave(frames:frames,rate:48000,level:0.6,hz:701)
            defer {try? FileManager.default.removeItem(at:a);try? FileManager.default.removeItem(at:b)}
            let provider=SequenceAssets(files:[a,b],kinds:[.music,spoken ? .spoken:.music])
            let session=try await PlaybackSession.open(context:ownedContext(),persistence:MemoryPersistence(),assets:provider,resolver:provider,capabilities:provider,automaticTick:false,initialGain:1,manualDecodedRendering:true,effects:AudioEffects(crossfade:12))
            try await session.startOwnedMedia(OwnedMedia.items)
        await awaitReady(session)
            var count=0;var worst:Float=0;var handoffAt:Int?
            while count<frames*2-overlap {
                let output=try await session.renderSelected(UInt32(min(1024,frames*2-overlap-count)))
                for i in 0..<Int(output.frameLength) {
                    let frame=count+i;let bIndex=frame-(frames-overlap)
                    let old=frame<frames ? Float(sin(Double(frame)*2*Double.pi*317/48000))*0.2:0
                    let new=bIndex>=0 ? Float(sin(Double(bIndex)*2*Double.pi*701/48000))*0.6:0
                    let t=overlap>1 ? max(0,min(1,Float(bIndex)/Float(overlap-1))):1
                    let expected=frame<frames-overlap ? old:(frame<frames ? old*(1-t)+new*t:new)
                    worst=max(worst,abs(output.floatChannelData![0][i]-expected))
                }
                count+=Int(output.frameLength)
                if handoffAt==nil,try await session.snapshot().queue.current?.media==OwnedMedia.items[1] {handoffAt=count}
                await Task.yield()
            }
            XCTAssertLessThanOrEqual(worst,0.000002);XCTAssertEqual(handoffAt,frames-overlap)
            print("W16-C queue fade seconds=12 spoken=\(spoken) frames=\(count) handoff=\(handoffAt ?? -1) maximumError=\(worst)")
            await session.close()
        }
    }
    func testHeldQueuePreparationRemovalAndSyntheticRouteOrQuit() async throws {
        for action in ["remove","replace","route","quit"] {
            let a=try wave(frames:96000,rate:48000,level:0.2,hz:317);let b=try wave(frames:96000,rate:48000,level:0.15,hz:701)
            defer {try? FileManager.default.removeItem(at:a);try? FileManager.default.removeItem(at:b)}
            let provider=SequenceAssets(files:[a,b],kinds:[.music,.music]);let gate=CPreparationGate()
            let session=try await PlaybackSession.open(context:ownedContext(),persistence:MemoryPersistence(),assets:HeldSequenceAssets(base:provider,gate:gate),resolver:provider,capabilities:provider,automaticTick:false,initialGain:1,manualDecodedRendering:true)
            let starting=Task {try await session.startOwnedMedia(OwnedMedia.items)}
            let deadline=ContinuousClock.now.advanced(by:.seconds(5))
            while !(await gate.waiting()),ContinuousClock.now<deadline {await Task.yield()}
            let entered=await gate.waiting();XCTAssertTrue(entered)
            let before=try await session.queueSnapshotForMeasurement()
            switch action {
            case "remove":try await session.sendQueue(.remove([before.upcoming.first!.id]))
            case "replace":try await session.startOwnedMedia([OwnedMedia.items[0]])
            case "route":await session.routeInvalidated(try RouteID("synthetic-output-loss"))
            default:await session.close()
            }
            await gate.release();_ = try? await starting.value
            let after=try await session.queueSnapshotForMeasurement();XCTAssertNil(after.metadata.handoff)
            if action == "remove" || action == "replace" {
                let output=try await session.renderSelected(1024)
                XCTAssertEqual(output.floatChannelData![0][100],0.2*Float(sin(100*2*Double.pi*317/48000)),accuracy:0.000002)
                XCTAssertFalse(after.session.entries.contains{$0.media == OwnedMedia.items[1]})
            } else {
                let rate=await session.engine.nativeRate();XCTAssertEqual(rate,0)
                let buffers=await session.engine.decodedResourceState();XCTAssertEqual(buffers.retainedFrames,0)
            }
            print("W16-C held next preparation action=\(action) stale next cannot schedule; synthetic route label only")
            await session.close()
        }
    }
    func testSQLitePreparedIntentAndCommitBeforeHandoffPublication() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("W16-C-queue-"+UUID().uuidString)
        let a=try wave(frames:96000,rate:48000,level:0.2,hz:317);let b=try wave(frames:96000,rate:48000,level:0.15,hz:701)
        defer {try? FileManager.default.removeItem(at:a);try? FileManager.default.removeItem(at:b);try? FileManager.default.removeItem(at:root)}
        let request=ownedContext();let store=try SQLiteStore(directory:root,context:request)
        try await store.saveAccount(Account(id:OwnedMedia.account.accountID,serviceIdentity:ServiceID("owned-identity"),context:OwnedMedia.account,displayName:"Owned local",credential:nil),context:request)
        let gate=CPreparationGate();let persistence=CDurablePersistence(store:store,gate:gate)
        let provider=SequenceAssets(files:[a,b],kinds:[.music,.music])
        let session=try await PlaybackSession.open(context:request,persistence:persistence,assets:provider,resolver:provider,capabilities:provider,automaticTick:false,initialGain:1,manualDecodedRendering:true)
        try await session.startOwnedMedia(OwnedMedia.items)
        await awaitReady(session)
        let first=try await session.snapshot();XCTAssertNotNil(first.queue.metadata.handoff)
        let raw=try await store.restoredQueue(context:request);let cursor=try XCTUnwrap(raw?.continuation.cursor)
        let envelope=try XCTUnwrap(Data(base64Encoded:String(cursor.dropFirst("local-queue-v2:".count))))
        let metadata=try XCTUnwrap((JSONSerialization.jsonObject(with:envelope) as? [String:Any])?["metadata"] as? [String:Any])
        XCTAssertNotNil(metadata["handoff"])
        let restored=try await SQLiteQueuePersistence(store:store).load(context:request)
        XCTAssertNil(restored?.metadata.handoff);XCTAssertEqual(restored?.intent,.pause(.restored))
        await persistence.enable()
        let rendering=Task { var count=0;while count<96000 {let block=try await session.renderSelected(UInt32(min(1024,96000-count)));count+=Int(block.frameLength)};return count }
        let deadline=ContinuousClock.now.advanced(by:.seconds(5))
        while !(await gate.waiting()),ContinuousClock.now<deadline {await Task.yield()}
        let entered=await gate.waiting();XCTAssertTrue(entered)
        let held=try await session.queueSnapshotForMeasurement();XCTAssertEqual(held.current?.id,first.queue.current?.id)
        let diskBefore=try await store.restoredQueue(context:request);XCTAssertEqual(diskBefore?.queue.currentOccurrence,first.queue.current?.id)
        await gate.release();let count=try await rendering.value;XCTAssertEqual(count,96000)
        let adopted=try await session.snapshot();XCTAssertEqual(adopted.queue.current?.media,OwnedMedia.items[1]);XCTAssertEqual(adopted.queue.metadata.recent.count,1)
        let diskAfter=try await store.restoredQueue(context:request);XCTAssertEqual(diskAfter?.queue.currentOccurrence,adopted.queue.current?.id)
        XCTAssertNotEqual(first.queue.playbackToken,adopted.queue.playbackToken)
        print("W16-C SQLite: prepared intent durable; held adoption not published; commit precedes native/Domain identity publication")
        await session.close();await store.close()
    }
    func testPauseSeekManualNextShuffleAndRepeatKeepQueueOwnership() async throws {
        let a=try wave(frames:96000,rate:48000,level:0.2,hz:317);let b=try wave(frames:96000,rate:48000,level:0.15,hz:701)
        defer {try? FileManager.default.removeItem(at:a);try? FileManager.default.removeItem(at:b)}
        let provider=SequenceAssets(files:[a,b],kinds:[.music,.music])
        let session=try await PlaybackSession.open(context:ownedContext(),persistence:MemoryPersistence(),assets:provider,resolver:provider,capabilities:provider,automaticTick:false,initialGain:1,manualDecodedRendering:true)
        try await session.startOwnedMedia([OwnedMedia.items[0],OwnedMedia.items[1],OwnedMedia.items[0]])
            await awaitReady(session)
        _ = try await session.renderSelected(1024)
        try await session.pause();let paused=try await session.snapshot();XCTAssertNil(paused.queue.metadata.handoff)
        try await session.resume();try await session.seek(1)
        let sought=try await session.renderSelected(1024)
        XCTAssertEqual(sought.floatChannelData![0][100],0.2*Float(sin(Double(48000+100)*2*Double.pi*317/48000)),accuracy:0.000002)
        try await session.sendQueue(.shuffle(42));let shuffled=try await session.snapshot();XCTAssertNil(shuffled.queue.metadata.handoff)
        try await session.next();let next=try await session.snapshot();XCTAssertNotEqual(next.queue.current?.id,paused.queue.current?.id)
        try await session.sendQueue(.repeatMode(.one))
        let repeated=try await session.renderSelected(1024);XCTAssertEqual(repeated.frameLength,1024)
        await awaitReady(session)
        let repeatScope=try await session.snapshot();XCTAssertNotNil(repeatScope.queue.metadata.handoff)
        for _ in 0..<120 {_ = try await session.renderSelected(1024);if try await session.snapshot().queue.playbackToken != repeatScope.queue.playbackToken {break}}
        let after=try await session.snapshot();XCTAssertEqual(after.queue.current?.id,repeatScope.queue.current?.id);XCTAssertNotEqual(after.queue.playbackToken,repeatScope.queue.playbackToken)
        await session.close()
    }
    func testUnavailableAndImmutableAdsNeverOverlapOrPrefetchPastBarrier() async throws {
        for unavailable in [false,true] {
            let a=try wave(frames:96000,rate:48000,level:0.2,hz:317);let b=try wave(frames:96000,rate:48000,level:0.15,hz:701)
            defer {try? FileManager.default.removeItem(at:a);try? FileManager.default.removeItem(at:b)}
            let provider=SequenceAssets(files:[a,b],kinds:[.music,unavailable ? .music:.advertisement],unavailableNext:unavailable)
            let session=try await PlaybackSession.open(context:ownedContext(),persistence:MemoryPersistence(),assets:provider,resolver:provider,capabilities:provider,automaticTick:false,initialGain:1,manualDecodedRendering:true,effects:AudioEffects(crossfade:12))
            if unavailable {try await session.startOwnedMedia(OwnedMedia.items)}
            else {
                try await session.startOwnedMedia([OwnedMedia.items[0]])
                try await session.sendQueue(.serviceEntry(QueueEntry(media:OwnedMedia.items[1],segment:.advertisement,originalOrder:1),immutable:true))
            }
            var count=0;var worst:Float=0
            while count<95000 {
                let output=try await session.renderSelected(UInt32(min(1024,95000-count)))
                for i in 0..<Int(output.frameLength) {worst=max(worst,abs(output.floatChannelData![0][i]-0.2*Float(sin(Double(count+i)*2*Double.pi*317/48000))))}
                count+=Int(output.frameLength)
            }
            let state=try await session.snapshot();XCTAssertEqual(state.queue.current?.media,OwnedMedia.items[0]);XCTAssertNil(state.queue.metadata.handoff)
            XCTAssertLessThanOrEqual(worst,0.000002)
            XCTAssertFalse(state.queue.upcoming.first!.consumed)
            print("W16-C barrier unavailable=\(unavailable): current coherent frames=\(count), no overlap/early consumption, errorState=\(state.failures)")
            await session.close()
        }
    }
    func testPreparedNextExpiryRetractsAlreadyQueuedSamples() async throws {
        let a=try wave(frames:96000,rate:48000,level:0.2,hz:317);let b=try wave(frames:96000,rate:48000,level:0.15,hz:701)
        defer {try? FileManager.default.removeItem(at:a);try? FileManager.default.removeItem(at:b)}
        let wall=CExpiryWall()
        let provider=SequenceAssets(files:[a,b],kinds:[.music,.music],nextExpiry:wall.now().addingTimeInterval(1),wall:wall)
        let session=try await PlaybackSession.open(context:ownedContext(),persistence:MemoryPersistence(),assets:provider,resolver:provider,capabilities:provider,wall:wall,automaticTick:false,initialGain:1,manualDecodedRendering:true)
        try await session.startOwnedMedia(OwnedMedia.items)
        await awaitReady(session)
        var count=0
        while count<95000 {let block=try await session.renderSelected(UInt32(min(1024,95000-count)));count+=Int(block.frameLength)}
        let before=try await session.snapshot();XCTAssertNotNil(before.queue.metadata.handoff)
        wall.advance(2)
        let tail=try await session.renderSelected(1000)
        XCTAssertEqual(tail.frameLength,1000)
        var worst:Float=0
        for i in 0..<1000 {worst=max(worst,abs(tail.floatChannelData![0][i]-0.2*Float(sin(Double(95000+i)*2*Double.pi*317/48000))))}
        XCTAssertLessThanOrEqual(worst,0.000002)
        print("W16-C prepared expiry: future buffers withdrawn; exact current tail=1000 frames maximumError=\(worst)")
        await session.close()
    }
    func testShortImpulseBoundariesHaveNoSilentOrRepeatedLogicalSamples() async throws {
        for rate in [44100.0,48000] {
            var urls:[URL]=[];var references:[[Float]]=[]
            for (count,level) in [(4097,Float(0.25)),(5003,Float(-0.2))] {
                let format=AVAudioFormat(standardFormatWithSampleRate:rate,channels:2)!
                let url=FileManager.default.temporaryDirectory.appendingPathComponent("W16-C-impulse-"+UUID().uuidString+".wav")
                let file=try AVAudioFile(forWriting:url,settings:format.settings)
                let block=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:UInt32(count))!;block.frameLength=UInt32(count)
                let values=(0..<count).map {i in (i==0 || i==count-1 || i==2047) ? level:Float(i%2==0 ? 0.03:-0.03)}
                for c in 0..<2 {for i in 0..<count {block.floatChannelData![c][i]=values[i]}}
                try file.write(from:block);file.close();urls.append(url);references.append(values)
            }
            defer {for url in urls {try? FileManager.default.removeItem(at:url)}}
            let provider=SequenceAssets(files:urls,kinds:[.music,.music])
            let session=try await PlaybackSession.open(context:ownedContext(),persistence:MemoryPersistence(),assets:provider,resolver:provider,capabilities:provider,automaticTick:false,initialGain:1,manualDecodedRendering:true)
            try await session.startOwnedMedia([OwnedMedia.items[0],OwnedMedia.items[1],OwnedMedia.items[0]])
            await awaitReady(session)
            let expected=references[0]+references[1]+references[0];var count=0;var worst:Float=0
            while count<expected.count {
                let block=try await session.renderSelected(UInt32(min(1024,expected.count-count)))
                for i in 0..<Int(block.frameLength) {worst=max(worst,abs(block.floatChannelData![0][i]-expected[count+i]))}
                count+=Int(block.frameLength)
                if count >= 4097 && count - Int(block.frameLength) < 4097 { await awaitReady(session) }
            }
            XCTAssertEqual(count,13197);XCTAssertLessThanOrEqual(worst,0.000002)
            print("W16-C impulses rate=\(rate) frames=\(count) boundaryPositions=[4097,9100] maximumError=\(worst)")
            await session.close()
        }
    }
    func testQueuePCMGaplessAtNativeRates() async throws {
        // Fixed before production measurements: <=2e-6 PCM absolute error, exact
        // logical frame count, <=1 source sample timestamp uncertainty.
        for rate in [44100.0,48000] {
            let count = Int(rate * 2)
            let a = try wave(frames: count, rate: rate, level: 0.2, hz:317)
            let b = try wave(frames: count+123, rate: rate, level:0.15,hz:701)
            defer { try? FileManager.default.removeItem(at:a);try? FileManager.default.removeItem(at:b) }
            let provider = SequenceAssets(files:[a,b],kinds:[.music,.music])
            let persistence = MemoryPersistence()
            let session = try await PlaybackSession.open(context:ownedContext(),persistence:persistence,assets:provider,resolver:provider,capabilities:provider,automaticTick:false,initialGain:1,manualDecodedRendering:true)
            try await session.startOwnedMedia([OwnedMedia.items[0],OwnedMedia.items[1],OwnedMedia.items[0]])
            await awaitReady(session)
            let initial = try await session.snapshot(); XCTAssertNotNil(initial.queue.metadata.handoff)
            let lengths=[count,count+123,count]; var cursor=0; var worst:Float=0
            let total=lengths.reduce(0,+)
            while cursor < total {
                let output = try await session.renderSelected(UInt32(min(1024,total-cursor)))
                XCTAssertGreaterThan(output.frameLength,0)
                for i in 0..<Int(output.frameLength) {
                    let frame=cursor+i; let second=frame>=count && frame<count+count+123
                    let local=second ? frame-count : (frame<count ? frame : frame-count-count-123)
                    let expected=(second ? Float(0.15):0.2)*Float(sin(Double(local)*2*Double.pi*(second ? 701:317)/rate))
                    worst=max(worst,abs(output.floatChannelData![0][i]-expected))
                }
                cursor += Int(output.frameLength)
                await Task.yield()
            }
            XCTAssertEqual(cursor,total);XCTAssertLessThanOrEqual(worst,0.000002)
            for _ in 0..<200 { if try await session.snapshot().queue.current == nil { break }; await Task.yield() }
            let final = try await session.snapshot()
            XCTAssertNil(final.queue.current);XCTAssertEqual(final.queue.metadata.recent.count,3)
            print("W16-C queue PCM rate=\(rate) frames=\(cursor) worst=\(worst) logicalHistory=\(final.queue.metadata.recent.count)")
            await session.close()
        }
    }
}
