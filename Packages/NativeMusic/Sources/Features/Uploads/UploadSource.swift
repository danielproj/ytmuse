import AVFoundation
import Foundation

/// What a chosen file looks like from its first bytes. This is the app's own reading, not a statement about what YouTube Music
/// accepts: the service decides that after the upload and its answer is shown as it is (UP-S1).
public enum UploadAudioFormat: String, Codable, Sendable, CaseIterable {
    case mp3, flac, mpeg4Audio, ogg, windowsMedia, wav, aiff
    public var label: String {
        switch self {
        case .mp3: "MP3"
        case .flac: "FLAC"
        case .mpeg4Audio: "M4A"
        case .ogg: "Ogg"
        case .windowsMedia: "WMA"
        case .wav: "WAV"
        case .aiff: "AIFF"
        }
    }
    static let extensions: [String: UploadAudioFormat] = [
        "mp3": .mp3, "flac": .flac, "m4a": .mpeg4Audio, "ogg": .ogg, "oga": .ogg, "opus": .ogg, "wma": .windowsMedia, "wav": .wav, "aif": .aiff, "aiff": .aiff, "aifc": .aiff,
    ]
    /// The brands of an MPEG-4 `ftyp` box: the major brand, then the compatible ones.
    static func brands(_ bytes: [UInt8]) -> [String] {
        guard bytes.count >= 12 else { return [] }
        func text(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
        let size = (Int(bytes[0]) << 24) | (Int(bytes[1]) << 16) | (Int(bytes[2]) << 8) | Int(bytes[3])
        var result = [text(8..<12)]
        var index = 16
        while index + 4 <= min(size, bytes.count) { result.append(text(index..<index + 4)); index += 4 }
        return result
    }
    /// An MPEG-4 file none of whose brands says audio or video: only its actual tracks can say.
    static func isGenericMPEG4(_ head: Data) -> Bool {
        let bytes = [UInt8](head.prefix(64))
        guard bytes.count >= 12, String(decoding: bytes[4..<8], as: UTF8.self) == "ftyp" else { return false }
        return sniff(head).format == nil && !sniff(head).video
    }
    /// The container named by the first bytes, when they name one. MPEG-4 is reported as audio only for the audio brands.
    static func sniff(_ head: Data) -> (format: UploadAudioFormat?, protected: Bool, video: Bool) {
        let bytes = [UInt8](head.prefix(64))
        func text(_ range: Range<Int>) -> String { range.upperBound <= bytes.count ? String(decoding: bytes[range], as: UTF8.self) : "" }
        if text(0..<3) == "ID3" { return (.mp3, false, false) }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] & 0xE0 == 0xE0, bytes[1] & 0x06 != 0 { return (.mp3, false, false) }
        if text(0..<4) == "fLaC" { return (.flac, false, false) }
        if text(0..<4) == "OggS" { return (.ogg, false, false) }
        if bytes.count >= 16, Array(bytes[0..<8]) == [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11] { return (.windowsMedia, false, false) }
        if text(0..<4) == "RIFF", text(8..<12) == "WAVE" { return (.wav, false, false) }
        if text(0..<4) == "FORM", ["AIFF", "AIFC"].contains(text(8..<12)) { return (.aiff, false, false) }
        if text(4..<8) == "ftyp" {
            // The major brand alone says little (encoders write `mp42`, `isom` or `dash` for plain audio): read the compatible brands too.
            let brands = Self.brands(bytes)
            if brands.contains("M4P ") { return (.mpeg4Audio, true, false) }
            if brands.contains("M4A ") || brands.contains("M4B ") { return (.mpeg4Audio, false, false) }
            if !Set(brands).isDisjoint(with: ["M4V ", "M4VH", "M4VP", "qt  "]) { return (nil, false, true) }
        }
        return (nil, false, false)
    }
}

/// What the file says about itself; every field is optional and none is invented. The title falls back to the file name, and
/// `titleFromFilename` says so.
public struct UploadMetadata: Codable, Equatable, Sendable {
    public var title: String
    public var artist: String?
    public var album: String?
    public var durationSeconds: Double?
    public var titleFromFilename: Bool
    public init(title: String, artist: String? = nil, album: String? = nil, durationSeconds: Double? = nil, titleFromFilename: Bool = false) {
        self.title = title; self.artist = artist; self.album = album; self.durationSeconds = durationSeconds; self.titleFromFilename = titleFromFilename
    }
}

/// A file the person chose, checked and described. The record keeps no file contents. Nothing here ever writes, moves or deletes the file.
public struct UploadSource: Codable, Equatable, Sendable {
    public let path: String
    public let displayName: String
    public let byteCount: Int64
    public let modified: Date
    public let format: UploadAudioFormat?
    /// The first bytes named an audio container. False means only the extension said audio, and the service will have the last word.
    public let contentConfirmed: Bool
    public var metadata: UploadMetadata
    /// A security-scoped bookmark, when one could be made, so a restart can read the same file again without a second prompt.
    public let bookmark: Data?
    public var url: URL { URL(fileURLWithPath: path) }
    /// Two selections of the same file name the same path, size and modification time.
    public var identity: String { "\(path)|\(byteCount)|\(modified.timeIntervalSince1970)" }
    public init(path: String, displayName: String, byteCount: Int64, modified: Date, format: UploadAudioFormat?, contentConfirmed: Bool, metadata: UploadMetadata, bookmark: Data? = nil) {
        self.path = path; self.displayName = displayName; self.byteCount = byteCount; self.modified = modified
        self.format = format; self.contentConfirmed = contentConfirmed; self.metadata = metadata; self.bookmark = bookmark
    }
}

/// Why a file was not added. Each says what was wrong with the choice, in terms of the file (never as a claim about the service).
public enum UploadRefusalReason: Error, Equatable, Sendable {
    case notAFile, folder, unreadable, empty, notAudio, video, protectedAudio, changedWhileReading
    /// The service published this size limit (a transport that published none never produces this).
    case tooLarge(limit: Int64)
    /// Test mode accepts only the app's own synthetic audio.
    case outsideTestFiles
    case duplicate(of: String)
    case uploadsUnavailable
    case needsAccount
    case tooManyAtOnce(Int)
    public var message: String {
        switch self {
        case .notAFile: String(localized: "This isn’t a regular file, so it wasn’t added.")
        case .folder: String(localized: "This is a folder. Choose the audio files inside it instead.")
        case .unreadable: String(localized: "This app couldn’t read this file, so it wasn’t added.")
        case .empty: String(localized: "This file is empty, so it wasn’t added.")
        case .notAudio: String(localized: "This doesn’t look like an audio file, so it wasn’t added.")
        case .video: String(localized: "This is a video file. Uploads to your music library take audio files.")
        case .protectedAudio: String(localized: "This file is copy-protected, so it can’t be uploaded.")
        case .changedWhileReading: String(localized: "This file changed while it was being read. Choose it again once it has finished changing.")
        case .tooLarge(let limit): String(localized: "This file is larger than the \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)) YouTube Music accepts.")
        case .outsideTestFiles: String(localized: "Test mode only accepts the app’s own synthetic audio files.")
        case .duplicate(let name): String(localized: "“\(name)” is already in the upload list.")
        case .uploadsUnavailable: String(localized: "Uploading arrives in a later update, so nothing was added.")
        case .needsAccount: String(localized: "Sign in to YouTube Music to upload. Nothing was added.")
        case .tooManyAtOnce(let limit): String(localized: "This app adds up to \(limit) files at a time. The rest weren’t added.")
        }
    }
}
public struct UploadRefusal: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let name: String
    public let reason: UploadRefusalReason
}

/// Checks one chosen file: that it is a readable, non-empty, regular audio file that holds still while it is read, and describes it.
/// The app's local checks are all this does; whether the service accepts the format or the size is the service's answer to give.
public struct UploadSourceInspector: Sendable {
    public typealias MetadataReader = @Sendable (URL) async -> UploadMetadata?
    /// Which kinds of track a file really holds, or nil when it cannot be read.
    public typealias TrackReader = @Sendable (URL) async -> (audio: Bool, video: Bool)?
    /// A size limit the transport published, or nil when it published none (no limit is assumed).
    public var maximumFileBytes: Int64?
    /// In test mode, the one folder files may come from.
    public var testRoot: URL?
    public var metadata: MetadataReader
    public var tracks: TrackReader
    public init(maximumFileBytes: Int64? = nil, testRoot: URL? = nil, metadata: @escaping MetadataReader = UploadMetadataReader.read,
                tracks: @escaping TrackReader = UploadMetadataReader.trackKinds) {
        self.maximumFileBytes = maximumFileBytes; self.testRoot = testRoot; self.metadata = metadata; self.tracks = tracks
    }

    public func inspect(_ chosen: URL) async -> Result<UploadSource, UploadRefusalReason> {
        guard chosen.isFileURL else { return .failure(.notAFile) }
        let url = chosen.resolvingSymlinksInPath().standardizedFileURL
        if let testRoot {
            let root = testRoot.resolvingSymlinksInPath().standardizedFileURL.path
            guard url.path.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { return .failure(.outsideTestFiles) }
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return .failure(.unreadable) }
        if values.isDirectory == true || values.isPackage == true { return .failure(.folder) }
        guard values.isRegularFile == true, let size = values.fileSize, let modified = values.contentModificationDate else { return .failure(.notAFile) }
        guard size > 0 else { return .failure(.empty) }
        if let limit = maximumFileBytes, Int64(size) > limit { return .failure(.tooLarge(limit: limit)) }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .failure(.unreadable) }
        let head = (try? handle.read(upToCount: 64)) ?? Data()
        try? handle.close()
        let sniffed = UploadAudioFormat.sniff(head)
        let extensionFormat = UploadAudioFormat.extensions[url.pathExtension.lowercased()]
        if sniffed.protected || url.pathExtension.lowercased() == "m4p" { return .failure(.protectedAudio) }
        if sniffed.video { return .failure(.video) }
        var format = sniffed.format, confirmed = sniffed.format != nil
        if UploadAudioFormat.isGenericMPEG4(head) {
            // No brand says audio or video: look at the file's actual tracks.
            if let kinds = await tracks(url) {
                if kinds.video { return .failure(.video) }
                guard kinds.audio else { return .failure(.notAudio) }
                format = .mpeg4Audio; confirmed = true
            } else if extensionFormat == .mpeg4Audio { format = .mpeg4Audio }
            else { return .failure(.notAudio) }
        }
        guard format != nil || extensionFormat != nil else { return .failure(.notAudio) }
        let fallback = url.deletingPathExtension().lastPathComponent
        let read = await metadata(url)
        var fresh = url
        fresh.removeAllCachedResourceValues()
        guard let again = try? fresh.resourceValues(forKeys: keys), again.fileSize == size, again.contentModificationDate == modified else { return .failure(.changedWhileReading) }
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess])
        return .success(UploadSource(path: url.path, displayName: url.lastPathComponent, byteCount: Int64(size), modified: modified, format: format ?? extensionFormat,
                                     contentConfirmed: confirmed,
                                     metadata: read ?? UploadMetadata(title: fallback, titleFromFilename: true), bookmark: bookmark))
    }
}

/// Reads what the file's own tags say with AVFoundation; a file it cannot read is described by its name alone.
public enum UploadMetadataReader {
    /// The kinds of track the file really holds; nil when AVFoundation cannot read it or it holds neither.
    @Sendable public static func trackKinds(_ url: URL) async -> (audio: Bool, video: Bool)? {
        let asset = AVURLAsset(url: url)
        guard let audio = try? await asset.loadTracks(withMediaType: .audio), let video = try? await asset.loadTracks(withMediaType: .video),
              !audio.isEmpty || !video.isEmpty else { return nil }
        return (!audio.isEmpty, !video.isEmpty)
    }
    @Sendable public static func read(_ url: URL) async -> UploadMetadata? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        func value(_ identifier: AVMetadataIdentifier) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier).first,
                  let text = try? await item.load(.stringValue) else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed.utf8.count > 1024 ? nil : trimmed
        }
        let title = await value(.commonIdentifierTitle), artist = await value(.commonIdentifierArtist), album = await value(.commonIdentifierAlbumName)
        let seconds = (try? await asset.load(.duration))?.seconds
        let duration = seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        if title == nil, artist == nil, album == nil, duration == nil { return nil }
        let fallback = url.deletingPathExtension().lastPathComponent
        return UploadMetadata(title: title ?? fallback, artist: artist, album: album, durationSeconds: duration, titleFromFilename: title == nil)
    }
}

// MARK: Scoped read access

public enum UploadFileAccessError: Error, Equatable, Sendable { case unreadable, changed }

/// Read access to one chosen file, held for one job and released the moment the job stops needing it. The app opens files read-only
/// and has no API that writes, moves or deletes one.
public final class UploadFileLease: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var releaseAction: (@Sendable () -> Void)?
    public init(url: URL, release: @escaping @Sendable () -> Void) { self.url = url; releaseAction = release }
    public var isReleased: Bool { lock.withLock { releaseAction == nil } }
    public func release() {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in defer { releaseAction = nil }; return releaseAction }
        action?()
    }
    deinit { release() }
}
public protocol UploadFileAccessing: Sendable {
    /// Opens the file the person chose, provided it is still the file they chose.
    func open(_ source: UploadSource) throws -> UploadFileLease
}
/// Security-scoped read access (a no-op wrapper outside the sandbox), after checking the file still has the size and
/// modification time it had when it was chosen.
public struct ScopedUploadFileAccess: UploadFileAccessing {
    public init() {}
    public func open(_ source: UploadSource) throws -> UploadFileLease {
        var url = source.url
        var scoped: URL?
        if let bookmark = source.bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale),
               resolved.standardizedFileURL.path == source.path, resolved.startAccessingSecurityScopedResource() { scoped = resolved }
        }
        let held = scoped
        let release: @Sendable () -> Void = { held?.stopAccessingSecurityScopedResource() }
        url.removeAllCachedResourceValues()
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]), values.isRegularFile == true,
              FileManager.default.isReadableFile(atPath: url.path) else { release(); throw UploadFileAccessError.unreadable }
        guard values.fileSize.map(Int64.init) == source.byteCount, values.contentModificationDate == source.modified else { release(); throw UploadFileAccessError.changed }
        return UploadFileLease(url: url, release: release)
    }
}
