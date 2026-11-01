import Foundation
import Testing
import WidgetShared

/// T25.1 / T25.2 / T25.4 (MAC06, ARCH09): the snapshot is small and redacted by construction, written atomically, read strictly, and deleted completely.
@Suite struct WidgetSnapshotStoreTests {
    @Test func aSnapshotRoundTripsExactly() throws {
        let dir = Scratch.make(); defer { Scratch.remove(dir) }
        let store = WidgetSnapshotStore(directory: dir)
        let snapshot = WidgetFixtures.playing()
        try store.write(snapshot)
        #expect(store.read() == .snapshot(snapshot))
        #expect(store.listing() == [WidgetIdentity.snapshotFileName], "the snapshot is the only file, and no staging file is left")
    }
    @Test func aRedactedStateCannotCarryContentAndNothingIsWrittenForOne() throws {
        let dir = Scratch.make(); defer { Scratch.remove(dir) }
        let store = WidgetSnapshotStore(directory: dir)
        for state in [WidgetPlaybackState.signedOut, .locked] {
            var leaky = WidgetSnapshot.redacted(state); leaky.title = "Private Playlist Name"
            #expect(!leaky.isConsistent, "\(state) with a title is refused")
            #expect(throws: (any Error).self) { try store.write(leaky) }
            var scoped = WidgetSnapshot.redacted(state); scoped.scope = WidgetFixtures.scope
            #expect(!scoped.isConsistent, "\(state) with an account stamp is refused")
            var buttons = WidgetSnapshot.redacted(state); buttons.capabilities = WidgetFixtures.allButtons
            #expect(!buttons.isConsistent, "\(state) with buttons is refused")
            var picture = WidgetSnapshot.redacted(state); picture.artwork = Data([1, 2, 3])
            #expect(!picture.isConsistent, "\(state) with a picture is refused")
        }
        #expect(store.listing().isEmpty, "a refused write leaves nothing behind, not even the directory's staging file")
    }
    @Test func theContentMustAgreeWithTheState() {
        let scope = WidgetFixtures.scope
        #expect(WidgetSnapshot(state: .playing, title: "T", scope: scope).isConsistent)
        #expect(!WidgetSnapshot(state: .playing, title: "T").isConsistent, "playing without an account stamp")
        #expect(!WidgetSnapshot(state: .playing, scope: scope).isConsistent, "playing without a title")
        #expect(!WidgetSnapshot(state: .advertisement, title: "The song the ad interrupts", scope: scope).isConsistent, "an advertisement names no song")
        #expect(WidgetSnapshot(state: .advertisement, scope: scope).isConsistent)
        #expect(!WidgetSnapshot(state: .idle, title: "T", scope: scope).isConsistent, "idle names nothing")
        #expect(WidgetSnapshot(state: .idle, scope: scope).isConsistent)
        #expect(!WidgetSnapshot(state: .paused, title: "T", artwork: Data(count: WidgetSnapshot.artworkByteLimit + 1), scope: scope).isConsistent, "an oversize picture")
        #expect(WidgetSnapshot(state: .paused, title: String(repeating: "a", count: 500), scope: scope).title?.count == WidgetSnapshot.titleLimit, "a title is cut to the limit")
    }
    @Test func theReaderRefusesAnythingThatIsNotThisSchema() throws {
        let dir = Scratch.make(); defer { Scratch.remove(dir) }
        let store = WidgetSnapshotStore(directory: dir)
        #expect(store.read() == .missing)
        try store.write(WidgetFixtures.playing())
        let good = try Data(contentsOf: store.fileURL)
        var object = try #require(try JSONSerialization.jsonObject(with: good) as? [String: Any])
        func plant(_ edit: (inout [String: Any]) -> Void) throws -> WidgetReadResult {
            var copy = object; edit(&copy)
            return WidgetSnapshotStore.decode(try JSONSerialization.data(withJSONObject: copy))
        }
        #expect(try plant { $0["accountEmail"] = "person@example.com" } == .unreadable, "an extra key (an email) is never rendered")
        #expect(try plant { $0["cookie"] = "SAPISID=secret" } == .unreadable)
        #expect(try plant { $0["queue"] = ["a", "b"] } == .unreadable)
        #expect(try plant { var scope = $0["scope"] as? [String: Any] ?? [:]; scope["email"] = "person@example.com"; $0["scope"] = scope } == .unreadable, "an extra key INSIDE the stamp is refused too, not dropped by the decoder")
        #expect(try plant { var caps = $0["capabilities"] as? [String: Any] ?? [:]; caps["token"] = "x"; $0["capabilities"] = caps } == .unreadable, "and inside the button flags")
        #expect(try plant { $0["scope"] = "not an object" } == .unreadable)
        #expect(try plant { $0["schema"] = 2 } == .unreadable, "another schema version")
        #expect(try plant { $0["state"] = "locked" } == .unreadable, "a locked state that still carries a title")
        #expect(try plant { $0["state"] = "weird" } == .unreadable)
        #expect(try plant { $0["title"] = nil } == .unreadable, "playing without a title")
        #expect(WidgetSnapshotStore.decode(Data("not json".utf8)) == .unreadable)
        #expect(WidgetSnapshotStore.decode(Data()) == .unreadable)
        #expect(WidgetSnapshotStore.decode(Data(count: WidgetSnapshotStore.fileByteLimit + 1)) == .unreadable, "an oversize file is refused unread")
        object["state"] = "paused"
        #expect(WidgetSnapshotStore.decode(try JSONSerialization.data(withJSONObject: object)) != .unreadable, "the control: a valid variation is read")
    }
    @Test func aWriteIsAtomicAndOwnerOnly() async throws {
        let dir = Scratch.make(); defer { Scratch.remove(dir) }
        let store = WidgetSnapshotStore(directory: dir)
        try store.write(WidgetFixtures.playing("First"))
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int)
        #expect(mode & 0o077 == 0, "owner only: \(String(mode, radix: 8))")
        // A reader running while the file is replaced 300 times sees a whole snapshot every time, never a half.
        let reader = Task.detached { () -> Int in
            var unreadable = 0
            for _ in 0..<3000 { if case .unreadable = store.read() { unreadable += 1 } }
            return unreadable
        }
        for i in 0..<300 { try store.write(WidgetFixtures.playing("Song \(i)", artist: "Artist \(i)")) }
        #expect(await reader.value == 0, "no read saw a partial file")
        #expect(store.listing() == [WidgetIdentity.snapshotFileName], "no staging file survives a replace")
    }
    @Test func deleteRemovesTheSnapshotAndEveryStagingLeftoverAndNothingElse() throws {
        let dir = Scratch.make(); defer { Scratch.remove(dir) }
        let store = WidgetSnapshotStore(directory: dir)
        try store.write(WidgetFixtures.playing())
        try Data("x".utf8).write(to: dir.appendingPathComponent(WidgetIdentity.temporaryPrefix + "crashed"))
        try Data("keep".utf8).write(to: dir.appendingPathComponent("someone-elses-file"))
        try store.delete()
        #expect(store.read() == .missing)
        #expect(store.listing() == ["someone-elses-file"], "only this module's files are removed")
        try store.delete()   // idempotent
        try WidgetSnapshotStore(directory: dir.appendingPathComponent("never-created")).delete()
    }
    @Test func theRealGroupContainersFolderIsRecognisedWhateverTheSpellingAndALinkToItToo() throws {
        let home = Scratch.make(); defer { Scratch.remove(home) }
        let groups = home.appendingPathComponent("Library/Group Containers", isDirectory: true)
        try FileManager.default.createDirectory(at: groups.appendingPathComponent("group.example"), withIntermediateDirectories: true)
        #expect(WidgetSnapshotStore.refusesRealContainer(groups, home: home))
        #expect(WidgetSnapshotStore.refusesRealContainer(groups.appendingPathComponent("group.example/deep/er"), home: home))
        #expect(WidgetSnapshotStore.refusesRealContainer(groups.appendingPathComponent("group.example/../group.example"), home: home))
        let link = home.appendingPathComponent("innocent-looking")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: groups.appendingPathComponent("group.example"))
        #expect(WidgetSnapshotStore.refusesRealContainer(link, home: home), "a symbolic link into the folder is the folder")
        #expect(!WidgetSnapshotStore.refusesRealContainer(home.appendingPathComponent("Library/Application Support"), home: home))
        #expect(!WidgetSnapshotStore.refusesRealContainer(FileManager.default.temporaryDirectory.appendingPathComponent("ytmuse-w25-x"), home: home))
        #expect(!WidgetSnapshotStore.refusesRealContainer(home.appendingPathComponent("Library/Group ContainersX"), home: home), "a sibling with the same prefix is not inside it")
    }
    @Test func theAccountStampIsAOneWayDigestThatNeverContainsTheAccountId() {
        let a = UUID(), b = UUID()
        let token = WidgetScope.token(for: a)
        #expect(token == WidgetScope.token(for: a) && token != WidgetScope.token(for: b), "stable per account, different between accounts")
        #expect(token.count == 32 && token.allSatisfy { $0.isHexDigit })
        #expect(!token.contains(a.uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8)), "the id is not recoverable from the stamp")
        let encoded = String(decoding: (try? JSONEncoder().encode(WidgetSnapshot(state: .idle, scope: WidgetScope(account: a, generation: 1)))) ?? Data(), as: UTF8.self)
        #expect(!encoded.lowercased().contains(a.uuidString.lowercased()), "the snapshot carries the digest, not the account id")
    }
    @Test func theThumbnailIsSmallAndAnUnreadablePictureIsNoPicture() throws {
        let thumbnail = try #require(WidgetArtwork.thumbnail(from: WidgetFixtures.picture(edge: 1200)))
        #expect(thumbnail.count <= WidgetSnapshot.artworkByteLimit)
        #expect(WidgetArtwork.thumbnail(from: Data("not an image".utf8)) == nil)
        #expect(WidgetArtwork.thumbnail(from: WidgetFixtures.picture(), limit: 8) == nil, "a picture that cannot be made small enough is dropped, never truncated")
    }
}
