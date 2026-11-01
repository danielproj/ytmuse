#if DEBUG
import AccountSession
import Features
import Foundation

/// Debug-only, labelled development data for the isolated UI tests of the Uploads screen. It exists only with `YTMUSE_UI_DEVELOPMENT_DATA=1`,
/// `YTMUSE_UI_DEVELOPMENT_LIBRARY=1`, `YTMUSE_UI_DEVELOPMENT_UPLOADS=1` and QA isolation, and no Release build contains it. It performs no
/// network request and sends nothing anywhere: a scripted transport answers like the service would, over synthetic audio the app writes
/// into its own scratch folder (the only place test mode accepts files from). What a file does is decided by its name.
struct DevelopmentUploads {
    static var enabled: Bool { isEnabled(ProcessInfo.processInfo.environment) }
    static func isEnabled(_ environment: [String: String]) -> Bool {
        DevelopmentLibrary.isEnabled(environment) && environment["YTMUSE_UI_DEVELOPMENT_UPLOADS"] == "1"
    }
    let lists = DevelopmentUploadLists()
    let samples: URL
    let transport: DevelopmentUploadTransport
    let picker: DevelopmentUploadPicker
    let store = DevelopmentUploadJobStore()
    let delays: [Duration] = Array(repeating: .milliseconds(700), count: 40)

    init(root: URL) {
        samples = root.appendingPathComponent("upload-samples", isDirectory: true)
        transport = DevelopmentUploadTransport(lists: lists)
        picker = DevelopmentUploadPicker(directory: samples)
    }

    private static func song(_ title: String, entity: String?, video: String) -> MusicCatalogItem {
        MusicCatalogItem(kind: .song, title: title, details: ["Development Artist", "Development Album"], videoID: video,
                         links: [MusicLink(kind: .artist, title: "Development Artist", browseID: "UCdevelopmentartist00000000")],
                         durationText: "0:03", isUpload: true, uploadEntityID: entity)
    }
    private static func page(_ items: [MusicCatalogItem], layout: MusicShelf.Layout) -> MusicBrowsePage {
        let shelf = MusicShelf(key: "dev-uploads", title: nil, layout: layout, items: items, continuation: nil)
        var accounting = MusicParseAccounting()
        accounting.sections = 1; accounting.shelves = 1; accounting.items = items.count; accounting.classified = items.count
        return MusicBrowsePage(shelves: [shelf], accounting: accounting)
    }
    static func reader(_ lists: DevelopmentUploadLists) -> LibraryCollectionModel.Reader {
        { source in
            let entries = await lists.entries
            let page: MusicBrowsePage
            switch source.browseID {
            case MusicUploadKind.songs.browseID: page = Self.page(entries.map { Self.song($0.title, entity: $0.entity, video: $0.video) }, layout: .list)
            case MusicUploadKind.albums.browseID:
                // An uploaded album that published no removal command: nothing is offered for it.
                page = Self.page([MusicCatalogItem(kind: .album, title: "Demo Album (development)", details: ["Development Artist"], serviceLabel: "Album",
                                                   browseID: "MPREdevelopmentupload1", playlistID: nil, isUpload: true)], layout: .grid)
            case MusicUploadKind.artists.browseID:
                page = Self.page([MusicCatalogItem(kind: .artist, title: "Development Artist", details: ["1 song"], browseID: "UCdevelopmentartist00000000")], layout: .list)
            default: throw MusicSessionError.unrecognised
            }
            return MusicBrowseReply(value: page, mode: .signedIn, accountGeneration: 0)
        }
    }
    /// Answers like a service: slowly enough for the pending state to be seen. One upload's removal is refused and one is left unconfirmed.
    static func remover(_ lists: DevelopmentUploadLists) -> LibraryWriteLedger.Writer {
        { request in
            try await Task.sleep(for: .milliseconds(1500))
            guard case .removeUpload(let entity) = request else { throw MusicSessionError.policy }
            switch entity {
            case "devupload-song-fail": return MusicWriteReply(outcome: .rejected(.service), accountGeneration: 0)
            case "devupload-song-unconfirmed": return MusicWriteReply(outcome: .indeterminate(.noAnswer), accountGeneration: 0)
            default:
                await lists.remove(entity: entity)
                return MusicWriteReply(outcome: .confirmed, accountGeneration: 0)
            }
        }
    }
    /// The check after an unconfirmed removal: the development list cannot be read for that one upload, so the check says it cannot tell.
    static func lister(_ lists: DevelopmentUploadLists) -> UploadRemovalModel.Lister {
        { target in target.entityID == "devupload-song-unconfirmed" ? nil : await lists.contains(entity: target.entityID) }
    }
}

actor DevelopmentUploadLists {
    struct Entry: Sendable { let title: String; let entity: String; let video: String }
    private(set) var entries: [Entry] = [
        Entry(title: "Home Recording", entity: "devupload-song-0001", video: "devupsong01"),
        Entry(title: "Refused Removal Song", entity: "devupload-song-fail", video: "devupsong02"),
        Entry(title: "Unconfirmed Removal Song", entity: "devupload-song-unconfirmed", video: "devupsong03"),
    ]
    func add(title: String) { entries.append(Entry(title: title, entity: "devupload-song-" + UUID().uuidString.prefix(8).lowercased(), video: "devupnew" + String(entries.count).padding(toLength: 3, withPad: "0", startingAt: 0))) }
    func remove(entity: String) { entries.removeAll { $0.entity == entity } }
    func contains(entity: String) -> Bool { entries.contains { $0.entity == entity } }
}

/// A scripted upload route over the development lists. What a file does is decided by its name: "refused" is refused when sent,
/// "slow" keeps sending until cancelled, "fails" uploads and then fails processing, anything else uploads and is processed.
final class DevelopmentUploadTransport: UploadTransport, @unchecked Sendable {
    let lists: DevelopmentUploadLists
    private let lock = NSLock()
    private var polled: [String: Int] = [:]
    private var titles: [String: String] = [:]
    init(lists: DevelopmentUploadLists) { self.lists = lists }
    var capability: UploadCapability { UploadCapability(availability: .available, resumption: .unsupported, maximumFileBytes: nil) }
    func upload(_ request: UploadRequest, progress: @escaping @Sendable (Int64) -> Void, handle: @escaping @Sendable (String) -> Void) async throws -> String {
        let name = request.fileURL.lastPathComponent.lowercased()
        let id = "devhandle-" + request.jobID.uuidString.lowercased()
        handle(id)
        if name.contains("refused") {
            try await Task.sleep(for: .milliseconds(600))
            throw UploadTransportError.refused("Development message: this file wasn’t accepted.")
        }
        let steps = name.contains("slow") ? 300 : 6
        for step in 1...steps {
            do { try await Task.sleep(for: .milliseconds(name.contains("slow") ? 200 : 150)) } catch { throw UploadTransportError.cancelled }
            progress(request.byteCount * Int64(min(step, steps - 1)) / Int64(steps))
        }
        lock.withLock { titles[id] = request.metadata.title }
        return id
    }
    func processing(handle: String) async throws -> UploadProcessing {
        let (count, title) = lock.withLock { () -> (Int, String) in polled[handle, default: 0] += 1; return (polled[handle] ?? 1, titles[handle] ?? "") }
        if title.lowercased().contains("fails") { return count < 2 ? .processing : .failed("Development message: processing failed.") }
        if count < 3 { return .processing }
        await lists.add(title: title)
        return .completed
    }
    func cancel(handle: String?) async {}
}

/// "Choose Files…" in the development screens: writes four small synthetic WAV files (silence) into the scratch folder and returns them.
@MainActor struct DevelopmentUploadPicker: UploadFilePicking {
    let directory: URL
    func chooseFiles() async -> [URL] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let names = ["Aurora Test Tone.wav", "Refused Test Tone.wav", "Processing Fails Test Tone.wav", "Slow Test Tone.wav"]
        var urls: [URL] = []
        for name in names {
            let url = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) { try? Self.silentWAV(name: name).write(to: url) }
            urls.append(url)
        }
        return urls
    }
    /// 0.2 s of 8 kHz mono 16-bit silence, made here: owned synthetic audio, no third-party material.
    static func silentWAV(name: String) -> Data {
        let samples = 1600, dataBytes = samples * 2
        func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        func le16(_ v: Int) -> [UInt8] { (0..<2).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        var bytes: [UInt8] = Array("RIFF".utf8) + le32(36 + dataBytes) + Array("WAVE".utf8) + Array("fmt ".utf8) + le32(16) + le16(1) + le16(1) + le32(8000) + le32(16000) + le16(2) + le16(16)
        bytes += Array("data".utf8) + le32(dataBytes) + [UInt8](repeating: 0, count: dataBytes)
        return Data(bytes)
    }
}

/// Job records for the development screens: in memory, never a file.
actor DevelopmentUploadJobStore: UploadJobStoring {
    private var saved: [String: [UploadJob]] = [:]
    func load(account: String) -> [UploadJob] { saved[account] ?? [] }
    func save(_ jobs: [UploadJob], account: String) { saved[account] = jobs }
    func clear(account: String) { saved[account] = nil }
}
#endif
