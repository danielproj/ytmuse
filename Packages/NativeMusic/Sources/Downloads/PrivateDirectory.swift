import Foundation
import Darwin
import Synchronization

final class PrivateIOMetrics: Sendable {
    let counts = Mutex<[String: Int]>([:])
    func add(_ name: String) { counts.withLock { $0[name, default: 0] += 1 } }
    func snapshot() -> [String: Int] { counts.withLock { $0 } }
}

/// All descendants are opened relative to pinned directory descriptors, without following links.
/// Never uses a service string as a filesystem component. Atomic writes fsync before publication.
final class PrivateDirectory: @unchecked Sendable {
    let fd: Int32
    let metrics: PrivateIOMetrics
    init(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        metrics = PrivateIOMetrics()
        fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw OfflineRecovery.redownload }
        do { try validate() } catch { Darwin.close(fd); throw error }
    }
    private init(fd: Int32, metrics: PrivateIOMetrics) throws {
        self.fd = fd; self.metrics = metrics
        do { try validate() } catch { Darwin.close(fd); throw error }
    }
    deinit { Darwin.close(fd) }
    private func validate() throws {
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid(), st.st_mode & 0o077 == 0 else { throw OfflineRecovery.redownload }
    }
    private func name(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw OfflineRecovery.redownload }
    }
    func exists(_ name: String) throws -> Bool {
        try self.name(name)
        var st = stat()
        if fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 {
            guard st.st_mode & S_IFMT != S_IFLNK else { throw OfflineRecovery.redownload }; return true
        }
        guard errno == ENOENT else { throw OfflineRecovery.redownload }; return false
    }
    func directory(_ name: String, create: Bool = false) throws -> PrivateDirectory {
        try self.name(name)
        if create, mkdirat(fd, name, 0o700) != 0, errno != EEXIST { throw ioError() }
        let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw OfflineRecovery.redownload }
        return try PrivateDirectory(fd: child, metrics: metrics)
    }
    func signature(_ name: String, maximum: Int) throws -> Data {
        try self.name(name)
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { throw OfflineRecovery.redownload }; defer { Darwin.close(file) }
        var st = stat()
        guard fstat(file, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1, st.st_uid == getuid(), st.st_mode & 0o077 == 0, st.st_size >= 0, st.st_size <= maximum else { throw OfflineRecovery.redownload }
        return Data("\(name)|\(st.st_dev)|\(st.st_ino)|\(st.st_size)|\(st.st_mtimespec.tv_sec):\(st.st_mtimespec.tv_nsec)|\(st.st_ctimespec.tv_sec):\(st.st_ctimespec.tv_nsec)".utf8)
    }
    func read(_ name: String, maximum: Int) throws -> Data {
        try self.name(name)
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { throw OfflineRecovery.redownload }; defer { Darwin.close(file) }
        var st = stat()
        guard fstat(file, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1, st.st_uid == getuid(), st.st_mode & 0o077 == 0, st.st_size >= 0, st.st_size <= maximum else { throw OfflineRecovery.redownload }
        var result = Data(count: Int(st.st_size))
        let actual = result.withUnsafeMutableBytes { buffer -> Int in
            var total = 0
            while total < buffer.count {
                let n = Darwin.read(file, buffer.baseAddress!.advanced(by: total), buffer.count - total)
                if n <= 0 { return -1 }; total += n
            }
            return total
        }
        guard actual == result.count else { throw OfflineRecovery.redownload }
        return result
    }
    func requireWritable() throws {
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw OfflineRecovery.storageUnavailable }
        guard st.st_mode & S_IWUSR != 0 else { throw OfflineRecovery.storageUnavailable }
    }
    func lockStaging() throws { guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw OfflineRecovery.storageUnavailable } }
    func isStagingBusy() -> Bool {
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { return true }
        flock(fd, LOCK_UN); return false
    }
    func matches(_ name: String, directory: PrivateDirectory) -> Bool {
        var at = stat(); var held = stat()
        return fstatat(fd, name, &at, AT_SYMLINK_NOFOLLOW) == 0 && fstat(directory.fd, &held) == 0 && at.st_dev == held.st_dev && at.st_ino == held.st_ino
    }
    private func sync(_ descriptor: Int32) -> Int32 { metrics.add("fsyncCalls"); return fsync(descriptor) }
    func write(_ bytes: Data, name: String) throws {
        try self.name(name); try requireWritable()
        let temporary = UUID().uuidString + ".write"
        let file = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw ioError() }
        defer { Darwin.close(file); unlinkat(fd, temporary, 0) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                guard n > 0 else { throw ioError() }; offset += n
            }
        }
        guard sync(file) == 0, renameat(fd, temporary, fd, name) == 0, sync(fd) == 0 else { throw ioError() }
        metrics.add("fileWrites"); if name == "index" { metrics.add("indexWrites") }
    }
    func publish(_ staging: String, as name: String) throws {
        try self.name(staging); try self.name(name)
        guard renameatx_np(fd, staging, fd, name, UInt32(RENAME_EXCL)) == 0, sync(fd) == 0 else { throw ioError() }
    }
    func entries() throws -> [String] {
        // dup shares directory offsets; openat(".") provides an independent enumeration cursor.
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard copy >= 0, let stream = fdopendir(copy) else { throw OfflineRecovery.redownload }
        defer { closedir(stream) }
        var result: [String] = []
        while let entry = readdir(stream) {
            let value = withUnsafePointer(to: &entry.pointee.d_name) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) } }
            if value != "." && value != ".." { result.append(value) }
        }
        return result
    }
    func remove(_ name: String) throws {
        try self.name(name)
        var st = stat()
        guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }; throw OfflineRecovery.redownload
        }
        if st.st_mode & S_IFMT == S_IFDIR {
            let child = try directory(name)
            for entry in try child.entries() { try child.remove(entry) }
            guard unlinkat(fd, name, AT_REMOVEDIR) == 0 else { throw ioError() }
        } else {
            // unlinking a malicious link removes only that directory entry, never its target.
            guard unlinkat(fd, name, 0) == 0 else { throw ioError() }
        }
        guard sync(fd) == 0 else { throw ioError() }
    }
    private func ioError() -> OfflineRecovery { errno == ENOSPC ? .storageFull : .storageUnavailable }
}
