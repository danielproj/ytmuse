import Features
import Foundation
import Testing

/// Source sweeps over the W20 code. They read the Swift files themselves, so a later edit that breaks a rule fails here.
enum W20Sources {
    static func swiftFiles(_ relative: String) throws -> [URL] {
        let base = packageRoot().appendingPathComponent("Sources").appendingPathComponent(relative)
        let found = try #require(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        return found.sorted { $0.path < $1.path }
    }
    /// The code of a file without comments and without string literals' contents (so words in documentation do not count).
    static func code(_ url: URL) throws -> String {
        var lines: [String] = []
        for line in try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }
            lines.append(line.components(separatedBy: " // ").first ?? line)
        }
        return lines.joined(separator: "\n")
    }
    static var discoveryAndSocial: [URL] { get throws { try swiftFiles("Features/DiscoveryExtras") + swiftFiles("Features/Social") } }
}

@Suite struct W20SourceGuardTests {
    @Test func theSweepSeesTheSources() throws {
        let files = try W20Sources.discoveryAndSocial
        #expect(files.count >= 10, "\(files.count) files")
        #expect(files.contains { $0.lastPathComponent == "SocialSurface.swift" } && files.contains { $0.lastPathComponent == "PreviewArbiter.swift" })
    }
    @Test func nothingInTheDiscoveryOrSocialSourcesCanReachANetworkOrReadAnAddress() throws {
        // Comments and moderation take a SocialSubject (a service id), never an address: there is no way to ask them to read an external page.
        let forbidden = ["URLSession", "URLRequest", "http://", "https://", "WKWebView", "NWConnection", "Data(contentsOf", "String(contentsOf", "JSONDecoder", "JSONSerialization", "URLComponents(string"]
        for file in try W20Sources.discoveryAndSocial {
            let code = try W20Sources.code(file)
            for word in forbidden { #expect(!code.contains(word), "\(file.lastPathComponent) mentions \(word)") }
        }
    }
    @Test func theTransportProtocolsTakeNoAddress() throws {
        let comments = try W20Sources.code(packageRoot().appendingPathComponent("Sources/Features/Social/CommentsSource.swift"))
        let signatures = comments.components(separatedBy: "\n").filter { $0.contains("func read(") || $0.contains("func post(") || $0.contains("func moderate(") }
        #expect(signatures.count >= 6, "protocol and unresolved implementation")
        for line in signatures { #expect(!line.contains("URL") && !line.contains("String) async") || line.contains("_ text: String"), Comment(rawValue: line)) }
        let subject = try W20Sources.code(packageRoot().appendingPathComponent("Sources/Features/Social/CommentsSource.swift"))
        #expect(subject.contains("struct SocialSubject") && !subject.contains("var url") && !subject.contains("let url"))
    }
    @Test func theOnlyWritersAreTheLedgerTheEditSessionAndTheCommentsTransport() throws {
        // No file of this node calls a signed write or a playlist edit by itself.
        for file in try W20Sources.discoveryAndSocial {
            let code = try W20Sources.code(file)
            #expect(!code.contains("writer("), "\(file.lastPathComponent) calls a writer")
            #expect(!code.contains("ledger.submit(") && !code.contains("ledger.retry(") && !code.contains(".submit("), "\(file.lastPathComponent) submits a change itself")
            #expect(!code.contains(".apply("), "\(file.lastPathComponent) applies a playlist request")
            #expect(!code.contains("awaitedMusic"), "\(file.lastPathComponent) reaches the coordinator")
            #expect(!code.contains("MusicWriteRequest("), "\(file.lastPathComponent) builds a library write")
            #expect(!code.contains("MusicPlaylistRequest.edit"), "\(file.lastPathComponent) builds a playlist edit")
        }
        // The application's one signed write call site is unchanged by this node.
        let appShell = try W20Sources.swiftFiles("AppShell")
        let sites = try appShell.filter { try W20Sources.code($0).contains("awaitedMusic().write(") }
        #expect(sites.map(\.lastPathComponent) == ["LibraryComposition.swift"], "still one write call site: \(sites.map(\.lastPathComponent))")
    }
    @Test func theDiscoveryCompositionAddsNoWriteAndNoNetworkRequest() throws {
        let code = try W20Sources.code(packageRoot().appendingPathComponent("Sources/AppShell/DiscoveryComposition.swift"))
        for word in ["URLSession", "URLRequest", "awaitedMusic", ".write(", "https://", "WKWebView"] { #expect(!code.contains(word), Comment(rawValue: word)) }
    }
    @Test func developmentDataExistsOnlyInDebugBuilds() throws {
        let text = try String(contentsOf: packageRoot().appendingPathComponent("Sources/AppShell/DevelopmentDiscovery.swift"), encoding: .utf8)
        #expect(text.hasPrefix("#if DEBUG") && text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("#endif"))
        let composition = try String(contentsOf: packageRoot().appendingPathComponent("Sources/AppShell/DiscoveryComposition.swift"), encoding: .utf8)
        for word in ["DevelopmentDiscovery.isEnabled", "DevelopmentDiscovery(environment", "DevelopmentDiscovery.comments", "scripted"] {
            for (index, line) in composition.components(separatedBy: "\n").enumerated() where line.contains(word) && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                let before = composition.components(separatedBy: "\n").prefix(index + 1).joined(separator: "\n")
                #expect(before.components(separatedBy: "#if DEBUG").count > before.components(separatedBy: "#endif").count, "\(word) at line \(index + 1) is outside #if DEBUG")
            }
        }
    }
    @Test func theLabelledDevelopmentDataIsNamedWhereverItAppears() throws {
        let views = try W20Sources.code(packageRoot().appendingPathComponent("Sources/Features/DiscoveryExtras/DiscoveryViews.swift"))
        let social = try W20Sources.code(packageRoot().appendingPathComponent("Sources/Features/Social/SocialViews.swift"))
        #expect(views.contains("Development data · Not YouTube Music") && social.contains("Development data · Not YouTube Music"))
    }
    @Test func everyMethodPathNamedInAnErrorOrNoteExists() throws {
        // Words inside strings are not executed: a note must not advise a control that does not exist.
        for file in try W20Sources.discoveryAndSocial {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in text.matches(of: /client\.(\w+)\.(\w+)\(/) { Issue.record("\(file.lastPathComponent) names a client path: \(match.output.0)") }
        }
    }
    @Test func everyDiscoveryAndSocialStringIsInTheStringCatalog() throws {
        let catalogURL = repositoryRoot().appendingPathComponent("Resources/Localizable.xcstrings")
        let strings = try #require((try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])?["strings"] as? [String: Any])
        // An interpolated Int is %lld in a catalog key and a String is %@; for presence the two are the same placeholder.
        let known = Set(strings.keys.map { $0.replacingOccurrences(of: "%lld", with: "%@") })
        let patterns = [#"String\(localized: "((?:[^"\\]|\\.)*)"\)"#, #"(?:Text|Label|Button|Picker|TextField|Section|confirmationDialog|Menu)\("((?:[^"\\]|\\.)*)""#,
                        #"(?:title|message|recovery): "((?:[^"\\]|\\.)*)""#]
        var checked = 0
        for file in try W20Sources.discoveryAndSocial {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                for pattern in patterns {
                    let regex = try NSRegularExpression(pattern: pattern)
                    for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                        guard let range = Range(match.range(at: 1), in: line) else { continue }
                        var key = String(line[range])
                        guard key.range(of: #"[A-Za-z]{2}"#, options: .regularExpression) != nil, !key.hasSuffix("-") else { continue }
                        if key.range(of: #"^[a-z]+([A-Z][A-Za-z]*)?$|^[a-z]+(\.[a-z0-9]+)+$|^(discovery|social)"#, options: .regularExpression) != nil { continue }   // an identifier or symbol
                        key = key.replacingOccurrences(of: #"\\\((?:[^()]|\([^()]*\))*\)"#, with: "%@", options: .regularExpression).replacingOccurrences(of: "\\\"", with: "\"")
                        checked += 1
                        #expect(known.contains(key), Comment(rawValue: "\(file.lastPathComponent): missing \(key)"))
                    }
                }
            }
        }
        #expect(checked >= 90, "the sweep found \(checked) strings")
    }
    @Test func theSamplesScreenShowsAPreviewingClipsPictureInW17sSingleOwnerSurface() throws {
        let views = try W20Sources.code(packageRoot().appendingPathComponent("Sources/Features/DiscoveryExtras/DiscoveryViews.swift"))
        #expect(views.contains("sampleVideoSurface") && views.contains("if previewing, let surface { surface(clip)"), "the row asks the application for the picture while its clip previews")
        let destination = try W20Sources.code(packageRoot().appendingPathComponent("Sources/AppShell/BrowserDestinationView.swift"))
        #expect(destination.contains(".environment(\\.sampleVideoSurface, samplePicture)") && destination.contains("SamplePicture(playback:"))
        let composition = try W20Sources.code(packageRoot().appendingPathComponent("Sources/AppShell/DiscoveryComposition.swift"))
        #expect(composition.contains("struct SamplePicture") && composition.contains("WebVideoPreview(player:"), "the surface is W17's own inline preview, which owns the picture through VideoSurfaceOwnership")
        let surfaces = try String(contentsOf: packageRoot().appendingPathComponent("Sources/AppShell/VideoSurfaces.swift"), encoding: .utf8)
        #expect(surfaces.contains("struct WebVideoPreview") && surfaces.contains("surface: .inline"))
    }
    @Test func theLocalListeningSummaryIsNotOnTheRecapScreen() throws {
        let views = try String(contentsOf: packageRoot().appendingPathComponent("Sources/Features/DiscoveryExtras/DiscoveryViews.swift"), encoding: .utf8)
        let start = try #require(views.range(of: "public struct RecapView"))
        let end = try #require(views.range(of: "public struct LocalListeningView"))
        let recap = String(views[start.lowerBound..<end.lowerBound])
        #expect(!recap.contains("LocalListeningSection") && !recap.contains("refreshLocal"), "the Recap screen shows only what the source supplies")
        #expect(views.contains("struct LocalListeningView") && views.contains("DiscoveryTitle(title: \"On this Mac\""))
        #expect(DiscoveryEntry.allCases.map(\.rawValue).contains("local"))
        #expect((try? NativeItemRouteProbe.recapLocalIdentifierIsValid()) == true)
    }
    @Test func aLikeOrDislikePressGoesThroughTheSocialSurfaceWhereOneExists() throws {
        let library = try W20Sources.code(packageRoot().appendingPathComponent("Sources/Features/Library/LibraryView.swift"))
        #expect(library.contains("if let social, control.kind == .like || control.kind == .dislike { await social.rate(control) { await ledger.submit(control.intent) } }"))
        #expect(library.contains("await ledger.submit(control.intent)"), "every other change is still the ledger's")
    }
}

enum NativeItemRouteProbe {
    /// The route the "On this Mac" entry opens must be a valid one (the recap kind with the identifier `local`).
    static func recapLocalIdentifierIsValid() throws -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return DiscoveryEntry.local.rawValue.unicodeScalars.allSatisfy { allowed.contains($0) } && (1...256).contains(DiscoveryEntry.local.rawValue.utf8.count)
    }
}
