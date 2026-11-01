import Foundation
import Domain

extension SQLiteStore {
    public func collectionMetadata(_ id: ServiceID, context: RequestContext) throws -> CatalogMetadata? {
        let key = try scope(context)
        guard let raw = try db.scalar("SELECT metadata FROM collections WHERE scope=? AND id=?", [.text(key), .text(id.rawValue)]).optional else { return nil }
        // Playlist rows and catalog rows have a deliberately separate versioned codec.
        if let playlist = try? decode(PlaylistRecord.self, raw) { return try playlist.metadata.value() }
        return try decode(CatalogRecord.self, raw).value()
    }
    public func savePlaylist(_ playlist: Playlist, context: RequestContext) throws {
        let key = try scope(context)
        try validate(playlist.metadata.id.rawValue)
        try db.execute("INSERT INTO collections VALUES(?,?,?) ON CONFLICT(scope,id) DO UPDATE SET metadata=excluded.metadata", [.text(key), .text(playlist.metadata.id.rawValue), .text(try encode(PlaylistRecord(playlist)))])
    }
    public func playlist(_ id: ServiceID, context: RequestContext) throws -> Playlist? {
        let key = try scope(context)
        guard let raw = try db.scalar("SELECT metadata FROM collections WHERE scope=? AND id=?", [.text(key), .text(id.rawValue)]).optional else { return nil }
        return try decode(PlaylistRecord.self, raw).value()
    }
}
extension CatalogRecord {
    func value() throws -> CatalogMetadata { try CatalogMetadata(id: sid(id), title: title, description: description, artwork: artwork.map(sid), related: related.map(sid)) }
}
struct CapabilityStateRecord: Codable {
    let state: String; var error: ErrorRecord? = nil
    init(_ value: CapabilityState) {
        switch value { case .supported: state = "supported"; case .unknown: state = "unknown"; case .restricted(let e): state = "restricted"; error = ErrorRecord(e); case .temporarilyUnavailable(let e): state = "temporary"; error = ErrorRecord(e); case .failed(let e): state = "failed"; error = ErrorRecord(e) }
    }
    func value() throws -> CapabilityState {
        switch state { case "supported": .supported; case "unknown": .unknown; case "restricted": .restricted(try required(error).value()); case "temporary": .temporarilyUnavailable(try required(error).value()); case "failed": .failed(try required(error).value()); default: throw StorageError.corrupt }
    }
}
struct PlaylistRecord: Codable {
    let metadata: CatalogRecord; let owner: String; let privacy: String; let permissions: [String: CapabilityStateRecord]; let providerVersion: String?; let version: UInt64
    init(_ value: Playlist) {
        metadata = CatalogRecord(value.metadata); owner = value.owner.rawValue; privacy = value.privacy.rawValue
        permissions = Dictionary(uniqueKeysWithValues: value.permissions.map { ($0.key.rawValue, CapabilityStateRecord($0.value)) })
        providerVersion = value.providerVersion; version = value.snapshotVersion
    }
    func value() throws -> Playlist {
        let states = try Dictionary(uniqueKeysWithValues: permissions.map { (try required(Feature(rawValue: $0.key)), try $0.value.value()) })
        return try Playlist(metadata: metadata.value(), owner: sid(owner), privacy: required(PlaylistPrivacy(rawValue: privacy)), permissions: states, providerVersion: providerVersion, snapshotVersion: version)
    }
}
