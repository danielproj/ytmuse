import Foundation
import CryptoKit
import Domain
import Darwin

/// OFF02: one persistent record per logical download. The record is the only truth the scheduler resumes from.
struct JobRecord: Codable, Equatable, Sendable {
    var id: UUID
    var media: String
    var title: String
    var subtitle: String?
    var origin: MediaOrigin
    /// Source-private hint (a file path for a local file). Never a credential.
    var location: String?
    /// Bound on first resolve. Bytes of a different variant are never added to this job's staging file.
    var variant: String?
    var validator: String?
    var length: Int64?
    var supportsRanges: Bool = false
    var expectedSHA256: String?
    var completed = RangeSet()
    var phase: DownloadPhase = .queued
    var pause: DownloadPauseCause?
    var failure: DownloadFailure?
    /// Consecutive failures without progress (OFF13).
    var attempts = 0
    var corruptRestarts = 0
    var nextAttemptAt: Date?
    /// Collection references ("collection:<id>"), the manual pin ("manual") and the automatic marker ("smart").
    var references: Set<String> = []
    var pinned = false
    var automatic = false
    var sequence: UInt64 = 0
    var overrideNetwork = false
    var stagingName: String?
    /// Device:inode of the staging file the ranges were written into. Ranges are valid only for that exact file.
    var stagingIdentity: String?
    /// UTType identifier of the kept file (for the native player's loader).
    var contentType: String?
    var grantValidatedAt: Date?
    var grantExpires: Date?
    var renewAfter: Date?
    var grantIssuer: String?
    var grantRights: Set<String> = []
    var storedBytes: Int64 = 0
    var createdAt: Date
    var contentSHA256: String?
}
struct CollectionRecord: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var members: [String]
    /// Members the person removed by hand; they stay out until they leave the playlist and rejoin.
    var excluded: [String] = []
}
struct LedgerSettings: Codable, Equatable, Sendable {
    var budget: Int64 = DownloadPolicy.defaultBudget
    var smartDownloads = false
    /// W27: allow AUTOMATIC jobs on an expensive (not constrained) path. Absent in a ledger written before it existed, which reads as the default, off.
    var automaticOnExpensive: Bool? = nil
}
struct LedgerFile: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version = LedgerFile.currentVersion
    var account: String
    var sequence: UInt64 = 0
    var jobs: [JobRecord] = []
    var collections: [CollectionRecord] = []
}
struct UsageSummary: Codable, Equatable, Sendable {
    var storedBytes: Int64 = 0
    var protectedBytes: Int64 = 0
    var automaticBytes: Int64 = 0
    /// Retained bytes whose job record was lost (a damaged ledger was set aside). They keep counting toward the limit.
    var unlistedBytes: Int64 = 0
}

public enum LedgerStage: Sendable { case beforeWrite, afterWrite }

/// Durable, atomic, fsynced job ledger. One file per account under a root private to the app; a root-level settings
/// file and a small usage summary per account let the 20 GiB budget span accounts without opening any account's ledger.
final class DownloadLedgerRoot: @unchecked Sendable {
    static let ledgerName = "ledger.json", usageName = "usage.json", settingsName = "settings.json", stagingDirectory = "staging"
    let rootURL: URL
    let root: PrivateDirectory
    /// Test seam: observes (and may abort) each durable write, to model a crash at every persisted state.
    var fault: (@Sendable (LedgerStage) throws -> Void)?
    init(root url: URL) throws {
        rootURL = url
        root = try PrivateDirectory(root: url)
    }
    static func directoryName(_ account: AccountContext) -> String {
        let framed = account.accountID.uuidString + ":\(account.channelID.rawValue.utf8.count):" + account.channelID.rawValue + ":" + account.region
        return SHA256.hash(data: Data(framed.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func accountDirectory(_ account: AccountContext, create: Bool) throws -> PrivateDirectory {
        try root.directory(Self.directoryName(account), create: create)
    }
    func accountURL(_ account: AccountContext) -> URL { rootURL.appendingPathComponent(Self.directoryName(account), isDirectory: true) }

    func load(_ account: AccountContext) throws -> LedgerFile {
        let key = Self.directoryName(account)
        guard try root.exists(key) else { return LedgerFile(account: key) }
        let directory = try root.directory(key)
        guard try directory.exists(Self.ledgerName) else { return LedgerFile(account: key) }
        let data = try directory.read(Self.ledgerName, maximum: 64 << 20)
        guard let file = try? JSONDecoder.ledger.decode(LedgerFile.self, from: data) else { throw LedgerError.corrupt }
        guard file.version <= LedgerFile.currentVersion else { throw LedgerError.unsupportedVersion }
        // The ledger names its own account: a copied or misplaced file is never adopted for another account.
        guard file.account == key else { throw LedgerError.wrongAccount }
        return file
    }
    func save(_ file: LedgerFile, account: AccountContext, usage: UsageSummary) throws {
        guard file.account == Self.directoryName(account) else { throw LedgerError.wrongAccount }
        try fault?(.beforeWrite)
        let directory = try accountDirectory(account, create: true)
        try directory.write(try JSONEncoder.ledger.encode(file), name: Self.ledgerName)
        try directory.write(try JSONEncoder.ledger.encode(usage), name: Self.usageName)
        try fault?(.afterWrite)
    }
    /// A damaged ledger is set aside, not deleted, and the account starts clean; the retained objects stay in the store.
    @discardableResult
    func quarantine(_ account: AccountContext) throws -> UsageSummary {
        let directory = try accountDirectory(account, create: true)
        var previous = UsageSummary()
        if (try? directory.exists(Self.usageName)) == true, let data = try? directory.read(Self.usageName, maximum: 1 << 16), let usage = try? JSONDecoder.ledger.decode(UsageSummary.self, from: data) { previous = usage }
        if try directory.exists(Self.ledgerName) {
            let data = try directory.read(Self.ledgerName, maximum: 64 << 20)
            try directory.write(data, name: "ledger.damaged-\(Int(Date().timeIntervalSince1970)).json")
            try directory.remove(Self.ledgerName)
        }
        // What the lost ledger accounted for is still on disk: carry it forward as unlisted instead of forgetting it.
        previous.unlistedBytes += previous.storedBytes; previous.storedBytes = 0; previous.protectedBytes = 0; previous.automaticBytes = 0
        return previous
    }
    func removeStagingDirectory(_ account: AccountContext) throws {
        if let directory = try? accountDirectory(account, create: false), try directory.exists(Self.stagingDirectory) { try directory.remove(Self.stagingDirectory) }
    }
    func loadUsage(_ account: AccountContext) -> UsageSummary {
        guard let directory = try? accountDirectory(account, create: false), (try? directory.exists(Self.usageName)) == true,
              let data = try? directory.read(Self.usageName, maximum: 1 << 16), let usage = try? JSONDecoder.ledger.decode(UsageSummary.self, from: data) else { return UsageSummary() }
        return usage
    }
    func removeAccount(_ account: AccountContext) throws {
        let key = Self.directoryName(account)
        if try root.exists(key) { try root.remove(key) }
    }
    func loadSettings() throws -> LedgerSettings {
        guard try root.exists(Self.settingsName) else { return LedgerSettings() }
        guard let value = try? JSONDecoder.ledger.decode(LedgerSettings.self, from: try root.read(Self.settingsName, maximum: 1 << 16)), value.budget > 0 else { throw LedgerError.corrupt }
        return value
    }
    func saveSettings(_ settings: LedgerSettings) throws { try root.write(try JSONEncoder.ledger.encode(settings), name: Self.settingsName) }
    /// Retained bytes across every account directory (OFF03). A missing or unreadable summary counts as zero for that
    /// account only when its directory has no ledger; an unreadable existing summary is rebuilt by the owner on next save.
    func usageAcrossAccounts() -> UsageSummary {
        var total = UsageSummary()
        guard let names = try? root.entries() else { return total }
        for name in names where name != Self.settingsName {
            guard let directory = try? root.directory(name), (try? directory.exists(Self.usageName)) == true,
                  let data = try? directory.read(Self.usageName, maximum: 1 << 16), let usage = try? JSONDecoder.ledger.decode(UsageSummary.self, from: data) else { continue }
            total.storedBytes += usage.storedBytes + usage.unlistedBytes; total.protectedBytes += usage.protectedBytes + usage.unlistedBytes; total.automaticBytes += usage.automaticBytes; total.unlistedBytes += usage.unlistedBytes
        }
        return total
    }
    /// W27: the same sum, over the account directories whose names are NOT in `listed` (a directory no roster entry owns). Enumerated, not subtracted.
    func usageOutside(_ listed: Set<String>) -> UsageSummary {
        var total = UsageSummary()
        guard let names = try? root.entries() else { return total }
        for name in names where name != Self.settingsName && !listed.contains(name) {
            guard let directory = try? root.directory(name), (try? directory.exists(Self.usageName)) == true,
                  let data = try? directory.read(Self.usageName, maximum: 1 << 16), let usage = try? JSONDecoder.ledger.decode(UsageSummary.self, from: data) else { continue }
            total.storedBytes += usage.storedBytes + usage.unlistedBytes; total.protectedBytes += usage.protectedBytes + usage.unlistedBytes; total.automaticBytes += usage.automaticBytes; total.unlistedBytes += usage.unlistedBytes
        }
        return total
    }
    /// Staging files for one account. Names are random tokens, never source strings.
    func staging(_ account: AccountContext, create: Bool) throws -> PrivateDirectory {
        try accountDirectory(account, create: create).directory(Self.stagingDirectory, create: create)
    }
}
extension JSONEncoder {
    static var ledger: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; e.outputFormatting = [.sortedKeys]; return e }
}
extension JSONDecoder {
    static var ledger: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }
}

/// Random-access writes into a staging file held open by descriptor. Data is fsynced before any range is recorded.
final class StagingFile: @unchecked Sendable {
    let fd: Int32
    let url: URL
    init(directory: PrivateDirectory, directoryURL: URL, name: String) throws {
        guard !name.contains("/"), !name.isEmpty else { throw OfflineRecovery.storageUnavailable }
        let descriptor = openat(directory.fd, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw errno == ENOSPC ? OfflineRecovery.storageFull : OfflineRecovery.storageUnavailable }
        var st = stat()
        guard fstat(descriptor, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1, st.st_uid == getuid() else { Darwin.close(descriptor); throw OfflineRecovery.storageUnavailable }
        fd = descriptor; url = directoryURL.appendingPathComponent(name)
    }
    deinit { Darwin.close(fd) }
    var identity: String { var st = stat(); return fstat(fd, &st) == 0 ? "\(st.st_dev):\(st.st_ino)" : "" }
    var size: Int64 { var st = stat(); return fstat(fd, &st) == 0 ? Int64(st.st_size) : 0 }
    func write(_ data: Data, at offset: Int64) throws {
        var written = 0
        try data.withUnsafeBytes { buffer in
            while written < buffer.count {
                let n = pwrite(fd, buffer.baseAddress!.advanced(by: written), buffer.count - written, off_t(offset) + off_t(written))
                guard n > 0 else { throw errno == ENOSPC ? OfflineRecovery.storageFull : OfflineRecovery.storageUnavailable }
                written += n
            }
        }
    }
    func sync() throws { guard fsync(fd) == 0 else { throw errno == ENOSPC ? OfflineRecovery.storageFull : OfflineRecovery.storageUnavailable } }
    func truncate(to length: Int64) throws { guard ftruncate(fd, off_t(length)) == 0 else { throw OfflineRecovery.storageUnavailable } }
    /// SHA-256 of the first `length` bytes, in bounded reads.
    func digest(length: Int64) throws -> String {
        var hasher = SHA256(); var offset: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while offset < length {
            let want = Int(min(Int64(buffer.count), length - offset))
            let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, want, off_t(offset)) }
            guard n > 0 else { throw OfflineRecovery.redownload }
            hasher.update(data: Data(buffer[0..<n])); offset += Int64(n)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
