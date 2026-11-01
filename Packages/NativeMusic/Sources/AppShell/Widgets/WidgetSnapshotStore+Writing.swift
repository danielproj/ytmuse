import Domain
import Foundation
import WidgetShared

// W27 rework 1. The snapshot is written and deleted only here, in the app target, and only through `GuardedFiles` (the widget extension that shares `WidgetSnapshotStore`
// only reads, and does not import Domain).
extension WidgetSnapshotStore {
    /// Atomic: the bytes are staged in the same directory with owner-only permissions and swapped in with `replaceItemAt`, so a reader sees the old file or the
    /// new one, never a half. An inconsistent snapshot is refused before anything is written.
    public func write(_ snapshot: WidgetSnapshot) throws {
        guard snapshot.isConsistent else { throw CocoaError(.fileWriteInvalidFileName) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        guard data.count <= Self.fileByteLimit else { throw CocoaError(.fileWriteOutOfSpace) }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = directory.appendingPathComponent(WidgetIdentity.temporaryPrefix + UUID().uuidString)
        guard fileManager.createFile(atPath: staging.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        do {
            if fileManager.fileExists(atPath: fileURL.path) { _ = try GuardedFiles(root: directory).replace(fileURL, withStaged: staging) }
            else { try GuardedFiles(root: directory).move(staging, to: fileURL) }
        } catch { try? GuardedFiles(root: directory).remove(staging); throw error }
    }

    /// Removes the snapshot and every staging leftover. Idempotent; a missing directory is fine. Never removes the directory itself or anything it did not name.
    public func delete() throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: fileURL.path) { try GuardedFiles(root: directory).remove(fileURL) }
        for name in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasPrefix(WidgetIdentity.temporaryPrefix) {
            try? GuardedFiles(root: directory).remove(directory.appendingPathComponent(name))
        }
    }
}
