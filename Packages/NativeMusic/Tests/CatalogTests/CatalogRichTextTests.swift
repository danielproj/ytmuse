import AccountSession
import Features
import Foundation
import Testing

/// T11.4: native rich text rejects executable and untrusted payloads, bounds the body, and keeps attribution.
@Suite struct CatalogRichTextTests {
    private func run(_ text: String, _ url: String? = nil) -> MusicTextRun { MusicTextRun(text: text, url: url.flatMap(URL.init(string:))) }
    private func plain(_ value: AttributedString) -> String { String(value.characters) }

    @Test func markupIsShownAsLiteralText() {
        let text = CatalogRichText.make([run("<script>alert(1)</script> <b>bold</b> **x** [a](javascript:alert(1)) <img src=x onerror=alert(1)>")])
        #expect(plain(text.body) == "<script>alert(1)</script> <b>bold</b> **x** [a](javascript:alert(1)) <img src=x onerror=alert(1)>")
        #expect(text.links.isEmpty)
        #expect(text.body.runs.allSatisfy { $0.link == nil })
    }
    @Test(arguments: ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,<script>1</script>", "ftp://creativecommons.org/x", "ytmuse://song/abc",
                      "https://evil.example/phish", "https://creativecommons.org.evil.example/x", "https://user:pw@creativecommons.org/x",
                      "https://creativecommons.org:8443/x", "https://notwikipedia.org/x", "vnd.youtube.music://music.youtube.com/x"])
    func untrustedLinkTargetsNeverBecomeLinks(url: String) {
        let text = CatalogRichText.make([run("see ("), run("the link", url), run(")")])
        #expect(text.links.isEmpty, "\(url)")
        #expect(plain(text.body) == "see (the link)")
    }
    @Test func allowedHostsLinkAndHttpIsUpgraded() {
        let text = CatalogRichText.make([run("Source: "), run("Wikipedia", "https://en.wikipedia.org/wiki/Daft_Punk"), run(" and "), run("licence", "http://creativecommons.org/licenses/by-sa/3.0/legalcode")])
        #expect(text.links.map(\.absoluteString) == ["https://en.wikipedia.org/wiki/Daft_Punk", "https://creativecommons.org/licenses/by-sa/3.0/legalcode"])
    }
    @Test func linkTextThatNamesAnotherHostIsNotALink() {
        let text = CatalogRichText.make([run("https://en.wikipedia.org/wiki/X", "https://creativecommons.org/licenses/by/4.0")])
        #expect(text.links.isEmpty)
        let ok = CatalogRichText.make([run("https://creativecommons.org/licenses/...", "https://creativecommons.org/licenses/by/4.0")])
        #expect(ok.links.count == 1)
    }
    @Test func controlAndDirectionalCharactersAreRemoved() {
        let text = CatalogRichText.make([run("a\u{0}b\u{7}c\u{202E}d\u{2066}e\u{200B}f\u{FEFF}g\r\nh\ti")])
        #expect(plain(text.body) == "abcdefg\nh\ti")
    }
    @Test func blankLinesCollapseAndEdgesAreTrimmed() {
        #expect(plain(CatalogRichText.make([run("\n\n  one\n\n\n\n\ntwo \n\n")]).body) == "one\n\ntwo")
    }
    @Test func bodyIsBoundedAtAWordAndMarkedTruncated() {
        let words = (0..<400).map { "word\($0)" }.joined(separator: " ")
        let text = CatalogRichText.make([run(words)], limit: 100)
        #expect(text.truncated)
        let shown = plain(text.body)
        #expect(shown.hasSuffix("…") && shown.count <= 101)
        #expect(!shown.dropLast().hasSuffix(" ") && words.hasPrefix(String(shown.dropLast())))
        #expect(CatalogRichText.make([run(words)], limit: 100_000).body.characters.count <= CatalogRichText.expandedLimit + 1)
        #expect(!CatalogRichText.make([run("short")], limit: 100).truncated)
    }
    @Test func attributionSurvivesTruncationWhole() {
        let attribution = [run("From Wikipedia ("), run("https://en.wikipedia.org/wiki/Foo", "https://en.wikipedia.org/wiki/Foo"),
                           run(") under Creative Commons Attribution CC-BY-SA 3.0 ("),
                           run("https://creativecommons.org/licenses/...", "https://creativecommons.org/licenses/by-sa/3.0/legalcode"), run(")")]
        let body = (0..<300).map { "sentence\($0)." }.joined(separator: " ")
        let text = CatalogRichText.make([run(body + "\n\n")] + attribution, limit: 120)
        #expect(text.truncated)
        #expect(plain(text.attribution!) == "From Wikipedia (https://en.wikipedia.org/wiki/Foo) under Creative Commons Attribution CC-BY-SA 3.0 (https://creativecommons.org/licenses/...)")
        #expect(text.links.count == 2)
        #expect(!plain(text.body).contains("Wikipedia"))
    }
    @Test func aLinkInTheOnlyParagraphIsNotMistakenForAttribution() {
        let text = CatalogRichText.make([run("Visit "), run("our page", "https://www.youtube.com/@x"), run(" for more.")])
        #expect(text.attribution == nil && text.links.count == 1 && plain(text.body) == "Visit our page for more.")
    }
    @Test func attributionIsBoundedAgainstAbuse() {
        let huge = [run("body\n\n"), run(String(repeating: "x", count: 50_000), "https://en.wikipedia.org/wiki/X")]
        let text = CatalogRichText.make(huge)
        #expect((text.attribution?.characters.count ?? 0) <= 601, "the cap plus the marker")
        #expect(text.truncated && plain(text.attribution!).hasSuffix("…"), "a cut is always marked")
    }
    @Test func emptyInputIsEmpty() {
        #expect(CatalogRichText.make([]).isEmpty && CatalogRichText.make([run("  \n ")]).isEmpty)
    }
    @Test func theRealArtistAndAlbumDescriptionsKeepTheirLicenceLine() throws {
        for capture in [Capture.artist, .album] {
            let header = try #require(realPage(capture).header)
            let text = CatalogRichText.make(header.description, limit: 200)
            #expect(text.truncated, "\(capture) body is bounded")
            let attribution = try #require(text.attribution)
            #expect(plain(attribution).hasPrefix("From Wikipedia") && plain(attribution).contains("Creative Commons"))
            #expect(text.links.count == 2 && Set(text.links.map(\.host)) == ["en.wikipedia.org", "creativecommons.org"])
            #expect(text.links.allSatisfy { $0.scheme == "https" })
        }
    }
    @Test func thePodcastBlurbWithBarePlainURLsStaysPlain() throws {
        let header = try #require(realPage(.podcast).header)
        let text = CatalogRichText.make(header.description, limit: CatalogRichText.expandedLimit)
        #expect(text.links.isEmpty)
        #expect(plain(text.body).contains("royalty-free sound library"))
    }
    // MARK: Rework 1

    @Test func aLinkInTheMiddleDoesNotTurnTheRestIntoACappedAttribution() {
        let long = String(repeating: "A long closing paragraph that belongs to the description. ", count: 30)
        let text = CatalogRichText.make([run("First paragraph.\n\nSecond paragraph with "), run("a link", "https://en.wikipedia.org/wiki/X"), run(" inside.\n\n" + long)], limit: 2000)
        #expect(text.attribution == nil, "the paragraph with the last link is not the last paragraph")
        #expect(plain(text.body).contains("First paragraph.") && plain(text.body).contains("closing paragraph") && !text.truncated)
        #expect(text.links.count == 1)
    }
    @Test func aLongTextIsNeverCutWithoutAMarkerAndShowMoreWidensIt() {
        let long = (0..<200).map { "word\($0)" }.joined(separator: " ")
        let collapsed = CatalogRichText.make([run(long + "\n\nSee "), run("source", "https://en.wikipedia.org/wiki/X")], limit: CatalogRichText.collapsedLimit)
        #expect(collapsed.truncated && plain(collapsed.body).hasSuffix("…"))
        let expanded = CatalogRichText.make([run(long + "\n\nSee "), run("source", "https://en.wikipedia.org/wiki/X")], limit: CatalogRichText.expandedLimit)
        #expect(!expanded.truncated && plain(expanded.body).contains("word199"))
        // An attribution over the collapsed cap is cut with a marker and flagged, so "Show more" is offered; expanded it fits.
        let attribution = String(repeating: "Licence text. ", count: 80)
        let runs = [run("Body.\n\n"), run(attribution, "https://creativecommons.org/licenses/by-sa/3.0/")]
        let cut = CatalogRichText.make(runs, limit: CatalogRichText.collapsedLimit)
        #expect(cut.truncated && plain(cut.attribution!).hasSuffix("…"))
        let whole = CatalogRichText.make(runs, limit: CatalogRichText.expandedLimit)
        #expect(!whole.truncated && !plain(whole.attribution!).hasSuffix("…") && plain(whole.attribution!).count > 600)
    }
    @Test(arguments: ["https://www.youtube.com/redirect?q=https%3A%2F%2Fevil.example%2F", "https://youtube.com/redirect?event=video_description&q=https%3A%2F%2Fevil.example",
                      "https://music.youtube.com/redirect?q=x", "https://m.youtube.com/redirect?q=https%3A%2F%2Fevil.example", "https://gaming.youtube.com/redirect?q=x", "https://a.b.youtube.com/redirect?q=x", "https://www.youtube.com/attribution_link?u=%2Fwatch", "https://www.youtube.com/", "https://youtu.be/"])
    func youTubeRedirectsAndOtherNonContentPathsAreNotLinks(url: String) {
        #expect(CatalogRichText.make([run("x", url)]).links.isEmpty, "\(url)")
    }
    /// Derived from the allowlist itself: every host form the matcher admits for a YouTube entry is path-restricted, whatever the subdomain.
    @Test func everyHostTheAllowlistAdmitsForYouTubeRefusesRedirectsAndNonContentPaths() {
        let entries = CatalogRichText.allowedHosts.filter { $0.contains("youtube") }
        #expect(entries.contains("youtube.com"))
        for entry in entries {
            for prefix in ["", "www.", "m.", "gaming.", "music.", "studio.", "a.b.c."] {
                let host = prefix + entry
                guard CatalogRichText.isYouTube(host) else { continue }
                for path in ["/redirect?q=https%3A%2F%2Fevil.example", "/attribution_link?u=%2Fwatch", "/", "/anything"] {
                    #expect(CatalogRichText.make([run("x", "https://\(host)\(path)")]).links.isEmpty, "\(host)\(path)")
                }
                #expect(CatalogRichText.make([run("x", "https://\(host)/watch?v=aaaaaaaaaaa")]).links.count == 1, "\(host) content still links")
            }
        }
    }
    @Test func youTubeContentPagesStillLink() {
        for url in ["https://www.youtube.com/watch?v=aaaaaaaaaaa", "https://music.youtube.com/playlist?list=PLx", "https://www.youtube.com/channel/UCx", "https://www.youtube.com/@artist",
                    "https://music.youtube.com/browse/MPREb_x", "https://youtu.be/aaaaaaaaaaa"] {
            #expect(CatalogRichText.make([run("x", url)]).links.count == 1, "\(url)")
        }
    }
}
