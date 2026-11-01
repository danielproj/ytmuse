import AccountSession
import Artwork
import DesignSystem
import Features
import Foundation
import Observation
import SwiftUI

/// The catalog screens' shared state for the app: how pages are read (signed or anonymous, through the account
/// coordinator), the session cache, the models that keep each navigation entry's page (so Back returns to the same page
/// with the same scroll anchor), and the entries opened so far (a song's detail is built from the row it was opened from).
@MainActor final class CatalogHub {
    let artwork: CatalogArtwork
    /// The labelled development catalog answers instead of the service (Debug, isolated UI runs only).
    let development: Bool
    private let reader: CatalogPageModel.Reader
    private let continuer: CatalogPageModel.Continuer
    private let cache = CatalogCache()
    private let scope: @MainActor () -> String
    private let playback: @MainActor () -> SearchPlayback
    private weak var performer: (any SearchActionPerformer)?
    /// Told about each live signed page read, so the library write ledger can compare what the service says with what it showed.
    var pageObserver: (@MainActor (MusicBrowsePage) -> Void)?
    /// Told about the same pages so the tuner can list the radios they published (W20). It reads; it sends nothing.
    var radioObserver: (@MainActor (MusicBrowsePage) -> Void)?
    /// W18: a show page's own Play/Shuffle registers the show with the podcast controls (set by the bootstrap).
    var podcastStart: PodcastStartRegistration?
    private var models: [UUID: CatalogPageModel] = [:]
    private var order: [UUID] = []
    private var known: [String: MusicCatalogItem] = [:]
    private var knownOrder: [String] = []
    private var titles: [String: String] = [:]
    private let modelLimit = 24
    private let knownLimit = 2000

    init(artwork: CatalogArtwork, development: Bool, reader: @escaping CatalogPageModel.Reader, continuer: @escaping CatalogPageModel.Continuer,
         scope: @escaping @MainActor () -> String, playback: @escaping @MainActor () -> SearchPlayback, performer: (any SearchActionPerformer)?,
         pacer: ContinuationPacer = ContinuationPacer()) {
        // Every continuation request, from any page or shelf, waits for its account's next slot.
        self.continuer = { token in
            try await pacer.wait(scope: await scope())
            return try await continuer(token)
        }
        self.artwork = artwork; self.development = development; self.reader = reader
        self.scope = scope; self.playback = playback; self.performer = performer
    }

    // MARK: Routes

    /// A route this hub renders. Development routes (`development-…`) belong to the older placeholder and are not ours.
    func handles(_ route: NativeItemRoute) -> Bool {
        guard !route.identifier.hasPrefix("development-") else { return false }
        switch route.kind {
        case .artist, .album, .playlist, .podcast, .category, .song, .video: return true
        // An episode page is shown by the podcasts surface; the id must be the page id the service named.
        case .episode: return route.identifier.hasPrefix("MPED")
        case .sample, .tuner, .recap, .badge: return false
        }
    }
    func target(for route: NativeItemRoute) -> CatalogTarget? {
        switch route.kind {
        case .artist: CatalogTarget(kind: .artist, identifier: route.identifier)
        case .album: CatalogTarget(kind: .album, identifier: route.identifier)
        case .playlist: CatalogTarget(kind: .playlist, identifier: route.identifier)
        case .podcast: CatalogTarget(kind: .podcast, identifier: route.identifier)
        case .category: CatalogTarget(browseID: route.identifier, params: route.params)
        default: nil
        }
    }
    func route(for item: MusicCatalogItem) -> NativeItemRoute? {
        remember([item])
        switch item.kind {
        case .song, .video: return item.videoID.flatMap { try? NativeItemRoute(kind: .song, identifier: $0) }
        case .artist, .album, .playlist, .podcast:
            let kind: NativeItemKind = item.kind == .artist ? .artist : item.kind == .album ? .album : item.kind == .playlist ? .playlist : .podcast
            return item.browseID.flatMap { try? NativeItemRoute(kind: kind, identifier: $0) }
        case .category: return item.browseID.flatMap { try? NativeItemRoute(kind: .category, identifier: $0, params: item.browseParams) }
        case .episode: return item.browseID.flatMap { $0.hasPrefix("MPED") ? try? NativeItemRoute(kind: .episode, identifier: $0) : nil }
        }
    }
    func route(for link: MusicLink) -> NativeItemRoute? {
        let kind: NativeItemKind
        switch link.kind {
        case .artist: kind = .artist
        case .album: kind = .album
        case .playlist: kind = .playlist
        case .podcast: kind = .podcast
        case .other: kind = .category
        }
        return try? NativeItemRoute(kind: kind, identifier: link.browseID, params: kind == .category ? link.params : nil)
    }
    func route(for result: SearchResult) -> NativeItemRoute? {
        guard result.opensPage else { return nil }
        switch result.kind {
        case .song, .video:
            guard let video = result.target.videoID else { return nil }
            remember([MusicCatalogItem(kind: result.kind == .video ? .video : .song, title: result.title, details: result.details, explicit: result.badges.contains(.explicit), videoID: video)])
            return try? NativeItemRoute(kind: .song, identifier: video)
        case .artist: return result.target.browseID.flatMap { try? NativeItemRoute(kind: .artist, identifier: $0) }
        case .album: return result.target.browseID.flatMap { try? NativeItemRoute(kind: .album, identifier: $0) }
        case .playlist: return (result.target.browseID ?? result.target.playlistID).flatMap { try? NativeItemRoute(kind: .playlist, identifier: $0) }
        case .podcast: return result.target.browseID.flatMap { try? NativeItemRoute(kind: .podcast, identifier: $0) }
        case .episode: return result.target.browseID.flatMap { $0.hasPrefix("MPED") ? try? NativeItemRoute(kind: .episode, identifier: $0) : nil }
        }
    }
    func rememberTitle(_ title: String, for route: NativeItemRoute) { if !title.isEmpty { titles[route.identifier + "?" + (route.params ?? "")] = title } }
    func title(for route: NativeItemRoute) -> String { titles[route.identifier + "?" + (route.params ?? "")] ?? String(localized: "Browse") }
    func remember(_ items: [MusicCatalogItem]) {
        for item in items where item.kind == .song || item.kind == .video {
            guard let id = item.videoID else { continue }
            if known[id] == nil { knownOrder.append(id) }
            known[id] = item
            while knownOrder.count > knownLimit { known[knownOrder.removeFirst()] = nil }
        }
    }
    func song(_ videoID: String) -> MusicCatalogItem? { known[videoID] }

    // MARK: Models

    func model(for entry: BrowserEntry) -> CatalogPageModel? {
        if let model = models[entry.id] { touch(entry.id); return model }
        let target: CatalogTarget
        if let route = entry.item {
            if route.kind == .song || route.kind == .video {
                // A song's detail comes from the row it was opened from and asks for nothing; its model only runs actions.
                target = CatalogTarget(browseID: "song-" + route.identifier)
            } else {
                guard handles(route), let page = self.target(for: route) else { return nil }
                target = page
            }
        } else {
            switch entry.destination {
            case .home: target = .home
            case .explore: target = .explore
            default: return nil
            }
        }
        let model = CatalogPageModel(target: target, reader: reader, continuer: continuer, cache: cache, accountScope: scope, playback: playback,
                                     performer: performer, staleAfter: target.staleAfter, onItems: { [weak self] items in self?.remember(items) },
                                     onPage: { [weak self] page in self?.pageObserver?(page); self?.radioObserver?(page) })
        model.podcastStart = podcastStart
        models[entry.id] = model; order.append(entry.id)
        while order.count > modelLimit { models[order.removeFirst()] = nil }
        return model
    }
    private func touch(_ id: UUID) { order.removeAll { $0 == id }; order.append(id) }

    /// The shell calls this when the active account (or whether its session is live) changes.
    func accountChanged() {
        for model in models.values { model.accountChanged() }
    }

    func navigator(_ navigation: BrowserNavigation) -> CatalogNavigator {
        CatalogNavigator(
            openItem: { [weak self, weak navigation] item in
                guard let self, let navigation, let route = self.route(for: item) else { return }
                self.rememberTitle(item.title, for: route)
                navigation.open(navigation.session.current.destination, item: route)
            },
            openLink: { [weak self, weak navigation] link in
                guard let self, let navigation, let route = self.route(for: link) else { return }
                self.rememberTitle(link.title, for: route)
                navigation.open(navigation.session.current.destination, item: route)
            },
            openTarget: { [weak self, weak navigation] target, title in
                guard let self, let navigation, let route = try? NativeItemRoute(kind: .category, identifier: target.browseID, params: target.params) else { return }
                self.rememberTitle(title, for: route)
                navigation.open(navigation.session.current.destination, item: route)
            })
    }
}

// MARK: Composition

extension LocalAccountBootstrap {
    /// The catalog's reader: signed for the active account, anonymous otherwise, through the account coordinator. It waits for
    /// the account store to finish opening, so a page asked for at launch is read under the account that is actually active.
    @MainActor func awaitedMusic() async throws -> MusicSessionCoordinator {
        await load()
        guard let music else { throw MusicSessionError.policy }
        return music
    }
    func makeCatalogHub() -> CatalogHub {
        let reader: CatalogPageModel.Reader
        let continuer: CatalogPageModel.Continuer
        var development = false
        #if DEBUG
        if DevelopmentCatalog.enabled {
            development = true
            reader = DevelopmentCatalog.reader; continuer = DevelopmentCatalog.continuer
        } else if Self.automationIsolated(ProcessInfo.processInfo.environment) {
            // A UI-automation launch (explicit isolation or design mode) without the development catalog never reaches the network.
            // (A plain Debug run is store-isolated by default but is a developer's run and reads the service like search does.)
            reader = { _ in throw MusicSessionError.policy }; continuer = { _ in throw MusicSessionError.policy }
        } else {
            (reader, continuer) = liveCatalogReaders()
        }
        #else
        (reader, continuer) = liveCatalogReaders()
        #endif
        let hub = CatalogHub(artwork: catalogArtwork, development: development, reader: reader, continuer: continuer,
                             scope: { [unowned self] in searchScopeToken }, playback: { [unowned self] in searchPlayback }, performer: searchPerformer)
        // A show page's own Play/Shuffle goes through the same registration as an episode's Play (speed, progress, resume).
        hub.podcastStart = PodcastStartRegistration(began: { [weak self] show, list in self?.podcasts.playback.showStarting(show: show, playlistID: list) })
        return hub
    }
    #if DEBUG
    static func automationIsolated(_ environment: [String: String]) -> Bool {
        environment[IsolatedQAStorage.environmentKey] == "1" || environment["YTMUSE_NATIVE_DESIGN_TEST"] == "1"
    }
    #endif
    private func liveCatalogReaders() -> (CatalogPageModel.Reader, CatalogPageModel.Continuer) {
        let reader: CatalogPageModel.Reader = { [weak self] target in
            guard let self else { throw MusicSessionError.stale }
            return try await self.awaitedMusic().browse(id: target.browseID, params: target.params)
        }
        let continuer: CatalogPageModel.Continuer = { [weak self] token in
            guard let self else { throw MusicSessionError.stale }
            return try await self.awaitedMusic().continuation(token: token)
        }
        return (reader, continuer)
    }
}
