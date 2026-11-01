import Foundation
import CryptoKit
import Darwin

func artworkDigest(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
func artworkDigest(_ value: String) -> String { artworkDigest(Data(value.utf8)) }
struct ArtworkDiskRecord: Codable, Sendable {
    let publication: UUID
    let key: String
    let owner: String
    let expires: Date
    let width: Int
    let height: Int
    let palette: ArtworkPalette
    let pngHash: String
    let png: Data
}
public struct ArtworkDiskCounters: Sendable {
    public internal(set) var bytes = 0, peakBytes = 0, entries = 0, evictions = 0, corruptions = 0, failures = 0
    public internal(set) var mainThreadWorkViolations = 0
    public internal(set) var startupEntriesScanned = 0, startupScanLimitFailures = 0
}
/// No UI/main actor calls perform filesystem operations. Private flat, hashed filenames;
/// bounded open/read with O_NOFOLLOW protects against symlinks and oversized persisted input.
actor ArtworkDiskStore {
    private struct Entry { let size: Int; let cost: Int; let expires: Date; var used: Date; var publication: UUID? = nil }
    private let root: URL
    private let configuration: ArtworkConfiguration
    private var index: [String: Entry] = [:]
    private var ready = false
    private var directoryFD: Int32 = -1
    private var counters = ArtworkDiskCounters()
    init(root: URL, configuration: ArtworkConfiguration) { self.root = root.standardizedFileURL; self.configuration = configuration }
    deinit { if directoryFD >= 0 { close(directoryFD) } }
    func snapshot() -> ArtworkDiskCounters { counters }
    private func prepare(now: Date = Date()) throws {
        if Thread.isMainThread { counters.mainThreadWorkViolations += 1 }
        if ready { try purgeExpired(now: now); return }
        guard root.isFileURL, root.path == root.resolvingSymlinksInPath().path else { throw ArtworkError.storageUnavailable }
        index.removeAll(); counters.bytes = 0; counters.entries = 0
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if directoryFD >= 0 { close(directoryFD); directoryFD = -1 }
        directoryFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryFD >= 0, fchmod(directoryFD, 0o700) == 0 else { throw ArtworkError.storageUnavailable }
        guard let directory = fdopendir(dup(directoryFD)) else { throw ArtworkError.storageUnavailable }
        defer { closedir(directory) }
        var scanned = 0
        while let item = readdir(directory) {
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            scanned += 1
            counters.startupEntriesScanned += 1
            guard scanned <= configuration.maximumEntries * 2 else {
                counters.startupScanLimitFailures += 1
                throw ArtworkError.storageUnavailable
            }
            var info = stat()
            guard fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw ArtworkError.storageUnavailable }
            let regular = info.st_mode & S_IFMT == S_IFREG
            if validName(name), regular, info.st_nlink == 1, info.st_size > 0, info.st_size <= recordLimit {
                let size = Int(info.st_size), cost = max(Int(info.st_size), Int(info.st_blocks) * 512)
                let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard fd >= 0 else { throw ArtworkError.storageUnavailable }
                var header = Data(count: 16)
                let readCount = header.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, 16) }
                close(fd)
                guard readCount == 16, let expires = headerExpiry(header) else {
                    guard unlinkat(directoryFD, name, 0) == 0 else { throw ArtworkError.storageUnavailable }
                    counters.corruptions += 1; continue
                }
                if expires <= now {
                    guard unlinkat(directoryFD, name, 0) == 0 else { throw ArtworkError.storageUnavailable }
                    counters.evictions += 1; continue
                }
                index[name] = Entry(size: size, cost: cost, expires: expires, used: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)))
                counters.bytes += cost
                try trim(adding: 0)
            } else {
                guard regular || info.st_mode & S_IFMT == S_IFLNK, unlinkat(directoryFD, name, 0) == 0 else { throw ArtworkError.storageUnavailable }
                counters.corruptions += 1
            }
        }
        ready = true
        try trim(adding: 0)
        counters.entries = index.count; counters.peakBytes = counters.bytes
    }
    private func headerExpiry(_ data: Data) -> Date? {
        guard data.count >= 16, data.prefix(8) == Data("YTMART01".utf8) else { return nil }
        let bits = data.dropFirst(8).prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let seconds = Double(bitPattern: bits)
        return seconds.isFinite ? Date(timeIntervalSince1970: seconds) : nil
    }
    private func purgeExpired(now: Date) throws {
        for name in Array(index.keys) where index[name]!.expires <= now { try erase(name); counters.evictions += 1 }
    }
    func purge(now: Date) throws { try prepare(now: now) }
    private var recordLimit: Int { configuration.maximumInputBytes + 65536 }
    private func validName(_ name: String) -> Bool {
        let pieces = name.split(separator: ".")
        return pieces.count == 3 && pieces[2] == "art" && pieces.prefix(2).allSatisfy { $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } }
    }
    private func erase(_ name: String) throws {
        guard unlinkat(directoryFD, name, 0) == 0 || errno == ENOENT else { throw ArtworkError.storageUnavailable }
        if let entry = index.removeValue(forKey: name) { counters.bytes -= entry.cost }
        counters.entries = index.count
    }
    private func trim(adding: Int) throws {
        while counters.bytes + adding > configuration.diskBytes || index.count >= configuration.maximumEntries && adding > 0 || index.count > configuration.maximumEntries {
            guard let oldest = index.min(by: { $0.value.used < $1.value.used })?.key else { break }
            try erase(oldest); counters.evictions += 1
        }
    }
    func read(key: String, owner: String, now: Date) -> ArtworkDiskRecord? {
        // An unusable directory or scan/cleanup failure says nothing about an entry.
        do { try prepare(now: now) }
        catch { counters.failures += 1; return nil }
        let name = "\(owner).\(key).art"
        guard let entry = index[name] else { return nil }
        do {
            let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw ArtworkError.storageUnavailable }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw ArtworkError.storageUnavailable }
            guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
                  info.st_size == entry.size, info.st_size <= recordLimit,
                  info.st_mode & 0o077 == 0 else { throw ArtworkError.invalidImage }
            var data = Data(count: entry.size + 1)
            let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            guard count >= 0 else { throw ArtworkError.storageUnavailable }
            guard count == entry.size else { throw ArtworkError.invalidImage }
            data.count = count
            guard let expires = headerExpiry(data), expires > now else { throw ArtworkError.invalidImage }
            let record = try PropertyListDecoder().decode(ArtworkDiskRecord.self, from: data.dropFirst(16))
            guard record.key == key, record.owner == owner, record.expires == expires, record.expires.timeIntervalSince1970.isFinite,
                  record.expires > now, record.width > 0, record.height > 0, record.width <= 2048, record.height <= 2048,
                  record.png.count <= configuration.maximumInputBytes, record.png.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]), record.pngHash == artworkDigest(record.png),
                  [record.palette.red, record.palette.green, record.palette.blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  record.palette.opacity == 0.22 else { throw ArtworkError.invalidImage }
            index[name]?.used = now
            index[name]?.publication = record.publication
            return record
        } catch ArtworkError.storageUnavailable {
            // Failed open/stat/read is not proof of malformed persisted bytes. Preserve
            // the entry for a later read; caller may use the approved source meanwhile.
            counters.failures += 1
            return nil
        } catch {
            counters.corruptions += 1
            if index[name] != nil { try? erase(name) }
            counters.failures += 1
            return nil
        }
    }
    func write(_ record: ArtworkDiskRecord, now: Date, authority: ArtworkAuthority, owner: ArtworkOwner, generation: UInt64, beforeCommit: (@Sendable () -> Void)? = nil) {
        do {
            guard authority.isCurrent(owner, generation: generation) else { return }
            try prepare(now: now)
            guard record.owner == artworkDigest(owner.account.accountID.uuidString), record.expires.timeIntervalSince1970.isFinite, record.expires > now, record.png.count <= configuration.maximumInputBytes else { return }
            var data = Data("YTMART01".utf8)
            var bits = record.expires.timeIntervalSince1970.bitPattern.bigEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
            data.append(try PropertyListEncoder().encode(record))
            guard data.count <= recordLimit, data.count <= configuration.diskBytes else { return }
            let name = "\(record.owner).\(record.key).art"
            guard validName(name) else { throw ArtworkError.storageUnavailable }
            guard authority.isCurrent(owner, generation: generation) else { return }
            if index[name] != nil { try erase(name) }
            // Reserve a conservative allocation quantum before materializing a staging file.
            // Final accounting charges allocated blocks as well as logical bytes (no sparse-file oracle).
            let reserved = (data.count + 65535) / 65536 * 65536
            guard reserved <= configuration.diskBytes else { return }
            try trim(adding: reserved)
            // Exclusive mode 0600 file followed by atomic rename within the private directory.
            let temporary = UUID().uuidString + ".tmp"
            let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw ArtworkError.storageUnavailable }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { unlinkat(directoryFD, temporary, 0) }
            var info = stat()
            do {
                try handle.write(contentsOf: data)
                guard fstat(fd, &info) == 0 else { throw ArtworkError.storageUnavailable }
                try handle.close()
            } catch { throw error }
            let cost = max(data.count, Int(info.st_blocks) * 512)
            guard cost <= reserved else { throw ArtworkError.storageUnavailable }
            beforeCommit?()
            guard !Task.isCancelled else { return }
            counters.peakBytes = max(counters.peakBytes, counters.bytes + cost)
            let committed = try authority.commitIfCurrent(owner, generation: generation) {
                guard renameat(directoryFD, temporary, directoryFD, name) == 0 else { throw ArtworkError.storageUnavailable }
                index[name] = Entry(size: data.count, cost: cost, expires: record.expires, used: now, publication: record.publication); counters.bytes += cost
                counters.entries = index.count; counters.peakBytes = max(counters.peakBytes, counters.bytes)
            }
            if !committed { unlinkat(directoryFD, temporary, 0) }
        } catch { counters.failures += 1 }
    }
    func remove(key: String, owner: String, publication: UUID? = nil) {
        do { try prepare(); let name = "\(owner).\(key).art"; if let entry = index[name], publication == nil || entry.publication == publication { try erase(name) } } catch { counters.failures += 1 }
    }
    func remove(owner: String) throws {
        try prepare()
        for name in Array(index.keys) where name.hasPrefix(owner + ".") { try erase(name) }
    }
    /// W27: bytes this owner's cached files occupy on disk (the same cost the store's own counters use).
    func bytes(owner: String) throws -> Int {
        try prepare()
        return index.filter { $0.key.hasPrefix(owner + ".") }.reduce(0) { $0 + $1.value.cost }
    }
    func clear() throws {
        try prepare()
        for name in Array(index.keys) { try erase(name) }
    }
}
