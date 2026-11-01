import AccountSession
import Domain
import Foundation
import Testing
@testable import YouTubeMusicAdapter

private struct FixedNow: WallClock { func now() -> Date { Date(timeIntervalSince1970: 1_700_000_000) } }

/// A scripted signed service: nothing here reaches a network. It records every request after the real policy check.
private actor ScriptedSigned: SignedMusicTransport {
    private(set) var requests: [URLRequest] = []
    let body: Data
    init(body: String = "{}") { self.body = Data(body.utf8) }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> SignedMusicWireResponse {
        try SignedMusicPolicy.validate(request, maximumBytes: maximumBytes)
        requests.append(request)
        return .init(status: 200, body: body, contentType: "application/json; charset=UTF-8")
    }
    func captured() -> [URLRequest] { requests }
}
private func session() throws -> MusicCookieSession {
    func cookie(_ name: String, _ value: String) -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: value, .domain: ".youtube.com", .path: "/", .expires: Date(timeIntervalSince1970: 1_700_000_000 + 86_400)])!
    }
    return try MusicCookieSession(accountID: UUID(), cookies: [cookie("SAPISID", "SYNTHETIC-SAPISID-VALUE"), cookie("SID", "SYNTHETIC-SID-VALUE")], now: Date(timeIntervalSince1970: 1_700_000_000))
}

/// The removal request, compared with the request ytmusicapi's `delete_upload_entity` sends (POST `music/delete_privately_owned_entity`, body
/// `{"entityId": …}`), and the three places the app reads a removal target and an answer from. No capture of a signed answer exists.
@Suite struct UploadWireTests {
    private let entity = "FEmusic_library_privately_owned_release_detailB123456"
    private func send(_ body: String) async throws -> (MusicWriteOutcome, URLRequest?) {
        let transport = ScriptedSigned(body: body)
        let client = SignedMusicClient(transport: transport, clock: FixedNow()) { "1.20261028.01.00" }
        let outcome = try await client.write(.removeUpload(entityID: entity), session: try session()).value
        return (outcome, await transport.captured().first)
    }
    @Test func theRemovalIsOneSignedPostWithTheDocumentedShape() async throws {
        let (_, request) = try await send(#"{"actions":[{"x":1}]}"#)
        let sent = try #require(request)
        #expect(sent.httpMethod == "POST" && sent.url?.absoluteString == "https://music.youtube.com/youtubei/v1/music/delete_privately_owned_entity?prettyPrint=false")
        #expect(sent.value(forHTTPHeaderField: "Authorization")?.hasPrefix("SAPISIDHASH ") == true)
        let data = try #require(sent.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["entityId"] as? String == entity && Set(body.keys) == ["entityId", "context"], "nothing but the entity id and the client context")
        let (path, wireBody) = SignedMusicClient.wire(.removeUpload(entityID: entity))
        #expect(path == "music/delete_privately_owned_entity" && wireBody["entityId"] as? String == entity && wireBody.count == 1)
        #expect(SignedMusicPolicy.writePaths.contains("/youtubei/v1/music/delete_privately_owned_entity"))
        #expect(SignedMusicPolicy.writePaths.count == 7, "the six W12 paths and this one; nothing else can change anything")
    }
    @Test func successNeedsPositiveEvidenceAndAnErrorIsARefusal() async throws {
        #expect(try await send(#"{"error":{"code":400}}"#).0 == .rejected(.service))
        #expect(try await send(#"{"errors":[{"x":1}]}"#).0 == .rejected(.service))
        #expect(try await send("{}").0 == .indeterminate(.unrecognisedAnswer), "an empty answer proves nothing")
        #expect(try await send(#"{"actions":[]}"#).0 == .indeterminate(.unrecognisedAnswer))
        #expect(try await send(#"{"actions":[{"addToToastAction":{}}]}"#).0 == .confirmed)
    }
    @Test func onlyAnIdOfTheServicesOwnShapeIsWellFormed() {
        for good in ["devupload-song-0001", "FEmusic_library_privately_owned_release_detailB123", "a1b2c3d4e5", "abc:def_ghi-jkl"] { #expect(MusicWriteRequest.removeUpload(entityID: good).isWellFormed, Comment(rawValue: good)) }
        for bad in ["", "short", "has space in it", "semi;colon;chars", String(repeating: "a", count: 513), "new\nline12345"] { #expect(!MusicWriteRequest.removeUpload(entityID: bad).isWellFormed, Comment(rawValue: bad)) }
    }
}

/// The comparison the brief asks for, kept executable: the pinned copy of ytmusicapi's upload code (`artifacts/harness/nodes/W19/reference`,
/// reference only, MIT) names the same endpoint, body key, target location and library pages this app uses.
@Suite struct UploadReferenceComparisonTests {
    private func reference(_ name: String) throws -> String {
        try String(contentsOf: repositoryRoot().appendingPathComponent("artifacts/harness/nodes/W19/reference/" + name), encoding: .utf8)
    }
    @Test func theRemovalRequestMatchesTheReferenceClient() throws {
        let mixin = try reference("ytmusicapi-uploads.py.txt")
        let (path, body) = SignedMusicClient.wire(.removeUpload(entityID: "t_po_CICr2crg7OWpchDKwoakAQ"))
        #expect(mixin.contains("endpoint = \"\(path)\""), "the reference sends to the same path")
        #expect(mixin.contains("body = {\"entityId\": entityId}") && Set(body.keys) == ["entityId"], "…with the same one-key body")
        #expect(MusicWriteRequest.removeUpload(entityID: "t_po_CICr2crg7OWpchDKwoakAQ").isWellFormed, "an id of the shape the reference's own docs show is accepted")
    }
    @Test func theTargetIsReadFromWhereTheReferenceReadsIt() throws {
        let parser = try reference("ytmusicapi-uploads-parser.py.txt")
        // The reference's key chain, in order, ending at the entity id.
        var position = parser.startIndex
        for key in ["confirmDialogEndpoint", "content", "confirmDialogRenderer", "confirmButton", "buttonRenderer", "command", "musicDeletePrivatelyOwnedEntityCommand", "entityId"] {
            let found = try #require(parser.range(of: "\"\(key)\"", range: position..<parser.endIndex), Comment(rawValue: key))
            position = found.upperBound
        }
    }
    @Test func theThreeListsAreTheReferencesThreePages() throws {
        let mixin = try reference("ytmusicapi-uploads.py.txt")
        for kind in MusicUploadKind.allCases { #expect(mixin.contains("\"browseId\": \"\(kind.browseID)\""), Comment(rawValue: kind.browseID)) }
    }
    @Test func theReferenceIsThePinnedCopyItsManifestSays() throws {
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: repositoryRoot().appendingPathComponent("artifacts/harness/nodes/W19/reference/manifest.json"))) as? [String: Any])
        for file in try #require(manifest["files"] as? [[String: Any]]) {
            let data = try Data(contentsOf: repositoryRoot().appendingPathComponent("artifacts/harness/nodes/W19/reference/" + (file["local"] as? String ?? "")))
            #expect(sha256(data) == file["sha256"] as? String)
        }
    }
}

@Suite struct UploadParserTests {
    private func page(menuItems: [Any]?, in mode: MusicBrowseParser.Mode = .collection) throws -> MusicBrowsePage {
        let raw = try Data(contentsOf: fixturesRoot().appendingPathComponent("W12/library-uploads.json"))
        var root = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        func walk(_ node: Any, _ visit: (inout [String: Any]) -> Void) -> Any {
            if var object = node as? [String: Any] {
                for (key, value) in object { object[key] = walk(value, visit) }
                visit(&object); return object
            }
            if let list = node as? [Any] { return list.map { walk($0, visit) } }
            return node
        }
        var first = true
        let walked = walk(root) { object in
            if first, object["flexColumns"] != nil, let menuItems { object["menu"] = ["menuRenderer": ["items": menuItems]]; first = false }
        }
        root = try #require(walked as? [String: Any])
        return try MusicBrowseParser.parse(root, mode: mode)
    }
    private func deleteItem(_ entity: String) -> [String: Any] {
        ["menuNavigationItemRenderer": ["navigationEndpoint": ["confirmDialogEndpoint": ["content": ["confirmDialogRenderer": ["confirmButton": ["buttonRenderer": ["command":
            ["musicDeletePrivatelyOwnedEntityCommand": ["entityId": entity]]]]]]]]]]
    }
    @Test func anUploadedTracksOwnDeleteCommandSuppliesTheRemovalTarget() throws {
        let items = try page(menuItems: [deleteItem("devupload-song-0001")]).shelves.flatMap(\.items)
        #expect(items.count == 4 && items.allSatisfy(\.isUpload))
        #expect(items.first?.uploadEntityID == "devupload-song-0001")
        #expect(items.dropFirst().allSatisfy { $0.uploadEntityID == nil }, "a row that published none has none: no target is derived or guessed")
    }
    @Test func theTargetIsReadOnlyFromACollectionAndOnlyWhenUnambiguousAndWellFormed() throws {
        // A catalog reading cannot even read these rows (an uploaded track exists only in a collection), so no target can come out of it.
        #expect(throws: MusicSessionError.unrecognised) { _ = try page(menuItems: [deleteItem("devupload-song-0001")], in: .catalog) }
        #expect(try page(menuItems: [deleteItem("devupload-song-0001"), deleteItem("devupload-song-0002")]).shelves.flatMap(\.items).first?.uploadEntityID == nil, "two different targets in one menu: none is chosen")
        #expect(try page(menuItems: [deleteItem("devupload-song-0001"), deleteItem("devupload-song-0001")]).shelves.flatMap(\.items).first?.uploadEntityID == "devupload-song-0001")
        #expect(try page(menuItems: [deleteItem("no spaces allowed here")]).shelves.flatMap(\.items).first?.uploadEntityID == nil)
        #expect(try page(menuItems: nil).shelves.flatMap(\.items).allSatisfy { $0.uploadEntityID == nil })
    }
    @Test func theThreeUploadListsNameTheirOwnPagesAndEntryKinds() {
        #expect(MusicUploadKind.songs.browseID == MusicLibraryKind.uploads.browseID, "uploaded songs are the Library's uploads page, read by the same model and parser")
        #expect(MusicUploadKind.albums.browseID == "FEmusic_library_privately_owned_releases" && MusicUploadKind.artists.browseID == "FEmusic_library_privately_owned_artists")
        #expect(MusicUploadKind.songs.holds == MusicLibraryKind.uploads.holds && MusicUploadKind.albums.holds == [.album] && MusicUploadKind.artists.holds == [.artist])
    }
}
