import Features
import Foundation
import Testing
@testable import AppShell

/// The job list on disk: a private file per account in an app-owned directory; tests use scratch directories only.
@Suite struct UploadJobFileStoreTests {
    private let a = "11111111-1111-4111-8111-111111111111", b = "22222222-2222-4222-8222-222222222222"
    private func job(_ scratch: Scratch, account: String, name: String = "Tone.wav") throws -> UploadJob {
        let url = try scratch.wav(name)
        let source = UploadSource(path: url.path, displayName: name, byteCount: 3244, modified: Date(timeIntervalSince1970: 1_700_000_000), format: .wav, contentConfirmed: true, metadata: UploadMetadata(title: "Tone"))
        return UploadJob(account: account, source: source)
    }
    @Test func jobsRoundTripPrivatelyAndPerAccount() async throws {
        let scratch = try Scratch()
        let directory = scratch.root.appendingPathComponent("upload-jobs")
        let store = UploadJobFileStore(directory: directory)
        let first = try job(scratch, account: a), second = try job(scratch, account: b, name: "Other.wav")
        try await store.save([first], account: a); try await store.save([second], account: b)
        let loadedA = try await store.load(account: a), loadedB = try await store.load(account: b)
        #expect(loadedA.map(\.id) == [first.id] && loadedB.map(\.id) == [second.id])
        let file = directory.appendingPathComponent(a + ".plist")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        let folder = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600 && folder == 0o700)
        let other = try await store.load(account: "33333333-3333-4333-8333-333333333333")
        #expect(other.isEmpty)
    }
    @Test func anAccountKeyThatIsNotAUUIDOrAJobOfAnotherAccountIsRefused() async throws {
        let scratch = try Scratch()
        let store = UploadJobFileStore(directory: scratch.root.appendingPathComponent("upload-jobs"))
        await #expect(throws: (any Error).self) { try await store.load(account: "../../etc/passwd") }
        await #expect(throws: (any Error).self) { try await store.save([], account: "not-a-uuid") }
        let foreign = try job(scratch, account: b)
        await #expect(throws: (any Error).self) { try await store.save([foreign], account: a) }
        #expect(!FileManager.default.fileExists(atPath: scratch.root.appendingPathComponent("upload-jobs").path), "refused before anything was written")
    }
    @Test func aCorruptFileIsReportedAndAnEmptyListRemovesTheFile() async throws {
        let scratch = try Scratch()
        let directory = scratch.root.appendingPathComponent("upload-jobs")
        let store = UploadJobFileStore(directory: directory)
        try await store.save([try job(scratch, account: a)], account: a)
        let file = directory.appendingPathComponent(a + ".plist")
        try Data("garbage".utf8).write(to: file)
        await #expect(throws: (any Error).self) { try await store.load(account: a) }
        try await store.save([], account: a)
        let afterEmpty = try await store.load(account: a)
        #expect(!FileManager.default.fileExists(atPath: file.path) && afterEmpty.isEmpty)
    }
    @Test func removingTheAccountRemovesOnlyItsJobListAndNeverAChosenFile() async throws {
        let scratch = try Scratch()
        let store = UploadJobFileStore(directory: scratch.root.appendingPathComponent("upload-jobs"))
        let first = try job(scratch, account: a)
        try await store.save([first], account: a); try await store.save([try job(scratch, account: b)], account: b)
        try await store.clear(account: a)
        let afterA = try await store.load(account: a), afterB = try await store.load(account: b)
        #expect(afterA.isEmpty && afterB.count == 1)
        #expect(FileManager.default.fileExists(atPath: first.source.path), "the file that was chosen is untouched")
    }
    @Test func theLateBoundStoreFailsBeforeItIsBoundAndForwardsAfter() async throws {
        let scratch = try Scratch()
        let late = LateBoundUploadStore()
        await #expect(throws: (any Error).self) { _ = try await late.load(account: a) }
        await late.bind(UploadJobFileStore(directory: scratch.root.appendingPathComponent("u")))
        let loaded = try await late.load(account: a)
        #expect(loaded.isEmpty)
    }
}

/// Guards over the sources: no live upload route, no file deletion, one removal path, strings in the catalog, dev data only in Debug.
@Suite struct UploadGuardTests {
    private func sources() throws -> [(name: String, text: String)] {
        var result: [(String, String)] = []
        let root = packageRoot().appendingPathComponent("Sources")
        for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)! where url.pathExtension == "swift" {
            result.append(("Sources" + url.path.dropFirst(root.path.count), try String(contentsOf: url, encoding: .utf8)))
        }
        return result
    }
    /// Line comments removed, string literals kept: a `//` inside a literal (`"https://…"`) is part of the code, not a comment.
    private func code(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var result = "", inString = false, escaped = false, previous: Character?
            for character in line {
                if inString {
                    result.append(character)
                    if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                } else if character == "/", previous == "/" {
                    result.removeLast(); break
                } else {
                    if character == "\"" { inString = true }
                    result.append(character)
                }
                previous = character
            }
            return result
        }
    }
    @Test func theCommentStripperKeepsURLLiteralsAndDropsComments() {
        #expect(code(#"let a = "https://upload.youtube.com/x" // note"#) == [#"let a = "https://upload.youtube.com/x" "#])
        #expect(code("let b = 1 // https://example.com") == ["let b = 1 "])
        #expect(code(#"let c = "a \" // not a comment""#) == [#"let c = "a \" // not a comment""#])
        #expect(code("/// doc https://x.y") == [""])
    }
    private func uploadSources() throws -> [(name: String, text: String)] {
        try sources().filter { $0.name.contains("Features/Uploads") || $0.name.hasSuffix("AppShell/UploadComposition.swift") || $0.name.hasSuffix("AppShell/DevelopmentUploads.swift") }
    }

    @Test func thereIsNoLiveUploadRouteAndNoGenericVideoUpload() throws {
        let swept = try uploadSources()
        #expect(swept.count >= 8, "the sweep covers the upload sources")
        for (name, text) in swept {
            for line in code(text) {
                for forbidden in ["https://", "http://", "upload.youtube.com", "usermusic", "resumable", "URLSession", "URLRequest", "youtubei/v1/upload", "/upload/youtube", "videos.insert", "studio.youtube.com"] {
                    #expect(!line.lowercased().contains(forbidden.lowercased()), Comment(rawValue: "\(name): \(forbidden)"))
                }
            }
        }
        // The only upload transports in the production sources: the unavailable one. The scripted one is Debug-only.
        var conformances: [String] = []
        for (name, text) in try sources() where code(text).contains(where: { $0.contains(": UploadTransport") || $0.contains(", UploadTransport") }) { conformances.append(name) }
        #expect(Set(conformances) == ["Sources/Features/Uploads/UploadTransport.swift", "Sources/AppShell/DevelopmentUploads.swift"], Comment(rawValue: "\(conformances)"))
        let dev = try #require(try sources().first { $0.name.hasSuffix("DevelopmentUploads.swift") })
        #expect(dev.text.hasPrefix("#if DEBUG") && dev.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("#endif"))
        #expect(dev.text.contains("environment[\"YTMUSE_UI_DEVELOPMENT_UPLOADS\"] == \"1\"") && dev.text.contains("DevelopmentLibrary.isEnabled(environment)"))
    }
    @Test func theProductionCompositionHoldsTheUnavailableTransportAndOnlyDebugSwapsIt() throws {
        let composition = try #require(try sources().first { $0.name.hasSuffix("AppShell/UploadComposition.swift") })
        let lines = code(composition.text)
        #expect(lines.filter { $0.contains("var transport: any UploadTransport = UnavailableUploadTransport()") }.count == 1)
        let assignments = lines.enumerated().filter { $0.element.contains("transport = ") && !$0.element.contains("var transport") }
        let debugStart = try #require(lines.firstIndex { $0.contains("#if DEBUG") }), debugEnd = try #require(lines.firstIndex { $0.contains("#endif") })
        #expect(assignments.allSatisfy { $0.offset > debugStart && $0.offset < debugEnd }, "the transport is replaced only inside #if DEBUG")
        #expect(lines.contains { $0.contains("DevelopmentUploads.enabled") })
    }
    @Test func nothingInTheUploadCodeWritesMovesOrDeletesAFileThatWasChosen() throws {
        let forbidden = ["removeItem", "trashItem", "moveItem", "replaceItem", "copyItem", "setAttributes", "createFile", "FileHandle(forWriting", "FileHandle(forUpdating", ".write(to", "truncate", "setxattr", "chmod", "unlink"]
        for (name, text) in try uploadSources() {
            for line in code(text) where forbidden.contains(where: line.contains) {
                // The app's own records are the only things it deletes or writes: the job store's own file inside its own directory, and the
                // development samples inside the isolated scratch folder.
                let allowed = name.hasSuffix("AppShell/UploadComposition.swift") || name.hasSuffix("AppShell/DevelopmentUploads.swift")
                #expect(allowed, Comment(rawValue: "\(name): \(line)"))
            }
        }
        let composition = try #require(try sources().first { $0.name.hasSuffix("AppShell/UploadComposition.swift") })
        for line in code(composition.text) where line.contains("removeItem") { #expect(line.contains("url"), Comment(rawValue: "only a path the store built from its own directory: \(line)")) }
        for line in code(composition.text) where line.contains("let url = ") { #expect(line.contains("try file("), Comment(rawValue: "every path in the store comes from `file(_:)`: \(line)")) }
        for (name, text) in try uploadSources() where name.contains("Features/Uploads") {
            #expect(!code(text).contains { $0.contains("FileManager") && $0.contains("remove") }, Comment(rawValue: name))
        }
    }
    @Test func theGuardCatchesAFullUploadURLInASource() throws {
        let sample = "static let liveEndpoint = \"https://upload.youtube.com/upload/usermusic/http\""
        #expect(code(sample).contains { $0.contains("https://") && $0.contains("upload.youtube.com") })
    }
    @Test func noViewTakesATernaryOfLiteralsThatWouldSkipTheStringCatalog() throws {
        // `Button(cond ? "A" : "B")` is a String, not a localised key; each literal must be its own view call.
        for (name, text) in try uploadSources() where name.contains("Features/Uploads") {
            for line in code(text) where line.contains("Button(") || line.contains("Text(") || line.contains("Label(") {
                #expect(line.range(of: #"(?:Button|Text|Label)\([^()"]*\?[^()]*"[^"]*"\s*:\s*""#, options: .regularExpression) == nil, Comment(rawValue: "\(name): \(line)"))
            }
        }
    }
    @Test func theRemovalReadBackDecidesThroughTheTestedFunction() throws {
        let composition = try #require(try sources().first { $0.name.hasSuffix("AppShell/UploadComposition.swift") })
        let lines = code(composition.text)
        #expect(lines.contains { $0.contains("UploadListEvidence.stillListed(") }, "the composition decides through the pure, tested function")
        #expect(!lines.contains { $0.contains("uploadEntityID ==") || $0.contains("continuation != nil") }, "…and holds no decision of its own")
        #expect(lines.contains { $0.contains("reader(.uploads(") }, "…reading through the composed reader")
    }
    @Test func theIsolationProofRunsInTheT19Suite() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/test.sh"), encoding: .utf8)
        let t19 = try #require(script.range(of: #"if \[\[ "\$2" == T19 \]\]; then"#, options: .regularExpression))
        let body = String(script[t19.upperBound...].prefix(while: { _ in true }).prefix(3500))
        #expect(body.contains("artifacts/harness/nodes/W19/isolation-proof.py"), "the proof is part of the suite")
        let builder = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/build-proof-products.sh"), encoding: .utf8)
        #expect(body.contains("./scripts/build-proof-products.sh") && builder.contains("Debug Release"), "…with the Debug and Release products it inspects built first")
    }
    @Test func theRemovalWriterIsReachableOnlyFromTheModelsConfirmedPath() throws {
        let swept = try sources()
        var callers: [String] = []
        for (name, text) in swept where code(text).contains(where: { $0.contains("await remover(") }) { callers.append(name) }
        #expect(callers == ["Sources/Features/Uploads/UploadRemoval.swift"])
        let model = try #require(swept.first { $0.name.hasSuffix("Features/Uploads/UploadRemoval.swift") })
        #expect(code(model.text).filter { $0.contains("await remover(") }.count == 1, "one call site")
        // `send` is reached only from complete (after confirm/begin), retry and retryUnconfirmed: each needs a state that only a question and an explicit action produce.
        #expect(code(model.text).filter { $0.contains("await send(") }.count == 3)
        for (name, text) in swept where name != "Sources/Features/Uploads/UploadRemoval.swift" {
            for line in code(text) where line.contains("removal.begin()") || line.contains("removal.confirm()") || line.contains("removal.complete()") || line.contains("removal.retry") || line.contains("removal.request(removing") {
                #expect(name.hasSuffix("Features/Uploads/UploadsView.swift") && (line.contains("Button") || line.contains("Task") || line.contains("accessibilityActions") || line.contains("label")), Comment(rawValue: "\(name): \(line)"))
            }
        }
        // The composition gives the model the very writer closure the ledger holds: still one `awaitedMusic().write(` in the app.
        let writeCalls = swept.flatMap { source in code(source.text).filter { $0.contains("awaitedMusic().write(") }.map { _ in source.name } }
        #expect(writeCalls == ["Sources/AppShell/LibraryComposition.swift"])
    }
    @Test func choosingAFileHasNoPathToTheRemovalFlow() throws {
        for (name, text) in try sources() where name.contains("Features/Uploads") && !name.hasSuffix("UploadRemoval.swift") && !name.hasSuffix("UploadsView.swift") && !name.hasSuffix("UploadsSurface.swift") && !name.hasSuffix("UploadListEvidence.swift") {
            #expect(!code(text).contains { $0.contains("UploadRemovalModel") || $0.contains("removeUpload") }, Comment(rawValue: "\(name) knows about removal"))
        }
        let removal = try #require(try sources().first { $0.name.hasSuffix("Features/Uploads/UploadRemoval.swift") })
        #expect(!code(removal.text).contains { $0.contains("UploadQueue") || $0.contains("UploadSource") || $0.contains("fileURL") || $0.contains("URL(fileURLWithPath") }, "the removal model holds no file")
    }
    @Test func everyUploadStringIsInTheStringCatalog() throws {
        let catalogURL = repositoryRoot().appendingPathComponent("Resources/Localizable.xcstrings")
        let strings = try #require((try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])?["strings"] as? [String: Any])
        let localized = try NSRegularExpression(pattern: #"String\(localized: "((?:[^"\\]|\\.)*)"\)"#)
        let literal = try NSRegularExpression(pattern: #"(?:Text|Label|Button|Picker|TextField|Section|confirmationDialog)\("((?:[^"\\]|\\.)*)""#)
        var checked = 0
        for (name, text) in try uploadSources() where !name.hasSuffix("DevelopmentUploads.swift") {
            for regex in [localized, literal] {
                for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    guard let range = Range(match.range(at: 1), in: text) else { continue }
                    var key = String(text[range])
                    guard key.range(of: #"[A-Za-z]{2}"#, options: .regularExpression) != nil, !key.hasSuffix("-") else { continue }
                    key = key.replacingOccurrences(of: #"\\\((?:[^()]|\([^()]*\))*\)"#, with: "%@", options: .regularExpression)
                    key = key.replacingOccurrences(of: "\\\"", with: "\"")
                    key = key.replacingOccurrences(of: #"%(?!@|lld|%)"#, with: "%%", options: .regularExpression)
                    checked += 1
                    let count = key.replacingOccurrences(of: "%@", with: "%lld")
                    #expect(strings[key] != nil || strings[count] != nil, Comment(rawValue: "\(name): missing \(key)"))
                }
            }
        }
        #expect(checked >= 60)
    }
    @Test func theCapabilityTextClaimsNoFormatListOrQuota() throws {
        let doc = try String(contentsOf: repositoryRoot().appendingPathComponent("Docs/Uploads.md"), encoding: .utf8).lowercased()
        #expect(doc.contains("w37") && doc.contains("no live upload"))
        for (name, text) in try uploadSources() where !name.hasSuffix("DevelopmentUploads.swift") {
            for line in code(text) where line.contains("localized") || line.contains("Text(\"") {
                let lower = line.lowercased()
                for claim in ["300 mb", "100,000", "quota", "supports mp3", "up to 5", "gigabyte"] { #expect(!lower.contains(claim), Comment(rawValue: "\(name): \(line)")) }
            }
        }
    }
}
