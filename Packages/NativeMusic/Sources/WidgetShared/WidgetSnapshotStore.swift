import Foundation

// W25 (MAC06, ARCH09). The one file in the App Group. The directory is INJECTED: the app target passes the group container in a normal launch, and the
// isolation layer passes a temporary directory under every automated launch and every test. No code in a package target or a test target names the real
// container (`WidgetGroupGuardTests` sweeps for it); `refusesRealContainer` is the fatal check the composition applies before a store is built.

public enum WidgetReadResult: Equatable, Sendable {
    case snapshot(WidgetSnapshot)
    /// No file: never written, or deleted at sign-out / account removal.
    case missing
    /// A file that is not this schema: unreadable, too large, unknown keys, inconsistent. Treated as unknown by the widget (redacted view).
    case unreadable
}

public struct WidgetSnapshotStore: Sendable {
    /// A snapshot file larger than this is refused unread.
    public static let fileByteLimit = 96 * 1024
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public var fileURL: URL { directory.appendingPathComponent(WidgetIdentity.snapshotFileName) }

    /// True for any path inside the account holder's real `~/Library/Group Containers` (or its resolved form). The composition makes this fatal for an
    /// isolated or test process; nothing else may construct a store on such a path outside a normal launch.
    public static func refusesRealContainer(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let real = home.appendingPathComponent("Library/Group Containers", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
        let candidate = url.resolvingSymlinksInPath().standardizedFileURL.path
        return candidate == real || candidate.hasPrefix(real + "/")
    }

    // Writing and deleting live in the APP target (`WidgetSnapshotStore+Writing.swift`, through `GuardedFiles`): this file is shared with the widget extension, which only reads.

    public func read() -> WidgetReadResult {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return .missing }
        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path), let size = attributes[.size] as? Int, size <= Self.fileByteLimit,
              let data = try? Data(contentsOf: fileURL) else { return .unreadable }
        return Self.decode(data)
    }
    /// The reader's whole decision, on bytes: the top-level keys must all be in the schema, the decode must succeed and the content must agree with the state.
    public static func decode(_ data: Data) -> WidgetReadResult {
        guard data.count <= fileByteLimit, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys).isSubset(of: WidgetSnapshot.allowedKeys) else { return .unreadable }
        // The same rule one level down: an extra key inside `scope` or `capabilities` is refused too, not silently dropped by the decoder.
        if let scope = object["scope"] { guard let nested = scope as? [String: Any], Set(nested.keys).isSubset(of: WidgetScope.allowedKeys) else { return .unreadable } }
        if let capabilities = object["capabilities"] { guard let nested = capabilities as? [String: Any], Set(nested.keys).isSubset(of: WidgetCapabilities.allowedKeys) else { return .unreadable } }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data), snapshot.isConsistent else { return .unreadable }
        return .snapshot(snapshot)
    }

    /// The names in the directory (for the App Group inspection, T25.4).
    public func listing() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted() }
}
