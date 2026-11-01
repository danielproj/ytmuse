import AccountSession
import Domain
import Features
import Foundation
import Testing
@testable import AppShell
import YouTubeMusicAdapter

private func packageRoot() -> URL {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { root.deleteLastPathComponent() }          // Tests/LibraryTests/<file> -> package root
    return root
}
private func swiftFiles(under folder: URL) throws -> [(name: String, text: String)] {
    let keys: [URLResourceKey] = [.isRegularFileKey]
    guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return [] }
    var result: [(String, String)] = []
    for case let url as URL in walker where url.pathExtension == "swift" {
        result.append((url.path.replacingOccurrences(of: packageRoot().path + "/", with: ""), try String(contentsOf: url, encoding: .utf8)))
    }
    return result
}
/// Lines that are code (not comments), so a comment that names a type is not a use of it.
private func codeLines(_ text: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///") && !trimmed.hasPrefix("*")
    }
}

/// The addendum's safety rules, as tests: no test target may construct a live signed transport, and a library change is sent only from
/// the explicit-action paths.
@Suite struct LibraryGuardTests {
    /// Every construction of a signed client or transport in a piece of source that is not one of the allowed test spellings. Works on the
    /// whole text (so a construction split over lines is one construction) and on every spelling that can reach the live transport: the
    /// type's initialiser, `.init`, an annotated `= .init(…)`, and a client whose `transport:` is left to its default.
    static func liveTransportOffences(in source: String) -> [String] {
        let text = codeLines(source).joined(separator: "\n")
        var offences: [String] = []
        func arguments(from open: String.Index) -> String {
            var depth = 0, index = open
            while index < text.endIndex {
                if text[index] == "(" { depth += 1 } else if text[index] == ")" { depth -= 1; if depth == 0 { return String(text[open...index]) } }
                index = text.index(after: index)
            }
            return String(text[open...])
        }
        func scan(_ pattern: String, _ ok: (String) -> Bool, _ label: String) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text), let open = text[range].lastIndex(of: "(") else { continue }
                let args = arguments(from: open)
                if !ok(args) { offences.append(label + ": " + String(text[range]) + args.prefix(80).replacingOccurrences(of: "\n", with: " ")) }
            }
        }
        // A signed client must be given its transport; one built without it defaults to the live one.
        scan(#"SignedMusicClient\s*(?:\.init)?\s*\("#, { $0.contains("transport:") }, "SignedMusicClient without an explicit transport")
        scan(#"\.init\s*\(\s*publicClient:"#, { $0.contains("transport:") }, ".init(publicClient:) without an explicit transport")
        scan(#"=\s*\.init\s*\("#, { _ in true }, "")
        // The live signed transport may not be named at all, except through the local-only protocol seam.
        scan(#"DirectSignedMusicTransport\s*(?:\.init)?\s*\("#, { $0.hasPrefix("(protocolClasses:") || $0.hasPrefix("(protocolClasses :") }, "the live signed transport")
        scan(#"DirectSignedMusicTransport\s*\.\s*live\s*\("#, { _ in false }, "the live signed transport")
        for match in (try? NSRegularExpression(pattern: #"DirectSignedMusicTransport\b(?!\s*(?:\.init\s*)?\()"#))?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [] {
            if let range = Range(match.range, in: text) {
                let line = text[text.lineRange(for: range)].trimmingCharacters(in: .whitespaces)
                // A type annotation or a mention that is not a construction: `.init` through an annotation is caught by the next rule.
                if line.contains("= .init") || line.contains(".init(") { offences.append("annotated live transport: " + line) }
            }
        }
        if text.contains("PublicMusicClient()") { offences.append("live public client") }
        return offences.filter { !$0.hasPrefix(": ") && !$0.isEmpty }
    }
    @Test func noTestTargetConstructsALiveSignedTransport() throws {
        let tests = try swiftFiles(under: packageRoot().appendingPathComponent("Tests"))
        #expect(tests.count > 50, "the scan covers the test targets")
        var offenders: [String] = []
        for (name, text) in tests where !name.hasSuffix("LibraryGuardTests.swift") {
            offenders += Self.liveTransportOffences(in: text).map { name + ": " + $0 }
            if text.contains("URLSession.shared"), text.contains("music.youtube.com") { offenders.append(name + ": the shared session next to the service's host") }
        }
        #expect(offenders.isEmpty, Comment(rawValue: offenders.joined(separator: "\n")))
    }
    @Test func theGuardCanSeeEverySpellingThatReachesTheLiveTransport() {
        let bypasses = [
            "let t = DirectSignedMusicTransport()",
            "let t = DirectSignedMusicTransport(session: URLSession.shared)",
            "let t: DirectSignedMusicTransport = .init()",
            "let t = DirectSignedMusicTransport.init()",
            "let t = try DirectSignedMusicTransport.live()",
            "let c = SignedMusicClient(publicClient: p)",
            "let c = SignedMusicClient.init(publicClient: p)",
            "let c: SignedMusicClient = .init(publicClient: p)",
            "let c = SignedMusicClient(\n    publicClient: p,\n    clock: clock)",
            "let c = SignedMusicClient(clock: Now()) { \"1.2\" }",
            "let p = try PublicMusicClient()",
        ]
        for source in bypasses { #expect(!Self.liveTransportOffences(in: source).isEmpty, Comment(rawValue: source)) }
        let allowed = [
            "let c = SignedMusicClient(transport: scripted, clock: Now()) { \"1.2\" }",
            "let c = SignedMusicClient(publicClient: p, transport: scripted, clock: Now())",
            "let c = SignedMusicClient(\n    publicClient: p,\n    transport: scripted)",
            "let t = DirectSignedMusicTransport(protocolClasses: [LocalOnlyProtocol.self])",
            "// DirectSignedMusicTransport() in a comment",
            "func signedClient(_ t: ScriptedSigned) -> SignedMusicClient { SignedMusicClient(transport: t, clock: FixedNow()) { \"1\" } }",
        ]
        for source in allowed { #expect(Self.liveTransportOffences(in: source).isEmpty, Comment(rawValue: source)) }
    }
    /// The process-level half of the guard: whatever a test file spells, the live transport cannot be made in a test process.
    @Test func theLiveSignedTransportRefusesToBeMadeInATestProcess() throws {
        #expect(LiveTransportGuard.isTestProcess, "this process is a test process")
        #expect(throws: MusicSessionError.policy) { _ = try DirectSignedMusicTransport.live() }
        let adapter = try swiftFiles(under: packageRoot().appendingPathComponent("Sources/YouTubeMusicAdapter"))
        let signed = try #require(adapter.first { $0.name.hasSuffix("SignedMusic.swift") }).text
        let initBody = try #require(signed.range(of: "    public init() {\n")).upperBound
        #expect(signed[initBody...].prefix(260).contains("precondition(!LiveTransportGuard.isTestProcess"), "the initialiser itself stops a test process")
        // The test seam takes protocol classes, never a session.
        #expect(!signed.contains("init(session: URLSession)") && signed.contains("init(protocolClasses: [AnyClass])"))
    }
    /// The local store keeps more than the list shows and "Clear" removes all of it, so the confirmation may not state a count of what it shows.
    @Test func theClearConfirmationDoesNotCountOnlyWhatIsListed() throws {
        let history = try #require(try swiftFiles(under: packageRoot().appendingPathComponent("Sources/Features/History")).first { $0.name.hasSuffix("HistoryView.swift") }).text
        let line = try #require(codeLines(history).first { $0.contains(".confirmationDialog(") })
        #expect(line.contains("Clear all plays") && !line.contains(".count"))
    }
    @Test func theLiveTransportIsBuiltOnlyByTheApplicationTarget() throws {
        let sources = try swiftFiles(under: packageRoot().appendingPathComponent("Sources"))
        for (name, text) in sources where text.contains("DirectSignedMusicTransport()") {
            #expect(name.hasSuffix("SignedMusic.swift"), "\(name) constructs the live signed transport")
        }
        let app = try swiftFiles(under: packageRoot().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App/Sources"))
        #expect(app.contains { $0.text.contains("SignedMusicClient(publicClient:") })
    }
    @Test func aChangeIsSentOnlyThroughTheLedgersExplicitActionPaths() throws {
        let sources = try swiftFiles(under: packageRoot().appendingPathComponent("Sources"))
        var writers: [String] = []
        for (name, text) in sources {
            for line in codeLines(text) where line.contains(".write(") && (line.contains("awaitedMusic") || line.contains("coordinator") || line.contains("music.write") || line.contains("music?.write")) { writers.append(name) }
        }
        #expect(writers == ["Sources/AppShell/LibraryComposition.swift"], "the only caller of the coordinator's write is the ledger's writer closure")
        let composition = try #require(sources.first { $0.name.hasSuffix("AppShell/LibraryComposition.swift") })
        let calls = codeLines(composition.text).filter { $0.contains("awaitedMusic().write(") }
        #expect(calls.count == 1 && calls[0].contains("return try await"), "one call site inside that file too: the writer closure the ledger holds")
        // The ledger's entry points are called from views (a button) and nowhere that loops or runs on a timer.
        var submitters: Set<String> = []
        for (name, text) in sources where codeLines(text).contains(where: { $0.contains("ledger.submit(") || $0.contains("ledger.retry(") || $0.contains(".submit(control.intent)") }) { submitters.insert(name) }
        #expect(submitters.isSubset(of: ["Sources/Features/Library/LibraryView.swift"]), Comment(rawValue: "\(submitters)"))
        for (name, text) in sources where name.hasPrefix("Sources/Features/Library") || name.hasPrefix("Sources/Features/History") {
            for line in codeLines(text) where line.contains("submit(") && (line.contains("for ") || line.contains("forEach") || line.contains("Timer") || line.contains("sleep")) {
                // A button inside a ForEach of controls is one button per control; a loop that submits is not allowed.
                #expect(line.contains("Button"), "\(name): \(line)")
            }
        }
    }
    @Test func theWritePathIsNotReachableFromAnyOtherModuleThanTheCoordinator() throws {
        let sources = try swiftFiles(under: packageRoot().appendingPathComponent("Sources"))
        for (name, text) in sources where text.contains("SignedMusicPolicy.writePaths") || text.contains("MusicWriteRequest") {
            #expect(["AccountSession", "YouTubeMusicAdapter", "Features", "AppShell"].contains { name.hasPrefix("Sources/\($0)/") }, Comment(rawValue: name))
        }
    }
    @Test func developmentLibraryDataExistsOnlyInsideDebugAndOnlyWithBothFlagsAndIsolation() throws {
        let sources = try swiftFiles(under: packageRoot().appendingPathComponent("Sources"))
        let file = try #require(sources.first { $0.name.hasSuffix("AppShell/DevelopmentLibrary.swift") })
        #expect(file.text.hasPrefix("#if DEBUG") && file.text.hasSuffix("#endif\n"))
        #expect(file.text.contains("DevelopmentSearch.isEnabled(environment) && environment[\"YTMUSE_UI_DEVELOPMENT_LIBRARY\"] == \"1\""), "the gate needs the older flag, isolation and its own flag")
        for (name, text) in sources where name != file.name && text.contains("DevelopmentLibrary") {
            var depth = 0
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#if DEBUG") { depth += 1 } else if trimmed.hasPrefix("#endif") { depth -= 1 }
                if trimmed.contains("DevelopmentLibrary") && !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///") { #expect(depth > 0, "unguarded in \(name): \(trimmed)") }
            }
        }
        #expect(!file.text.contains("URLSession") && !file.text.contains("https://"), "the development data performs no network request")
    }
    @Test func libraryUserStringsAreInTheStringCatalog() throws {
        let catalogURL = packageRoot().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Localizable.xcstrings")
        let strings = try #require((try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])?["strings"] as? [String: Any])
        let pattern = try NSRegularExpression(pattern: #"String\(localized: "((?:[^"\\]|\\.)*)"\)"#)
        var checked = 0
        for (name, text) in try swiftFiles(under: packageRoot().appendingPathComponent("Sources")) where name.contains("Features/Library") || name.contains("Features/History") || name.hasSuffix("AppShell/LibraryComposition.swift") || name.contains("Catalog/CatalogModels") {
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                var key = String(text[range])
                key = key.replacingOccurrences(of: #"\\\([^)]*\)"#, with: "%@", options: .regularExpression)
                checked += 1
                #expect(strings[key] != nil || strings[key.replacingOccurrences(of: "%@", with: "%lld")] != nil, "\(name): missing \(key)")
            }
        }
        #expect(checked >= 40)
    }
    @Test func theCatalogsLiteralViewTextIsInTheStringCatalogToo() throws {
        let catalogURL = packageRoot().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Localizable.xcstrings")
        let strings = try #require((try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])?["strings"] as? [String: Any])
        let pattern = try NSRegularExpression(pattern: #"(?:Text|Label|Button|Picker|TextField|Section)\("((?:[^"\\]|\\.)*)""#)
        var checked = 0
        for (name, text) in try swiftFiles(under: packageRoot().appendingPathComponent("Sources/Features")) where name.contains("Features/Library") || name.contains("Features/History") {
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let key = String(text[range])
                guard !key.isEmpty, !key.contains("\\("), key.range(of: #"[A-Za-z]{2}"#, options: .regularExpression) != nil else { continue }
                checked += 1
                #expect(strings[key] != nil, "\(name): missing view text '\(key)'")
            }
        }
        #expect(checked >= 30)
    }
}

/// The local record is a private file per account in an app-owned directory; tests use scratch directories only.
@Suite struct LocalHistoryStoreTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("w12-history-" + UUID().uuidString)
        // Isolation check: a store test never binds anything outside the system temporary directory.
        guard url.path.hasPrefix(FileManager.default.temporaryDirectory.path), !url.path.contains("Application Support") else { throw CocoaError(.fileWriteNoPermission) }
        return url
    }
    private let account = "11111111-1111-4111-8111-111111111111"
    @Test func recordsArePrivateOrderedBoundedAndPerAccount() async throws {
        let directory = try scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalHistoryFileStore(directory: directory, maximum: 3)
        for index in 0..<5 { try await store.append(LocalHistoryRecord(videoID: "aaaaaaaaaa\(index)", title: "T\(index)", artist: nil, startedAt: Date(timeIntervalSince1970: Double(index)), listenedSeconds: 31), account: account) }
        let recent = try await store.recent(account: account, limit: 10)
        #expect(recent.map(\.title) == ["T4", "T3", "T2"], "newest first, bounded")
        let others = try await store.recent(account: "22222222-2222-4222-8222-222222222222", limit: 10)
        #expect(others.isEmpty, "another account sees nothing")
        let file = directory.appendingPathComponent(account + ".plist")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((folder[.posixPermissions] as? Int) == 0o700)
    }
    @Test func clearingRemovesOnlyThisAccountsFile() async throws {
        let directory = try scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalHistoryFileStore(directory: directory)
        let other = "22222222-2222-4222-8222-222222222222"
        let record = LocalHistoryRecord(videoID: "aaaaaaaaaa1", title: "T", artist: nil, startedAt: Date(), listenedSeconds: 31)
        try await store.append(record, account: account); try await store.append(record, account: other)
        try await store.clear(account: account)
        let cleared = try await store.recent(account: account, limit: 10), kept = try await store.recent(account: other, limit: 10)
        #expect(cleared.isEmpty && kept.count == 1)
    }
    @Test func anAccountKeyThatIsNotAUUIDIsRefusedBeforeItCanBecomeAPath() async throws {
        let directory = try scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalHistoryFileStore(directory: directory)
        let record = LocalHistoryRecord(videoID: "aaaaaaaaaa1", title: "T", artist: nil, startedAt: Date(), listenedSeconds: 31)
        for bad in ["../../etc/passwd", "a/b", "", "not-a-uuid", account + "/../x"] {
            await #expect(throws: (any Error).self) { try await store.append(record, account: bad) }
            await #expect(throws: (any Error).self) { _ = try await store.recent(account: bad, limit: 1) }
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path), "nothing was created by the refused calls")
    }
    @Test func aCorruptFileIsReportedNotTreatedAsAnEmptyHistory() async throws {
        let directory = try scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent(account + ".plist"))
        let store = LocalHistoryFileStore(directory: directory)
        await #expect(throws: (any Error).self) { _ = try await store.recent(account: account, limit: 5) }
    }
    @Test func removingTheAccountRemovesItsLocalRecord() async throws {
        let directory = try scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalHistoryFileStore(directory: directory)
        try await store.append(LocalHistoryRecord(videoID: "aaaaaaaaaa1", title: "T", artist: nil, startedAt: Date(), listenedSeconds: 31), account: account)
        let context = try AccountContext(accountID: UUID(uuidString: account)!, channelID: ID("UCsyntheticChannel000000"), region: "GB")
        try await store.removeLocal(context, context: RequestContext(account: context, accountGeneration: 1, requestGeneration: 1))
        let remaining = try await store.recent(account: account, limit: 5)
        #expect(remaining.isEmpty)
    }
    @Test func theLateBoundStoreFailsBeforeItIsBoundAndForwardsAfter() async throws {
        let directory = try scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let late = LateBoundHistoryStore()
        await #expect(throws: (any Error).self) { _ = try await late.recent(account: account, limit: 1) }
        await late.bind(LocalHistoryFileStore(directory: directory))
        try await late.append(LocalHistoryRecord(videoID: "aaaaaaaaaa1", title: "T", artist: nil, startedAt: Date(), listenedSeconds: 31), account: account)
        let forwarded = try await late.recent(account: account, limit: 5)
        #expect(forwarded.count == 1)
    }
}
