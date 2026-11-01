import AppKit
import Foundation
import SystemIntegration

// W26 (MAC11, T26.3). The Cocoa scripting layer for `Resources/YTMuse.sdef`.
//
// Each command class builds a `ScriptRequest` from its Apple Event arguments and gives it to `ScriptDispatcher`, which validates it and calls the
// shell (`ScriptingTarget`): the same transport admission as a media key, the same queue command, navigation-only link opening. A class holds no
// state and reaches nothing else. There is no property or command for an account token, a cookie, a header or a request in the dictionary, and
// none in this file.
//
// REAL-DATA SAFETY: an Apple Event that names this application by bundle identifier makes LaunchServices start a copy of the app that is NOT
// isolated when none is running. Tests and probes therefore never send events; they call `ScriptDispatcher` and these classes in-process, or
// address the process id of an isolated instance they launched themselves (`ScriptingIsolationGuardTests` sweeps every test and script for
// `tell application id`).

/// The shell the commands reach. Set at launch, cleared at quit; a command that arrives with none set is refused, not queued.
@MainActor enum ScriptingHost {
    static weak var target: (any ScriptingTarget)?
}

private final class Unchecked<Value>: @unchecked Sendable { let value: Value; init(_ value: Value) { self.value = value } }

/// Base of every command: runs the request on the main actor and replies when it is done (queue insertion awaits the session).
@objc(YTMuseScriptCommand) class YTMuseScriptCommand: NSScriptCommand {
    /// The request this command's arguments describe; nil is an argument error.
    func request() -> ScriptRequest? { nil }
    override func performDefaultImplementation() -> Any? {
        guard let request = request() else {
            scriptErrorNumber = ScriptRefusal.invalidArgument.code; scriptErrorString = ScriptRefusal.invalidArgument.message
            return nil
        }
        suspendExecution()
        let box = Unchecked(self)
        Task { @MainActor in
            let command = box.value
            if let target = ScriptingHost.target {
                if let refusal = await ScriptDispatcher.perform(request, on: target) { command.scriptErrorNumber = refusal.code; command.scriptErrorString = refusal.message }
            } else {
                command.scriptErrorNumber = ScriptRefusal.nothingPlaying.code; command.scriptErrorString = ScriptRefusal.nothingPlaying.message
            }
            command.resumeExecution(withResult: nil)
        }
        return nil
    }
    var text: String? { directParameter as? String }
}
@objc(YTMusePlayCommand) final class YTMusePlayCommand: YTMuseScriptCommand { override func request() -> ScriptRequest? { .play } }
@objc(YTMusePauseCommand) final class YTMusePauseCommand: YTMuseScriptCommand { override func request() -> ScriptRequest? { .pause } }
@objc(YTMusePlayPauseCommand) final class YTMusePlayPauseCommand: YTMuseScriptCommand { override func request() -> ScriptRequest? { .playPause } }
@objc(YTMuseNextTrackCommand) final class YTMuseNextTrackCommand: YTMuseScriptCommand { override func request() -> ScriptRequest? { .nextTrack } }
@objc(YTMusePreviousTrackCommand) final class YTMusePreviousTrackCommand: YTMuseScriptCommand { override func request() -> ScriptRequest? { .previousTrack } }
@objc(YTMuseSeekCommand) final class YTMuseSeekCommand: YTMuseScriptCommand {
    override func request() -> ScriptRequest? {
        let arguments = evaluatedArguments ?? [:]
        return Self.makeRequest(to: (arguments["toPosition"] as? NSNumber)?.doubleValue, by: (arguments["byDelta"] as? NSNumber)?.doubleValue)
    }
    /// Exactly one of `to` and `by`.
    static func makeRequest(to: Double?, by: Double?) -> ScriptRequest? {
        switch (to, by) {
        case (let seconds?, nil): .seekTo(seconds)
        case (nil, let delta?): .seekBy(delta)
        default: nil
        }
    }
}
@objc(YTMuseQueueAddCommand) final class YTMuseQueueAddCommand: YTMuseScriptCommand { override func request() -> ScriptRequest? { text.map { .queue($0, placement: .end) } } }
@objc(YTMuseQueueNextCommand) final class YTMuseQueueNextCommand: YTMuseScriptCommand { override func request() -> ScriptRequest? { text.map { .queue($0, placement: .next) } } }
@objc(YTMuseOpenLinkCommand) final class YTMuseOpenLinkCommand: YTMuseScriptCommand { override func request() -> ScriptRequest? { text.map { .openLocation($0) } } }

/// The `track` class of the dictionary: public metadata and the public link only.
@objc(YTMuseScriptTrack) final class YTMuseScriptTrackObject: NSObject, @unchecked Sendable {
    private let track: ScriptTrack
    init(_ track: ScriptTrack) { self.track = track; super.init() }
    @objc var name: String { track.name }
    @objc var artist: String? { track.artist }
    @objc var duration: NSNumber? { track.duration.map { NSNumber(value: $0) } }
    @objc var position: NSNumber? { track.position.map { NSNumber(value: $0) } }
    @objc var publicLink: String? { track.url }
    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let application = NSScriptClassDescription(for: NSApplication.self) else { return nil }
        return NSPropertySpecifier(containerClassDescription: application, containerSpecifier: nil, key: "scriptCurrentTrack")
    }
}

/// The `application` properties of the dictionary.
extension NSApplication {
    @objc var scriptPlayerState: String { MainActor.assumeIsolated { ScriptingHost.target?.playerState.rawValue ?? ScriptPlayerState.stopped.rawValue } }
    @objc var scriptCurrentTrack: YTMuseScriptTrackObject? { MainActor.assumeIsolated { ScriptingHost.target?.currentTrack.map(YTMuseScriptTrackObject.init) } }
    @objc var scriptVolume: Int {
        get { MainActor.assumeIsolated { ScriptingHost.target?.volumePercent ?? 0 } }
        set {
            MainActor.assumeIsolated {
                guard let command = NSScriptCommand.current() else { return }
                guard let target = ScriptingHost.target else { command.scriptErrorNumber = ScriptRefusal.nothingPlaying.code; command.scriptErrorString = ScriptRefusal.nothingPlaying.message; return }
                // Volume is a synchronous property set; the dispatcher's validation is the same one the other commands use.
                guard (0...100).contains(newValue) else { command.scriptErrorNumber = ScriptRefusal.invalidArgument.code; command.scriptErrorString = ScriptRefusal.invalidArgument.message; return }
                if let refusal = target.setVolume(percent: newValue) { command.scriptErrorNumber = refusal.code; command.scriptErrorString = refusal.message }
            }
        }
    }
}

/// Every Cocoa class the dictionary names, so the linker keeps them and a test can compare them with the file.
enum ScriptingClasses {
    static let commandClasses: [String: AnyClass] = [
        "YTMusePlayCommand": YTMusePlayCommand.self, "YTMusePauseCommand": YTMusePauseCommand.self, "YTMusePlayPauseCommand": YTMusePlayPauseCommand.self,
        "YTMuseNextTrackCommand": YTMuseNextTrackCommand.self, "YTMusePreviousTrackCommand": YTMusePreviousTrackCommand.self, "YTMuseSeekCommand": YTMuseSeekCommand.self,
        "YTMuseQueueAddCommand": YTMuseQueueAddCommand.self, "YTMuseQueueNextCommand": YTMuseQueueNextCommand.self, "YTMuseOpenLinkCommand": YTMuseOpenLinkCommand.self,
    ]
    static let objectClasses: [String: AnyClass] = ["YTMuseScriptTrack": YTMuseScriptTrackObject.self]
}
