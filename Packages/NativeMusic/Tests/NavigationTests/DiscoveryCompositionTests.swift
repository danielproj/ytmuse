#if DEBUG
import Testing
import Foundation
import Features
@testable import AppShell

/// W20: how the application composes Samples, the tuner, Recap, badges and the social surface. Isolated storage only; nothing here
/// plays, signs in or reaches a network.
@Suite(.serialized) @MainActor struct DiscoveryCompositionTests {
    private func withBootstrap(_ environment: [String: String], _ body: (LocalAccountBootstrap) async throws -> Void) async throws {
        let bootstrap = LocalAccountBootstrap(environment: environment)
        let storage = try #require(bootstrap.isolatedStorage)
        do { try await body(bootstrap) } catch { await storage.destroy(); throw error }
        await storage.destroy()
    }
    private let live = ["YTMUSE_UI_TEST_ISOLATED": "1"]
    private let development = ["YTMUSE_UI_TEST_ISOLATED": "1", "YTMUSE_UI_DEVELOPMENT_DATA": "1", "YTMUSE_UI_DEVELOPMENT_LIBRARY": "1", "YTMUSE_UI_DEVELOPMENT_DISCOVERY": "1"]

    @Test func theApplicationsOwnSourcesAreUnresolvedAndSayWhyNothingIsSimulated() async throws {
        try await withBootstrap(live) { bootstrap in
            let discovery = bootstrap.discovery
            #expect(!discovery.development)
            guard case .unresolved(let reason) = discovery.samples.state else { Issue.record("Samples must be unresolved, not \(discovery.samples.state)"); return }
            #expect(reason.contains("Samples aren’t available yet"))
            guard case .unresolved = discovery.summaries.recap, case .unresolved = discovery.summaries.badges else { Issue.record("Recap and badges must be unresolved"); return }
            #expect(discovery.tuner.capability == .noRadio && discovery.tuner.seeds.isEmpty)
            let social = bootstrap.social
            guard case .unresolved = social.state(SocialSubject(kind: .song, id: "vid00000001", title: "x")) else { Issue.record("comments must be unresolved"); return }
            #expect(!social.development && bootstrap.discoveryReadout == nil)
        }
    }
    @Test func theSocialRoleCheckAgreesWithTheLibraryAboutBeingSignedIn() async throws {
        try await withBootstrap(live) { bootstrap in
            #expect(bootstrap.social.isSignedIn == false, "no account: signed out, so every social action is denied")
            #expect(bootstrap.social.songRole() == .signedOut)
        }
        var library = live
        library["YTMUSE_UI_DEVELOPMENT_DATA"] = "1"; library["YTMUSE_UI_DEVELOPMENT_LIBRARY"] = "1"
        try await withBootstrap(library) { bootstrap in
            #expect(bootstrap.social.isSignedIn, "the labelled development library is signed in, as its playlists and invitations are")
            #expect(!bootstrap.social.development, "and comments stay unresolved without the discovery flag")
            guard case .unresolved = bootstrap.social.state(SocialSubject(kind: .song, id: "vid00000001", title: "x")) else { Issue.record("comments must stay unresolved"); return }
        }
    }
    @Test func nothingStartsWhenTheSurfacesAreMadeOrLoaded() async throws {
        try await withBootstrap(live) { bootstrap in
            let discovery = bootstrap.discovery
            await discovery.samples.load(); await discovery.summaries.loadRecap(); await discovery.summaries.loadBadges()
            #expect(discovery.arbiter.active == nil)
            #expect(discovery.samples.readCount == 0 && discovery.summaries.readCount == 0, "an unresolved source is never read")
            #expect(bootstrap.playback.music == nil, "no hidden player was created")
        }
    }
    @Test func theDevelopmentSourcesAppearOnlyWithAllTheFlags() async throws {
        for missing in ["YTMUSE_UI_DEVELOPMENT_DATA", "YTMUSE_UI_DEVELOPMENT_LIBRARY", "YTMUSE_UI_DEVELOPMENT_DISCOVERY"] {
            var environment = development; environment[missing] = nil
            try await withBootstrap(environment) { bootstrap in
                #expect(!bootstrap.discovery.development, "without \(missing)")
                guard case .unresolved = bootstrap.discovery.samples.state else { Issue.record("expected unresolved without \(missing)"); return }
            }
        }
    }
    @Test func theDevelopmentSurfaceIsLabelledAndPreviewsHandOffThroughTheScriptedSessionOnly() async throws {
        try await withBootstrap(development) { bootstrap in
            let discovery = bootstrap.discovery
            #expect(discovery.development)
            await discovery.samples.load()
            #expect(discovery.samples.clips.count == 2)
            await discovery.samples.preview("devclip00001")
            #expect(bootstrap.discoveryReadout?().contains("preview=devclip00001") == true)
            await discovery.samples.preview("devclip00002")
            #expect(bootstrap.discoveryReadout?().contains("preview=devclip00002") == true && bootstrap.discoveryReadout?().contains("overlap=0") == true)
            await discovery.samples.play("devclip00002")
            #expect(bootstrap.discoveryReadout?().contains("preview=none") == true && bootstrap.discoveryReadout?().contains("handoffs=1") == true)
            #expect(bootstrap.playback.music == nil, "the scripted player is not the hidden player")
        }
    }
    @Test func pinnedConditionsKeepDevelopmentPreviewsFromStartingByThemselves() async throws {
        var environment = development; environment["YTMUSE_UI_PREVIEW_CONDITIONS"] = "lowpower"
        try await withBootstrap(environment) { bootstrap in
            let discovery = bootstrap.discovery
            await discovery.samples.load()
            await discovery.samples.focus("devclip00001")
            #expect(discovery.arbiter.active == nil && discovery.arbiter.autoplayRefusal == .lowPowerMode)
            await discovery.samples.preview("devclip00001")
            #expect(discovery.arbiter.active == "devclip00001")
        }
    }
    @Test func theDevelopmentRadioSeedsStartRadiosThroughTheScriptedSessionAndSuppliedControlsAppear() async throws {
        try await withBootstrap(development) { bootstrap in
            let tuner = bootstrap.discovery.tuner
            #expect(tuner.seeds.count == 2)
            await tuner.start(tuner.seeds[0])
            #expect(tuner.context != nil && tuner.controls.map(\.id) == ["devmix"])
            await tuner.choose(option: "devdiscover", in: "devmix")
            #expect(tuner.context?.choices == ["devmix": "devdiscover"])
        }
    }
    @Test func aScopeChangeClearsTheDiscoveryAndSocialState() async throws {
        try await withBootstrap(development) { bootstrap in
            let discovery = bootstrap.discovery
            await discovery.samples.load()
            await discovery.samples.preview("devclip00001")
            discovery.accountChanged(); bootstrap.social.accountChanged()
            await discovery.arbiter.stop(.requested)
            #expect(discovery.samples.state == .idle && discovery.arbiter.active == nil && discovery.tuner.seeds.isEmpty)
        }
    }
}
#endif
