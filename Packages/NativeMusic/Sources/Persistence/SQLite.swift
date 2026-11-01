import Foundation
import SQLite3
import Darwin

/// Error descriptions deliberately contain neither SQL, bound values nor filesystem paths.
public enum StorageError: String, Error, Sendable { case sqlite, corrupt, unsupportedVersion, insufficientSpace, permissions, invalidInput, conflict, closed }

enum SQLValue { case text(String), integer(Int64), real(Double), null
    var string: String { if case .text(let s) = self { return s }; return "" }
    var int: Int64 { if case .integer(let n) = self { return n }; return 0 }
    var double: Double { switch self { case .real(let n): n; case .integer(let n): Double(n); default: 0 } }
    var optional: String? { if case .null = self { return nil }; return string }
}

final class SQLite {
    private(set) var handle: OpaquePointer?
    let url: URL
    init(_ url: URL, readOnly: Bool = false) throws {
        guard let canonical = realpath(url.deletingLastPathComponent().path, nil) else { throw StorageError.permissions }
        defer { free(canonical) }
        self.url = URL(fileURLWithPath: String(cString: canonical) + "/" + url.lastPathComponent)
        if !readOnly { try Self.privateFile(url) }
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(self.url.path, &handle, flags | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else { close(); throw StorageError.sqlite }
        sqlite3_busy_timeout(handle, 5000)
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA trusted_schema=OFF")
    }
    deinit { close() }
    func close() { if let handle { sqlite3_close_v2(handle); self.handle = nil } }
    static func privateDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let attr = try fm.attributesOfItem(atPath: url.path)
        guard attr[.type] as? FileAttributeType == .typeDirectory, attr[.ownerAccountID] as? UInt32 == getuid(), chmod(url.path, 0o700) == 0 else { throw StorageError.permissions }
    }
    static func privateFile(_ url: URL) throws {
        let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw StorageError.permissions }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, fchmod(fd, 0o600) == 0 else { throw StorageError.permissions }
    }
    func protectSidecars() throws {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let path = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: path.path) { try Self.privateFile(path) }
        }
    }
    @discardableResult func execute(_ sql: String, _ values: [SQLValue] = []) throws -> Int {
        var count = 0
        try rows(sql, values) { _ in count += 1 }
        return Int(sqlite3_changes(handle))
    }
    func rows(_ sql: String, _ values: [SQLValue] = [], _ receive: ([SQLValue]) throws -> Void) throws {
        guard let handle else { throw StorageError.closed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw StorageError.sqlite }
        defer { sqlite3_finalize(statement) }
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            let code: Int32
            switch value {
            case .text(let text): code = text.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            case .integer(let number): code = sqlite3_bind_int64(statement, index, number)
            case .real(let number): code = sqlite3_bind_double(statement, index, number)
            case .null: code = sqlite3_bind_null(statement, index)
            }
            guard code == SQLITE_OK else { throw StorageError.sqlite }
        }
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw StorageError.sqlite }
            let row = (0..<sqlite3_column_count(statement)).map { col -> SQLValue in
                switch sqlite3_column_type(statement, col) {
                case SQLITE_INTEGER: .integer(sqlite3_column_int64(statement, col))
                case SQLITE_FLOAT: .real(sqlite3_column_double(statement, col))
                case SQLITE_TEXT: .text(String(cString: sqlite3_column_text(statement, col)))
                default: .null
                }
            }
            try receive(row)
        }
    }
    func all(_ sql: String, _ values: [SQLValue] = []) throws -> [[SQLValue]] {
        var result: [[SQLValue]] = []; try rows(sql, values) { result.append($0) }; return result
    }
    func scalar(_ sql: String, _ values: [SQLValue] = []) throws -> SQLValue { try all(sql, values).first?.first ?? .null }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let value = try body(); try execute("COMMIT"); try protectSidecars(); return value }
        catch { try? execute("ROLLBACK"); throw error }
    }
    func integrity() throws {
        guard try scalar("PRAGMA integrity_check").string == "ok", try all("PRAGMA foreign_key_check").isEmpty else { throw StorageError.corrupt }
    }
    func checkFreeSpace(availableBytes: Int64? = nil) throws {
        // page_count includes the committed WAL view; file size alone undercounts a busy WAL.
        let pages = try scalar("PRAGMA page_count").int
        let pageSize = try scalar("PRAGMA page_size").int
        let (size, overflow) = pages.multipliedReportingOverflow(by: pageSize)
        let (required, reserveOverflow) = size.multipliedReportingOverflow(by: 3)
        guard !overflow, !reserveOverflow, size >= 0 else { throw StorageError.insufficientSpace }
        let free = try availableBytes ?? (FileManager.default.attributesOfFileSystem(forPath: url.deletingLastPathComponent().path)[.systemFreeSize] as? Int64 ?? 0)
        guard free > max(16 * 1024 * 1024, required) else { throw StorageError.insufficientSpace }
    }
    func backup(to destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw StorageError.conflict }
        try checkFreeSpace()
        let output = try SQLite(destination)
        guard let backup = sqlite3_backup_init(output.handle, "main", handle, "main") else { throw StorageError.sqlite }
        let code = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard code == SQLITE_DONE, finished == SQLITE_OK else { throw StorageError.sqlite }
        try output.integrity()
        // Backups are self-contained files, with no private history in a retained WAL.
        guard try output.scalar("PRAGMA journal_mode=DELETE").string == "delete" else { throw StorageError.sqlite }
        try output.protectSidecars()
    }
}

/// Defense in depth for fields that are metadata, never an authorization transport.
/// Opaque secrets cannot be recognized by content: callers must use the reference-only API.
enum MetadataSafety {
    static func validate(_ text: String) throws {
        guard text.utf8.count <= 65_536, !text.contains("\0") else { throw StorageError.invalidInput }
        let lowered = text.lowercased()
        let forbidden = ["bearer ", "authorization:", "cookie:", "set-cookie:", "access_token=", "refresh_token=", "signature=", "sig=", "x-goog-signature=", "sapisidhash "]
        guard !forbidden.contains(where: lowered.contains) else { throw StorageError.invalidInput }
        if let url = URL(string: text), url.scheme != nil {
            guard url.user == nil, url.password == nil, url.query == nil else { throw StorageError.invalidInput }
        }
    }
}
