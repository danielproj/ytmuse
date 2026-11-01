import AppKit
import Foundation
import Testing
import Domain
import AccountSession
@testable import Playback
@testable import AppShell

// W21 test support. Synthetic, sanitized values only: a fake hidden page, a fake Keychain-free cookie source, in-memory application and login item.

let lifecycleMusicFrame = WebMusicFrame(isMainFrame: true, scheme: "https", host: "music.youtube.com", port: 0)
let lifecycleVideo = "SYNTHlife01", lifecycleOtherVideo = "SYNTHlife02", lifecycleAdVideo = "SYNTHlifead"

/// One state report from the hidden page, in the bridge's own schema.
func lifecycleState(doc: Int = 1, load: Int = 1, playing: Bool = true, position: Double = 10, duration: Double = 200, video: String = lifecycleVideo,
                    title: String = "Synthetic Song", artist: String = "Synthetic Artist", ad: Bool = false, playlist: String? = "PLsyntheticLife") -> [String: Any] {
    var body: [String: Any] = ["type": "state", "doc": doc, "load": load, "playing": playing, "buffering": false, "position": position, "duration": duration,
                               "videoId": video, "title": title, "artist": artist, "artwork": "https://lh3.googleusercontent.com/synthetic-art", "ad": ad]
    if let playlist { body["playlistId"] = playlist }
    return body
}

func lifecycleIdentity() throws -> (LocalIdentity, RequestContext) {
    let id = UUID()
    let context = try AccountContext(accountID: id, channelID: ID("UCsyntheticLifecycle"), region: "US")
    let account = try Account(id: id, serviceIdentity: ServiceID("UCsyntheticLifecycle"), context: context, displayName: "Synthetic Listener", credential: try CredentialReference("synthetic-ref"))
    return (LocalIdentity(account: account, state: .connected), RequestContext(account: context, accountGeneration: 4, requestGeneration: 0))
}

/// The one playback owner with a fake hidden page: what every window, the status item and the mini-player share.
@MainActor struct LifecycleRig {
    let log: PageLog
    let authority: AppPlaybackAuthority
    let model: PlaybackModel
    let identity: LocalIdentity
    let context: RequestContext
    static func make(timing: ManualSleepTiming? = nil) async throws -> LifecycleRig {
        let log = PageLog()
        var clocks: (@MainActor () -> any SleepTimerTiming)?
        if let timing { clocks = { timing } }
        let authority = AppPlaybackAuthority(makeMusicPage: { delegate in let page = FakeMusicPage(delegate: delegate); log.pages.append(page); return page }, makeSleepTiming: clocks)
        await authority.configureMusic { _ in FakeCookieSource() }
        let (identity, context) = try lifecycleIdentity()
        try await authority.restorePaused(identity, context: context)
        return LifecycleRig(log: log, authority: authority, model: PlaybackModel(authority: authority), identity: identity, context: context)
    }
    /// A switch of account: the authority's own barrier.
    func detach() async throws {
        try await authority.detach(previous: context, barrier: RequestContext(account: nil, accountGeneration: 9, requestGeneration: 0))
    }
    /// An explicit Play, then the page's first reports (the document commits, then it plays).
    @discardableResult func play(playlist: String = "PLsyntheticLife", state: [String: Any] = lifecycleState()) async throws -> (WebMusicPlayer, FakeMusicPage) {
        _ = await model.playMusic(playlistID: playlist, title: "Synthetic Mix", request: authority.requestOwnedStart())
        let page = try #require(log.pages.first)
        page.commitLast(); page.send(state)
        return (try #require(model.music), page)
    }
}

/// A scripted application: it records every policy change and can be hidden.
@MainActor final class FakeApplication: ApplicationActivating {
    var presence: DockPresence = .regular
    var isHidden = false
    private(set) var changes: [DockPresence] = []
    private(set) var activations = 0
    func setPresence(_ presence: DockPresence) { if self.presence != presence { changes.append(presence) }; self.presence = presence }
    func activate() { activations += 1 }
}

/// A window that is on screen for the census but invisible to the person (transparent, borderless, click-through, one point).
@MainActor func lifecycleWindow(shown: Bool = true) -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 1, height: 1), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true; window.hasShadow = false
    if shown { window.orderFrontRegardless() }
    return window
}

/// Source files of the package and the app target, for the structural guards.
enum LifecycleSources {
    /// The structural sweeps read thousands of lines: they run off the main actor so they never delay the main-actor timing tests beside them.
    static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T { await Task.detached(priority: .utility) { work() }.value }
    nonisolated static var packageRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    nonisolated static var repositoryRoot: URL { packageRoot.deletingLastPathComponent().deletingLastPathComponent() }
    nonisolated static func swiftFiles(under root: URL) -> [URL] {
        // Build output and metadata are never walked into (thousands of files): the sweeps read sources only.
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker {
            if [".build", ".git", ".swiftpm", "DerivedData", "node_modules"].contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            if url.pathExtension == "swift" { found.append(url) }
        }
        return found
    }
    /// Code lines only: comments are stripped so a sentence naming a forbidden API is not a use of it.
    nonisolated static func code(_ file: URL) -> [(line: Int, text: String)] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n").enumerated().map { ($0.offset + 1, ($0.element.components(separatedBy: "//").first ?? $0.element)) }
    }
    nonisolated static func source(_ relative: String) throws -> String { try String(contentsOf: packageRoot.appendingPathComponent(relative), encoding: .utf8) }
}

/// The real login-item guard (addendum 7): the one sweep the tests and the guard's own self-test both run. Comments and string literals are
/// stripped first, so a sentence or a literal that merely names the type is not a use, and NO folder is exempt: the guard's own file is clean
/// because it never writes the name as code. (A name built at run time, for example through the Objective-C runtime, cannot be seen by any
/// name sweep: `isIsolated` and the app's own composition are what keep a launch on the fake at run time.)
enum LoginItemGuard {
    static let appTargetFile = "App/Sources/NativeMusicApp.swift"
    nonisolated static func stripped(_ line: String) -> String {
        // A string literal is erased unless it interpolates (`\(...)` is code); runs of whitespace collapse, so `import  Service...` is still an import.
        var result = line
        let matches = (try? NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*""#))?.matches(in: line, range: NSRange(line.startIndex..., in: line)) ?? []
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result), !result[range].contains("\\(") else { continue }
            result.replaceSubrange(range, with: "\"\"")
        }
        let code = result.components(separatedBy: "//").first ?? result
        return code.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }
    /// "relative/path:line" of every code line under `root`'s source directories that names the real service or imports its framework.
    nonisolated static func references(under root: URL, directories: [String] = ["Packages", "Tests", "App", "Extensions", "scripts"]) -> [String] {
        let service = "SMApp" + "Service", framework = "import Service" + "Management"
        var found: [String] = []
        let base = root.resolvingSymlinksInPath().path
        for directory in directories {
            for file in LifecycleSources.swiftFiles(under: root.appendingPathComponent(directory)) {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                for (index, line) in text.components(separatedBy: "\n").enumerated() {
                    let code = stripped(line)
                    if code.contains(service) || code.contains(framework) { found.append("\(file.resolvingSymlinksInPath().path.replacingOccurrences(of: base + "/", with: "")):\(index + 1)") }
                }
            }
        }
        return found
    }
    /// What the repository's references must be: only the app target's one file.
    nonisolated static func offenders(_ references: [String]) -> [String] { references.filter { !$0.hasPrefix(appTargetFile + ":") } }
}
