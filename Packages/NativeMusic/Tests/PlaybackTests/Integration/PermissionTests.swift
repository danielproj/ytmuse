import Foundation
import Testing
@testable import Playback
@testable import SystemIntegration
@testable import AppShell

/// The real-API guard (addendum 5): the system's notification center, authorization request and hot-key registration are named in exactly one file, in the
/// app target. The sweep strips comments and string literals first, so a sentence naming an API is not a use.
enum SystemPermissionGuard {
    static let appTargetFile = "App/Sources/NativeMusicApp.swift"
    /// Names whose use anywhere else would let a test (or a package) reach the real system: the notification center and its authorization request, the
    /// hot-key registration, Apple-event sending, the local network browsers and listeners.
    static let names = ["UNUserNotificationCenter", "requestAuthorization(options", "UNNotificationRequest(", "RegisterEventHotKey", "InstallEventHandler", "CopySymbolicHotKeys",
                        "AESendMessage", "NSAppleScript(", "NWBrowser(", "NetServiceBrowser", "NetService(", "NSBackgroundActivityScheduler",
                        "CLLocationManager(", "AVCaptureDevice.requestAccess"]   // Siri authorization and donations are W24's guard (`IntentDonationGuardTests`)
    nonisolated static func references(under root: URL, directories: [String] = ["Packages", "Tests", "App", "Extensions", "scripts"]) -> [String] {
        var found: [String] = []
        let base = root.resolvingSymlinksInPath().path
        for directory in directories {
            for file in LifecycleSources.swiftFiles(under: root.appendingPathComponent(directory)) {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                for (index, line) in text.components(separatedBy: "\n").enumerated() {
                    let code = LoginItemGuard.stripped(line)
                    for name in names where code.contains(name) { found.append("\(file.resolvingSymlinksInPath().path.replacingOccurrences(of: base + "/", with: "")):\(index + 1): \(name)") }
                }
            }
        }
        return found
    }
    /// A name in the guard's own file is built from pieces, so the sweep reads clean.
    nonisolated static func offenders(_ references: [String]) -> [String] { references.filter { !$0.hasPrefix(appTargetFile + ":") && !isTheCastBrowser($0) } }
    /// W39: the one approved place that browses the local network is the Cast discovery file, and only for the Bonjour browser. It starts nothing until the person
    /// opens the output picker, and its entry point refuses inside a test process (`CastNetworkGate`; `CastNetworkGuardTests` pins both).
    static let castBrowserFile = "Packages/NativeMusic/Sources/OutputRoutes/Cast/CastNetwork.swift"
    nonisolated static func isTheCastBrowser(_ reference: String) -> Bool { reference.hasPrefix(castBrowserFile + ":") && reference.hasSuffix(": NWBrowser(") }
}

/// T26.5 (MAC08, MAC09): permissions are asked for only when the related function is invoked; defaults stay off or unassigned.
@Suite @MainActor struct NotificationOptInTests {
    private func model(_ service: RecordingNotifications) -> (NotificationSettingsModel, InMemoryDefaults) {
        let defaults = InMemoryDefaults()
        return (NotificationSettingsModel(service: service, preferences: defaults), defaults)
    }

    @Test func offByDefaultAndConstructingItNeverAsks() async {
        let service = RecordingNotifications()
        let (model, defaults) = model(service)
        #expect(!model.isOn && model.status == .notDetermined && model.note == nil)
        await model.songChanged(title: "Song", artist: "Artist", isAdvertisement: false)
        #expect(service.requestCount == 0 && service.posted.isEmpty, "a song change with the feature off asks for nothing and posts nothing")
    }

    /// With the system's permission already granted, the feature being off is the ONLY thing that keeps a song change from showing a notification (the first
    /// mutation run found that nothing else tested this: with permission not yet decided the missing permission hid it).
    @Test func permissionAloneNeverMakesTheFeatureOn() async {
        let service = RecordingNotifications(current: .authorized)
        let (model, defaults) = model(service)
        #expect(!model.isOn)
        await model.songChanged(title: "Song", artist: "Artist", isAdvertisement: false)
        #expect(service.posted.isEmpty && service.requestCount == 0, "granted by the system earlier (for another app feature), still off here: nothing is shown")
        await model.setEnabled(true)
        await model.songChanged(title: "Song", artist: "Artist", isAdvertisement: false)
        #expect(service.posted.count == 1)
        await model.setEnabled(false)
        await model.songChanged(title: "Other", artist: nil, isAdvertisement: false)
        #expect(service.posted.count == 1, "turned off again: nothing more")
    }

    @Test func turningItOnIsTheOnlyThingThatRequestsAuthorization() async {
        let service = RecordingNotifications(current: .notDetermined, answer: .authorized)
        let (model, defaults) = model(service)
        await model.setEnabled(true)
        #expect(service.requestCount == 1 && model.isOn && defaults.bool(forKey: NotificationSettingsModel.key))
        await model.setEnabled(false)
        #expect(!model.isOn && !defaults.bool(forKey: NotificationSettingsModel.key) && service.requestCount == 1, "turning it off asks for nothing")
        await model.setEnabled(true)
        #expect(service.requestCount == 1, "already decided: no second prompt")
    }

    @Test func aRefusedPermissionLeavesTheSwitchOffAndSaysWhy() async {
        let service = RecordingNotifications(current: .notDetermined, answer: .denied)
        let (model, defaults) = model(service)
        await model.setEnabled(true)
        #expect(!model.isOn && !defaults.bool(forKey: NotificationSettingsModel.key) && model.status == .denied)
        #expect(model.note?.contains("System Settings") == true)
        let already = RecordingNotifications(current: .denied)
        let (second, defaults2) = self.model(already)
        await second.setEnabled(true)
        #expect(already.requestCount == 0 && !second.isOn, "a refusal already on record is not asked again")
    }

    @Test func aSongChangeShowsTitleAndArtistOnlyAndNeverForAnAdvertisement() async {
        let service = RecordingNotifications(current: .authorized)
        let (model, defaults) = model(service)
        await model.setEnabled(true)
        await model.songChanged(title: "Song", artist: "Artist", isAdvertisement: false)
        await model.songChanged(title: "Advertisement", artist: nil, isAdvertisement: true)
        await model.songChanged(title: "  ", artist: "Artist", isAdvertisement: false)
        await model.songChanged(title: nil, artist: "Artist", isAdvertisement: false)
        #expect(service.posted == [SongNotification(title: "Song", subtitle: "Artist")])
        #expect(Mirror(reflecting: service.posted[0]).children.compactMap(\.label).sorted() == ["subtitle", "title"], "no link, path or account in a notification")
        #expect(SongNotification.make(title: String(repeating: "x", count: 500), artist: "", isAdvertisement: false) == SongNotification(title: String(repeating: "x", count: 200), subtitle: nil))
    }

    @Test func permissionRevokedLaterStopsNotificationsWithoutAskingAgain() async {
        let service = RecordingNotifications(current: .authorized)
        let (model, defaults) = model(service)
        await model.setEnabled(true)
        service.current = .denied
        await model.songChanged(title: "Song", artist: "Artist", isAdvertisement: false)
        #expect(service.posted.isEmpty && service.requestCount == 0 && model.status == .denied)
    }

    @Test func aSongThatStartsPlayingReachesTheNotifierThroughTheShellAndOnlyOnce() async throws {
        let rig = try await IntegrationRig.make(playing: false); defer { rig.cleanUp() }
        rig.notifications.current = .notDetermined
        rig.shell.startIntegration()
        defer { rig.shell.stopIntegration() }
        let model = try #require(rig.shell.notifications)
        try await rig.rig.play()   // the feature is off: nothing is posted, nothing is asked
        try await Task.sleep(for: .milliseconds(150))
        #expect(rig.notifications.requestCount == 0 && rig.notifications.posted.isEmpty)
        await model.setEnabled(true)
        #expect(rig.notifications.requestCount == 1 && model.isOn)
        let page = try #require(rig.rig.log.pages.first)
        page.send(lifecycleState(video: lifecycleOtherVideo, title: "Second Song", artist: "Second Artist"))
        for _ in 0..<40 where rig.notifications.posted.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        #expect(rig.notifications.posted == [SongNotification(title: "Second Song", subtitle: "Second Artist")])
        page.send(lifecycleState(position: 40, video: lifecycleOtherVideo, title: "Second Song", artist: "Second Artist"))
        try await Task.sleep(for: .milliseconds(150))
        #expect(rig.notifications.posted.count == 1, "a position report is not a song change")
        page.send(lifecycleState(video: lifecycleAdVideo, title: "Ad", ad: true))
        try await Task.sleep(for: .milliseconds(150))
        #expect(rig.notifications.posted.count == 1, "an advertisement is never announced")
    }
}

@Suite @MainActor struct PermissionDefaultsTests {
    @Test func everyOptInFeatureIsOffOrUnassignedUntilThePersonActs() async throws {
        let rig = try await IntegrationRig.make(playing: false); defer { rig.cleanUp() }
        rig.shell.startIntegration()
        defer { rig.shell.stopIntegration() }
        #expect(rig.shell.loginItem.status == .notRegistered && !rig.shell.loginItem.isOn, "launch at login is off")
        #expect(rig.shell.notifications?.isOn == false, "song-change notifications are off")
        #expect(rig.shell.globalShortcuts?.assigned.isEmpty == true && rig.hotKeys.registerCalls == 0 && rig.hotKeys.registrations.isEmpty, "global shortcuts are unassigned")
        #expect(rig.notifications.requestCount == 0, "nothing asked the system for notification permission")
        #expect(rig.sharing.presented.isEmpty)
    }

    @Test func theLoginItemHasOnePathAndStartingTheShellNeverRegistersIt() async throws {
        let login = InMemoryLoginItemService()
        let defaults = InMemoryDefaults()
        let rig = try await LifecycleRig.make()
        let shell = ShellCoordinator(playback: rig.model, loginItem: login, application: FakeApplication(), preferences: defaults, installsStatusItem: false)
        shell.startIntegration(); defer { shell.stopIntegration() }
        shell.start()
        #expect(login.registerCount == 0 && login.unregisterCount == 0 && login.status == .notRegistered)
        // W21's guard stands: the real service is named in the app target's one file, and this node added no second path.
        let references = await LifecycleSources.offMain { LoginItemGuard.references(under: LifecycleSources.repositoryRoot) }
        #expect(LoginItemGuard.offenders(references).isEmpty && references.contains { $0.hasPrefix(LoginItemGuard.appTargetFile + ":") })
    }

    @Test func noPermissionPromptingApiIsNamedOutsideTheAppTarget() async {
        let references = await LifecycleSources.offMain { SystemPermissionGuard.references(under: LifecycleSources.repositoryRoot) }
        #expect(references.contains { $0.hasPrefix(SystemPermissionGuard.appTargetFile + ":") && $0.contains("UNUserNotificationCenter") }, "the app target's one file does name the notification center (so this sweep is not vacuous)")
        #expect(references.contains { $0.hasPrefix(SystemPermissionGuard.appTargetFile + ":") && $0.contains("RegisterEventHotKey") })
        #expect(SystemPermissionGuard.offenders(references).isEmpty, "\(SystemPermissionGuard.offenders(references))")
    }

    @Test func theGuardFlagsEachKindOfRealApiWhereverItAppears() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ytmuse-w26-guard-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("Tests"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let planted = SystemPermissionGuard.names.map { name in name.hasSuffix("(options") ? name + ": [.alert])" : name }
        for (index, name) in planted.enumerated() { try ("import Foundation\nlet x\(index) = " + name + "\n").write(to: scratch.appendingPathComponent("Tests/P\(index).swift"), atomically: true, encoding: .utf8) }
        try "// UNUserNotificationCenter in a comment\nlet s = \"RegisterEventHotKey in a string\"\n".write(to: scratch.appendingPathComponent("Tests/Quiet.swift"), atomically: true, encoding: .utf8)
        let found = SystemPermissionGuard.references(under: scratch, directories: ["Tests"])
        for name in SystemPermissionGuard.names { #expect(found.contains { $0.hasSuffix(": " + name) }, "not flagged: \(name)") }
        #expect(!found.contains { $0.contains("Quiet.swift") }, "a comment or a string is not a use")
        #expect(SystemPermissionGuard.offenders(found).count == found.count)
    }

    @Test func nothingRequestsLocalNetworkAutomationOrAnyUsageDescription() async throws {
        let plist = try IntegrationSources.text("App/Info.plist"), entitlements = try IntegrationSources.text("App/NativeMusic.entitlements")
        // W39 (casting): the Local Network question is declared for Cast discovery and nothing else, with its one Bonjour service. It is asked only when the output
        // picker is opened (`CastNetworkGuardTests`, `CastAppTests`).
        #expect(plist.contains("NSLocalNetworkUsageDescription") && plist.contains("<key>NSBonjourServices</key><array><string>_googlecast._tcp</string></array>"))
        for key in ["NSAppleEventsUsageDescription", "NSUserNotificationsUsageDescription", "NSSiriUsageDescription", "NSCameraUsageDescription",
                    "NSMicrophoneUsageDescription", "NSLocationUsageDescription", "NSContactsUsageDescription", "NSCalendarsUsageDescription", "NSBluetoothAlwaysUsageDescription"] {
            #expect(!plist.contains(key), Comment(rawValue: key))
        }
        for key in ["com.apple.security.automation.apple-events", "com.apple.developer.usernotifications", "com.apple.developer.associated-domains", "com.apple.security.network.server", "com.apple.developer.networking.multicast"] {
            #expect(!entitlements.contains(key), Comment(rawValue: key))
        }
        // The listeners in the package: the sign-in redirect's, bound to 127.0.0.1 only (loopback is not the local network and shows no permission prompt), and
        // W39's Cast relay, bound to ONE private-network address, to the receiver's own address only, with a token, a lifetime and no wildcard (`CastRelayTests`).
        let listeners = await IntegrationSources.codeOffMain(under: "Packages/NativeMusic/Sources").filter { $0.text.contains("NWListener") }.map(\.file).sorted()
        #expect(listeners == ["Packages/NativeMusic/Sources/AccountSession/OAuth/NativeOAuthLoopback.swift", "Packages/NativeMusic/Sources/OutputRoutes/Cast/CastRelayServer.swift"])
        #expect(try IntegrationSources.text(listeners[0]).contains("requiredLocalEndpoint = .hostPort(host: \"127.0.0.1\""))
        #expect(try IntegrationSources.text(listeners[1]).contains("requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bindAddress), port: .any)"))
        // And no source browses the local network except casting's one discovery file (W39), which is where that permission belongs.
        var browsers: [String] = []
        for source in await IntegrationSources.codeOffMain(under: "Packages/NativeMusic/Sources") {
            for name in ["NWBrowser", "NetServiceBrowser", "NWPathMonitor(requiredInterfaceType: .wifi", "DNSServiceBrowse", "GCKDiscoveryManager"] where source.text.contains(name) {
                if name == "NWBrowser", source.file == SystemPermissionGuard.castBrowserFile { browsers.append(source.file) } else { Issue.record("\(source.file) names \(name)") }
            }
        }
        #expect(browsers == [SystemPermissionGuard.castBrowserFile], "the Cast discovery file is the one browser")
    }

    @Test func authorizationIsRequestedFromOnePlaceInThePackageAndOnlyByTheSettingsToggle() async throws {
        var sites: [String] = []
        for source in await IntegrationSources.codeOffMain(under: "Packages/NativeMusic/Sources") where source.text.contains(".requestAuthorization()") { sites.append(source.file) }
        #expect(sites == ["Packages/NativeMusic/Sources/AppShell/Integration/ShellIntegration.swift"])
        let text = try IntegrationSources.text("Packages/NativeMusic/Sources/AppShell/Integration/ShellIntegration.swift")
        let body = try #require(text.components(separatedBy: "func setEnabled(_ on: Bool) async {").dropFirst().first?.components(separatedBy: "/// A song started.").first)
        #expect(body.contains("service.requestAuthorization()") && text.components(separatedBy: "service.requestAuthorization()").count == 3, "the request is inside the two toggles' functions and nowhere else")
        // W27: the download and error messages are a second opt-in toggle, and the only other place that asks.
        let statusBody = try #require(text.components(separatedBy: "func setStatusEnabled(_ on: Bool) async {").dropFirst().first?.components(separatedBy: "/// A download finished or failed").first)
        #expect(statusBody.contains("service.requestAuthorization()"), "the status toggle asks, and nothing else does")
        let settings = try IntegrationSources.text("Packages/NativeMusic/Sources/AppShell/Integration/IntegrationSettings.swift")
        #expect(settings.contains("model.setEnabled(on)"))
    }
}

/// Rework 1: these tests leave nothing in `~/Library/Preferences`. Their preferences are in memory.
@Suite struct TestPreferencesStayInMemoryTests {
    @Test func inMemoryDefaultsAnswerLikeTheRealThingAndStayOffTheDisk() {
        let defaults = InMemoryDefaults()
        #expect(defaults.isEmpty && !defaults.bool(forKey: "k") && defaults.object(forKey: "k") == nil && defaults.data(forKey: "k") == nil)
        defaults.set(true, forKey: "b"); defaults.set(Data([1, 2]), forKey: "d"); defaults.set("s", forKey: "s"); defaults.set(3, forKey: "i")
        #expect(defaults.bool(forKey: "b") && defaults.data(forKey: "d") == Data([1, 2]) && defaults.string(forKey: "s") == "s" && defaults.integer(forKey: "i") == 3 && defaults.object(forKey: "b") as? Bool == true)
        defaults.removeObject(forKey: "b")
        #expect(!defaults.bool(forKey: "b") && defaults.object(forKey: "b") == nil)
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/local.native-music.test-w26-in-memory.plist")
        #expect(!FileManager.default.fileExists(atPath: file.path), "a write went to the preferences folder")
    }
    @Test func noW26TestMakesANamedPreferencesSuite() async {
        var users: [String] = []
        for source in await IntegrationSources.codeOffMain(under: "Packages/NativeMusic/Tests/PlaybackTests/Integration") where source.text.contains("UserDefaults(suiteName") { users.append(source.file) }
        #expect(users.isEmpty, "\(users)")
    }
}
