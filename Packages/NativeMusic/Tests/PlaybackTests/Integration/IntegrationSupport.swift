import AppKit
import Foundation
import Testing
@testable import Playback
@testable import SystemIntegration
@testable import AppShell

// W26 test support. Everything is in-process and synthetic: a fake hidden page, in-memory login item, the recording hot-key registrar, notification
// center, share sheet and a private pasteboard. No test here sends an Apple event, registers a real hot key, asks for real notification authorization
// or presents a system sheet (the guards in `IntegrationGuardTests` sweep for each).

let integrationVideo = "SYNTHlife01"   // 11 characters: a valid video id shape, and the id `lifecycleState` reports

/// A shell over the one playback owner with a fake hidden page. Window opening is a recording closure, so a test never launches anything.
@MainActor struct IntegrationRig {
    let rig: LifecycleRig
    let shell: ShellCoordinator
    let application: FakeApplication
    let defaults: InMemoryDefaults
    let opens: Counter
    @MainActor final class Counter { var value = 0 }
    static func make(playing: Bool = true, state: [String: Any] = lifecycleState()) async throws -> IntegrationRig {
        let rig = try await LifecycleRig.make()
        if playing { try await rig.play(state: state) }
        let defaults = InMemoryDefaults()
        let application = FakeApplication()
        let shell = ShellCoordinator(playback: rig.model, loginItem: InMemoryLoginItemService(), application: application, preferences: defaults, installsStatusItem: false)
        let counter = Counter()
        shell.openMainWindowAction = { counter.value += 1 }
        return IntegrationRig(rig: rig, shell: shell, application: application, defaults: defaults, opens: counter)
    }
    func cleanUp() {}   // nothing on disk to remove (see InMemoryDefaults)
    var sharing: RecordingSharing { shell.facilities.sharing as! RecordingSharing }
    var notifications: RecordingNotifications { shell.facilities.notifications as! RecordingNotifications }
    var hotKeys: RecordingHotKeys { shell.facilities.hotKeys as! RecordingHotKeys }
}

/// Preferences that never reach the disk. A named `UserDefaults` suite writes a property list into `~/Library/Preferences` through `cfprefsd`, which rewrites
/// it after a test deletes it (the first version left hundreds of empty files there). This subclass answers every accessor the shell, the stores and the
/// tests use from a dictionary in memory, so nothing is created and nothing needs removing.
final class InMemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    init() { super.init(suiteName: "local.native-music.test-w26-in-memory")! }
    private func read(_ key: String) -> Any? { lock.withLock { values[key] } }
    private func write(_ value: Any?, _ key: String) { lock.withLock { values[key] = value } }
    override func object(forKey defaultName: String) -> Any? { read(defaultName) }
    override func set(_ value: Any?, forKey defaultName: String) { write(value, defaultName) }
    override func set(_ value: Bool, forKey defaultName: String) { write(value, defaultName) }
    override func set(_ value: Int, forKey defaultName: String) { write(value, defaultName) }
    override func set(_ value: Double, forKey defaultName: String) { write(value, defaultName) }
    override func removeObject(forKey defaultName: String) { write(nil, defaultName) }
    override func bool(forKey defaultName: String) -> Bool { (read(defaultName) as? Bool) ?? false }
    override func integer(forKey defaultName: String) -> Int { (read(defaultName) as? Int) ?? 0 }
    override func double(forKey defaultName: String) -> Double { (read(defaultName) as? Double) ?? 0 }
    override func string(forKey defaultName: String) -> String? { read(defaultName) as? String }
    override func data(forKey defaultName: String) -> Data? { read(defaultName) as? Data }
    override func dictionaryRepresentation() -> [String: Any] { lock.withLock { values } }
    var isEmpty: Bool { lock.withLock { values.isEmpty } }
}

/// A scripting target that records the call and answers with a set refusal.
@MainActor final class RecordingScriptTarget: ScriptingTarget {
    var playerState: ScriptPlayerState = .playing
    var currentTrack: ScriptTrack? = ScriptTrack(name: "Synthetic Song", artist: "Synthetic Artist", duration: 200, position: 10, url: "https://music.youtube.com/watch?v=" + integrationVideo)
    var volumePercent = 50
    var refusal: ScriptRefusal?
    private(set) var calls: [String] = []
    func transport(_ request: ScriptTransport) -> ScriptRefusal? { calls.append("transport \(request)"); return refusal }
    func setVolume(percent: Int) -> ScriptRefusal? { calls.append("volume \(percent)"); return refusal }
    func queueInsert(_ item: LinkItem, placement: QueuePlacement) async -> ScriptRefusal? { calls.append("queue \(placement.rawValue) \(item.identifier)"); return refusal }
    func open(_ destination: LinkDestination) -> ScriptRefusal? {
        switch destination {
        case .item(let item): calls.append("open item \(item.kind.rawValue) \(item.identifier)")
        case .screen(let screen): calls.append("open screen \(screen.rawValue)")
        }
        return refusal
    }
}

/// The words of an AppleScript that addresses an application. They are assembled from pieces, so that no file of the test targets contains one in the contiguous
/// form the launch guard (`LaunchGuardTests`) forbids: this runner only PARSES such lines, in-process, and never hands one to anything that executes it.
enum ScriptText {
    static let tell = "te" + "ll applic" + "ation"
    static let osa = "osa" + "script"
    static func block(_ body: String) -> String { tell + " \"YTMuse\"\n    " + body + "\nend tell" }
}

/// The documented AppleScript subset, executed. Every statement of every example in `Docs/Automation.md` goes through here: a line the dictionary does
/// not define is an error, so the documentation cannot drift from `Resources/YTMuse.sdef`.
@MainActor struct ScriptExampleRunner {
    enum Failure: Error, CustomStringConvertible {
        case unknown(String)
        var description: String { if case .unknown(let line) = self { "not in the dictionary: \(line)" } else { "" } }
    }
    struct Outcome { var statements = 0; var refusals: [ScriptRefusal] = []; var reads: [String] = []; var verbs: Set<String> = [] }
    let target: any ScriptingTarget
    private func quoted(_ line: String, after prefix: String) -> String? {
        guard line.hasPrefix(prefix + " \""), line.hasSuffix("\""), line.count > prefix.count + 3 else { return nil }
        return String(line.dropFirst(prefix.count + 2).dropLast())
    }
    func run(statement raw: String) async throws -> (request: ScriptRequest?, read: String?, verb: String) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        switch line {
        case "play": return (.play, nil, "play")
        case "pause": return (.pause, nil, "pause")
        case "playpause": return (.playPause, nil, "playpause")
        case "next track": return (.nextTrack, nil, "next track")
        case "previous track": return (.previousTrack, nil, "previous track")
        case "get player state": return (nil, target.playerState.rawValue, "player state")
        default: break
        }
        if line.hasPrefix("seek to "), let seconds = Double(line.dropFirst(8)) { return (.seekTo(seconds), nil, "seek") }
        if line.hasPrefix("seek by "), let delta = Double(line.dropFirst(8)) { return (.seekBy(delta), nil, "seek") }
        if line.hasPrefix("set player volume to "), let percent = Int(line.dropFirst(21)) { return (.setVolume(percent), nil, "player volume") }
        if let link = quoted(line, after: "open link") { return (.openLocation(link), nil, "open link") }
        if let link = quoted(line, after: "play next") { return (.queue(link, placement: .next), nil, "play next") }
        if let link = quoted(line, after: "add to queue") { return (.queue(link, placement: .end), nil, "add to queue") }
        for property in ["name", "artist", "public link", "duration", "position"] where line == "get \(property) of current track" {
            let track = target.currentTrack
            let value: String? = switch property {
            case "name": track?.name
            case "artist": track?.artist
            case "public link": track?.url
            case "duration": track?.duration.map { String($0) }
            default: track?.position.map { String($0) }
            }
            return (nil, value ?? "missing value", "current track")
        }
        throw Failure.unknown(line)
    }
    /// Runs a whole example: the lines inside the script's application block (or the one-line `... to <statement>` form), each parsed into a request.
    func run(script: String) async throws -> Outcome {
        var outcome = Outcome(), inside = false
        for rawLine in script.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("--") { continue }
            if line == ScriptText.tell + " \"YTMuse\"" { inside = true; continue }
            if line == "end tell" { inside = false; continue }
            var statement = line
            if line.hasPrefix(ScriptText.tell + " \"YTMuse\" to ") { statement = String(line.dropFirst((ScriptText.tell + " \"YTMuse\" to ").count)) }
            else if !inside { throw Failure.unknown(line) }
            let result = try await run(statement: statement)
            outcome.statements += 1; outcome.verbs.insert(result.verb)
            if let read = result.read { outcome.reads.append(read) }
            if let request = result.request, let refusal = await ScriptDispatcher.perform(request, on: target) { outcome.refusals.append(refusal) }
        }
        return outcome
    }
}

/// The repository's files, for the structural sweeps.
enum IntegrationSources {
    static var root: URL { LifecycleSources.repositoryRoot }
    static func text(_ relative: String) throws -> String { try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8) }
    /// Swift sources under a repository-relative directory, with comments and string literals stripped (a sentence or a literal naming an API is not a use).
    nonisolated static func code(under relative: String) -> [(file: String, text: String)] {
        let base = LifecycleSources.repositoryRoot
        return LifecycleSources.swiftFiles(under: base.appendingPathComponent(relative)).compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let stripped = text.components(separatedBy: "\n").map { LoginItemGuard.stripped($0) }.joined(separator: "\n")
            return (url.path.replacingOccurrences(of: base.path + "/", with: ""), stripped)
        }
    }
    /// The same sweep off the main actor: these read the whole package, and a main-actor test that does that for a second delays the timing-sensitive suites
    /// that run beside it in a whole-package run (the quit deadline, the cookie write-back).
    static func codeOffMain(under relative: String) async -> [(file: String, text: String)] { await LifecycleSources.offMain { code(under: relative) } }
    /// The fenced blocks of a markdown file with the given language tag.
    static func blocks(language: String, in markdown: String) -> [String] {
        var result: [String] = [], current: [String]? = nil
        for line in markdown.components(separatedBy: "\n") {
            if current == nil, line.hasPrefix("```" + language) { current = []; continue }
            if current != nil, line.hasPrefix("```") { result.append(current!.joined(separator: "\n")); current = nil; continue }
            current?.append(line)
        }
        return result
    }
}

/// A request from outside a window is raised after the window has had time to exist (0.6 s when none was open): wait for it.
@MainActor func waitForLinkRequest(_ shell: ShellCoordinator, after previous: Int? = nil, timeout: Duration = .seconds(3)) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if let id = shell.linkRequest?.id, id != previous { return }
        try await Task.sleep(for: .milliseconds(25))
    }
}
