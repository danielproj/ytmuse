import Domain
import Foundation

/// The updater's ONE filesystem wrapper (W27's guard sweep allows destructive file calls only inside a named wrapper). It applies the same refusal as W27's `GuardedFiles`, AT
/// EACH CALL: while the process is isolated (every test process, every QA launch) it refuses any target in the account holder's real stores (`RealStores`) and any target at
/// all outside the temporary folder, so even a broken binding or a broken check further out could never remove, copy or replace anything real from a test. On top of that every
/// call is confined by its own rule: the staging folder is a folder named "Updates" and the only place the updater deletes from; a download is moved from the temporary folder
/// into it; the installed app is replaced only by a sibling this updater copied beside it. Nothing here takes a path from the feed.
struct UpdateFiles: Sendable {
    private let forceIsolated: Bool
    private let real: RealStores
    /// The process decides (`ProcessIsolation`) and the real stores are the real ones.
    static let standard = UpdateFiles(forceIsolated: false, real: .resolved())
    /// A test may use a FAKE home and may force isolation ON. `forceIsolated: false` never loosens it: the process flag still applies.
    init(forceIsolated: Bool = false, real: RealStores) { self.forceIsolated = forceIsolated; self.real = real }
    private var isolated: Bool { forceIsolated || ProcessIsolation.isIsolated }

    private func fm() -> FileManager { .default }
    static func isStagingFolder(_ url: URL) -> Bool { url.lastPathComponent == "Updates" && url.pathComponents.count > 2 }
    static func inside(_ url: URL, _ root: URL) -> Bool { RealStores.contains(RealStores.canonical(root), RealStores.canonical(url)) && RealStores.canonical(url) != RealStores.canonical(root) }
    private static func insideTemporary(_ url: URL) -> Bool {
        [URL(fileURLWithPath: NSTemporaryDirectory()), FileManager.default.temporaryDirectory].contains { RealStores.contains(RealStores.canonical($0), RealStores.canonical(url)) }
    }
    /// The isolated-process refusal: nothing in a real store, and nothing outside the temporary folder.
    func permits(_ url: URL) -> Bool {
        guard isolated else { return true }
        return !real.containsRealPath(url) && Self.insideTemporary(url)
    }
    private func require(_ urls: URL...) throws { for url in urls where !permits(url) { throw UpdateRejection.transport("refused: not allowed in this process") } }

    /// Deletes the staging folder and everything in it. Refuses any folder that is not one named "Updates".
    @discardableResult func wipeStaging(_ root: URL) -> Bool {
        guard Self.isStagingFolder(root), permits(root) else { return false }
        try? fm().removeItem(at: root); return true
    }
    /// Deletes one thing inside the staging folder (never the folder itself).
    func remove(_ url: URL, insideStaging root: URL) {
        guard Self.isStagingFolder(root), Self.inside(url, root), permits(url) else { return }
        try? fm().removeItem(at: url)
    }
    /// Copies the app out of a mounted image (a mount point inside the staging folder) into the staging folder.
    func copy(_ source: URL, toStaged destination: URL, insideStaging root: URL) throws {
        guard Self.isStagingFolder(root), Self.inside(destination, root), Self.inside(source, root) else { throw UpdateRejection.transport("staging folder") }
        try require(source, destination)
        try fm().copyItem(at: source, to: destination)
    }
    /// Moves a finished download from the system's temporary folder to its place in the staging folder.
    func placeDownload(_ file: URL, at destination: URL) throws {
        guard Self.isStagingFolder(destination.deletingLastPathComponent()), Self.insideTemporary(file) else { throw UpdateRejection.transport("staging folder") }
        try require(destination)
        try? fm().removeItem(at: destination)
        try fm().moveItem(at: file, to: destination)
    }
    /// Deletes the system's own temporary download file.
    func discardTemporary(_ file: URL) {
        guard Self.insideTemporary(file) else { return }
        try? fm().removeItem(at: file)
    }
    static let siblingPrefix = ".YTMuse-update-"
    /// Copies the verified staged app next to the installed one (same volume, so the later exchange is atomic).
    func copyBeside(_ staged: URL, installed: URL, name: String) throws -> URL {
        guard installed.pathExtension == "app", name.hasPrefix(Self.siblingPrefix), name.hasSuffix(".app"), !name.contains("/") else { throw UpdateRejection.installLocationNotWritable }
        let sibling = installed.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
        try require(installed, sibling)
        try fm().copyItem(at: staged, to: sibling)
        return sibling
    }
    /// Removes a sibling this updater made (a failed install).
    func removeSibling(_ sibling: URL, installed: URL) {
        guard sibling.deletingLastPathComponent().path == installed.deletingLastPathComponent().path, sibling.lastPathComponent.hasPrefix(Self.siblingPrefix), permits(sibling) else { return }
        try? fm().removeItem(at: sibling)
    }
    /// The one atomic exchange: the installed app becomes the verified sibling.
    func exchange(installed: URL, withSibling sibling: URL) throws -> URL? {
        guard installed.pathExtension == "app", sibling.deletingLastPathComponent().path == installed.deletingLastPathComponent().path, sibling.lastPathComponent.hasPrefix(Self.siblingPrefix) else { throw UpdateRejection.installLocationNotWritable }
        try require(installed, sibling)
        return try fm().replaceItemAt(installed, withItemAt: sibling, backupItemName: nil, options: [])
    }
    /// Removes the temporary mount point folder of a disk image.
    func removeMountPoint(_ mount: URL, insideStaging root: URL) { remove(mount, insideStaging: root) }
}
