import Foundation
import Domain

func encode<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let text = String(decoding: try encoder.encode(value), as: UTF8.self)
    try MetadataSafety.validate(text)
    return text
}
func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONDecoder().decode(type, from: Data(text.utf8)) }
func sid(_ value: String) throws -> ServiceID { try ServiceID(value) }
func uuid(_ value: String) throws -> UUID { guard let id = UUID(uuidString: value) else { throw StorageError.corrupt }; return id }
func unsigned(_ value: String) throws -> UInt64 { guard let n = UInt64(value) else { throw StorageError.corrupt }; return n }
func occurrence(_ value: OccurrenceIdentity) -> String {
    switch value { case .provider(let id): "p:" + id.rawValue; case .synthetic(let id): "s:" + id.uuidString }
}
func occurrence(_ value: String) throws -> OccurrenceIdentity {
    if value.hasPrefix("p:") { return .provider(try sid(String(value.dropFirst(2)))) }
    guard value.hasPrefix("s:") else { throw StorageError.corrupt }
    return .synthetic(try uuid(String(value.dropFirst(2))))
}
struct ErrorRecord: Codable {
    let kind: String; var detail: String? = nil; var date: Date? = nil
    init(_ error: DomainError) {
        switch error {
        case .rateLimited(let at): kind = "rateLimited"; date = at
        case .invalidInput(let violation): kind = "invalidInput"; detail = violation.rawValue
        default: kind = String(describing: error)
        }
    }
    func value() throws -> DomainError {
        switch kind {
        case "unauthorized": .unauthorized; case "forbidden": .forbidden; case "unsupported": .unsupported
        case "unavailableContent": .unavailableContent; case "regionRestricted": .regionRestricted
        case "rateLimited": .rateLimited(retryAfter: date); case "offline": .offline; case "malformedResponse": .malformedResponse
        case "expiredMedia": .expiredMedia; case "transientTransport": .transientTransport
        case "staleContext": .staleContext; case "capabilityUnknown": .capabilityUnknown; case "capabilityExpired": .capabilityExpired
        case "reconciliationRequired": .reconciliationRequired
        case "invalidInput": if let detail, let violation = InputViolation(rawValue: detail) { .invalidInput(violation) } else { throw StorageError.corrupt }
        default: throw StorageError.corrupt
        }
    }
}
struct SyncRecord: Codable {
    let state: String; var operation: UUID? = nil; var error: ErrorRecord? = nil
    init(_ sync: SyncState) {
        switch sync { case .localOnly: state = "local"; case .confirmed: state = "confirmed"; case .needsReconciliation: state = "reconcile"
        case .pending(let id): state = "pending"; operation = id
        case .failed(let e): state = "failed"; error = ErrorRecord(e) }
    }
    func value() throws -> SyncState {
        switch state { case "local": .localOnly; case "confirmed": .confirmed; case "reconcile": .needsReconciliation
        case "pending": if let operation { .pending(operation) } else { throw StorageError.corrupt }
        case "failed": if let error { .failed(try error.value()) } else { throw StorageError.corrupt }
        default: throw StorageError.corrupt }
    }
}
struct AvailabilityRecord: Codable {
    let state: String; var error: ErrorRecord? = nil
    init(_ value: Availability) { switch value { case .available: state = "available"; case .unknown: state = "unknown"; case .unavailable(let e): state = "unavailable"; error = ErrorRecord(e) } }
    func value() throws -> Availability {
        switch state { case "available": .available; case "unknown": .unknown; case "unavailable": if let error { .unavailable(try error.value()) } else { throw StorageError.corrupt }; default: throw StorageError.corrupt }
    }
}
struct MediaRecord: Codable {
    let artists: [String]; let duration: Double?; let artwork: [String]; let explicit: Bool?; let availability: AvailabilityRecord
    init(_ item: MediaItem) { artists = item.artists.map(\.rawValue); duration = item.duration; artwork = item.artwork.map(\.rawValue); explicit = item.explicit; availability = AvailabilityRecord(item.availability) }
    func value(id: String, kind: String, title: String) throws -> MediaItem {
        guard let mediaKind = MediaKind(rawValue: kind) else { throw StorageError.corrupt }
        return try MediaItem(id: sid(id), kind: mediaKind, title: title, artists: artists.map(sid), duration: duration, artwork: artwork.map(sid), explicit: explicit, availability: availability.value())
    }
}
struct IntentRecord: Codable {
    var action: String; var flag: Bool? = nil; var title: String? = nil; var description: String? = nil; var privacy: String? = nil
    var items: [String]? = nil; var before: String? = nil; var role: String? = nil
    init(_ value: RemoteMutation) {
        switch value {
        case .library(let action):
            switch action {
            case .save(let v): self.action = "save"; flag = v; case .like(let v): self.action = "like"; flag = v
            case .dislike(let v): self.action = "dislike"; flag = v; case .follow(let v): self.action = "follow"; flag = v
            case .pauseHistory(let v): self.action = "pauseHistory"; flag = v; case .clearHistory: self.action = "clearHistory"
            }
        case .playlist(let action):
            switch action {
            case .create(let t, let p): self.action = "create"; title = t; privacy = p.rawValue
            case .edit(let t, let d, let p): self.action = "edit"; title = t; description = d; privacy = p?.rawValue
            case .delete: self.action = "delete"
            case .add(let list): self.action = "add"; items = list.map(\.rawValue)
            case .remove(let list): self.action = "remove"; items = list.map(occurrence)
            case .move(let list, let next): self.action = "move"; items = list.map(occurrence); before = next.map(occurrence)
            case .join(let invitation): self.action = "join"; items = [invitation.rawValue]
            case .leave: self.action = "leave"
            case .invite(let r): self.action = "invite"; role = r
            }
        }
    }
    func value() throws -> RemoteMutation {
        switch action {
        case "save": return .library(.save(try required(flag))); case "like": return .library(.like(try required(flag)))
        case "dislike": return .library(.dislike(try required(flag))); case "follow": return .library(.follow(try required(flag)))
        case "pauseHistory": return .library(.pauseHistory(try required(flag))); case "clearHistory": return .library(.clearHistory)
        case "create": return .playlist(.create(title: try required(title), privacy: try required(privacy.flatMap(PlaylistPrivacy.init))))
        case "edit": return .playlist(.edit(title: title, description: description, privacy: privacy.flatMap(PlaylistPrivacy.init)))
        case "delete": return .playlist(.delete)
        case "add": return .playlist(.add(try required(items).map(sid)))
        case "remove": return .playlist(.remove(try required(items).map(occurrence)))
        case "move": return .playlist(.move(occurrences: try required(items).map(occurrence), before: try before.map(occurrence)))
        case "join": return .playlist(.join(invitation: try sid(required(items?.first))))
        case "leave": return .playlist(.leave)
        case "invite": return .playlist(.invite(role: try required(role)))
        default: throw StorageError.corrupt
        }
    }
}
func required<T>(_ value: T?) throws -> T { guard let value else { throw StorageError.corrupt }; return value }
struct PreferenceRecord: Codable {
    let kind: String; var bool: Bool? = nil; var integer: Int? = nil; var number: Double? = nil; var text: String? = nil
    init(_ value: PreferenceValue) {
        switch value { case .boolean(let b): kind = "bool"; bool = b; case .integer(let i): kind = "int"; integer = i; case .number(let n): kind = "number"; number = n; case .text(let t): kind = "text"; text = t }
    }
    func value() throws -> PreferenceValue {
        switch kind { case "bool": .boolean(try required(bool)); case "int": .integer(try required(integer)); case "number": .number(try required(number)); case "text": .text(try required(text)); default: throw StorageError.corrupt }
    }
}
