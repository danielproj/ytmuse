import AccountSession
import Foundation

/// W09-F2 rework 2: which rows a catalog page has, and in which order. ONE function for what the page registers with its `IdentityRestorer`
/// and what `ShelfView` draws, so the recorded "first row on screen" is the first row the person sees (a podcast show draws its episodes in the
/// order the person chose, not the service's).
enum CatalogRows {
    /// Rows that stand one under another: a vertical list shelf. Carousels, grids, categories and the Quick-picks columns scroll sideways.
    static func isVerticalList(_ shelf: MusicShelf) -> Bool { shelf.layout == .list && (shelf.rowsPerColumn ?? 1) <= 1 }
    /// A show's episode list in the order the person chose (a view over the service's order); every other shelf as the service sent it.
    @MainActor static func drawn(_ shelf: MusicShelf, podcasts: PodcastsSurface?, pageReadAt: Date) -> [MusicCatalogItem] {
        guard let podcasts, !shelf.items.isEmpty, shelf.items.allSatisfy({ $0.kind == .episode }) else { return shelf.items }
        return podcasts.rows(for: shelf.items, pageReadAt: pageReadAt).map(\.item)
    }
    /// A row's identity on its page: the shelf and the occurrence, so a track that appears twice has two identities.
    static func rowItem(_ shelf: MusicShelf, _ item: MusicCatalogItem) -> String { shelf.key + "|" + (item.occurrenceID ?? item.id) }
    /// Every shelf, then the rows of each vertical list shelf in the order they are drawn; each row's parent is its shelf.
    @MainActor static func registration(of shelves: [MusicShelf], podcasts: PodcastsSurface?, pageReadAt: Date) -> (order: [String], parents: [String: String]) {
        var order: [String] = [], parents: [String: String] = [:]
        for shelf in shelves where !shelf.items.isEmpty || shelf.continuation != nil {
            order.append(shelf.key)
            guard isVerticalList(shelf) else { continue }
            for item in drawn(shelf, podcasts: podcasts, pageReadAt: pageReadAt) { let id = rowItem(shelf, item); order.append(id); parents[id] = shelf.key }
        }
        return (order, parents)
    }
}
