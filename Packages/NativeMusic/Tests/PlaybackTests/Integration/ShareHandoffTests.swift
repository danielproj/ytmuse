import AppKit
import Foundation
import Testing
@testable import Playback
@testable import SystemIntegration
@testable import AppShell

/// T26.4 (MAC08, MAC12): share only canonical links, on an explicit action; Handoff carries the public URL and context only; the receiving-app limits are stated.
@Suite @MainActor struct ShareTests {
    @Test func nothingIsSharedOrCopiedUntilTheCommandIsChosen() async throws {
        let rig = try await IntegrationRig.make(); defer { rig.cleanUp() }
        _ = rig.shell.transport(.pause); _ = rig.shell.transport(.play)
        _ = rig.shell.openLink(text: "https://music.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(rig.sharing.presented.isEmpty && rig.shell.facilities.pasteboard.string(forType: .string) == nil, "playing and opening links never share or copy")
    }

    @Test func shareHandsOutTheCanonicalLinkOfTheSongThatIsPlayingAndNothingElse() async throws {
        let rig = try await IntegrationRig.make(); defer { rig.cleanUp() }
        let expected = URL(string: "https://music.youtube.com/watch?v=" + integrationVideo)!
        #expect(rig.shell.currentShareLink == expected)
        rig.shell.shareCurrentSong()
        #expect(rig.sharing.presented == [expected])
        rig.shell.copyCurrentSongLink()
        let copied = try #require(rig.shell.facilities.pasteboard.string(forType: .string))
        #expect(copied == expected.absoluteString)
        for fragment in ["si=", "cookie", "token", "SAPISID", "Authorization", "file:", "/Users/", "list=", "signature", "sig=", "expire"] { #expect(!copied.contains(fragment), "\(fragment)") }
        #expect(rig.shell.facilities.pasteboard.name != .general, "an automated launch never touches the person's clipboard")
    }

    @Test func anAdvertisementNothingPlayingAndOwnedAudioHaveNoLinkAndTheCommandsDoNothing() async throws {
        let ad = try await IntegrationRig.make(state: lifecycleState(ad: true)); defer { ad.cleanUp() }
        let idle = try await IntegrationRig.make(playing: false); defer { idle.cleanUp() }
        for rig in [ad, idle] {
            #expect(rig.shell.currentShareLink == nil)
            rig.shell.shareCurrentSong(); rig.shell.copyCurrentSongLink()
            #expect(rig.sharing.presented.isEmpty && rig.shell.facilities.pasteboard.string(forType: .string) == nil)
        }
    }

    @Test func aVideoIdThatIsNotAVideoIdNeverBecomesALink() async throws {
        // The page reports what it reports; the link is built only from an identifier that has a video id's shape.
        let rig = try await IntegrationRig.make(state: lifecycleState(video: "../../etc/passwd")); defer { rig.cleanUp() }
        #expect(rig.shell.currentShareLink == nil)
        let odd = try await IntegrationRig.make(state: lifecycleState(video: "dQw4w9WgXcQ&si=x")); defer { odd.cleanUp() }
        #expect(odd.shell.currentShareLink == nil)
    }

    @Test func theMenuOffersShareAndCopyOnlyThroughTheShellAndSharingIsAnInterface() async throws {
        let scenes = try IntegrationSources.text("Packages/NativeMusic/Sources/AppShell/NativeMusicScenes.swift")
        #expect(scenes.contains("shell.shareCurrentSong()") && scenes.contains("shell.copyCurrentSongLink()") && scenes.contains(".disabled(shell.currentShareLink == nil)"))
        // The system share sheet is named in one place and presented only by `SystemSharing.present`, itself called only by `shareCurrentSong`.
        var users: [String] = []
        for source in await IntegrationSources.codeOffMain(under: "Packages/NativeMusic/Sources") where source.text.contains("NSSharingServicePicker") { users.append(source.file) }
        #expect(users == ["Packages/NativeMusic/Sources/AppShell/Integration/ShellIntegration.swift"])
        let integration = try IntegrationSources.text("Packages/NativeMusic/Sources/AppShell/Integration/ShellIntegration.swift")
        #expect(integration.components(separatedBy: "facilities.sharing.present(").count == 2, "one call site")
        #expect(IntegrationFacilities.choose(isolated: true, hotKeys: nil, notifications: nil).sharing is RecordingSharing, "an isolated launch presents no system sheet")
    }

    // MARK: Share… on items, pages and in the player (SHARE)

    private func performer(_ rig: IntegrationRig) -> AppSearchPerformer {
        AppSearchPerformer(playback: rig.rig.model, pasteboard: rig.shell.facilities.pasteboard, sharing: { rig.shell.facilities.sharing })
    }
    @Test func shareOnAnItemOrPageReachesTheShellsSharingFacilityOnlyForACanonicalMusicLink() async throws {
        let rig = try await IntegrationRig.make(playing: false); defer { rig.cleanUp() }
        let performer = performer(rig)
        let good = [URL(string: "https://music.youtube.com/watch?v=dQw4w9WgXcQ")!, URL(string: "https://music.youtube.com/playlist?list=PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN")!,
                    URL(string: "https://music.youtube.com/channel/UCptBkLZ6XRxoyn8SkUMc_Iw")!, URL(string: "https://music.youtube.com/browse/MPREb_K8qWMWVqXGi")!]
        #expect(rig.sharing.presented.isEmpty, "building the performer or listing offers shares nothing")
        for url in good { #expect(performer.share(link: url)) }
        #expect(rig.sharing.presented == good)
        let before = rig.sharing.presented.count
        for text in ["https://music.youtube.com/watch?v=dQw4w9WgXcQ&si=abc", "https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=RDAMVMdQw4w9WgXcQ", "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                     "http://music.youtube.com/watch?v=dQw4w9WgXcQ", "ytmuse://song/dQw4w9WgXcQ", "file:///Users/someone/song.m4a", "https://evil.example/watch?v=dQw4w9WgXcQ",
                     "https://music.youtube.com/watch?v=dQw4w9WgXcQ#t=30", "https://music.youtube.com/playlist?list=PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN&jct=abcdefghij"] {
            #expect(!performer.share(link: URL(string: text)!), "\(text)")
        }
        #expect(rig.sharing.presented.count == before, "a link that is not exactly the canonical one is never handed to the sheet")
        #expect(rig.shell.facilities.pasteboard.string(forType: .string) == nil && rig.shell.facilities.pasteboard.name != .general, "sharing copies nothing, and an automated launch never touches the clipboard")
    }
    @Test func aPerformerWithoutASharingFacilitySharesNothing() async throws {
        let rig = try await IntegrationRig.make(playing: false); defer { rig.cleanUp() }
        let bare = AppSearchPerformer(playback: rig.rig.model, pasteboard: rig.shell.facilities.pasteboard)
        #expect(!bare.share(link: URL(string: "https://music.youtube.com/watch?v=dQw4w9WgXcQ")!) && rig.sharing.presented.isEmpty)
    }
    @Test func theCurrentSongSharesItsOwnIdThroughTheSameFacilityAndAnAdOrNothingPlayingHasNoPlayerShare() async throws {
        let rig = try await IntegrationRig.make(); defer { rig.cleanUp() }
        #expect(CurrentSongShare.item(for: rig.rig.model.music) == LinkItem(kind: .song, identifier: integrationVideo))
        rig.shell.shareCurrentSong()
        #expect(rig.sharing.presented == [URL(string: "https://music.youtube.com/watch?v=" + integrationVideo)!], "the song, never the radio or queue it plays from")
        let ad = try await IntegrationRig.make(state: lifecycleState(ad: true)); defer { ad.cleanUp() }
        let idle = try await IntegrationRig.make(playing: false); defer { idle.cleanUp() }
        let odd = try await IntegrationRig.make(state: lifecycleState(video: "dQw4w9WgXcQ&si=x")); defer { odd.cleanUp() }
        for other in [ad, idle, odd] { #expect(CurrentSongShare.item(for: other.rig.model.music) == nil) }
        #expect(CurrentSongShare.item(for: nil) == nil, "no player: owned or local media has no Music link")
    }
    @Test func thePlayerSharesTheSongFromItsOwnButtonBesideQueueAndNotFromTheMoreMenu() async throws {
        let rig = try await IntegrationRig.make(); defer { rig.cleanUp() }
        let state = try #require(rig.rig.model.music).snapshot
        #expect(WebCapsuleSecondary.moreItems(state: state, hasSleepTimer: true, canShowVideo: false, episode: false) == [.sleepTimer], "⋯ no longer carries Share")
        #expect(WebCapsuleSecondary.moreItems(state: state, hasSleepTimer: false, canShowVideo: false, episode: false).isEmpty)
        // Both player hosts provide it from their shell, and the button runs nothing but that closure.
        let shellSurfaces = try IntegrationSources.text("Packages/NativeMusic/Sources/AppShell/Lifecycle/ShellPlayerSurfaces.swift")
        let browser = try IntegrationSources.text("Packages/NativeMusic/Sources/AppShell/BrowserShell.swift")
        #expect(shellSurfaces.contains(".environment(\\.shareCurrentSong,") && browser.contains(".environment(\\.shareCurrentSong,"))
        let capsule = try IntegrationSources.text("Packages/NativeMusic/Sources/AppShell/PlayerCapsuleViews.swift")
        #expect(capsule.contains("Button { shareCurrentSong() }") && !capsule.contains("NSSharingServicePicker") && !capsule.contains("ShareLink"))
        #expect(capsule.components(separatedBy: "shareCurrentSong()").count - 1 == 1, "one Share in the player, not a second one in a menu")
        // The trailing group is the bar's, the mini-player's and Now Playing's: Share sits right after Queue there and before ⋯, and with no song to share
        // (an advertisement, a stopped player) it stays in place, disabled, so the controls never shift.
        let group = try #require(capsule.range(of: "@ViewBuilder private func group(")), end = try #require(capsule.range(of: "more(state, episode: episode, edge: edge)", range: group.upperBound..<capsule.endIndex))
        let body = capsule[group.upperBound..<end.lowerBound]
        let queue = try #require(body.range(of: ".accessibilityIdentifier(\"transportQueue\")")), share = try #require(body.range(of: ".accessibilityIdentifier(\"musicShare\")"))
        #expect(queue.upperBound < share.lowerBound)
        #expect(!body[queue.upperBound..<share.lowerBound].contains(".accessibilityIdentifier(\"music"), "nothing sits between Queue and Share")
        #expect(body.contains(".disabled(CurrentSongShare.item(for: player) == nil)"))
    }

    @Test func theServicesEntryOpensALinkThroughTheSameRulesAndRefusesWithOneSentence() async throws {
        let rig = try await IntegrationRig.make(playing: false); defer { rig.cleanUp() }
        let provider = LinkServicesProvider(shell: rig.shell)
        let good = NSPasteboard(name: NSPasteboard.Name("local.native-music.w26-service-" + UUID().uuidString)); defer { good.releaseGlobally() }
        good.clearContents(); good.setString("  https://music.youtube.com/watch?v=dQw4w9WgXcQ  ", forType: .string)
        var error: NSString = ""
        provider.openLink(good, userData: "", error: &error)
        #expect(error == "")
        try await waitForLinkRequest(rig.shell)
        #expect(rig.shell.linkRequest?.destination == .item(LinkItem(kind: .song, identifier: "dQw4w9WgXcQ")!))
        let bad = NSPasteboard(name: NSPasteboard.Name("local.native-music.w26-service-" + UUID().uuidString)); defer { bad.releaseGlobally() }
        bad.clearContents(); bad.setString("https://evil.example/watch?v=dQw4w9WgXcQ", forType: .string)
        let before = rig.shell.linkRequest?.id
        provider.openLink(bad, userData: "", error: &error)
        #expect(error as String == LinkRefusal.message)
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.shell.linkRequest?.id == before)
        let empty = NSPasteboard(name: NSPasteboard.Name("local.native-music.w26-service-" + UUID().uuidString)); defer { empty.releaseGlobally() }
        empty.clearContents()
        error = ""
        provider.openLink(empty, userData: "", error: &error)
        #expect(error as String == LinkRefusal.message)
    }

    @Test func theInfoPlistDeclaresTheServiceWithTheProvidersSelector() throws {
        let plist = try IntegrationSources.text("App/Info.plist")
        #expect(plist.contains("<key>NSServices</key>") && plist.contains("<key>NSMessage</key><string>openLink</string>") && plist.contains("Open in YTMuse"))
        #expect(LinkServicesProvider.instancesRespond(to: NSSelectorFromString("openLink:userData:error:")))
        // It accepts text only: it can be handed a string, never a file.
        #expect(plist.contains("<string>NSStringPboardType</string>") && !plist.contains("NSFilenamesPboardType") && !plist.contains("NSURLPboardType"))
    }
}

@Suite @MainActor struct HandoffTests {
    @Test func anItemPageAdvertisesThePublicLinkAndTheNavigationContextOnly() throws {
        let item = try #require(LinkItem(kind: .song, identifier: "dQw4w9WgXcQ"))
        let handoff = try #require(HandoffActivity(item: item))
        let activity = handoff.makeUserActivity()
        #expect(activity.activityType == "local.native-music.browse" && activity.activityType == HandoffActivity.activityType)
        #expect(activity.webpageURL == URL(string: "https://music.youtube.com/watch?v=dQw4w9WgXcQ"))
        #expect(activity.isEligibleForHandoff && !activity.isEligibleForSearch && !activity.isEligibleForPublicIndexing)
        #expect(activity.userInfo as? [String: String] == ["kind": "song", "identifier": "dQw4w9WgXcQ"])
        #expect(activity.requiredUserInfoKeys == ["kind", "identifier"])
        #expect(activity.title == nil && activity.keywords.isEmpty, "no title or keywords")
    }

    @Test(arguments: [LinkItemKind.song, .album, .artist, .podcast, .episode]) func everyPublicCatalogKindIsAdvertised(kind: LinkItemKind) throws {
        let id = ["song": "dQw4w9WgXcQ", "album": "MPREb_AbCdEfGhIjK", "artist": "UCRr1xG_2WIDs18a6cIiCxeA", "podcast": "MPSPPLabcdefgh", "episode": "MPEDabcdefghij"][kind.rawValue]!
        let handoff = try #require(HandoffActivity(item: LinkItem(kind: kind, identifier: id)))
        #expect(LinkPolicy.parse(handoff.webpageURL) == .success(.item(handoff.item)))
    }

    @Test func aPlaylistAndEveryPrivateScreenAdvertiseNothing() {
        #expect(HandoffActivity(item: LinkItem(kind: .playlist, identifier: "PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN")) == nil, "a playlist may be private")
        #expect(HandoffActivity(item: nil) == nil, "no item page: Library, History, Downloads, the queue")
        #expect(HandoffActivity.advertisedKinds == [.song, .album, .artist, .podcast, .episode])
    }

    @Test func anIncomingActivityIsReadBackThroughTheLinkPolicyAndTheUserInfoIsNeverTrusted() {
        func activity(_ type: String = HandoffActivity.activityType, url: String?, info: [String: Any]? = nil) -> NSUserActivity {
            let made = NSUserActivity(activityType: type)
            made.webpageURL = url.flatMap(URL.init(string:)); made.userInfo = info
            return made
        }
        #expect(HandoffActivity.destination(of: activity(url: "https://music.youtube.com/watch?v=dQw4w9WgXcQ")) == .item(LinkItem(kind: .song, identifier: "dQw4w9WgXcQ")!))
        #expect(HandoffActivity.destination(of: activity(url: "https://music.youtube.com/watch?v=dQw4w9WgXcQ", info: ["kind": "playlist", "identifier": "../../x"])) == .item(LinkItem(kind: .song, identifier: "dQw4w9WgXcQ")!),
                "the URL decides; a hostile user-info is ignored")
        // (NSUserActivity itself refuses any web address that is not http or https, so a hostile activity can only carry one of these.)
        for url in ["https://evil.example/watch?v=dQw4w9WgXcQ", "https://music.youtube.com/watch?v=dQw4w9WgXcQ&action=play", "http://music.youtube.com/watch?v=dQw4w9WgXcQ", "https://127.0.0.1/watch?v=dQw4w9WgXcQ",
                    "https://music.youtube.com/playlist?list=PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN"] {
            #expect(HandoffActivity.destination(of: activity(url: url)) == nil, "\(url)")
        }
        #expect(HandoffActivity.destination(of: activity(url: nil, info: ["kind": "song", "identifier": "dQw4w9WgXcQ"])) == nil, "context alone opens nothing")
        #expect(HandoffActivity.destination(of: activity("com.example.other", url: "https://music.youtube.com/watch?v=dQw4w9WgXcQ")) == nil)
    }

    @Test func anAutomatedLaunchAdvertisesNothingAndTheTypeIsDeclared() throws {
        let browser = try IntegrationSources.text("Packages/NativeMusic/Sources/AppShell/BrowserShell.swift")
        #expect(browser.contains("guard !LaunchStorageDecision.isIsolated, let route = navigation.session.current.item"), "Handoff is gated on a normal launch")
        #expect(browser.contains(".userActivity(HandoffActivity.activityType, isActive: handoff != nil)") && browser.contains(".onContinueUserActivity(HandoffActivity.activityType)"))
        #expect(LaunchStorageDecision.isIsolated, "this test process is isolated, so the page would advertise nothing")
        #expect(try IntegrationSources.text("App/Info.plist").contains("<key>NSUserActivityTypes</key><array><string>local.native-music.browse</string></array>"))
    }

    @Test func theReceivingAppLimitsAreStatedInTheCodeAndTheDocumentation() throws {
        let source = try IntegrationSources.text("Packages/NativeMusic/Sources/SystemIntegration/HandoffAndNotifications.swift")
        let doc = try IntegrationSources.text("Docs/Automation.md")
        for text in [source, doc] {
            #expect(text.contains("same Apple Account") && text.contains("default browser") && text.contains("iPhone companion") && text.contains("Spotify Connect"))
        }
        #expect(doc.contains("Receiving-app limits") && doc.contains("same team"))
    }
}
