import CryptoKit
import Foundation
import Security

public struct BundleInfo: Equatable, Sendable {
    public let identifier: String
    public let version: String
    public let build: String
    public init(identifier: String, version: String, build: String) { self.identifier = identifier; self.version = version; self.build = build }
}
public protocol BundleInfoReading: Sendable { func read(app: URL) throws -> BundleInfo }
public protocol DiskImageExtracting: Sendable { func extractApp(from image: URL, into directory: URL) throws -> URL }
public protocol CodeSignatureChecking: Sendable { func verify(app: URL) throws }

/// Reads the Info.plist of an app bundle straight from its file, without loading any code from it.
public struct PlistBundleInfoReader: BundleInfoReading {
    public init() {}
    public func read(app: URL) throws -> BundleInfo {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let id = plist["CFBundleIdentifier"] as? String, let version = plist["CFBundleShortVersionString"] as? String, let build = plist["CFBundleVersion"] as? String
        else { throw UpdateRejection.bundleMismatch("Info.plist") }
        return BundleInfo(identifier: id, version: version, build: build)
    }
}

/// The staged update on disk, written next to the app copy. It is a record of what was verified, not a source of trust: installation re-reads and
/// re-verifies the app itself.
public struct StagedUpdate: Codable, Equatable, Sendable {
    public let version: String
    public let build: Int
    public let bundleIdentifier: String
    public let appPath: String
    public let assetSHA256: String
}

/// Downloads the release asset, proves it is the bytes the signed feed named, opens it, proves the app inside is the release the feed described and
/// is signed by the same identity as the running app, and keeps it staged. Nothing here replaces or launches anything.
public final class UpdateStager: @unchecked Sendable {
    private let network: any UpdateNetwork
    private let extractor: any DiskImageExtracting
    private let signature: any CodeSignatureChecking
    private let info: any BundleInfoReading
    public let root: URL
    let files: UpdateFiles
    public convenience init(root: URL, network: any UpdateNetwork, extractor: any DiskImageExtracting, signature: any CodeSignatureChecking, info: any BundleInfoReading = PlistBundleInfoReader()) {
        self.init(root: root, network: network, extractor: extractor, signature: signature, info: info, files: .standard)
    }
    init(root: URL, network: any UpdateNetwork, extractor: any DiskImageExtracting, signature: any CodeSignatureChecking, info: any BundleInfoReading = PlistBundleInfoReader(), files: UpdateFiles) {
        self.files = files; self.root = root; self.network = network; self.extractor = extractor; self.signature = signature; self.info = info
    }
    var recordURL: URL { root.appendingPathComponent("staged.json") }
    /// The staging folder is wiped and rebuilt for every update, so it must be a folder of its own: only one named "Updates" is ever touched.
    private var rootIsOwnFolder: Bool { root.lastPathComponent == "Updates" && root.pathComponents.count > 2 }

    public func stage(_ release: FeedRelease, running: RunningApplication) async throws -> StagedUpdate {
        guard release.version > running.version, release.build > running.build else { throw UpdateRejection.notNewer }
        guard rootIsOwnFolder, files.permits(root) else { throw UpdateRejection.transport("staging folder") }   // before anything is downloaded or written
        let fm = FileManager.default
        files.wipeStaging(root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let image = root.appendingPathComponent("download.dmg")
        do {
            try await network.download(UpdateRequests.asset(release.asset.url), to: image, maxBytes: release.asset.length)
        } catch let rejection as UpdateRejection { files.wipeStaging(root); throw rejection }
        catch { files.wipeStaging(root); throw UpdateRejection.transport("download") }
        do {
            try Self.verifyAsset(at: image, length: release.asset.length, sha256: release.asset.sha256)
            let extracted = root.appendingPathComponent("app", isDirectory: true)
            try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
            let app = try extractor.extractApp(from: image, into: extracted)
            try Self.verifyBundle(app, matches: release, running: running, info: info)
            try signature.verify(app: app)
            files.remove(image, insideStaging: root)   // keep the verified app, not the image
            let record = StagedUpdate(version: release.version.description, build: release.build, bundleIdentifier: running.bundleIdentifier, appPath: app.path, assetSHA256: release.asset.sha256)
            try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
            return record
        } catch {
            files.wipeStaging(root)
            throw (error as? UpdateRejection) ?? UpdateRejection.transport("staging")
        }
    }

    /// The staged update, if one exists and is still a refusal-free candidate for the running app. A stale or malformed staging is deleted.
    public func staged(running: RunningApplication) -> StagedUpdate? {
        guard let data = try? Data(contentsOf: recordURL), let record = try? JSONDecoder().decode(StagedUpdate.self, from: data),
              let version = AppVersion(record.version), version > running.version, record.build > running.build, record.bundleIdentifier == running.bundleIdentifier,
              URL(fileURLWithPath: record.appPath).standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            discard(); return nil
        }
        return record
    }
    public func discard() { files.wipeStaging(root) }

    static func verifyAsset(at file: URL, length: Int, sha256: String) throws {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        guard size == length else { throw UpdateRejection.assetLengthMismatch }
        guard let handle = try? FileHandle(forReadingFrom: file) else { throw UpdateRejection.assetHashMismatch }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else { throw UpdateRejection.assetHashMismatch }
    }

    /// The app inside the image must BE the release the signed feed described, and newer than the running app, whatever the feed's other fields say.
    static func verifyBundle(_ app: URL, matches release: FeedRelease, running: RunningApplication, info: any BundleInfoReading) throws {
        let found = try info.read(app: app)
        guard found.identifier == running.bundleIdentifier else { throw UpdateRejection.bundleMismatch("identifier") }
        guard let version = AppVersion(found.version), version == release.version else { throw UpdateRejection.bundleMismatch("version") }
        guard Int(found.build) == release.build else { throw UpdateRejection.bundleMismatch("build") }
        guard version > running.version, release.build > running.build else { throw UpdateRejection.notNewer }
    }
}

/// Opens a disk image read-only, without a Finder window, at a mount point inside our own staging folder, copies the one app out, and detaches.
public struct HdiutilExtractor: DiskImageExtracting {
    let files: UpdateFiles
    public init() { files = .standard }
    init(files: UpdateFiles) { self.files = files }
    public func extractApp(from image: URL, into directory: URL) throws -> URL {
        let mount = directory.appendingPathComponent("mount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try Self.run(["attach", "-nobrowse", "-readonly", "-noautoopen", "-noverify", "-mountpoint", mount.path, image.path])
        defer { try? Self.run(["detach", "-force", mount.path]); files.removeMountPoint(mount, insideStaging: directory.deletingLastPathComponent()) }
        let entries = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]).filter { $0.pathExtension == "app" }
        // A link named like an app is refused: the checks would follow it to something outside the image and call it verified.
        guard entries.count == 1, let app = entries.first, let kind = try? app.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]), kind.isSymbolicLink != true, kind.isDirectory == true else { throw UpdateRejection.bundleMismatch("image contents") }
        let copy = directory.appendingPathComponent(app.lastPathComponent, isDirectory: true)
        try files.copy(app, toStaged: copy, insideStaging: directory.deletingLastPathComponent())
        return copy
    }
    private static func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateRejection.bundleMismatch("image") }
    }
}

/// The running app's own designated requirement, read from its code signature. A release is accepted only if it satisfies THAT requirement, so the
/// same Developer ID identity must have signed it, without this repository naming any Team ID. An ad-hoc or unsigned build has no such requirement
/// and cannot update itself.
public enum RunningSignature {
    public static func designatedRequirement(of app: URL? = nil) -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        if let app {
            guard SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess else { return nil }
        } else {
            guard SecCodeCopySelf([], &code) == errSecSuccess, let code, SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess else { return nil }
        }
        guard let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any], dictionary[kSecCodeInfoTeamIdentifier as String] != nil else { return nil }   // ad hoc: no team
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess else { return nil }
        return text as String?
    }
}

/// Verifies a staged app with the system's code-signing check: the signature and every resource must be intact (a changed file fails), nested code
/// is checked, and the app must satisfy the requirement. Strict validation, all architectures.
public struct SecurityCodeSignatureChecker: CodeSignatureChecking {
    public let requirement: String
    public init(requirement: String) { self.requirement = requirement }
    public func verify(app: URL) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { throw UpdateRejection.codeSignature("unreadable") }
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess, let parsed else { throw UpdateRejection.codeSignature("requirement") }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        var errors: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(staticCode, flags, parsed, &errors)
        errors?.release()
        guard status == errSecSuccess else { throw UpdateRejection.codeSignature(status == errSecCSReqFailed ? "requirement not met" : "invalid") }
    }
}
