import Foundation

/// Tiny lock protects only authority and final cache rename, never decode/read/write.
/// This closes actor reentrancy between a pipeline's generation check and disk publication.
final class ArtworkAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var current: (ArtworkOwner, UInt64)?
    func set(_ owner: ArtworkOwner?, generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        current = owner.map { ($0, generation) }
    }
    func isCurrent(_ owner: ArtworkOwner, generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return current?.0 == owner && current?.1 == generation
    }
    func commitIfCurrent(_ owner: ArtworkOwner, generation: UInt64, commit: () throws -> Void) rethrows -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard current?.0 == owner && current?.1 == generation else { return false }
        try commit(); return true
    }
}
