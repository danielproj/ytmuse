import AccountSession
import Domain
import Features
import Foundation

/// Upload jobs kept between launches: one small private file per account inside the app's data directory (the isolated scratch root
/// under QA isolation). It holds job records only, never file contents or credentials. Removing the account removes its file.
actor UploadJobFileStore: UploadJobStoring, AccountLifecycleParticipant {
    nonisolated let participantID = "upload-jobs"
    enum Failure: Error { case invalidAccount, corrupt }
    private let directory: URL
    init(directory: URL) { self.directory = directory }

    private func file(_ account: String) throws -> URL {
        guard let id = UUID(uuidString: account) else { throw Failure.invalidAccount }
        return directory.appendingPathComponent(id.uuidString + ".plist")
    }
    func load(account: String) throws -> [UploadJob] {
        let url = try file(account)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard data.count <= 16 * 1024 * 1024, let jobs = try? PropertyListDecoder().decode([UploadJob].self, from: data), jobs.allSatisfy({ $0.account == account }) else { throw Failure.corrupt }
        return jobs
    }
    func save(_ jobs: [UploadJob], account: String) throws {
        let url = try file(account)
        guard jobs.allSatisfy({ $0.account == account }) else { throw Failure.invalidAccount }
        if jobs.isEmpty { try? GuardedFiles(root: directory).remove(url); return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        try encoder.encode(jobs).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func clear(account: String) throws {
        let url = try file(account)
        try GuardedFiles(root: directory).remove(url)
    }
    func detach(previous: RequestContext, barrier: RequestContext) async throws {}
    func restorePaused(_ identity: LocalIdentity, context: RequestContext) async throws {}
    /// Removing an account removes the job list kept for it. Only this app's own record goes; no chosen file is touched.
    func removeLocal(_ account: AccountContext, context: RequestContext) async throws {
        try? clear(account: account.accountID.uuidString)
    }
}

/// The store the interface holds before the account directory is known; operations before `bind` fail, they are never dropped silently.
actor LateBoundUploadStore: UploadJobStoring {
    enum Failure: Error { case notBound }
    private var target: (any UploadJobStoring)?
    func bind(_ store: any UploadJobStoring) { target = store }
    func load(account: String) async throws -> [UploadJob] { try await bound().load(account: account) }
    func save(_ jobs: [UploadJob], account: String) async throws { try await bound().save(jobs, account: account) }
    func clear(account: String) async throws { try await bound().clear(account: account) }
    private func bound() throws -> any UploadJobStoring { guard let target else { throw Failure.notBound }; return target }
}

@MainActor private final class UploadsSurfaceBox { weak var surface: UploadsSurface? }

extension LocalAccountBootstrap {
    /// The Uploads destination: the three uploaded lists through the Library's own reader and parser, the job queue, and the removal flow.
    ///
    /// **No working upload in the application yet.** The real Music locker upload route is W37, so the queue's transport here is
    /// `UnavailableUploadTransport`: the screen says "Uploading arrives in a later update" and offers no upload control. A scripted
    /// transport is installed only under the Debug development flags (see `DevelopmentUploads`). Removal is the only account write: it
    /// goes through the very writer closure the Library's ledger holds (the one `write` call site), and only after a confirmation
    /// that names the upload.
    func makeUploadsSurface(library: LibrarySurface, reader: @escaping LibraryCollectionModel.Reader, continuer: @escaping LibraryCollectionModel.Continuer,
                            writer: @escaping LibraryWriteLedger.Writer, scope: @escaping @MainActor () -> String,
                            signedIn: @escaping @MainActor () -> SearchPlayback, accountKey: @escaping @MainActor () -> String?, development: Bool) -> UploadsSurface {
        let box = UploadsSurfaceBox()
        var transport: any UploadTransport = UnavailableUploadTransport()
        var reader = reader, continuer = continuer, writer = writer
        var listing: UploadRemovalModel.Lister = liveUploadListing(reader: reader)
        var picker: any UploadFilePicking = OpenPanelUploadPicker()
        var inspector = UploadSourceInspector()
        var store: any UploadJobStoring = uploadStore
        var delays = UploadQueue.defaultPollDelays
        var accountKey = accountKey
        #if DEBUG
        if development, DevelopmentUploads.enabled, let root = isolatedStorage?.root {
            let dev = DevelopmentUploads(root: root)
            transport = dev.transport; reader = DevelopmentUploads.reader(dev.lists); continuer = { _ in throw MusicSessionError.unrecognised }
            writer = DevelopmentUploads.remover(dev.lists); listing = DevelopmentUploads.lister(dev.lists)
            picker = dev.picker; inspector = UploadSourceInspector(testRoot: dev.samples); store = dev.store; delays = dev.delays
            accountKey = { DevelopmentLibrary.accountKey }
        }
        #endif
        var models: [MusicUploadKind: LibraryCollectionModel] = [:]
        for kind in MusicUploadKind.allCases {
            models[kind] = LibraryCollectionModel(source: .uploads(kind), reader: reader, continuer: continuer, accountScope: scope)
        }
        let queue = UploadQueue(transport: transport, store: store, inspector: inspector, accountKey: accountKey,
                                refresh: { await box.surface?.refreshLists() ?? false }, pollDelays: delays)
        let removal = UploadRemovalModel(remover: writer, listing: listing, accountScope: scope, signedIn: signedIn, removed: { _ = await box.surface?.refreshLists() })
        let surface = UploadsSurface(library: library, models: models, queue: queue, removal: removal, picker: picker, development: development)
        box.surface = surface
        return surface
    }
    /// Reads the service's Uploads list to settle an unconfirmed removal, through the same reader the lists use (so an automation-isolated
    /// composition stays sealed). The decision is `UploadListEvidence.stillListed`: still listed → true; read completely and without it →
    /// false; anything else cannot tell.
    private func liveUploadListing(reader: @escaping LibraryCollectionModel.Reader) -> UploadRemovalModel.Lister {
        { target in
            let kind: MusicUploadKind = target.kind == .album ? .albums : target.kind == .artist ? .artists : .songs
            guard let reply = try? await reader(.uploads(kind)) else { return nil }
            return UploadListEvidence.stillListed(target, in: reply)
        }
    }
}
