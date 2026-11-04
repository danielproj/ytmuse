import AccountSession
import Foundation

// W09-F2: what each production destination records for a navigation entry, and how it puts it back. Plain functions of the page's own
// models, so they are tested without a window. The views only connect them to `remembersPage`.

extension LibrarySurface {
    /// The Library visit: the collection on show, its search, order, layout and selection, and whether only kept items are listed.
    public var pageMemory: PageMemory {
        let model = model
        return PageMemory(query: model.query, selection: model.selection,
                          values: ["kind": selectedKind.rawValue, "downloadedOnly": showsDownloadedOnly ? "1" : "0", "sort": model.sort.rawValue, "layout": model.layout.rawValue])
    }
    public func restorePage(_ saved: PageMemory) {
        if let kind = saved.values["kind"].flatMap(MusicLibraryKind.init(rawValue:)) { selectedKind = kind }
        showsDownloadedOnly = saved.values["downloadedOnly"] == "1" && downloads != nil
        let model = model
        model.query = saved.query ?? ""
        model.sort = saved.values["sort"].flatMap(LibrarySort.init(rawValue:)) ?? .service
        model.layout = saved.values["layout"].flatMap(LibraryLayout.init(rawValue:)) ?? model.layout
        model.selection = saved.selection ?? []
    }
}

extension LibrarySurface {
    /// A new Library visit starts with its own transient state: no search text, no selection (and the top of the list). Kind, order, layout and
    /// "Downloaded only" are durable settings and carry over, unless the destination opens on a particular collection.
    public func beginFreshVisit(opensOn: MusicLibraryKind? = nil) {
        if let opensOn { selectedKind = opensOn; showsDownloadedOnly = false }
        model.query = ""; model.selection = []
    }
}

extension SearchModel {
    /// A new Search visit starts with no selected result. The query and scope carry over on purpose: the window has one search field, which Command-F focuses.
    public func beginFreshVisit() { restoreSelection(nil) }
}

extension DownloadsModel {
    /// The Downloads visit: its segmented filter.
    public var pageMemory: PageMemory { PageMemory(values: ["filter": filter.rawValue]) }
    public func restorePage(_ saved: PageMemory) { filter = saved.values["filter"].flatMap(Filter.init(rawValue:)) ?? .all }
}

extension SearchModel {
    /// The Search visit: the query, where it searches and the selected result.
    public var pageMemory: PageMemory { PageMemory(query: query, selection: selection.map { [$0] } ?? [], values: ["scope": scope.rawValue]) }
    public func restorePage(_ saved: PageMemory) {
        // A retired private scope must never turn a restored query into a public search.
        if let raw = saved.values["scope"] { scope = SearchPlace(rawValue: raw) ?? .library }
        query = saved.query ?? ""
        // Results arrive after the query, so the selection is applied when the result it names does.
        restoreSelection(saved.selection?.first)
    }
}
