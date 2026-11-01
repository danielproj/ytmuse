import CryptoKit
import Foundation
import Testing
@testable import Updates
import Domain
@testable import Features
import SystemIntegration
@testable import AccountSession
@testable import YouTubeMusicAdapter
@testable import Playback

// T29.3. No telemetry, advertising SDK, remote code or remote configuration; every destination the application can name is in Docs/Network-Destinations.json (SEC02), and the
// code's own policies, probed with a corpus of hosts at run time, accept nothing outside it. scripts/check-destinations.py runs the same audit on source and on the built
// bundle; this suite is the in-process half and ties the inventory to the policies.

struct Inventory: Decodable {
    struct Entry: Decodable { let host: String }
    let service: [Entry], artwork: [Entry], pageDriven: [Entry], externalLinks: [Entry], local: [Entry], updates: [Entry], documentation: [Entry]
    let telemetryDenyList: [String], deniedEntitlements: [String], allowedUsageDescriptions: [String]
    enum CodingKeys: String, CodingKey { case service, artwork, pageDriven, externalLinks, local, updates, documentation, telemetryDenyList, deniedEntitlements, allowedUsageDescriptions }
    static let current: Inventory = {
        let data = try! Data(contentsOf: Repo.root.appendingPathComponent("Docs/Network-Destinations.json"))
        return try! JSONDecoder().decode(Inventory.self, from: data)
    }()
    var all: [Entry] { service + artwork + pageDriven + externalLinks + local + updates + documentation }
    /// Hosts the application's OWN code may contact: service and artwork entries (and loopback).
    var native: [Entry] { service + artwork }
    func allows(_ host: String, among entries: [Entry]) -> Bool {
        let host = host.lowercased()
        return entries.contains { entry in
            let pattern = entry.host.lowercased()
            return pattern.hasPrefix("*.") ? (host == String(pattern.dropFirst(2)) || host.hasSuffix(String(pattern.dropFirst(1)))) : host == pattern
        }
    }
}

enum HostCorpus {
    static let telemetry = ["www.google-analytics.com", "ssl.google-analytics.com", "app-measurement.com", "firebaseinstallations.googleapis.com", "settings.crashlytics.com", "o1.ingest.sentry.io", "api.mixpanel.com",
                            "api2.amplitude.com", "api.segment.io", "t.appsflyer.com", "app.adjust.com", "api2.branch.io", "data.flurry.com", "bam.nr-data.net", "browser-intake-datadoghq.com", "us.i.posthog.com",
                            "pagead2.googlesyndication.com", "securepubads.g.doubleclick.net", "googleads.g.doubleclick.net", "graph.facebook.com", "ads.example.com", "analytics.example.net"]
    static let hostile = ["evil.example", "music.youtube.com.evil.example", "evilmusic.youtube.com", "youtube.com.evil.example", "127.0.0.1", "localhost", "192.168.1.1", "169.254.169.254", "accounts.google.com.evil.example", "xn--music-3ve.youtube.com", "github.com.evil.example"]
    static let candidates: [String] = {
        var hosts = Set(telemetry + hostile)
        for entry in Inventory.current.all { hosts.insert(entry.host.hasPrefix("*.") ? "probe-sub." + entry.host.dropFirst(2) : entry.host); if entry.host.hasPrefix("*.") { hosts.insert(String(entry.host.dropFirst(2))) } }
        // TH2: the W30 updater's hosts and the look-alikes a redirect policy must refuse.
        hosts.formUnion(["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com", "githubusercontent.com", "raw.githubusercontent.com", "api.github.com", "codeload.github.com", "gist.github.com",
                         "evilgithub.com", "github.com.evil.example", "githubusercontent.com.evil.example", "evilgithubusercontent.com", "xgithub.com", "github.co", "notgithub.com"])
        hosts.formUnion(["yt3.ggpht.com", "yt4.ggpht.com", "lh3.googleusercontent.com", "lh6.googleusercontent.com", "i.ytimg.com", "rr4---sn-abc.googlevideo.com", "www.youtube.com", "m.youtube.com", "youtu.be", "www.googleapis.com"])
        return hosts.sorted()
    }()
}

@Suite("T29.3 destinations") struct DestinationTests {
    static let updatePolicy = UpdateTrustPolicy(publicKeys: [Curve25519.Signing.PrivateKey().publicKey.rawRepresentation], repository: "ytmuse/th2-destination-probe")
    /// A deny-list entry matches from the start of a word, never inside one.
    static func denied(_ word: String, in text: String) -> Bool {
        text.range(of: "(?<![a-z0-9])" + NSRegularExpression.escapedPattern(for: word), options: [.regularExpression, .caseInsensitive]) != nil
    }
    func get(_ host: String, path: String = "/x.jpg") -> URLRequest { var r = URLRequest(url: URL(string: "https://\(host)\(path)")!); r.httpMethod = "GET"; return r }

    @Test func theInventoryIsWellFormedAndNamesEveryClass() {
        let inventory = Inventory.current
        #expect(inventory.service.count >= 8 && inventory.artwork.count >= 3 && inventory.pageDriven.count >= 5 && inventory.local.count == 1 && !inventory.telemetryDenyList.isEmpty)
        #expect(inventory.local.first?.host == "127.0.0.1", "the only local entry is the loopback callback listener")
        #expect(inventory.all.allSatisfy { !$0.host.isEmpty && !$0.host.contains("/") && !$0.host.contains(":") })
        #expect(inventory.updates.map(\.host) == ["github.com", "*.githubusercontent.com"], "updates are opt-in (W30) and named")
    }

    /// Every policy that can start a native request, probed with the corpus: what each accepts is a subset of the inventory (and of the native classes where code, not a page, is the sender).
    @Test func theTransportPoliciesAcceptNothingOutsideTheInventory() async throws {
        let inventory = Inventory.current
        var accepted: [String: Set<String>] = [:]
        for host in HostCorpus.candidates {
            // The signed client: image shape (no credentials) and the music shape (credentials). Each is the only shape it accepts for that host.
            if (try? SignedMusicPolicy.validate(get(host), maximumBytes: 4096)) != nil { accepted["signed.image", default: []].insert(host) }
            var music = URLRequest(url: URL(string: "https://\(host)/youtubei/v1/search?prettyPrint=false")!); music.httpMethod = "POST"; music.httpBody = Data("{}".utf8)
            music.setValue("SAPISID=x", forHTTPHeaderField: "Cookie"); music.setValue("SAPISIDHASH 1_x", forHTTPHeaderField: "Authorization")
            music.setValue(MusicCookieSession.origin, forHTTPHeaderField: "Origin"); music.setValue(MusicCookieSession.origin, forHTTPHeaderField: "X-Origin")
            if (try? SignedMusicPolicy.validate(music, maximumBytes: 4096)) != nil { accepted["signed.music", default: []].insert(host) }
            // The public transport.
            let sent = Counter()
            let transport = DirectPublicTransport(clock: SystemConnectionClock(), execute: { _, _ in sent.bump(); return PublicHTTPResponse(data: Data("{}".utf8), status: 200) })
            var search = URLRequest(url: URL(string: "https://\(host)/youtubei/v1/search?prettyPrint=false")!); search.httpMethod = "POST"; search.httpBody = Data("{}".utf8)
            if (try? await transport.send(search, maximumBytes: 4096)) != nil { accepted["public", default: []].insert(host) }
            // Artwork from a page (the hidden player).
            if WebMusicBridge.allowedArtwork("https://\(host)/a.png") != nil { accepted["hidden-player-artwork", default: []].insert(host) }
            // Sign-in view navigation.
            if let url = URL(string: "https://\(host)/") {
                if MusicSignInNavigation.allows(url, mainFrame: true) { accepted["signin.main", default: []].insert(host) }
                if MusicSignInNavigation.allows(url, mainFrame: false) { accepted["signin.sub", default: []].insert(host) }
                if WebMusicNavigation.allowsMainFrame(url) { accepted["player.main", default: []].insert(host) }
            }
            // TH2 (W30): the updater. A redirect target is accepted only on GitHub's release hosts, and the feed address only when it is exactly the pinned repository's.
            if URLSessionUpdateNetwork.allowedRedirectHost(host) { accepted["updates.redirect", default: []].insert(host) }
            if let policy = Self.updatePolicy, UpdateRequests.feedURL("https://\(host)/\(policy.repository)/releases/latest/download/feed.json", policy: policy) != nil { accepted["updates.feed", default: []].insert(host) }
            // Pasted links.
            if case .success = LinkPolicy.parse(text: "https://\(host)/watch?v=dQw4w9WgXcQ") { accepted["links", default: []].insert(host) }
        }
        #expect(accepted.keys.count >= 7, "every policy accepted at least one host in the corpus: \(accepted.keys.sorted())")
        for (policy, hosts) in accepted {
            #expect(!hosts.isEmpty)
            let allowedSet = policy == "links" || policy == "signin.sub" ? inventory.all : policy.hasPrefix("updates.") ? inventory.updates : inventory.native
            for host in hosts { #expect(inventory.allows(host, among: policy.hasPrefix("signin") ? inventory.all : allowedSet), "\(policy) accepts \(host), which the inventory does not name for that purpose") }
        }
        // The corpus really contains the telemetry hosts, and none of them is accepted by a native-initiated policy.
        let nativePolicies = ["signed.image", "signed.music", "public", "hidden-player-artwork", "links", "player.main", "updates.redirect", "updates.feed"]
        let telemetry = Set(HostCorpus.telemetry), hostile = Set(HostCorpus.hostile)
        for policy in nativePolicies { #expect(accepted[policy, default: []].isDisjoint(with: telemetry.union(hostile)), "\(policy) accepted a telemetry or hostile host: \(accepted[policy, default: []].intersection(telemetry.union(hostile)))") }
        // The sign-in view's subframes and resources are Google's page's business: they may reach Google and YouTube hosts, but not an analytics or advertising one.
        #expect(accepted["signin.sub", default: []].isDisjoint(with: Set(["www.google-analytics.com", "pagead2.googlesyndication.com", "securepubads.g.doubleclick.net", "app-measurement.com", "api.mixpanel.com", "graph.facebook.com"]).subtracting(accepted["signin.sub", default: []].filter { $0.hasSuffix("google.com") || $0.hasSuffix("googleapis.com") })),
                "sign-in subframes accepted an advertising or analytics host")
        // Exact, native: music.youtube.com alone for the API and the player's main frame.
        // TH2 (W30): the updater's own hosts, exactly: github.com for the feed, and github.com plus the release-asset sub-domains for a redirect. No look-alike and no other GitHub host.
        #expect(accepted["updates.feed"] == ["github.com"], "the feed is read from github.com only: \(accepted["updates.feed", default: []].sorted())")
        let redirects = try #require(accepted["updates.redirect"], "the updater accepts at least its release hosts")
        #expect(redirects == ["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com", "raw.githubusercontent.com", "probe-sub.githubusercontent.com"], "redirects are followed to github.com and *.githubusercontent.com only: \(redirects.sorted())")
        #expect(accepted["signed.music"] == ["music.youtube.com"] && accepted["public"] == ["music.youtube.com"] && accepted["player.main"] == ["music.youtube.com"])
    }
    @Test func theHiddenPlayersSubframeRuleRefusesEveryNonWebScheme() {
        for text in ["file:///etc/passwd", "ftp://music.youtube.com/", "http://music.youtube.com/", "ytmuse://library", "javascript:alert(1)", "tel:+1555", "mailto:a@b.example", "itms-apps://x", "x-apple.systempreferences:", "about:config"] {
            #expect(!WebMusicNavigation.allowsSubframe(URL(string: text)), "\(text)")
            #expect(!WebMusicNavigation.allowsMainFrame(URL(string: text)), "\(text)")
        }
        for text in ["https://rr4---sn-abc.googlevideo.com/videoplayback", "blob:https://music.youtube.com/x", "data:text/plain,hi", "about:blank"] { #expect(WebMusicNavigation.allowsSubframe(URL(string: text)), "\(text) (page-driven, by class)") }
    }
    @Test func theTokenExchangeAndSigningKeysLiveOnGoogleHostsOnly() throws {
        let inventory = Inventory.current
        for endpoint in ["token", "revoke"] {
            let request = try DesktopOAuthTokenExchange.form(endpoint: endpoint, values: ["a": "b"])
            #expect(inventory.allows(request.url?.host ?? "", among: inventory.service))
        }
        #expect(throws: DesktopOAuthError.invalidConfiguration) { _ = try DesktopOAuthTokenExchange.form(endpoint: "userinfo", values: [:]) }
        #expect(throws: DesktopOAuthError.invalidConfiguration) { _ = try DesktopOAuthTokenExchange.form(endpoint: "../token", values: [:]) }
        for url in [GoogleJWTVerifier.discoveryURL, GoogleJWTVerifier.keysURL] { #expect(inventory.allows(url.host ?? "", among: inventory.service) && url.scheme == "https") }
    }
    @Test func descriptionLinksAreOpenedByThePersonsBrowserAndOnlyToTheirHosts() throws {
        let inventory = Inventory.current
        for host in CatalogRichText.allowedHosts { #expect(inventory.allows(host, among: inventory.externalLinks + inventory.service), "\(host) is a description link target and is not in the inventory") }
        for host in ["evil.example", "wikipedia.org.evil.example", "evilwikipedia.org", "127.0.0.1", "analytics.example.net"] {
            let run = MusicTextRun(text: "x", url: URL(string: "https://\(host)/a"))
            #expect(CatalogRichText.safeLink(run) == nil, "\(host)")
        }
    }

    // MARK: source and project sweeps

    @Test func noSourceNamesAHostOutsideTheInventoryOrAnAnalyticsSDK() throws {
        let inventory = Inventory.current
        let url = try NSRegularExpression(pattern: #"\b(?:https?|wss?|ftp)://([A-Za-z0-9][A-Za-z0-9.-]*)"#, options: [.caseInsensitive])
        var scanned = 0, hostsSeen = Set<String>()
        for base in ["Packages/NativeMusic/Sources", "App/Sources", "Extensions/Sources"] {
            for file in Repo.swiftFiles(under: base) {
                scanned += 1
                let code = Repo.code(try String(contentsOf: file, encoding: .utf8)), range = NSRange(code.startIndex..., in: code)
                for match in url.matches(in: code, range: range) {
                    let host = String(code[Range(match.range(at: 1), in: code)!]).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    hostsSeen.insert(host)
                    #expect(inventory.allows(host, among: inventory.all), "\(file.lastPathComponent) names \(host)")
                }
                for word in inventory.telemetryDenyList { #expect(!Self.denied(word, in: code), "\(file.lastPathComponent) names \(word)") }
            }
        }
        #expect(scanned > 300 && hostsSeen.contains("music.youtube.com") && hostsSeen.contains("oauth2.googleapis.com"), "the sweep saw the real population (\(scanned) files, \(hostsSeen.count) hosts)")
        // Planted: the rule fires on an unlisted host and on an SDK name.
        #expect(!inventory.allows("telemetry.example.net", among: inventory.all))
        #expect(Self.denied("firebase", in: "import FirebaseAnalytics") && Self.denied("rollbar.com", in: "https://api.rollbar.com/x"))
        #expect(!Self.denied("rollbar.com", in: "NSScroller scrollbar rollbar") && !Self.denied("amplitude.com", in: "let amplitude = peak"), "a word inside a longer word, or a DSP term, is not an SDK")
    }
    @Test func theProjectDeclaresNoExternalDependencyAndNoRemoteExecutableUpdate() throws {
        for manifest in ["Packages/NativeMusic/Package.swift", "Extensions/Package.swift"] { #expect(!Repo.code(try Repo.text(manifest)).contains(".package("), "\(manifest) declares a package dependency") }
        for resolved in ["Packages/NativeMusic/Package.resolved", "Extensions/Package.resolved"] {
            let path = Repo.root.appendingPathComponent(resolved)
            if let data = try? Data(contentsOf: path), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] { #expect((object["pins"] as? [Any])?.isEmpty ?? true, "\(resolved) pins a package") }
        }
        #expect(!(try Repo.text("App/NativeMusic.xcodeproj/project.pbxproj")).contains("XCRemoteSwiftPackageReference"))
        let tool = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: Repo.root.appendingPathComponent("toolchain.json"))) as? [String: Any])
        #expect((tool["external_dependencies"] as? [Any])?.isEmpty == true)
        let remoteCode = ["dl" + "open(", "Process()", "NSTask", "NS" + "AppleScript(source", "JSContext", ".evaluateScript(", "posix_spawn", "SMJobSubmit", "SMAppService.daemon", "loadPlugin"]
        for base in ["Packages/NativeMusic/Sources", "App/Sources", "Extensions/Sources"] {
            for file in Repo.swiftFiles(under: base) {
                let code = Repo.code(try String(contentsOf: file, encoding: .utf8))
                for word in remoteCode {
                    // The one reviewed launch (W30's updater attaches the downloaded image with the system's hdiutil): a fixed path, and no other executable named in the file.
                    if word == "Process()", file.lastPathComponent == "UpdateStaging.swift" {
                        let executables = code.matches(of: /executableURL\s*=\s*URL\(fileURLWithPath:\s*"([^"]+)"/).map { String($0.output.1) }
                        #expect(executables == ["/usr/bin/hdiutil"] && code.contains(word), "the only reviewed process launch is hdiutil at its fixed path: \(executables)")
                        continue
                    }
                    #expect(!code.contains(word), "\(file.lastPathComponent) uses \(word)")
                }
            }
        }
        // Every user script the web views run is a constant compiled into the app, never text that arrived over the network.
        let page = Repo.code(try Repo.text("Packages/NativeMusic/Sources/Playback/WebMusic/WebMusicPage.swift"))
        for line in page.components(separatedBy: "\n") where line.contains("WKUserScript(") { #expect(line.contains("WebMusicScripts."), "\(line)") }
        let signIn = Repo.code(try Repo.text("Packages/NativeMusic/Sources/AccountSession/WebSession/WebMusicSignIn.swift"))
        #expect(signIn.contains("passkeySuppressionSource"))
    }
    @Test func entitlementsAndUsageDescriptionsAreTheLeastTheAppNeeds() throws {
        let inventory = Inventory.current
        var checked = 0
        for file in ["App/NativeMusic.entitlements", "App/NativeMusic-adhoc.entitlements", "Extensions/NativeMusicWidget.entitlements", "Extensions/NativeMusicWidget-adhoc.entitlements", "Tests/AccountSession/TestHost.entitlements"] {
            let text = try Repo.text(file); checked += 1
            for key in inventory.deniedEntitlements { #expect(!text.contains("<key>\(key)</key>"), "\(file) requests \(key)") }
        }
        let app = try Repo.text("App/NativeMusic.entitlements")
        #expect(app.contains("com.apple.security.application-groups"))
        let keys = app.components(separatedBy: "<key>").dropFirst().map { String($0.prefix { $0 != "<" }) }
        #expect(keys == ["com.apple.security.application-groups"], "the signed app asks for the App Group and nothing else: \(keys)")
        let widget = try Repo.text("Extensions/NativeMusicWidget.entitlements")
        #expect(widget.components(separatedBy: "<key>").dropFirst().map { String($0.prefix { $0 != "<" }) } == ["com.apple.security.app-sandbox", "com.apple.security.application-groups"], "the widget extension is sandboxed with the App Group and no network entitlement")
        for plist in ["App/Info.plist", "Extensions/NativeMusicWidget-Info.plist"] {
            let text = try Repo.text(plist); checked += 1
            for match in text.matches(of: /<key>(NS[A-Za-z]+UsageDescription)<\/key>/) { #expect(inventory.allowedUsageDescriptions.contains(String(match.output.1)), "\(plist) declares \(match.output.1) before the feature is activated") }
            #expect(!text.contains("NSAppTransportSecurity"))
        }
        let project = try Repo.text("App/NativeMusic.xcodeproj/project.pbxproj")
        #expect(project.components(separatedBy: "ENABLE_HARDENED_RUNTIME = YES").count > 8, "hardened runtime is on for the app, the widget and the hosts")
        #expect(checked >= 7)
    }
    @Test func theSignInListenerIsLoopbackOnlyAndShortLived() throws {
        let code = Repo.code(try Repo.text("Packages/NativeMusic/Sources/AccountSession/OAuth/NativeOAuthLoopback.swift"))
        #expect(code.contains(#"requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)"#), "bound to loopback on an ephemeral port")
        #expect(code.contains("connections.count < 4") && code.contains("asyncAfter(deadline: .now() + 5)") && code.contains("16_384"), "four connections, five seconds, sixteen kilobytes")
        #expect(!code.contains("0.0.0.0") && !code.contains("::"), "never a wildcard address")
        let flow = Repo.code(try Repo.text("Packages/NativeMusic/Sources/AccountSession/OAuth/DesktopOAuth.swift"))
        #expect(flow.contains("deadline = clock.now() + 180"), "an attempt lives three minutes")
    }
}
