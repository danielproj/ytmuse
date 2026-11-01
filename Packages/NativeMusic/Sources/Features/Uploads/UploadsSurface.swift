import AccountSession
import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// How files are chosen. The application's picker is the system open panel; tests and the labelled development mode supply their own
/// synthetic files through the same seam.
@MainActor public protocol UploadFilePicking {
    func chooseFiles() async -> [URL]
}
/// The system open panel: audio files only, several at once, no folders, read access only.
@MainActor public struct OpenPanelUploadPicker: UploadFilePicking {
    public init() {}
    public func chooseFiles() async -> [URL] {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose music to upload")
        panel.prompt = String(localized: "Choose")
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        return await withCheckedContinuation { continuation in
            panel.begin { response in continuation.resume(returning: response == .OK ? panel.urls : []) }
        }
    }
}

/// The Uploads destination's state, owned by the shell: the three uploaded lists (songs, albums, artists, read through the Library's
/// own collection model and parser), the job queue and the one removal flow.
@MainActor @Observable public final class UploadsSurface {
    public let library: LibrarySurface
    public let models: [MusicUploadKind: LibraryCollectionModel]
    public let queue: UploadQueue
    public let removal: UploadRemovalModel
    public var selectedKind: MusicUploadKind = .songs
    /// The labelled development data answers instead of the service (Debug, isolated UI runs only).
    public let development: Bool
    @ObservationIgnored public let picker: any UploadFilePicking

    public init(library: LibrarySurface, models: [MusicUploadKind: LibraryCollectionModel], queue: UploadQueue, removal: UploadRemovalModel,
                picker: any UploadFilePicking = OpenPanelUploadPicker(), development: Bool = false) {
        self.library = library; self.models = models; self.queue = queue; self.removal = removal; self.picker = picker; self.development = development
    }
    public var model: LibraryCollectionModel { models[selectedKind]! }
    /// Reads every uploaded list again (after the service confirmed a file processed, or an upload was removed). True when all reads worked.
    public func refreshLists() async -> Bool {
        var ok = true
        for model in models.values {
            await model.refresh()
            if model.refreshFailure != nil { ok = false }
        }
        return ok
    }
    /// Opens the file chooser and queues what was chosen. Choosing a file is all it does; nothing is ever removed.
    public func chooseFiles() async {
        let urls = await picker.chooseFiles()
        guard !urls.isEmpty else { return }
        await queue.add(urls)
    }
    public func accountChanged() {
        for model in models.values { model.accountChanged() }
        queue.accountChanged(); removal.accountChanged()
    }
}
