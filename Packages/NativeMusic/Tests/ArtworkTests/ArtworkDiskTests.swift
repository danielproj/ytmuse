import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Domain
import Darwin

private func waitForStaging(_ semaphore: DispatchSemaphore) -> Bool { semaphore.wait(timeout: .now() + 5) == .success }
@testable import Artwork

@Suite(.serialized)
struct ArtworkDiskTests {
    private func owner() throws -> ArtworkOwner {
        ArtworkOwner(account: try AccountContext(accountID: UUID(), channelID: ID("owned-disk-tests"), region: "US"))
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ytmuse-w09-disk-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); return url
    }
    private func nativeNoisePNG(width: Int = 1400) throws -> Data {
        var bytes = [UInt8](repeating: 255, count: width * width * 4)
        var state: UInt64 = 0xfaceabcd
        for i in stride(from: 0, to: bytes.count, by: 4) {
            for j in 0..<3 { state = state &* 6364136223846793005 &+ 1; bytes[i+j] = UInt8(truncatingIfNeeded: state >> 32) }
        }
        let image = CGImage(width: width, height: width, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination)); return data as Data
    }
    private func record(_ owner: ArtworkOwner, key: String, png: Data, expiry: Date = .distantFuture, width: Int = 1400) -> ArtworkDiskRecord {
        ArtworkDiskRecord(publication: UUID(), key: artworkDigest(key), owner: artworkDigest(owner.account.accountID.uuidString), expires: expiry,
                          width: width, height: width, palette: ArtworkPalette(red: 0.5, green: 0.5, blue: 0.5, opacity: 0.22),
                          pngHash: artworkDigest(png), png: png)
    }
    @Test func actualDefaultDiskCeilingEvictsNativePNGRecords() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let account = try owner(), authority = ArtworkAuthority(); authority.set(account, generation: 1)
        let disk = ArtworkDiskStore(root: url, configuration: .default)
        let png = try nativeNoisePNG()
        let decoder = ArtworkDecoder()
        let decoded = try await decoder.decode(png, size: ArtworkSize(pointsWidth: 1400, pointsHeight: 1400, scale: 1), configuration: .default, persist: false)
        #expect(decoded.image.byteCost == 1400 * 1400 * 4)
        let count = 512 * 1024 * 1024 / png.count + 3
        #expect(count > 2 && count < 130)
        // Cumulative real encoded writes exceed the default ceiling. Identical owned bytes,
        // distinct variant keys; no sparse files, fake file sizes or injected byte counters.
        for i in 0..<count { await disk.write(record(account, key: "variant-\(i)", png: png), now: Date(), authority: authority, owner: account, generation: 1) }
        let stats = await disk.snapshot()
        let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])
        let actual = try files.reduce(0) { total, file in
            var info = stat()
            guard lstat(file.path, &info) == 0 else { throw ArtworkError.storageUnavailable }
            return total + max(Int(info.st_size), Int(info.st_blocks) * 512)
        }
        #expect(count * png.count > 512 * 1024 * 1024)
        #expect(stats.bytes == actual); #expect(actual <= 512 * 1024 * 1024)
        #expect(stats.peakBytes <= 512 * 1024 * 1024); #expect(stats.evictions >= 2)
        #expect(stats.failures == 0); #expect(stats.mainThreadWorkViolations == 0)
        #expect(await disk.read(key: artworkDigest("variant-0"), owner: artworkDigest(account.account.accountID.uuidString), now: Date()) == nil)
        #expect(await disk.read(key: artworkDigest("variant-\(count-1)"), owner: artworkDigest(account.account.accountID.uuidString), now: Date()) != nil)
        print("ARTWORK disk nativePNGBytes=\(png.count) actualWrites=\(count) cumulativePNGBytes=\(count * png.count) retainedFileBytes=\(actual) peak=\(stats.peakBytes) evictions=\(stats.evictions)")
    }
    @Test func staleAuthorityCannotCommitAndConditionalCleanupPreservesPeer() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let a = try owner(), b = try owner(), authority = ArtworkAuthority()
        let disk = ArtworkDiskStore(root: url, configuration: .default)
        let png = Data([1, 2, 3]) // Store seam; native decoding is tested with PNG in the ceiling case.
        authority.set(a, generation: 1)
        let old = record(a, key: "same", png: png)
        authority.set(b, generation: 2)
        await disk.write(old, now: Date(), authority: authority, owner: a, generation: 1)
        #expect(await disk.snapshot().entries == 0)
        authority.set(a, generation: 3)
        let peer = record(a, key: "same", png: png)
        await disk.write(peer, now: Date(), authority: authority, owner: a, generation: 3)
        await disk.remove(key: peer.key, owner: peer.owner, publication: old.publication)
        #expect(await disk.snapshot().entries == 1)
        await disk.remove(key: peer.key, owner: peer.owner, publication: peer.publication)
        #expect(await disk.snapshot().bytes == 0)
    }
    @Test func persistedOversizeSymlinkAndPermissionsAreRejected() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let account = try owner(), authority = ArtworkAuthority(); authority.set(account, generation: 1)
        let config = try ArtworkConfiguration(diskBytes: 100_000, maximumInputBytes: 8192)
        let rec = record(account, key: "persisted", png: try nativeNoisePNG(width: 32), width: 32)
        let path = url.appendingPathComponent("\(rec.owner).\(rec.key).art")
        let disk = ArtworkDiskStore(root: url, configuration: config)
        await disk.write(rec, now: Date(), authority: authority, owner: account, generation: 1)
        let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        #expect(await disk.read(key: rec.key, owner: rec.owner, now: Date()) != nil) // Otherwise-valid native PNG: permission guard must be load-bearing.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
        #expect(await disk.read(key: rec.key, owner: rec.owner, now: Date()) == nil)
        #expect(await disk.snapshot().bytes == 0)
        // An external sentinel is never followed or overwritten.
        let sentinel = url.deletingLastPathComponent().appendingPathComponent("ytmuse-w09-sentinel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: sentinel) }
        try Data("sentinel".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: sentinel)
        let restarted = ArtworkDiskStore(root: url, configuration: config)
        #expect(await restarted.read(key: rec.key, owner: rec.owner, now: Date()) == nil)
        #expect(try Data(contentsOf: sentinel) == Data("sentinel".utf8))
        try Data(repeating: 1, count: 80_000).write(to: path)
        let oversized = ArtworkDiskStore(root: url, configuration: config)
        #expect(await oversized.read(key: rec.key, owner: rec.owner, now: Date()) == nil)
        #expect(await oversized.snapshot().bytes == 0)
        let alias = url.deletingLastPathComponent().appendingPathComponent("ytmuse-w09-alias-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: alias) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
        let aliased = ArtworkDiskStore(root: alias, configuration: config)
        await aliased.write(rec, now: Date(), authority: authority, owner: account, generation: 1)
        #expect(await aliased.snapshot().failures == 1)
    }
    @Test func malformedPersistedHashExpirySizeAndOwnership() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let account = try owner(), authority = ArtworkAuthority(); authority.set(account, generation: 1)
        let original = record(account, key: "entry", png: try nativeNoisePNG())
        let path = url.appendingPathComponent("\(original.owner).\(original.key).art")
        for mutation in ["hash", "expiry", "size", "owner", "palette"] {
            let disk = ArtworkDiskStore(root: url, configuration: .default)
            await disk.write(original, now: Date(), authority: authority, owner: account, generation: 1)
            #expect(await disk.read(key: original.key, owner: original.owner, now: Date()) != nil) // Nonvacuous captured-success control.
            var plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: path).dropFirst(16), format: nil) as? [String: Any])
            switch mutation {
            case "hash": plist["pngHash"] = "incorrect"
            case "expiry": plist["expires"] = Date.distantPast
            case "size": plist["width"] = 99999
            case "owner": plist["owner"] = artworkDigest("other-owner")
            default: plist["palette"] = ["red": 5.0, "green": 0.5, "blue": 0.5, "opacity": 0.22]
            }
            var damaged = try Data(contentsOf: path).prefix(16)
            damaged.append(try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0))
            try damaged.write(to: path)
            let reader = ArtworkDiskStore(root: url, configuration: .default)
            #expect(await reader.read(key: original.key, owner: original.owner, now: Date()) == nil)
            #expect(await reader.snapshot().bytes == 0)
            #expect(await reader.snapshot().corruptions == 1)
        }
    }
}

extension ArtworkDiskTests {
    @Test func switchDuringActualDiskStagingRejectsFinalRename() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let a = try owner(), b = try owner(), authority = ArtworkAuthority()
        authority.set(a, generation: 1)
        let disk = ArtworkDiskStore(root: url, configuration: .default)
        let rec = record(a, key: "race", png: Data([1, 2, 3]))
        let staged = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let producer = Task.detached {
            await disk.write(rec, now: Date(), authority: authority, owner: a, generation: 1, beforeCommit: {
                staged.signal()
                _ = resume.wait(timeout: .now() + 5)
            })
        }
        let ready = await Task.detached { waitForStaging(staged) }.value
        #expect(ready)
        authority.set(b, generation: 2)
        resume.signal(); await producer.value
        #expect(await disk.snapshot().entries == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty)
    }
    @Test func expiredRestartRecordsAndOversizeObjectsAreRemoved() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let account = try owner(), authority = ArtworkAuthority(); authority.set(account, generation: 1)
        let now = Date()
        let disk = ArtworkDiskStore(root: url, configuration: .default)
        let rec = record(account, key: "expired", png: Data([1, 2, 3]), expiry: now.addingTimeInterval(1))
        await disk.write(rec, now: now, authority: authority, owner: account, generation: 1)
        #expect(await disk.snapshot().entries == 1)
        let restarted = ArtworkDiskStore(root: url, configuration: .default)
        #expect(await restarted.read(key: rec.key, owner: rec.owner, now: now.addingTimeInterval(2)) == nil)
        #expect(await restarted.snapshot().bytes == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty)
        let small = ArtworkDiskStore(root: url, configuration: try ArtworkConfiguration(diskBytes: 65536))
        await small.write(record(account, key: "oversize", png: Data(repeating: 0, count: 65537)), now: now, authority: authority, owner: account, generation: 1)
        #expect(await small.snapshot().bytes == 0)
    }
}

extension ArtworkDiskTests {
    /// Every entry is independently valid: native PNG, exact envelope identity/size/hash,
    /// bounded header, 0600 mode, unique flat filename. The default entry cache may evict
    /// while scanning; it must not fail at that unrelated 4096-entry retention ceiling.
    private func populatedDirectory(count: Int, account: ArtworkOwner) throws -> URL {
        let url = try root()
        do {
            let png = try nativeNoisePNG(width: 32)
            let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == 32 && image.height == 32)
            for i in 0..<count {
                let rec = record(account, key: "startup-\(i)", png: png, width: 32)
                var data = Data("YTMART01".utf8)
                var bits = rec.expires.timeIntervalSince1970.bitPattern.bigEndian
                withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
                data.append(try PropertyListEncoder().encode(rec))
                let path = url.appendingPathComponent("\(rec.owner).\(rec.key).art")
                guard FileManager.default.createFile(atPath: path.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw ArtworkError.storageUnavailable }
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: url.path).count == count)
            return url
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }
    @Test func defaultStartupScanAccepts8192ValidRecordsWithRetentionEviction() async throws {
        let account = try owner(), url = try populatedDirectory(count: 8192, account: account)
        defer { try? FileManager.default.removeItem(at: url) }
        let disk = ArtworkDiskStore(root: url, configuration: .default)
        let absent = await disk.read(key: artworkDigest("absent"), owner: artworkDigest(account.account.accountID.uuidString), now: Date())
        #expect(absent == nil)
        let stats = await disk.snapshot()
        #expect(stats.startupEntriesScanned == 8192); #expect(stats.startupScanLimitFailures == 0)
        #expect(stats.failures == 0); #expect(stats.corruptions == 0)
        #expect(stats.entries == 4096); #expect(stats.evictions == 4096)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
        let name = try #require(names.first), pieces = name.split(separator: ".")
        let retained = try #require(await disk.read(key: String(pieces[1]), owner: String(pieces[0]), now: Date()))
        #expect(retained.width == 32 && retained.height == 32)
        #expect(retained.png.count > 8)
        print("REWORK M12 control scanned=\(stats.startupEntriesScanned) retained=\(stats.entries) evictions=\(stats.evictions) failures=\(stats.failures) corruptions=\(stats.corruptions) validRetainedRead=true")
    }
    @Test func defaultStartupScanRejects8193ValidRecordsAsStorageFailure() async throws {
        let account = try owner(), url = try populatedDirectory(count: 8193, account: account)
        defer { try? FileManager.default.removeItem(at: url) }
        let disk = ArtworkDiskStore(root: url, configuration: .default)
        #expect(await disk.read(key: artworkDigest("absent"), owner: artworkDigest(account.account.accountID.uuidString), now: Date()) == nil)
        let stats = await disk.snapshot()
        #expect(stats.startupEntriesScanned == 8193)
        #expect(stats.startupScanLimitFailures == 1); #expect(stats.failures == 1)
        #expect(stats.corruptions == 0) // Every entry was valid; only startup work admission failed.
        #expect(stats.entries == 4096); #expect(stats.evictions == 4096)
        print("REWORK M12 reject scanned=\(stats.startupEntriesScanned) limitFailures=\(stats.startupScanLimitFailures) failures=\(stats.failures) corruptions=\(stats.corruptions)")
    }
}

extension ArtworkDiskTests {
    @Test(.enabled(if: geteuid() != 0))
    func validButTemporarilyUnreadableFileIsStorageFailureNotCorruption() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let account = try owner(), authority = ArtworkAuthority(); authority.set(account, generation: 1)
        let rec = record(account, key: "unreadable", png: try nativeNoisePNG(width: 32), width: 32)
        let path = url.appendingPathComponent("\(rec.owner).\(rec.key).art")
        let disk = ArtworkDiskStore(root: url, configuration: .default)
        await disk.write(rec, now: Date(), authority: authority, owner: account, generation: 1)
        #expect(await disk.read(key: rec.key, owner: rec.owner, now: Date()) != nil)
        // Fixture-only permission transition. An EACCES open does not prove bad bytes.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path.path)
        #expect(await disk.read(key: rec.key, owner: rec.owner, now: Date()) == nil)
        let failed = await disk.snapshot()
        #expect(failed.failures == 1); #expect(failed.corruptions == 0); #expect(failed.entries == 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        #expect(await disk.read(key: rec.key, owner: rec.owner, now: Date()) != nil)
    }
}
