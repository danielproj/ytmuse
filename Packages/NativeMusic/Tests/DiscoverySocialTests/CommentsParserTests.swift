import AccountSession
import CryptoKit
import Foundation
import Testing
@testable import YouTubeMusicAdapter

/// `MusicCommentsParser` against the real anonymous captures in `Fixtures/MF-comments` (2026-11-05).
///
/// What these files are: real responses with the structure, ids, entity keys, tokens, counts, printed times and like counts unchanged. The four
/// comment files had ONLY third-party personal values replaced (author names and handles become `@personNNNN`, comment text becomes same-length
/// letters), so a test that reads a comment's text or author reads a placeholder and says so. The `next` responses, the nonsense-id control, the
/// three made-for-kids examples and the stale-token shell are byte for byte what the service sent. See `Fixtures/MF-comments/manifest.json`.
private enum Comments {
    static let video = "khnokW3Mw24"
    static let firstThread = "UgwyhRsFkVy0erxIjJd4AaABAg"
    static let nonsense = "Qx7Lm2Zk9Vw"
    static let disabled = ["XqZsoesa55w", "WRVsOCh907o", "e_04ZrNroTo"]
    static func load(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: fixturesRoot().appendingPathComponent("MF-comments/" + name))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any], Comment(rawValue: name))
    }
    static func text(_ name: String) throws -> String { try String(contentsOf: fixturesRoot().appendingPathComponent("MF-comments/" + name), encoding: .utf8) }
    static func next(_ id: String) throws -> [String: Any] { try load("next-\(id).json") }
    static func page(_ name: String) throws -> MusicCommentsPage {
        try MusicCommentsParser.parsePage(try load("comments-\(video)\(name).json"), videoID: video)
    }
    static var tabsPath: [Any] { ["contents", "singleColumnMusicWatchNextResultsRenderer", "tabbedRenderer", "watchNextTabbedResultsRenderer", "tabs"] }
    static var mutationsPath: [Any] { ["frameworkUpdates", "entityBatchUpdate", "mutations"] }
    static var firstItemsPath: [Any] { ["onResponseReceivedEndpoints", 1, "reloadContinuationItemsCommand", "continuationItems"] }

    /// Returns a copy of `root` with the value at `path` replaced by `transform(old)`; a nil result removes it from its dictionary or array.
    static func edit(_ root: [String: Any], _ path: [Any], _ transform: (Any) -> Any?) -> [String: Any] {
        func go(_ value: Any, _ path: ArraySlice<Any>) -> Any? {
            guard let step = path.first else { return transform(value) }
            if let key = step as? String, var object = value as? [String: Any] {
                if let replaced = go(object[key] as Any, path.dropFirst()) { object[key] = replaced } else { object.removeValue(forKey: key) }
                return object
            }
            if let index = step as? Int, var array = value as? [Any] {
                if let replaced = go(array[index], path.dropFirst()) { array[index] = replaced } else { array.remove(at: index) }
                return array
            }
            return value
        }
        return go(root, path[...]) as? [String: Any] ?? root
    }
    static func array(_ root: [String: Any], _ path: [Any]) -> [Any] {
        var value: Any = root
        for step in path {
            if let key = step as? String { value = (value as? [String: Any])?[key] as Any } else if let index = step as? Int { value = (value as? [Any])?[index] as Any }
        }
        return value as? [Any] ?? []
    }
    static func entityPayloadCount(_ root: [String: Any]) -> Int {
        array(root, mutationsPath).filter { (($0 as? [String: Any])?["payload"] as? [String: Any])?["commentEntityPayload"] != nil }.count
    }
    static func viewModelCount(_ value: Any) -> Int {
        if let object = value as? [String: Any] {
            return object.reduce(0) { sum, pair in sum + (pair.key == "commentViewModel" && (pair.value as? [String: Any])?["commentKey"] != nil ? 1 : 0) + viewModelCount(pair.value) }
        }
        if let array = value as? [Any] { return array.reduce(0) { $0 + viewModelCount($1) } }
        return 0
    }
    static func remove(_ root: [String: Any], where predicate: (Any) -> Bool, at path: [Any]) -> [String: Any] {
        edit(root, path) { value in
            var array = (value as? [Any]) ?? []
            if let index = array.firstIndex(where: predicate) { array.remove(at: index) }
            return array
        }
    }
    static func isEntity(_ item: Any) -> Bool { (((item as? [String: Any])?["payload"]) as? [String: Any])?["commentEntityPayload"] != nil }
}

@Suite @MainActor struct CommentsParserTests {
    // MARK: Entry

    @Test func theCommentsTabIsFoundByStructureAndPublishesTheFirstPageContinuation() throws {
        let english = try MusicCommentsParser.parseEntry(Comments.next(Comments.video), videoID: Comments.video)
        guard case .continuation(let token) = english else { Issue.record("expected a continuation, got \(english)"); return }
        #expect(MusicBrowseParser.isToken(token) && token.count >= 40)
        // The same song with the interface in German: the tab is called "Kommentare", and is still found.
        let raw = try Comments.text("next-\(Comments.video)-de.json")
        #expect(raw.contains("\"title\": \"Kommentare\"") && !raw.contains("\"title\": \"Comments\""), "the German capture really names the tab differently")
        let german = try MusicCommentsParser.parseEntry(Comments.next("\(Comments.video)-de"), videoID: Comments.video)
        guard case .continuation(let germanToken) = german else { Issue.record("expected a continuation, got \(german)"); return }
        #expect(MusicBrowseParser.isToken(germanToken))
        // A continuation that names another video is not this video's answer.
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parseEntry(Comments.next(Comments.video), videoID: "aaaaaaaaaa1") }
    }

    @Test func theNonsenseIdControlEchoesItselfAndStillNeverYieldsAMessage() throws {
        let root = try Comments.next(Comments.nonsense)
        // Companion: the control really is the trap. The id is echoed and the tab really prints the disabled wording.
        let raw = try Comments.text("next-\(Comments.nonsense).json")
        #expect(raw.contains("Comments are turned off"))
        let echoed = ((root["currentVideoEndpoint"] as? [String: Any])?["watchEndpoint"] as? [String: Any])?["videoId"] as? String
        #expect(echoed == Comments.nonsense, "the service echoes an id that does not exist")
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parseEntry(root, videoID: Comments.nonsense) }
    }

    @Test func theStaleContinuationShellIsUnreadableAndNeverDisabledOrEmpty() throws {
        let shell = try Comments.load("comments-invalid-continuation.json")
        #expect(try Comments.text("comments-invalid-continuation.json").contains("Comments are turned off"), "the shell really prints the disabled wording")
        #expect(shell["contents"] != nil && shell["onResponseReceivedEndpoints"] == nil)
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parseEntry(shell, videoID: Comments.video) }
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parsePage(shell, videoID: Comments.video) }
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parseReplies(shell, parentID: Comments.firstThread) }
    }

    @Test func aMessageIsAServiceMessageOnlyForARealVideoThatTheResponseIdentifies() throws {
        for id in Comments.disabled {
            let root = try Comments.next(id)
            let entry = try MusicCommentsParser.parseEntry(root, videoID: id)
            guard case .serviceMessage(let text) = entry else { Issue.record("\(id): expected the service's message, got \(entry)"); continue }
            #expect(text == "Comments are turned off.", Comment(rawValue: id))
            // Companion: the real tab really carries a link run ("Learn more"), so the exact text proves it is left out rather than never there.
            let tabText = try Comments.text("next-\(id).json")
            #expect(tabText.contains("\"text\": \"Learn more\"") && tabText.contains("\"urlEndpoint\""), Comment(rawValue: id))
            // The same response asked about another video, or with its selected queue row gone or unselected, or without the echo, is unreadable.
            #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parseEntry(root, videoID: Comments.video) }
            let rowPath: [Any] = Comments.tabsPath + [0, "tabRenderer", "content", "musicQueueRenderer", "content", "playlistPanelRenderer", "contents", 0, "playlistPanelVideoRenderer"]
            let unselected = Comments.edit(root, rowPath + ["selected"]) { _ in false }
            #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parseEntry(unselected, videoID: id) }
            let otherRow = Comments.edit(root, rowPath + ["videoId"]) { _ in "aaaaaaaaaa1" }
            #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parseEntry(otherRow, videoID: id) }
            var noEcho = root
            noEcho["currentVideoEndpoint"] = nil
            #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parseEntry(noEcho, videoID: id) }
            let otherEcho = Comments.edit(root, ["currentVideoEndpoint", "watchEndpoint", "videoId"]) { _ in "aaaaaaaaaa1" }
            #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parseEntry(otherEcho, videoID: id) }
        }
    }

    @Test func aWatchNextPageWithoutACommentsTabIsNotOfferedAndOneWithoutTheQueueIsUnreadable() throws {
        let root = try Comments.next(Comments.video)
        let tabs = Comments.array(root, Comments.tabsPath)
        let commentsIndex = try #require(tabs.firstIndex { (($0 as? [String: Any])?["tabRenderer"] as? [String: Any])?["title"] as? String == "Comments" })
        let without = Comments.edit(root, Comments.tabsPath + [commentsIndex]) { _ in nil }
        #expect(try MusicCommentsParser.parseEntry(without, videoID: Comments.video) == .notOffered)
        let noQueue = Comments.edit(root, Comments.tabsPath + [0]) { _ in nil }
        let withoutBoth = Comments.edit(noQueue, Comments.tabsPath + [commentsIndex - 1]) { _ in nil }
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parseEntry(withoutBoth, videoID: Comments.video) }
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parseEntry([:], videoID: Comments.video) }
    }

    /// The index of the Comments tab in a `next` response, found as the one whose content is not the queue.
    private func commentsTabIndex(_ root: [String: Any]) throws -> Int {
        let tabs = Comments.array(root, Comments.tabsPath)
        return try #require(tabs.firstIndex {
            guard let content = (($0 as? [String: Any])?["tabRenderer"] as? [String: Any])?["content"] as? [String: Any] else { return false }
            return content["sectionListRenderer"] != nil || content["messageRenderer"] != nil
        })
    }

    @Test func aCommentsTabWithContentThisParserDoesNotKnowIsUnreadableNeverNotOffered() throws {
        let root = try Comments.next(Comments.video)
        let index = try commentsTabIndex(root)
        let tab: [Any] = Comments.tabsPath + [index, "tabRenderer"]
        // Control: the unedited capture reads, and a Comments tab with no content at all (the shape of Lyrics and Related) is skipped as not offered.
        #expect(try MusicCommentsParser.parseEntry(root, videoID: Comments.video) == .continuation(try tokenOf(root)))
        #expect(try MusicCommentsParser.parseEntry(Comments.edit(root, tab + ["content"]) { _ in nil }, videoID: Comments.video) == .notOffered)
        // 1. The content becomes a renderer kind this parser does not know.
        let unknownKind = Comments.edit(root, tab + ["content"]) { _ in ["itemSectionRenderer": ["contents": [] as [Any]]] }
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parseEntry(unknownKind, videoID: Comments.video) }
        // 2. The section list loses its targetId (only that).
        let noTarget = Comments.edit(root, tab + ["content", "sectionListRenderer", "targetId"]) { _ in nil }
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parseEntry(noTarget, videoID: Comments.video) }
        // 3. The section list loses its continuations (only that).
        let noContinuations = Comments.edit(root, tab + ["content", "sectionListRenderer", "continuations"]) { _ in nil }
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parseEntry(noContinuations, videoID: Comments.video) }
        // 3b. The continuations are there but not a reload continuation.
        let notReload = Comments.edit(root, tab + ["content", "sectionListRenderer", "continuations"]) { _ in [["nextContinuationData": ["continuation": "x"]]] }
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parseEntry(notReload, videoID: Comments.video) }
    }

    @Test func aMessageTabThatAlsoNamesABrowseEndpointIsUnreadableNeverAMessage() throws {
        for id in Comments.disabled {
            let root = try Comments.next(id)
            let index = try commentsTabIndex(root)
            #expect(try MusicCommentsParser.parseEntry(root, videoID: id) == .serviceMessage("Comments are turned off."), "control: the unedited capture reads")
            // 4. Only the endpoint is added; the message, the echo and the selected queue row stay the service's own.
            let withEndpoint = Comments.edit(root, Comments.tabsPath + [index, "tabRenderer", "endpoint"]) { _ in ["browseEndpoint": ["browseId": "MPLYt_aaaaaaaaaaa"]] }
            #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parseEntry(withEndpoint, videoID: id) }
        }
    }

    @Test func contentThatIsPresentButNotAnObjectOfOneKnownKindIsUnreadable() throws {
        let root = try Comments.next(Comments.video)
        let index = try commentsTabIndex(root)
        let path: [Any] = Comments.tabsPath + [index, "tabRenderer", "content"]
        // A present value that is not an object must not be cast to nil and skipped like an absent one.
        for malformed in [NSNull(), "sectionListRenderer", [Any](), 7] as [Any] {
            #expect(throws: MusicSessionError.unrecognised, Comment(rawValue: "\(malformed)")) { try MusicCommentsParser.parseEntry(Comments.edit(root, path) { _ in malformed }, videoID: Comments.video) }
        }
        // An empty object, a known kind next to another, a known kind that is not an object: all unreadable.
        let list = try #require(Comments.array(root, Comments.tabsPath).compactMap { (($0 as? [String: Any])?["tabRenderer"] as? [String: Any])?["content"] as? [String: Any] }.first { $0["sectionListRenderer"] != nil })
        for malformed: [String: Any] in [[:], list.merging(["messageRenderer": ["text": ["runs": [["text": "x"]]]]]) { $1 }, ["sectionListRenderer": "x"], ["messageRenderer": [Any]()]] {
            #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parseEntry(Comments.edit(root, path) { _ in malformed }, videoID: Comments.video) }
        }
        // The queue tab too: present but not an object is not "the queue", and a page without the queue is unreadable.
        let queuePath: [Any] = Comments.tabsPath + [0, "tabRenderer", "content", "musicQueueRenderer"]
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parseEntry(Comments.edit(root, queuePath) { _ in "x" }, videoID: Comments.video) }
    }

    @Test func otherRealWatchNextCapturesPublishTheirOwnContinuationUnderTheirOwnId() throws {
        // Cross-capture evidence beyond khnokW3Mw24: a different song page (captured 2026-11-03), a song radio and an artist radio.
        let cases = [("W18-real/next-song.json", "khnokW3Mw24"), ("R1-real/next-radio.json", "Rgrt_8mXrK8"), ("R2-real/next-radio-artist.json", "Zgbfx0KLwUk")]
        for (file, id) in cases {
            let data = try Data(contentsOf: fixturesRoot().appendingPathComponent(file))
            let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any], Comment(rawValue: file))
            guard case .continuation(let token) = try MusicCommentsParser.parseEntry(root, videoID: id) else { Issue.record("\(file): expected a continuation"); continue }
            #expect(MusicBrowseParser.isToken(token), Comment(rawValue: file))
            // Under any other id the same page is unreadable: the continuation names its own video.
            #expect(throws: MusicSessionError.unrecognised, Comment(rawValue: file)) { try MusicCommentsParser.parseEntry(root, videoID: "aaaaaaaaaa1") }
        }
    }

    private func tokenOf(_ root: [String: Any]) throws -> String {
        guard case .continuation(let token) = try MusicCommentsParser.parseEntry(root, videoID: Comments.video) else { throw MusicSessionError.unrecognised }
        return token
    }

    // MARK: First page, sort, next page

    @Test func theFirstPageReadsTwentyThreadsThePrintedCountsAndBothSortTokens() throws {
        let page = try Comments.page("")
        #expect(page.threads.count == 20)
        let header = try #require(page.header)
        #expect(header.countText == "2,904 Comments" && header.shortCountText == "2.9K")
        #expect(header.sortOptions.map(\.title) == ["Top", "Newest"] && header.sortOptions.map(\.isSelected) == [true, false])
        #expect(Set(header.sortOptions.map(\.token)).count == 2 && header.sortOptions.allSatisfy { MusicBrowseParser.isToken($0.token) })
        #expect(header.posting == .signInRequired, "anonymously the box is a sign-in prompt")
        #expect(MusicBrowseParser.isToken(try #require(page.nextToken)))
        let first = try #require(page.threads.first)
        #expect(first.comment.id == Comments.firstThread && first.comment.replyLevel == 0 && first.comment.parentID == nil)
        #expect(first.comment.publishedTime == "4 weeks ago" && first.comment.likeCountText == "306" && first.comment.replyCountText == "10")
        #expect(MusicBrowseParser.isToken(try #require(first.repliesToken)) && first.inlineReplies.isEmpty)
        #expect(page.threads.contains { $0.repliesToken == nil && $0.comment.replyCountText == nil }, "a thread with no replies publishes no replies continuation")
        // Derived values: the author is a placeholder, the text is placeholder letters of the original's length, and nobody is the current user.
        #expect(page.threads.allSatisfy { $0.comment.authorName.hasPrefix("@person") && !$0.comment.isCurrentUser && !$0.comment.text.isEmpty })
        #expect(page.threads.filter(\.comment.isArtist).count == 1)
        #expect(Set(page.threads.map(\.comment.id)).count == 20)
    }

    @Test func theSecondPageAppendsTwentyMoreThreadsWithoutAHeader() throws {
        let first = try Comments.page(""), second = try Comments.page("-page2")
        #expect(second.header == nil && second.threads.count == 20)
        #expect(MusicBrowseParser.isToken(try #require(second.nextToken)) && second.nextToken != first.nextToken)
        #expect(Set(first.threads.map(\.comment.id)).isDisjoint(with: Set(second.threads.map(\.comment.id))))
        // Another video's page, and a reply page, are not a comments page for this video.
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parsePage(Comments.load("comments-\(Comments.video)-page2.json"), videoID: "aaaaaaaaaa1") }
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parsePage(Comments.load("comments-\(Comments.video)-replies.json"), videoID: Comments.video) }
    }

    @Test func newestIsAnotherOrderWithItsOwnSelectedSortAndNoTargetId() throws {
        let top = try Comments.page(""), newest = try Comments.page("-newest")
        let targets = Comments.array(try Comments.load("comments-\(Comments.video)-newest.json"), ["onResponseReceivedEndpoints"]).compactMap { (($0 as? [String: Any])?["reloadContinuationItemsCommand"] as? [String: Any])?["targetId"] }
        #expect(targets.isEmpty, "the Newest capture prints no target, which is why a page's target is compared only when it prints one")
        let header = try #require(newest.header)
        #expect(header.sortOptions.map(\.title) == ["Top", "Newest"] && header.sortOptions.map(\.isSelected) == [false, true])
        #expect(newest.threads.count == 20 && newest.threads.map(\.comment.id) != top.threads.map(\.comment.id))
        #expect(Set(newest.threads.map(\.comment.id)) != Set(top.threads.map(\.comment.id)))
    }

    // MARK: Replies

    @Test func theRepliesPageYieldsTenRepliesFromNineItemsIncludingTheNestedOne() throws {
        let root = try Comments.load("comments-\(Comments.video)-replies.json")
        let items = Comments.array(root, ["onResponseReceivedEndpoints", 0, "appendContinuationItemsAction", "continuationItems"])
        #expect(items.count == 9, "the page lists nine items")
        let replies = try MusicCommentsParser.parseReplies(root, parentID: Comments.firstThread)
        #expect(replies.replies.count == 10 && replies.parentID == Comments.firstThread && replies.nextToken == nil)
        #expect(replies.replies.allSatisfy { $0.id.hasPrefix(Comments.firstThread + ".") && $0.parentID == Comments.firstThread })
        #expect(replies.replies.map(\.replyLevel) == [1, 1, 1, 1, 1, 1, 1, 1, 2, 1], "the ninth reply hangs under the eighth and is a level-2 reply")
        #expect(replies.replies[8].publishedTime == "10 hours ago" && Set(replies.replies.map(\.id)).count == 10)
        // The thread it answers for is checked: another thread's id is refused.
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parseReplies(root, parentID: "UgzzzzzzzzzzzzzzzzzzzzzzzzzzAaABAg") }
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parseReplies(root, parentID: "not a thread id") }
    }

    // MARK: Joins

    @Test func everyViewModelJoinsExactlyOneEntityAcrossAllFourCommentFiles() throws {
        var entities = 0, models = 0, parsed = 0
        for name in ["", "-page2", "-newest", "-replies"] {
            let root = try Comments.load("comments-\(Comments.video)\(name).json")
            entities += Comments.entityPayloadCount(root); models += Comments.viewModelCount(root)
            if name == "-replies" { parsed += try MusicCommentsParser.parseReplies(root, parentID: Comments.firstThread).replies.count }
            else { parsed += try MusicCommentsParser.parsePage(root, videoID: Comments.video).threads.count }
        }
        #expect(entities == 70 && models == 70 && parsed == 70, "entities \(entities), view models \(models), comments read \(parsed)")
    }

    @Test func theJoinIsByKeyNotByPositionSoReorderingTheEntitiesChangesNothing() throws {
        let root = try Comments.load("comments-\(Comments.video).json")
        let reversed = Comments.edit(root, Comments.mutationsPath) { Array(($0 as? [Any] ?? []).reversed()) }
        #expect(try MusicCommentsParser.parsePage(reversed, videoID: Comments.video) == (try Comments.page("")))
        // And a view model that names another thread's entity is refused rather than quietly rebound: ids must agree with the entity's own.
        let items = Comments.array(root, Comments.firstItemsPath)
        var second = try #require((items[1] as? [String: Any])?["commentThreadRenderer"] as? [String: Any])
        var model = try #require((second["commentViewModel"] as? [String: Any])?["commentViewModel"] as? [String: Any])
        let firstModel = try #require((((items[0] as? [String: Any])?["commentThreadRenderer"] as? [String: Any])?["commentViewModel"] as? [String: Any])?["commentViewModel"] as? [String: Any])
        model["commentKey"] = firstModel["commentKey"]
        second["commentViewModel"] = ["commentViewModel": model]
        let swapped = Comments.edit(root, Comments.firstItemsPath + [1]) { _ in ["commentThreadRenderer": second] }
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parsePage(swapped, videoID: Comments.video) }
    }

    @Test func aThreadWhoseEntityIsMissingFailsTheWholeReadAndIsNeverDropped() throws {
        let root = try Comments.load("comments-\(Comments.video).json")
        let without = Comments.remove(root, where: Comments.isEntity, at: Comments.mutationsPath)
        #expect(Comments.entityPayloadCount(without) == 19)
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parsePage(without, videoID: Comments.video) }
        let replies = try Comments.load("comments-\(Comments.video)-replies.json")
        let noNested = Comments.remove(replies, where: Comments.isEntity, at: Comments.mutationsPath)
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parseReplies(noNested, parentID: Comments.firstThread) }
    }

    @Test func anEntityNoThreadUsesFailsTheReadSoNothingIsLeftBehindSilently() throws {
        let root = try Comments.load("comments-\(Comments.video).json")
        let fewerThreads = Comments.edit(root, Comments.firstItemsPath + [3]) { _ in nil }
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parsePage(fewerThreads, videoID: Comments.video) }
        // The reply page without its nested sub-thread leaves the nested entity unused: refused.
        let replies = try Comments.load("comments-\(Comments.video)-replies.json")
        let path: [Any] = ["onResponseReceivedEndpoints", 0, "appendContinuationItemsAction", "continuationItems", 7, "commentThreadRenderer", "replies"]
        let flat = Comments.edit(replies, path) { _ in nil }
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parseReplies(flat, parentID: Comments.firstThread) }
    }

    @Test func aRepeatedEntityKeyAndADifferentOwnKeyAreRefused() throws {
        let root = try Comments.load("comments-\(Comments.video).json")
        let mutations = Comments.array(root, Comments.mutationsPath)
        let entity = try #require(mutations.first(where: Comments.isEntity))
        let duplicated = Comments.edit(root, Comments.mutationsPath) { ($0 as? [Any] ?? []) + [entity] }
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parsePage(duplicated, videoID: Comments.video) }
        var renamed = try #require(entity as? [String: Any])
        renamed["entityKey"] = "EhpWrongKeyWrongKeyWrongKeyAAAA%3D"
        let first = try #require(mutations.firstIndex(where: Comments.isEntity))
        let mismatched = Comments.edit(root, Comments.mutationsPath + [first]) { _ in renamed }
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parsePage(mismatched, videoID: Comments.video) }
    }

    @Test func aRepliesAnswerNamingAnotherThreadIsRefusedByItsTargetIdAlone() throws {
        // Everything else stays the real parent's: the replies, their ids and the parentID passed. Only the answer's own targetId changes.
        let root = try Comments.load("comments-\(Comments.video)-replies.json")
        let path: [Any] = ["onResponseReceivedEndpoints", 0, "appendContinuationItemsAction", "targetId"]
        #expect(Comments.array(root, ["onResponseReceivedEndpoints"]).count == 1)
        #expect(try MusicCommentsParser.parseReplies(root, parentID: Comments.firstThread).replies.count == 10, "control: unedited")
        let other = Comments.edit(root, path) { _ in "comment-replies-item-UgzzzzzzzzzzzzzzzzzzzzzzzzzzAaABAg" }
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parseReplies(other, parentID: Comments.firstThread) }
        let missing = Comments.edit(root, path) { _ in nil }
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parseReplies(missing, parentID: Comments.firstThread) }
    }

    @Test func aReplyWhoseIdBelongsToAnotherThreadIsRefusedByItsPrefixAlone() throws {
        // The targetId and parentID stay the real thread's. One reply's id is rewritten everywhere it is printed (its view model and its
        // entity), so the join, the level and the structure all agree and ONLY the reply-id prefix is wrong.
        let text = try Comments.text("comments-\(Comments.video)-replies.json")
        let replies = try MusicCommentsParser.parseReplies(Comments.load("comments-\(Comments.video)-replies.json"), parentID: Comments.firstThread)
        let victim = try #require(replies.replies.first { $0.replyLevel == 1 }).id
        let foreign = "UgzzzzzzzzzzzzzzzzzzzzzzzzzzAaABAg.9ZZZZZZZZZZ"
        #expect(text.components(separatedBy: "\"\(victim)\"").count - 1 >= 2, "the id is printed in the view model and in the entity")
        let rewritten = try #require(try JSONSerialization.jsonObject(with: Data(text.replacingOccurrences(of: "\"\(victim)\"", with: "\"\(foreign)\"").utf8)) as? [String: Any])
        #expect(Comments.entityPayloadCount(rewritten) == 10 && Comments.viewModelCount(rewritten) == 10)
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parseReplies(rewritten, parentID: Comments.firstThread) }
        // Control: the same rewrite to an id under THIS thread reads (so the prefix check is the only thing that refused the foreign one).
        let sibling = Comments.firstThread + ".9ZZZZZZZZZZ"
        let accepted = try #require(try JSONSerialization.jsonObject(with: Data(text.replacingOccurrences(of: "\"\(victim)\"", with: "\"\(sibling)\"").utf8)) as? [String: Any])
        #expect(try MusicCommentsParser.parseReplies(accepted, parentID: Comments.firstThread).replies.contains { $0.id == sibling })
    }

    @Test func anEntityWhoseOwnKeyDiffersFromItsDeliveredKeyIsRefusedByTheSelfKeyAlone() throws {
        // entityKey (what the mutation is delivered under) and the thread's commentKey stay the real ones, so the join succeeds.
        // Only the key printed inside the payload changes.
        let root = try Comments.load("comments-\(Comments.video).json")
        let index = try #require(Comments.array(root, Comments.mutationsPath).firstIndex(where: Comments.isEntity))
        let keyPath: [Any] = Comments.mutationsPath + [index, "payload", "commentEntityPayload", "key"]
        let own = Comments.array(root, Comments.mutationsPath)[index] as? [String: Any]
        #expect(((own?["payload"] as? [String: Any])?["commentEntityPayload"] as? [String: Any])?["key"] as? String == own?["entityKey"] as? String, "control: the real payload names its own key")
        let other = Comments.edit(root, keyPath) { _ in "EhpWrongKeyWrongKeyWrongKeyAAAA%3D" }
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parsePage(other, videoID: Comments.video) }
        let missing = Comments.edit(root, keyPath) { _ in nil }
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parsePage(missing, videoID: Comments.video) }
    }

    // MARK: Posting and the disabled wording

    @Test func theCommentBoxDisabledTextIsOnEveryNormalPageAndIsNeverAState() throws {
        let raw = try Comments.text("comments-\(Comments.video).json")
        #expect(raw.contains("\"disabledText\": \"Comments are turned off.\""), "a normal, readable page really carries the wording")
        let root = try Comments.load("comments-\(Comments.video).json")
        let page = try MusicCommentsParser.parsePage(root, videoID: Comments.video)
        #expect(page.threads.count == 20)
        // Removing the text changes nothing the parser reports, so it is not read at all.
        let path: [Any] = ["onResponseReceivedEndpoints", 0, "reloadContinuationItemsCommand", "continuationItems", 0, "commentsHeaderRenderer", "createRenderer", "commentSimpleboxRenderer", "disabledText"]
        let stripped = Comments.edit(root, path) { _ in nil }
        #expect(!(String(data: try JSONSerialization.data(withJSONObject: stripped), encoding: .utf8) ?? "").contains("\"disabledText\""), "the wording is really gone from the copy")
        #expect(try MusicCommentsParser.parsePage(stripped, videoID: Comments.video) == page)
    }

    @Test func aBoxWithoutASignInPromptOffersNothing() throws {
        let root = try Comments.load("comments-\(Comments.video).json")
        let path: [Any] = ["onResponseReceivedEndpoints", 0, "reloadContinuationItemsCommand", "continuationItems", 0, "commentsHeaderRenderer", "createRenderer", "commentSimpleboxRenderer", "prepareAccountEndpoint"]
        let page = try MusicCommentsParser.parsePage(Comments.edit(root, path) { _ in nil }, videoID: Comments.video)
        #expect(page.header?.posting == .notPublished)
    }

    // MARK: Shapes and bounds

    @Test func anEnvelopeWithNothingInItIsAShellAndAHeaderOnlyEnvelopeIsAnEmptyPage() throws {
        let root = try Comments.load("comments-\(Comments.video).json")
        let empty: [String: Any] = ["onResponseReceivedEndpoints": [["reloadContinuationItemsCommand": ["targetId": Comments.video, "continuationItems": [] as [Any]]]]]
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parsePage(empty, videoID: Comments.video) }
        var headerOnly = Comments.edit(root, ["onResponseReceivedEndpoints"]) { value in Array((value as? [Any] ?? []).prefix(1)) }
        // With the 20 entities still present and no thread to use them, the join refuses (an entity nothing refers to is a thread not read).
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parsePage(headerOnly, videoID: Comments.video) }
        headerOnly["frameworkUpdates"] = nil
        let page = try MusicCommentsParser.parsePage(headerOnly, videoID: Comments.video)
        #expect(page.header != nil && page.threads.isEmpty && page.nextToken == nil)
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parsePage(["error": ["code": 400]], videoID: Comments.video) }
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parsePage([:], videoID: "short") }
    }

    @Test func tokensTextAndAuthorFlagsAreCheckedNotTrusted() throws {
        let root = try Comments.load("comments-\(Comments.video).json")
        let badToken = Comments.edit(root, Comments.firstItemsPath + [20, "continuationItemRenderer", "continuationEndpoint", "continuationCommand", "token"]) { _ in "not a token\n" }
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parsePage(badToken, videoID: Comments.video) }
        let mutations = Comments.array(root, Comments.mutationsPath)
        let index = try #require(mutations.firstIndex(where: Comments.isEntity))
        let longText = Comments.edit(root, Comments.mutationsPath + [index, "payload", "commentEntityPayload", "properties", "content", "content"]) { _ in String(repeating: "x", count: 10_001) }
        #expect(throws: MusicSessionError.oversized) { try MusicCommentsParser.parsePage(longText, videoID: Comments.video) }
        let exactly = Comments.edit(root, Comments.mutationsPath + [index, "payload", "commentEntityPayload", "properties", "content", "content"]) { _ in String(repeating: "x", count: 10_000) }
        #expect(try MusicCommentsParser.parsePage(exactly, videoID: Comments.video).threads.first?.comment.text.count == 10_000)
        // The flags are the service's: a true `isCurrentUser` is passed on as published, a non-boolean one is refused.
        let flagPath: [Any] = Comments.mutationsPath + [index, "payload", "commentEntityPayload", "author", "isCurrentUser"]
        #expect(try MusicCommentsParser.parsePage(Comments.edit(root, flagPath) { _ in true }, videoID: Comments.video).threads.first?.comment.isCurrentUser == true)
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parsePage(Comments.edit(root, flagPath) { _ in "yes" }, videoID: Comments.video) }
    }

    @Test func aReplyListedAsATopLevelThreadIsRefused() throws {
        // The reply page's items are replies (ids with a dot, level 1): handed to the thread reader they must not be read as threads.
        let replies = try Comments.load("comments-\(Comments.video)-replies.json")
        let asPage = Comments.edit(replies, ["onResponseReceivedEndpoints", 0, "appendContinuationItemsAction", "targetId"]) { _ in Comments.video }
        #expect(throws: MusicSessionError.unrecognised) { try MusicCommentsParser.parsePage(asPage, videoID: Comments.video) }
    }

    // MARK: The fixtures themselves

    @Test func theCommentFixturesArePinnedByTheirManifestAndSayWhatTheyAre() throws {
        let manifest = try Comments.load("manifest.json")
        let files = try #require(manifest["files"] as? [[String: Any]])
        #expect(files.count == 11 && manifest["live_eligible"] as? Bool == false)
        // The manifest says what the sanitizing is: content only, the retained identifiers still resolve to the real public comments.
        let description = try #require(manifest["description"] as? String)
        #expect(description.contains("content sanitizing, not anonymization") && description.contains("still point at the real public comments"))
        for entry in files {
            let path = try #require(entry["path"] as? String), hash = try #require(entry["sha256"] as? String)
            let data = try Data(contentsOf: fixturesRoot().appendingPathComponent("MF-comments/" + path))
            #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == hash, Comment(rawValue: path))
            let mode = entry["mode"] as? String
            #expect(mode == (path.hasPrefix("comments-khnokW3Mw24") ? "real-anonymous-capture-sanitized" : "real-anonymous-capture"), Comment(rawValue: path))
            #expect(entry["live_eligible"] as? Bool == false && (entry["derivedFrom"] as? [String: Any])?["sha256"] is String)
        }
        // The sanitized files hold no handle the service printed: every @-name in them is a placeholder.
        for path in ["", "-page2", "-newest", "-replies"] {
            let text = try Comments.text("comments-\(Comments.video)\(path).json")
            let handles = try text.matches(of: Regex("@[A-Za-z0-9._\\-]+")).map { String(text[$0.range]) }
            #expect(!handles.isEmpty && handles.allSatisfy { $0.hasPrefix("@person") }, Comment(rawValue: path))
        }
    }
}
