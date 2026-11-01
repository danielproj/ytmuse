import AccountSession
import Domain
import Features
import Foundation
import Persistence

/// Immediate full-text matches over media records already saved in the account's local
/// store (the W03 FTS index). It answers only for the request context it is asked under,
/// so a record saved by another account is never returned. The store exposes no writer
/// to the app yet, so this source is composed once something saves media; until then the
/// library playlists are the live local source.
@MainActor final class StoredMediaSearchSource: LocalSearchSource {
    let scopes: Set<SearchPlace> = [.all, .library]
    private let store: SQLiteStore
    private let context: @MainActor () -> RequestContext?
    init(store: SQLiteStore, context: @escaping @MainActor () -> RequestContext?) { self.store = store; self.context = context }
    func search(_ query: FoldedQuery, limit: Int) async -> [SearchResult] {
        guard let context = context(), let page = try? await store.search(query.original, limit: max(1, min(limit, 200)), context: context) else { return [] }
        return page.items.compactMap { item -> SearchResult? in
            let kind: MusicSearchKind
            switch item.kind { case .song: kind = .song; case .video: kind = .video; case .episode: kind = .episode; case .live, .sample: return nil }
            var badges: Set<SearchBadge> = [.local]
            if item.explicit == true { badges.insert(.explicit) }
            return SearchResult(kind: kind, title: item.title, subtitle: nil, badges: badges, target: SearchTarget(videoID: item.id.rawValue),
                                fromService: false, quality: query.match(item.title) ?? .prefix)
        }.sorted(by: SearchRanking.order)
    }
}
