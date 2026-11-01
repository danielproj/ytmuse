import CoreSpotlight
import Domain
import Foundation
import SystemIntegration
import UniformTypeIdentifiers

// W25 (MAC05). The ONLY file in the repository that names CoreSpotlight or the system's searchable index. It writes to the account holder's real Spotlight index,
// so no package target, test target or probe may reach it: they all use `InMemorySearchableIndex` (`SpotlightGuardTests` sweeps every source and test for the
// system index). `NativeMusicApp` builds this for a normal launch only; an isolated launch is given the in-memory index by the shell whatever is passed here.
// Everything it indexes is decided before it is called (`SpotlightPolicy`, `SpotlightIndexer`): opt-in, public saved items and app actions, and private entities
// only with the second opt-in. It adds no thumbnail and no URL, only a title, a line and the identifier.

struct SystemSearchableIndex: SearchableIndexBackend {
    func index(_ entries: [SpotlightEntry], domain: String) async throws {
        let items = entries.map { entry -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: entry.kind == .action ? .content : .audio)
            attributes.title = entry.title
            attributes.contentDescription = entry.subtitle
            let item = CSSearchableItem(uniqueIdentifier: entry.uniqueID, domainIdentifier: domain, attributeSet: attributes)
            item.expirationDate = .distantFuture
            return item
        }
        for batch in stride(from: 0, to: items.count, by: 200) { try await Self.systemIndex().indexSearchableItems(Array(items[batch..<min(batch + 200, items.count)])) }
    }
    /// The ONLY place the system's index is named. An isolated process (every test, every QA launch) can never reach it: the call is refused here, at the call.
    private static func systemIndex() throws -> CSSearchableIndex {
        guard !ProcessIsolation.isIsolated else { throw GuardRefusal.realRoot("Spotlight index") }
        return CSSearchableIndex.default()
    }
    func delete(uniqueIDs: [String]) async throws { try await Self.systemIndex().deleteSearchableItems(withIdentifiers: uniqueIDs) }
    func delete(domains: [String]) async throws { try await Self.systemIndex().deleteSearchableItems(withDomainIdentifiers: domains) }
}
