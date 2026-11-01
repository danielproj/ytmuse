import Foundation
import Testing
@testable import Updates

private final class Token {}
let repositoryRoot: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

func swiftFiles(under directory: URL) -> [URL] {
    guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
    return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
}
func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

/// T30.2 and T30.3 as source rules: what the updater module may name, and who may press "restart".
@Suite struct UpdaterGuardTests {
    let moduleFiles = swiftFiles(under: repositoryRoot.appendingPathComponent("Packages/NativeMusic/Sources/Updates"))

    @Test func theSweptPopulationIsNotEmpty() {
        #expect(moduleFiles.count >= 8)
        #expect(moduleFiles.contains { $0.lastPathComponent == "UpdateStaging.swift" })
    }
    @Test func theUpdaterNamesNoSharedSessionCookieJarKeychainWebViewOrCodeLoader() {
        for file in moduleFiles {
            let source = text(file)
            for banned in ["URLSession.shared", "HTTPCookieStorage", "URLCredential", "SecItem", "Keychain", "WKWebView", "WebKit", "evaluateJavaScript", "dlopen", "NSAppleScript", "import AppKit", "import SwiftUI", "NSTask", "posix_spawn", "system("] {
                #expect(!source.contains(banned), "\(banned) in \(file.lastPathComponent)")
            }
            for banned in ["import AccountSession", "import Persistence", "import Playback", "import YouTubeMusicAdapter"] { #expect(!source.contains(banned), "\(banned) in \(file.lastPathComponent)") }
        }
    }
    @Test func theOnlyProcessItEverStartsIsHdiutilOnTheStagedImage() {
        let users = moduleFiles.filter { text($0).contains("Process()") }
        #expect(users.map(\.lastPathComponent) == ["UpdateStaging.swift"])
        let source = text(users[0])
        #expect(source.components(separatedBy: "executableURL").count - 1 == 1 && source.contains(#"URL(fileURLWithPath: "/usr/bin/hdiutil")"#))
    }
    @Test func theOnlyCodeLoadedFromADownloadIsNoneAndNothingExecutesDownloadedContent() {
        // The downloaded image is hashed, opened read-only and copied; the updater has no call that runs a file it fetched.
        for file in moduleFiles { for banned in ["NSWorkspace", "launchApplication", "openApplication", "/bin/sh", "/bin/bash", "NSExpression", "JSContext", "JavaScriptCore", "Bundle(url", "Bundle(path", "NSBundle", "principalClass", "CFBundleLoad"] { #expect(!text(file).contains(banned), "\(banned) in \(file.lastPathComponent)") } }
    }
    @Test func onlyAPersonsButtonCreatesARestartConfirmation() {
        let roots = ["Packages/NativeMusic/Sources", "App/Sources", "Extensions"].map { repositoryRoot.appendingPathComponent($0) }
        let callers = roots.flatMap(swiftFiles).filter { text($0).contains("RestartConfirmation.fromPersonAction()") || text($0).contains(".fromPersonAction()") }.map(\.lastPathComponent).filter { $0 != "UpdateInstaller.swift" }
        #expect(Set(callers) == ["UpdatesSettingsSection.swift"], "callers: \(callers)")
    }
    @Test func aSourceBuildCarriesNoFeedNoKeyAndNoRepository() throws {
        let plist = text(repositoryRoot.appendingPathComponent("App/Info.plist"))
        for key in [UpdateConfiguration.feedURLKey, UpdateConfiguration.keysKey, UpdateConfiguration.repositoryKey] { #expect(!plist.contains(key), "\(key)") }
        #expect(UpdateConfiguration(infoDictionary: [:]) == nil)
        #expect(UpdateConfiguration(infoDictionary: [UpdateConfiguration.feedURLKey: "", UpdateConfiguration.keysKey: [String](), UpdateConfiguration.repositoryKey: ""]) == nil)
        // A configured build parses; a bad key or a feed URL elsewhere does not.
        let key = FeedBuilder().key.publicKey.rawRepresentation.base64EncodedString()
        let good: [String: Any] = [UpdateConfiguration.feedURLKey: "https://github.com/\(repository)/releases/latest/download/feed.json", UpdateConfiguration.keysKey: [key], UpdateConfiguration.repositoryKey: repository]
        #expect(UpdateConfiguration(infoDictionary: good) != nil)
        #expect(UpdateConfiguration(infoDictionary: good.merging([UpdateConfiguration.keysKey: ["AAAA"]]) { $1 }) == nil)
        #expect(UpdateConfiguration(infoDictionary: good.merging([UpdateConfiguration.feedURLKey: "https://evil.example/feed.json"]) { $1 }) == nil)
    }
    @Test func theRepositoryNamesNoSigningKeyMaterial() {
        // No private key file, PEM block or 44-character base64 key literal sits in the updater, its tests' fixtures or the distribution docs.
        let files = moduleFiles + swiftFiles(under: repositoryRoot.appendingPathComponent("Packages/NativeMusic/Sources/FeedTool"))
        for file in files { #expect(!text(file).contains("PRIVATE KEY"), "\(file.lastPathComponent)") }
        let docs = text(repositoryRoot.appendingPathComponent("Docs/Distribution.md"))
        #expect(docs.range(of: #"[A-Za-z0-9+/]{43}="#, options: .regularExpression) == nil, "a key-shaped string in Docs/Distribution.md")
    }
    @Test func everyStringTheUpdaterShowsIsInTheStringCatalog() throws {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("Resources/Localizable.xcstrings"))
        let known = Set(try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["strings"] as? [String: Any]).keys)
        let files = ["Packages/NativeMusic/Sources/AppShell/Updates/UpdatesSettingsSection.swift", "Packages/NativeMusic/Sources/AppShell/Updates/UpdateComposition.swift", "Packages/NativeMusic/Sources/Updates/UpdateController.swift"]
        let literal = try NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
        var checked = 0
        for file in files {
            for line in text(repositoryRoot.appendingPathComponent(file)).components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("///") {
                for match in literal.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                    guard let range = Range(match.range(at: 1), in: line) else { continue }
                    let raw = String(line[range])
                    guard raw.contains(" ") else { continue }                       // identifiers, keys and paths have no spaces; sentences do
                    let key = raw.replacingOccurrences(of: #"\\\((?:[^()]|\([^()]*\))*\)"#, with: "%@", options: .regularExpression)
                    checked += 1
                    #expect(known.contains(key), "\(file.split(separator: "/").last ?? ""): missing from the string catalog: \(key)")
                }
            }
        }
        #expect(checked >= 20, "the sweep read the strings (\(checked))")
    }
}
