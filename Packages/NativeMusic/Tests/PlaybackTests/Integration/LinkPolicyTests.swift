import AppKit
import Foundation
import Testing
@testable import Playback
@testable import SystemIntegration
@testable import AppShell

/// T26.2 (MAC07): malformed hosts, identifiers, encoded action parameters and redirects cannot invoke a command or reach the network. A link only navigates.
@Suite struct LinkPolicyTests {
    static let video = "dQw4w9WgXcQ"
    static let playlist = "PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN"
    static let channel = "UCRr1xG_2WIDs18a6cIiCxeA"
    static let album = "MPREb_AbCdEfGhIjK"

    private func parse(_ text: String) -> Result<LinkDestination, LinkRefusal> { LinkPolicy.parse(text: text) }
    private func item(_ kind: LinkItemKind, _ id: String) -> LinkDestination { .item(LinkItem(kind: kind, identifier: id)!) }

    @Test(arguments: [
        ("https://music.youtube.com/watch?v=dQw4w9WgXcQ", LinkItemKind.song, "dQw4w9WgXcQ"),
        ("https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN", .song, "dQw4w9WgXcQ"),
        ("https://music.youtube.com/watch?v=dQw4w9WgXcQ&si=AbC_dEf-123", .song, "dQw4w9WgXcQ"),
        ("HTTPS://MUSIC.YOUTUBE.COM/watch?v=dQw4w9WgXcQ", .song, "dQw4w9WgXcQ"),
        ("https://www.youtube.com/watch?v=dQw4w9WgXcQ&feature=share", .song, "dQw4w9WgXcQ"),
        ("https://youtube.com/watch?v=dQw4w9WgXcQ", .song, "dQw4w9WgXcQ"),
        ("https://m.youtube.com/watch?v=dQw4w9WgXcQ", .song, "dQw4w9WgXcQ"),
        ("https://youtu.be/dQw4w9WgXcQ", .song, "dQw4w9WgXcQ"),
        ("https://youtu.be/dQw4w9WgXcQ?si=AbC_dEf-123", .song, "dQw4w9WgXcQ"),
        ("https://music.youtube.com/playlist?list=PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN", .playlist, "PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN"),
        ("https://www.youtube.com/playlist?list=PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN", .playlist, "PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN"),
        ("https://music.youtube.com/browse/VLPLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN", .playlist, "PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN"),
        ("https://music.youtube.com/browse/MPREb_AbCdEfGhIjK", .album, "MPREb_AbCdEfGhIjK"),
        ("https://music.youtube.com/browse/UCRr1xG_2WIDs18a6cIiCxeA", .artist, "UCRr1xG_2WIDs18a6cIiCxeA"),
        ("https://music.youtube.com/channel/UCRr1xG_2WIDs18a6cIiCxeA", .artist, "UCRr1xG_2WIDs18a6cIiCxeA"),
        ("https://www.youtube.com/channel/UCRr1xG_2WIDs18a6cIiCxeA", .artist, "UCRr1xG_2WIDs18a6cIiCxeA"),
        ("https://music.youtube.com/browse/MPSPPLabcdefgh", .podcast, "MPSPPLabcdefgh"),
        ("https://music.youtube.com/browse/MPEDabcdefghij", .episode, "MPEDabcdefghij"),
        ("ytmuse://song/dQw4w9WgXcQ", .song, "dQw4w9WgXcQ"),
        ("ytmuse://album/MPREb_AbCdEfGhIjK", .album, "MPREb_AbCdEfGhIjK"),
        ("ytmuse://artist/UCRr1xG_2WIDs18a6cIiCxeA", .artist, "UCRr1xG_2WIDs18a6cIiCxeA"),
        ("ytmuse://playlist/PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN", .playlist, "PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN"),
        ("  https://music.youtube.com/watch?v=dQw4w9WgXcQ\n", .song, "dQw4w9WgXcQ"),
    ] as [(String, LinkItemKind, String)])
    func acceptedLinksOpenTheNamedItemPage(text: String, kind: LinkItemKind, identifier: String) {
        #expect(parse(text) == .success(item(kind, identifier)), "\(text)")
    }

    @Test(arguments: ["home", "explore", "search", "library", "downloads", "history", "uploads", "podcasts", "queue"])
    func theAppSchemeOpensEachScreen(screen: String) {
        #expect(parse("ytmuse://\(screen)") == .success(.screen(LinkScreen(rawValue: screen)!)))
        #expect(parse("ytmuse://\(screen)/") == .success(.screen(LinkScreen(rawValue: screen)!)))
    }

    /// The malicious corpus. Every one is refused; none can name a command, a host that is not the service's, or a local address.
    static let refused: [String] = [
        // Hosts: look-alikes, subdomains, credentials, ports, addresses, local names, trailing dots.
        "https://evil.example/watch?v=dQw4w9WgXcQ", "https://music.youtube.com.evil.example/watch?v=dQw4w9WgXcQ", "https://evil.example/music.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://music.youtube.com@evil.example/watch?v=dQw4w9WgXcQ", "https://user:pw@music.youtube.com/watch?v=dQw4w9WgXcQ", "https://user@music.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://music.youtube.com:443/watch?v=dQw4w9WgXcQ", "https://music.youtube.com:8443/watch?v=dQw4w9WgXcQ", "https://music.youtube.com./watch?v=dQw4w9WgXcQ",
        "https://xmusic.youtube.com/watch?v=dQw4w9WgXcQ", "https://notyoutube.com/watch?v=dQw4w9WgXcQ", "https://music.youtube.co/watch?v=dQw4w9WgXcQ",
        "https://127.0.0.1/watch?v=dQw4w9WgXcQ", "https://127.0.0.1:8080/watch?v=dQw4w9WgXcQ", "https://localhost/watch?v=dQw4w9WgXcQ", "https://[::1]/watch?v=dQw4w9WgXcQ",
        "https://192.168.1.10/watch?v=dQw4w9WgXcQ", "https://169.254.169.254/latest/meta-data", "https://10.0.0.1/", "https://printer.local/watch?v=dQw4w9WgXcQ",
        "https://2130706433/watch?v=dQw4w9WgXcQ", "https://0x7f000001/watch?v=dQw4w9WgXcQ", "https://music.youtube.com%2eevil.example/watch?v=dQw4w9WgXcQ",
        "https://mu\u{0455}ic.youtube.com/watch?v=dQw4w9WgXcQ", "https://music.youtube.com\u{FF0E}evil.example/watch?v=dQw4w9WgXcQ", "https://www.youtube-nocookie.com/watch?v=dQw4w9WgXcQ",
        "https://studio.youtube.com/watch?v=dQw4w9WgXcQ", "https://accounts.google.com/", "https://google.com/search?q=x",
        // Schemes.
        "http://music.youtube.com/watch?v=dQw4w9WgXcQ", "ftp://music.youtube.com/watch?v=dQw4w9WgXcQ", "file:///etc/passwd", "file://localhost/Users/x/secret.mp3",
        "javascript:alert(1)", "data:text/html,<script>1</script>", "vnd.youtube.music://music.youtube.com/watch?v=dQw4w9WgXcQ", "vnd.youtube://dQw4w9WgXcQ", "x-apple.systempreferences:",
        "mailto:a@b.example", "ssh://music.youtube.com/watch?v=dQw4w9WgXcQ", "ws://music.youtube.com/", "intent://music.youtube.com/#Intent;end", "ytmusic://song/dQw4w9WgXcQ",
        // Paths.
        "https://music.youtube.com/", "https://music.youtube.com/watch", "https://music.youtube.com/watch/?v=dQw4w9WgXcQ", "https://music.youtube.com//watch?v=dQw4w9WgXcQ",
        "https://music.youtube.com/watch/../playlist?list=PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN", "https://music.youtube.com/%77atch?v=dQw4w9WgXcQ", "https://music.youtube.com/watch%2F?v=dQw4w9WgXcQ",
        "https://music.youtube.com/browse/", "https://music.youtube.com/browse/MPREb_AbCdEfGhIjK/extra", "https://music.youtube.com/browse/..", "https://music.youtube.com/browse/%2e%2e",
        "https://music.youtube.com/channel/", "https://music.youtube.com/channel/UCRr1xG_2WIDs18a6cIiCxeA/videos", "https://music.youtube.com/library", "https://music.youtube.com/upload",
        "https://music.youtube.com/redirect?q=http%3A%2F%2F127.0.0.1", "https://www.youtube.com/redirect?q=http://127.0.0.1/", "https://www.youtube.com/attribution_link?u=/watch%3Fv%3DdQw4w9WgXcQ",
        "https://www.youtube.com/oembed?url=http://127.0.0.1", "https://youtu.be/", "https://youtu.be/dQw4w9WgXcQ/extra", "https://youtu.be//dQw4w9WgXcQ", "https://www.youtube.com/shorts/dQw4w9WgXcQ",
        "https://www.youtube.com/embed/dQw4w9WgXcQ", "https://www.youtube.com/@someone", "https://www.youtube.com/user/someone", "https://www.youtube.com/results?search_query=x",
        "https://www.youtube.com/browse/MPREb_AbCdEfGhIjK",
        // Identifiers.
        "https://music.youtube.com/watch?v=", "https://music.youtube.com/watch?v=dQw4w9WgXc", "https://music.youtube.com/watch?v=dQw4w9WgXcQQ", "https://music.youtube.com/watch?v=dQw4w9WgXc!",
        "https://music.youtube.com/watch?v=dQw4w9WgXc.", "https://music.youtube.com/watch?v=..%2f..%2fx", "https://music.youtube.com/watch?v=dQw4w9WgXc%00", "https://music.youtube.com/watch?v=dQw4w9WgXc%20",
        "https://music.youtube.com/watch?v=%64Qw4w9WgXcQ", "https://music.youtube.com/watch?list=PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN", "https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=bad",
        "https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=LM", "https://music.youtube.com/playlist?list=LM", "https://music.youtube.com/playlist?list=", "https://music.youtube.com/playlist?list=PL",
        "https://music.youtube.com/playlist?list=XXvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN", "https://music.youtube.com/playlist?list=PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN&v=dQw4w9WgXcQ",
        "https://music.youtube.com/browse/MPREb_", "https://music.youtube.com/browse/MPREb_ab", "https://music.youtube.com/browse/UCshort", "https://music.youtube.com/browse/FEmusic_home",
        "https://music.youtube.com/browse/VLLM", "https://music.youtube.com/channel/UCRr1xG_2WIDs18a6cIiCxe", "https://music.youtube.com/channel/ucRr1xG_2WIDs18a6cIiCxeA",
        "https://music.youtube.com/channel/UCRr1xG_2WIDs18a6cIiCxeA%2Fx", "https://music.youtube.com/watch?v=" + String(repeating: "a", count: 3000),
        // Encoded action parameters, extra parameters, duplicates, fragments.
        "https://music.youtube.com/watch?v=dQw4w9WgXcQ&action=play", "https://music.youtube.com/watch?v=dQw4w9WgXcQ&play=1", "https://music.youtube.com/watch?v=dQw4w9WgXcQ&autoplay=1",
        "https://music.youtube.com/watch?v=dQw4w9WgXcQ&t=30", "https://music.youtube.com/watch?v=dQw4w9WgXcQ&url=http://127.0.0.1/", "https://music.youtube.com/watch?v=dQw4w9WgXcQ&redirect=http://127.0.0.1",
        "https://music.youtube.com/watch?v=dQw4w9WgXcQ%26action%3Dplay", "https://music.youtube.com/watch?v=dQw4w9WgXcQ%3Faction%3Dplay", "https://music.youtube.com/watch?v=dQw4w9WgXcQ&si=%3Caction%3E",
        "https://music.youtube.com/watch?v=dQw4w9WgXcQ&v=dQw4w9WgXcR", "https://music.youtube.com/watch?v=dQw4w9WgXcQ&si=a&si=b", "https://music.youtube.com/watch?v=dQw4w9WgXcQ&si=",
        "https://music.youtube.com/watch?v=dQw4w9WgXcQ&si=" + String(repeating: "a", count: 60), "https://music.youtube.com/watch?v=dQw4w9WgXcQ&feature=A;B", "https://music.youtube.com/watch?v=dQw4w9WgXcQ&feature=%0A",
        "https://music.youtube.com/watch?v=dQw4w9WgXcQ#action=play", "https://music.youtube.com/watch?v=dQw4w9WgXcQ#", "https://music.youtube.com/browse/MPREb_AbCdEfGhIjK?action=play",
        "https://music.youtube.com/browse/MPREb_AbCdEfGhIjK?play=1", "https://music.youtube.com/channel/UCRr1xG_2WIDs18a6cIiCxeA?action=subscribe", "https://youtu.be/dQw4w9WgXcQ?t=30", "https://youtu.be/dQw4w9WgXcQ?list=PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN",
        // The app's own scheme: no action parameters, no commands, no traversal.
        "ytmuse://song/dQw4w9WgXcQ?action=play", "ytmuse://song/dQw4w9WgXcQ?", "ytmuse://song/dQw4w9WgXcQ%3Faction%3Dplay", "ytmuse://song/dQw4w9WgXcQ#play", "ytmuse://song/dQw4w9WgXcQ/extra",
        "ytmuse://song/", "ytmuse://song", "ytmuse://song/..", "ytmuse://song/../../private", "ytmuse://song/%2e%2e%2fprivate", "ytmuse://song/dQw4w9WgXc", "ytmuse://song//dQw4w9WgXcQ",
        "ytmuse://command/play", "ytmuse://play", "ytmuse://pause", "ytmuse://next", "ytmuse://quit", "ytmuse://signout", "ytmuse://settings", "ytmuse://delete/dQw4w9WgXcQ", "ytmuse://like/dQw4w9WgXcQ",
        "ytmuse://library?action=clear", "ytmuse://library/clear", "ytmuse://home?next=ytmuse://quit", "ytmuse://song:80/dQw4w9WgXcQ", "ytmuse://user@song/dQw4w9WgXcQ", "ytmuse:///song/dQw4w9WgXcQ",
        "ytmuse://playlist/LM", "ytmuse://playlist/PLshort", "ytmuse://album/album_1", "ytmuse://SONG/dQw4w9WgXc", "ytmuse:song/dQw4w9WgXcQ",
        // Empty, whitespace and hidden characters.
        "", " ", "\n", "music.youtube.com/watch?v=dQw4w9WgXcQ", "//music.youtube.com/watch?v=dQw4w9WgXcQ", "/watch?v=dQw4w9WgXcQ", "dQw4w9WgXcQ",
        "https://music.youtube.com/watch?v=dQw4w9WgXcQ https://evil.example/", "https://music.youtube.com/watch?v=dQw4w9WgXcQ\nhttps://evil.example/",
        "https://music.youtube.com/watch?v=dQw4w9WgXcQ\r\nX-Injected: 1", "https://music.youtube.com/watch?v=dQw4w9WgXcQ\u{0}", "https://music.youtube.com/wat\tch?v=dQw4w9WgXcQ",
        "https://music.youtube.com/watch?v=dQw4w9WgXcQ\u{202E}", "https://music.youtube.com/watch?v=dQw4w9WgXcQ\u{200B}", "\u{FEFF}https://music.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://music.youtube.com/watch?v=dQw4w9\u{202E}WgXcQ", "https://music.youtube.com/watch?v=dQw4w9WgXc\u{00A0}",
    ]
    @Test(arguments: LinkPolicyTests.refused) func malformedOrMaliciousLinksAreRefused(text: String) {
        let result = parse(text)
        #expect({ if case .failure = result { true } else { false } }(), "should be refused: \(text.debugDescription)")
    }

    @Test func aLinkLongerThanTheBoundIsRefusedBeforeAnythingElse() {
        let long = "https://music.youtube.com/watch?v=dQw4w9WgXcQ&si=" + String(repeating: "a", count: LinkPolicy.maximumLength)
        #expect(parse(long) == .failure(.tooLong))
        #expect(LinkPolicy.parse(URL(string: long)!) == .failure(.tooLong))
    }

    @Test func everyRefusalReachesThePersonAsTheSameSentenceThatNamesNothing() {
        let message = LinkRefusal.message
        for text in Self.refused.prefix(60) where !text.isEmpty {
            for fragment in ["evil", "127.0.0.1", "localhost", "action", "dQw4w9WgXcQ", "javascript", "file:"] { #expect(!message.contains(fragment)) }
        }
        // One string for every case: the policy has no per-reason user text, so a refusal cannot say which part of a link was wrong.
        let reasons: [LinkRefusal] = [.notALink, .tooLong, .scheme, .host, .credentials, .port, .fragment, .path, .identifier, .query, .encoded, .characters]
        #expect(Set(reasons.map { _ in LinkRefusal.message }).count == 1)
    }

    @Test func theLegacyRouteParserAppliesTheSameRules() throws {
        #expect(try NativeItemRoute.parse(URL(string: "https://music.youtube.com/watch?v=dQw4w9WgXcQ")!) == (try NativeItemRoute(kind: .song, identifier: "dQw4w9WgXcQ")))
        #expect(try NativeItemRoute.parse(URL(string: "ytmuse://album/MPREb_AbCdEfGhIjK")!).kind == .album)
        for text in Self.refused.prefix(80) {
            guard let url = URL(string: text) else { continue }
            #expect(throws: (any Error).self, "\(text)") { try NativeItemRoute.parse(url) }
        }
        // A screen is not an item route.
        #expect(throws: (any Error).self) { try NativeItemRoute.parse(URL(string: "ytmuse://library")!) }
    }

    // MARK: A link never runs a command, plays, or fetches

    @MainActor @Test func openingALinkOnlyNavigatesAndNeverStartsPlaybackOrSendsACommandToThePage() async throws {
        let rig = try await IntegrationRig.make(playing: false)
        defer { rig.cleanUp() }
        let before = rig.rig.log.pages.first?.commands.count ?? 0, loads = rig.rig.log.pages.first?.loads.count ?? 0
        let navigation = BrowserNavigation()
        for text in ["https://music.youtube.com/watch?v=dQw4w9WgXcQ", "ytmuse://song/dQw4w9WgXcQ", "https://youtu.be/dQw4w9WgXcQ", "ytmuse://queue", "https://music.youtube.com/playlist?list=" + Self.playlist] {
            guard case .success(let destination) = LinkPolicy.parse(text: text) else { Issue.record("refused \(text)"); continue }
            #expect(LinkNavigation.apply(destination, to: navigation))
        }
        #expect(navigation.session.canBack, "pages were opened")
        #expect(rig.rig.model.music?.snapshot.phase ?? .idle == .idle, "nothing started")
        #expect((rig.rig.log.pages.first?.commands.count ?? 0) == before && (rig.rig.log.pages.first?.loads.count ?? 0) == loads, "nothing was sent to the hidden page")
        #expect(rig.opens.value == 0 && !rig.shell.transport.hasItem)
    }

    @MainActor @Test func aLinkWhilePlayingLeavesThePlayingSongAlone() async throws {
        let rig = try await IntegrationRig.make(playing: true)
        defer { rig.cleanUp() }
        let player = try #require(rig.rig.model.music), page = try #require(rig.rig.log.pages.first)
        let commands = page.commands.count, loads = page.loads.count, title = player.snapshot.title
        #expect(rig.shell.openLink(text: "https://music.youtube.com/watch?v=dQw4w9WgXcQ") == nil)
        #expect(rig.shell.openLink(text: "ytmuse://song/dQw4w9WgXcQ?action=play") != nil, "an action parameter is refused, not run")
        try await waitForLinkRequest(rig.shell)
        #expect(rig.shell.linkRequest?.destination == .item(LinkItem(kind: .song, identifier: "dQw4w9WgXcQ")!))
        #expect(page.commands.count == commands && page.loads.count == loads && player.snapshot.title == title, "no command reached the player")
    }

    /// Input-surface parity: a link pasted, dropped, sent by the Services menu, by AppleScript or by Handoff meets the SAME rules, so a link one surface
    /// refuses no other surface opens.
    @MainActor @Test func everyInputSurfaceAgreesOnEveryLink() async throws {
        let rig = try await IntegrationRig.make(playing: false); defer { rig.cleanUp() }
        let provider = LinkServicesProvider(shell: rig.shell)
        let board = NSPasteboard(name: NSPasteboard.Name("local.native-music.w26-parity-" + UUID().uuidString)); defer { board.releaseGlobally() }
        let sample = Self.refused.filter { !$0.isEmpty } + ["https://music.youtube.com/watch?v=dQw4w9WgXcQ", "ytmuse://library", "https://youtu.be/dQw4w9WgXcQ", "https://music.youtube.com/playlist?list=" + Self.playlist,
                                                            "https://music.youtube.com/browse/" + Self.album, "https://music.youtube.com/channel/" + Self.channel, " https://music.youtube.com/watch?v=dQw4w9WgXcQ "]
        var accepted = 0
        for text in sample {
            let verdict: Bool = { if case .success = LinkPolicy.parse(text: text) { true } else { false } }()
            if verdict { accepted += 1 }
            // The shell (paste, File > Open Link from Clipboard, Services all call it).
            #expect((rig.shell.openLink(text: text) == nil) == verdict, "openLink: \(text.debugDescription)")
            // The Services menu entry (a private pasteboard; the error out-parameter is its refusal).
            // (The pasteboard itself drops a leading byte-order mark, so that one input cannot be compared through it.)
            if !text.contains("\u{FEFF}") {
                board.clearContents(); board.setString(text, forType: .string)
                var serviceError: NSString = ""
                provider.openLink(board, userData: "", error: &serviceError)
                #expect((serviceError.length == 0) == verdict, "Services: \(text.debugDescription)")
            }
            // The window's drop handler (URL or text).
            if case .success? = LinkDrop.destination(from: text) { #expect(verdict, "drop accepted a refused link: \(text.debugDescription)") } else { #expect(!verdict, "drop refused an accepted link: \(text.debugDescription)") }
            // AppleScript's open link.
            let target = RecordingScriptTarget()
            #expect((await ScriptDispatcher.perform(.openLocation(text), on: target) == nil) == verdict, "AppleScript: \(text.debugDescription)")
            #expect(target.calls.isEmpty != verdict)
            // The route parser the window's own onOpenURL still uses, for an item link.
            if let url = URL(string: text.trimmingCharacters(in: .whitespaces)), case .success(.item) = LinkPolicy.parse(url) { #expect((try? NativeItemRoute.parse(url)) != nil) }
            // Handoff: only an https item page the app advertises.
            if verdict, let url = URL(string: text.trimmingCharacters(in: .whitespaces)), url.scheme == "https", case .success(.item(let item)) = LinkPolicy.parse(url) {
                let activity = NSUserActivity(activityType: HandoffActivity.activityType); activity.webpageURL = url
                #expect((HandoffActivity.destination(of: activity) != nil) == HandoffActivity.advertisedKinds.contains(item.kind))
            }
        }
        #expect(accepted >= 7 && accepted < sample.count, "the sample mixes accepted and refused links (\(accepted) of \(sample.count))")
    }

    @Test func linkHandlingNamesNoNetworkingOrProcessApi() {
        // The link policy and everything that applies a link are pure: no fetch, no redirect, no name resolution, no process, no file.
        let forbidden = ["URLSession", "URLRequest", "URLConnection", "NSURLConnection", "CFNetwork", "Network.framework", "NWConnection", "NWBrowser", "NWPathMonitor", "getaddrinfo", "gethostbyname",
                         "WKWebView", ".load(", "loadRequest", "NSWorkspace", "Process(", "NSAppleScript", "FileManager", "Data(contentsOf", "String(contentsOf", "openURL", "open(url"]
        var scanned = 0
        for source in IntegrationSources.code(under: "Packages/NativeMusic/Sources/SystemIntegration").filter({ $0.file.hasSuffix("/Links.swift") }) {
            scanned += 1
            for name in forbidden { #expect(!source.text.contains(name), "\(source.file) names \(name)") }
        }
        #expect(scanned == 1, "the sweep must read the link policy (a sweep over nothing proves nothing)")
        // The same for the function that applies a link and the router that hands it over.
        let integration = (try? IntegrationSources.text("Packages/NativeMusic/Sources/AppShell/Integration/ShellIntegration.swift")) ?? ""
        let applyBody = integration.components(separatedBy: "enum LinkNavigation {").dropFirst().first?.components(separatedBy: "// MARK: Sharing").first ?? ""
        #expect(!applyBody.isEmpty)
        for name in forbidden { #expect(!applyBody.contains(name), "LinkNavigation names \(name)") }
    }

    @Test func universalLinksAreNotRegistered() throws {
        // No associated domains: no domain is under the project's control. Neither the entitlements nor the Info.plist claim one.
        let entitlements = try IntegrationSources.text("App/NativeMusic.entitlements"), plist = try IntegrationSources.text("App/Info.plist")
        for text in [entitlements, plist] {
            #expect(!text.contains("com.apple.developer.associated-domains") && !text.contains("applinks:") && !text.contains("webcredentials:"))
        }
        // The app's one URL scheme is its own.
        #expect(plist.contains("<string>ytmuse</string>") && !plist.contains("<string>https</string>") && !plist.contains("<string>http</string>"))
    }
}

/// The canonical links the app hands out (T26.4): public, minimal, and read back by the same policy.
@Suite struct CanonicalLinkTests {
    @Test(arguments: [(LinkItemKind.song, "dQw4w9WgXcQ"), (.playlist, "PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN"), (.album, "MPREb_AbCdEfGhIjK"), (.artist, "UCRr1xG_2WIDs18a6cIiCxeA"),
                      (.podcast, "MPSPPLabcdefgh"), (.episode, "MPEDabcdefghij")] as [(LinkItemKind, String)])
    func everyCanonicalLinkIsHttpsMusicYoutubeAndRoundTrips(kind: LinkItemKind, identifier: String) throws {
        let url = try #require(CanonicalLink.url(kind: kind, identifier: identifier))
        #expect(url.scheme == "https" && url.host == "music.youtube.com" && url.port == nil && url.user == nil && url.fragment == nil)
        #expect(LinkPolicy.parse(url) == .success(.item(LinkItem(kind: kind, identifier: identifier)!)))
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? []
        #expect(Set(query).isSubset(of: ["v", "list"]), "no tracking, session or account parameter: \(query)")
    }
    @Test func aCanonicalLinkNeverCarriesAnythingButTheItemsIdentifier() {
        #expect(CanonicalLink.song(videoID: "dQw4w9WgXcQ")?.absoluteString == "https://music.youtube.com/watch?v=dQw4w9WgXcQ")
        for bad in ["", "short", "dQw4w9WgXcQ&si=x", "dQw4w9WgXc/", "../../etc", "dQw4w9WgXcQ?x", "token=abc1234", "/Users/me/song.m4a"] { #expect(CanonicalLink.song(videoID: bad) == nil, "\(bad)") }
    }
}
