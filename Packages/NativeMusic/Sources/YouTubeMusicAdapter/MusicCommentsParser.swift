import AccountSession
import Foundation

/// Reads a song's comments from YouTube Music's own `next` responses: the Comments tab of the watch-next page, the first page and sort
/// switch, continuation pages and reply pages. Pure functions over decoded JSON; no network, no account, no write.
///
/// Built on the real anonymous captures in `Fixtures/MF-comments` (2026-11-05). What the captures show, and what this parser therefore does:
/// - The Comments tab is found by STRUCTURE, never by its title (the German page calls it "Kommentare"). A tab whose content is a
///   `sectionListRenderer` with a `reloadContinuationData` and a `targetId` publishes the first-page continuation; a tab whose content is a
///   bare `messageRenderer` (and which names no browse endpoint, unlike Lyrics and Related) prints a message.
/// - A message is trusted only when the SAME response identifies the requested video: a nonsense 11-character id echoes itself in
///   `currentVideoEndpoint` and still answers "Comments are turned off.", and so does a stale continuation. The identity rule is a selected
///   `playlistPanelVideoRenderer` for exactly the requested id. A message in any other response is unreadable, never a disabled state.
/// - A continuation answer is an `onResponseReceivedEndpoints` envelope. A watch shell in its place (a stale or invalid token) is unreadable.
/// - Threads hold only view-model KEYS; the text and the author are entities in `frameworkUpdates.entityBatchUpdate.mutations`. Every thread
///   joins to its entity by key, a missing entity throws, and an entity no thread uses throws too: nothing is dropped silently.
/// - A reply page lists its replies as top-level items, but a reply can carry inline sub-threads of its own (a reply to a reply, level 2).
///   Those are walked; the item count is not the reply count.
/// - The comment box carries a `disabledText` on every normal page. It is never a state.
///
/// Internal notes (not surfaced anywhere): the Newest response carries no `targetId`, so a page's `targetId` is compared with the requested
/// video only when the page prints one. No capture of a video with zero comments exists; a valid envelope with a header and no thread is
/// read as an empty page, an envelope with nothing at all is unreadable. Signed shapes (a posting offer, delete, moderation) are not read.
public enum MusicCommentsParser {
    public static let maxThreadsPerPage = 100
    public static let maxRepliesPerPage = 100
    public static let maxNestingDepth = 4
    public static let maxTextCharacters = 10_000
    static let maxPrinted = 200
    static let maxMessage = 500
    static let maxEntities = 2000
    static let maxSortOptions = 8
    private static let commentIDPattern = #"^[A-Za-z0-9_-]{1,128}(\.[A-Za-z0-9_-]{1,128})*$"#
    private static let threadIDPattern = #"^[A-Za-z0-9_-]{1,128}$"#
    private static let keyPattern = #"^[A-Za-z0-9%_=+/.-]{1,1024}$"#

    // MARK: Entry (the Comments tab of a `next` response)

    public static func parseEntry(_ root: [String: Any], videoID: String) throws(MusicSessionError) -> MusicCommentsEntry {
        guard root["error"] == nil, MusicBrowseParser.isVideoID(videoID),
              let single = (root["contents"] as? [String: Any])?["singleColumnMusicWatchNextResultsRenderer"] as? [String: Any],
              let tabbed = (single["tabbedRenderer"] as? [String: Any])?["watchNextTabbedResultsRenderer"] as? [String: Any],
              let tabs = tabbed["tabs"] as? [[String: Any]], !tabs.isEmpty, tabs.count <= 8 else { throw .unrecognised }
        var queue = false
        var continuation: String?
        var message: String?
        var candidates = 0
        for entry in tabs {
            guard let tab = entry["tabRenderer"] as? [String: Any] else { throw .unrecognised }
            // No `content` at all is the shape of Lyrics and Related (they carry a browse `endpoint`): skipped. A `content` that is PRESENT
            // must be exactly one of the three shapes below, however malformed; anything else is unreadable, never a quiet "not offered".
            guard let rawContent = tab["content"] else { continue }
            guard let content = rawContent as? [String: Any], content.count == 1, let kind = content.keys.first else { throw .unrecognised }
            switch kind {
            case "musicQueueRenderer":
                guard content[kind] is [String: Any] else { throw .unrecognised }
                queue = true
            case "sectionListRenderer":
                // The recognised comments continuation: BOTH a reload continuation with a token AND the video it belongs to.
                guard let list = content[kind] as? [String: Any],
                      let published = (list["continuations"] as? [[String: Any]])?.compactMap({ $0["reloadContinuationData"] as? [String: Any] }).first,
                      let target = list["targetId"] as? String,
                      // A tab that publishes a first-page continuation names the video it belongs to; another video's is not this answer.
                      target == videoID, let token = published["continuation"] as? String, MusicBrowseParser.isToken(token) else { throw .unrecognised }
                candidates += 1; continuation = token
            case "messageRenderer":
                // The recognised message: a bare message on a tab that names no browse endpoint (Lyrics and Related name one).
                guard let box = content[kind] as? [String: Any], tab["endpoint"] == nil else { throw .unrecognised }
                // The link run ("Learn more") is a label for a link this model does not carry: only the runs without a navigation endpoint are text.
                let text = MusicBrowseParser.runs(box["text"]).filter { $0["navigationEndpoint"] == nil }.compactMap { $0["text"] as? String }
                    .joined().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text.count <= maxMessage else { throw .unrecognised }
                candidates += 1; message = text
            default:
                throw .unrecognised
            }
        }
        // A page without the up-next queue is not a watch-next page: "not offered" must never be read off an unrecognised response.
        guard queue, candidates <= 1 else { throw .unrecognised }
        if let continuation { return .continuation(continuation) }
        if let message {
            guard identifies(root, tabs: tabs, videoID: videoID) else { throw .unrecognised }
            return .serviceMessage(message)
        }
        return .notOffered
    }

    /// The identity rule: the response names the requested video as its current video AND carries the selected queue row for exactly that id.
    /// The current-video echo alone is not enough (an id that does not exist is echoed); the queue row is what a real video has.
    static func identifies(_ root: [String: Any], tabs: [[String: Any]], videoID: String) -> Bool {
        let current = ((root["currentVideoEndpoint"] as? [String: Any])?["watchEndpoint"] as? [String: Any])?["videoId"] as? String
        guard current == videoID else { return false }
        for entry in tabs {
            let queue = ((entry["tabRenderer"] as? [String: Any])?["content"] as? [String: Any])?["musicQueueRenderer"] as? [String: Any]
            let rows = (((queue?["content"] as? [String: Any])?["playlistPanelRenderer"] as? [String: Any])?["contents"] as? [[String: Any]]) ?? []
            for row in rows {
                if let video = row["playlistPanelVideoRenderer"] as? [String: Any], video["videoId"] as? String == videoID, video["selected"] as? Bool == true { return true }
            }
        }
        return false
    }

    // MARK: Page (first page, sort switch, continuation page)

    public static func parsePage(_ root: [String: Any], videoID: String) throws(MusicSessionError) -> MusicCommentsPage {
        guard root["error"] == nil, MusicBrowseParser.isVideoID(videoID),
              let endpoints = root["onResponseReceivedEndpoints"] as? [[String: Any]], !endpoints.isEmpty, endpoints.count <= 4 else { throw .unrecognised }
        let entities = try Entities(root)
        var context = Walk(entities: entities)
        var header: MusicCommentsHeader?
        var threads: [MusicCommentThread] = []
        var next: String?
        for endpoint in endpoints {
            let command = (endpoint["reloadContinuationItemsCommand"] as? [String: Any]) ?? (endpoint["appendContinuationItemsAction"] as? [String: Any])
            guard let command, let items = command["continuationItems"] as? [[String: Any]], items.count <= maxThreadsPerPage + 2 else { throw .unrecognised }
            if let target = command["targetId"] { guard target as? String == videoID else { throw .unrecognised } }
            for item in items {
                if let renderer = item["commentsHeaderRenderer"] as? [String: Any] {
                    guard header == nil else { throw .unrecognised }
                    header = try parseHeader(renderer)
                } else if let renderer = item["commentThreadRenderer"] as? [String: Any] {
                    guard threads.count < maxThreadsPerPage else { throw .oversized }
                    threads.append(try context.thread(renderer))
                } else if let renderer = item["continuationItemRenderer"] as? [String: Any] {
                    guard next == nil, let token = continuationToken(renderer) else { throw .unrecognised }
                    next = token
                } else { throw .unrecognised }
            }
        }
        // A reply listed under a top-level thread's page, or a top-level comment in a reply page, would be a different list.
        guard threads.allSatisfy({ $0.comment.replyLevel == 0 && $0.comment.parentID == nil }) else { throw .unrecognised }
        // An envelope that carries nothing is a shell, not an empty list.
        guard header != nil || !threads.isEmpty || next != nil else { throw .unrecognised }
        try context.requireAllEntitiesUsed()
        return MusicCommentsPage(header: header, threads: threads, nextToken: next)
    }

    static func parseHeader(_ renderer: [String: Any]) throws(MusicSessionError) -> MusicCommentsHeader {
        func printed(_ value: Any?) -> String? {
            let text = MusicBrowseParser.runs(value).compactMap { $0["text"] as? String }.joined()
            return text.isEmpty ? nil : text
        }
        let count = printed(renderer["countText"]), short = printed(renderer["commentsCount"])
        guard (count?.count ?? 0) <= maxPrinted, (short?.count ?? 0) <= maxPrinted else { throw .unrecognised }
        var options: [MusicCommentSortOption] = []
        if let menu = (renderer["sortMenu"] as? [String: Any])?["sortFilterSubMenuRenderer"] as? [String: Any] {
            guard let items = menu["subMenuItems"] as? [[String: Any]], items.count <= maxSortOptions else { throw .unrecognised }
            for item in items {
                guard let title = item["title"] as? String, !title.isEmpty, title.count <= maxPrinted,
                      let token = ((item["continuation"] as? [String: Any])?["reloadContinuationData"] as? [String: Any])?["continuation"] as? String,
                      MusicBrowseParser.isToken(token) else { throw .unrecognised }
                options.append(MusicCommentSortOption(title: title, isSelected: item["selected"] as? Bool ?? false, token: token))
            }
        }
        let box = (renderer["createRenderer"] as? [String: Any])?["commentSimpleboxRenderer"] as? [String: Any]
        let signIn = (box?["prepareAccountEndpoint"] as? [String: Any])?["signInEndpoint"] != nil
        return MusicCommentsHeader(countText: count, shortCountText: short, sortOptions: options, posting: signIn ? .signInRequired : .notPublished)
    }

    // MARK: Replies

    public static func parseReplies(_ root: [String: Any], parentID: String) throws(MusicSessionError) -> MusicCommentsReplies {
        guard root["error"] == nil, parentID.range(of: threadIDPattern, options: .regularExpression) != nil,
              let endpoints = root["onResponseReceivedEndpoints"] as? [[String: Any]], endpoints.count == 1,
              let command = endpoints[0]["appendContinuationItemsAction"] as? [String: Any],
              // The answer must be for exactly this thread; another thread's replies are not this one's.
              command["targetId"] as? String == "comment-replies-item-" + parentID,
              let items = command["continuationItems"] as? [[String: Any]], !items.isEmpty, items.count <= maxRepliesPerPage + 1 else { throw .unrecognised }
        let entities = try Entities(root)
        var context = Walk(entities: entities)
        var replies: [MusicComment] = []
        var next: String?
        for item in items {
            if let renderer = item["commentThreadRenderer"] as? [String: Any] {
                try context.collect(renderer, depth: 1, parentID: parentID, into: &replies)
            } else if let renderer = item["continuationItemRenderer"] as? [String: Any] {
                guard next == nil, let token = continuationToken(renderer) else { throw .unrecognised }
                next = token
            } else { throw .unrecognised }
            guard replies.count <= maxRepliesPerPage else { throw .oversized }
        }
        guard !replies.isEmpty else { throw .unrecognised }
        try context.requireAllEntitiesUsed()
        return MusicCommentsReplies(parentID: parentID, replies: replies, nextToken: next)
    }

    // MARK: Shared

    static func continuationToken(_ renderer: [String: Any]) -> String? {
        let token = ((renderer["continuationEndpoint"] as? [String: Any])?["continuationCommand"] as? [String: Any])?["token"] as? String
        guard let token, MusicBrowseParser.isToken(token) else { return nil }
        return token
    }

    /// The comment entities of a response, by entity key. A key that appears twice, or an entity whose own `key` differs from the key it was
    /// delivered under, is unreadable.
    struct Entities {
        var comments: [String: [String: Any]] = [:]
        init(_ root: [String: Any]) throws(MusicSessionError) {
            guard let mutations = ((root["frameworkUpdates"] as? [String: Any])?["entityBatchUpdate"] as? [String: Any])?["mutations"] as? [[String: Any]] else { return }
            guard mutations.count <= MusicCommentsParser.maxEntities else { throw .oversized }
            for mutation in mutations {
                guard let payload = (mutation["payload"] as? [String: Any])?["commentEntityPayload"] as? [String: Any] else { continue }
                guard mutation["type"] as? String == "ENTITY_MUTATION_TYPE_REPLACE", let key = mutation["entityKey"] as? String,
                      key.range(of: keyPattern, options: .regularExpression) != nil, payload["key"] as? String == key, comments[key] == nil else { throw .unrecognised }
                comments[key] = payload
            }
        }
    }

    /// Walks threads and joins them to their entities, remembering which entities were used.
    struct Walk {
        let entities: Entities
        var used = Set<String>()
        init(entities: Entities) { self.entities = entities }

        mutating func requireAllEntitiesUsed() throws(MusicSessionError) {
            // The mirror of the join: an entity no thread refers to is a thread (or a nested reply) that was not read.
            guard used.count == entities.comments.count else { throw .unrecognised }
        }

        /// A top-level thread: its comment, the replies continuation, and any reply the thread already carries inline.
        mutating func thread(_ renderer: [String: Any]) throws(MusicSessionError) -> MusicCommentThread {
            let comment = try self.comment(renderer, parentID: nil)
            var token: String?
            var inline: [MusicComment] = []
            for sub in try subThreads(renderer) {
                if let continuation = sub["continuationItemRenderer"] as? [String: Any] {
                    guard token == nil, let value = MusicCommentsParser.continuationToken(continuation) else { throw .unrecognised }
                    token = value
                } else if let nested = sub["commentThreadRenderer"] as? [String: Any] {
                    try collect(nested, depth: 1, parentID: comment.id, into: &inline)
                } else { throw .unrecognised }
            }
            return MusicCommentThread(comment: comment, repliesToken: token, inlineReplies: inline)
        }

        /// A reply and, depth first, the replies hanging under it. Each must belong to `parentID`'s thread.
        mutating func collect(_ renderer: [String: Any], depth: Int, parentID: String, into result: inout [MusicComment]) throws(MusicSessionError) {
            guard depth <= MusicCommentsParser.maxNestingDepth else { throw .oversized }
            let reply = try comment(renderer, parentID: parentID)
            guard reply.replyLevel >= 1, reply.id.hasPrefix(parentID + ".") else { throw .unrecognised }
            result.append(reply)
            guard result.count <= MusicCommentsParser.maxRepliesPerPage else { throw .oversized }
            for sub in try subThreads(renderer) {
                guard let nested = sub["commentThreadRenderer"] as? [String: Any] else { throw .unrecognised }
                try collect(nested, depth: depth + 1, parentID: parentID, into: &result)
            }
        }

        func subThreads(_ renderer: [String: Any]) throws(MusicSessionError) -> [[String: Any]] {
            guard let replies = renderer["replies"] else { return [] }
            guard let list = (replies as? [String: Any])?["commentRepliesRenderer"] as? [String: Any],
                  let subs = list["subThreads"] as? [[String: Any]], subs.count <= MusicCommentsParser.maxRepliesPerPage + 1 else { throw .unrecognised }
            return subs
        }

        /// The join: the view model names the entity by `commentKey`; the entity must exist, be unused, and carry the same comment id.
        mutating func comment(_ renderer: [String: Any], parentID: String?) throws(MusicSessionError) -> MusicComment {
            guard let model = (renderer["commentViewModel"] as? [String: Any])?["commentViewModel"] as? [String: Any],
                  let id = model["commentId"] as? String, id.range(of: MusicCommentsParser.commentIDPattern, options: .regularExpression) != nil,
                  let key = model["commentKey"] as? String, let entity = entities.comments[key], !used.contains(key),
                  let properties = entity["properties"] as? [String: Any], properties["commentId"] as? String == id,
                  let level = properties["replyLevel"] as? Int, level >= 0, level <= MusicCommentsParser.maxNestingDepth,
                  let author = entity["author"] as? [String: Any], let name = author["displayName"] as? String, !name.isEmpty, name.count <= MusicCommentsParser.maxPrinted,
                  let time = properties["publishedTime"] as? String, time.count <= MusicCommentsParser.maxPrinted,
                  let text = (properties["content"] as? [String: Any])?["content"] as? String else { throw .unrecognised }
            guard text.count <= MusicCommentsParser.maxTextCharacters else { throw .oversized }
            // The structure must agree with the ids: a top-level comment has no dot in its id and level 0; a reply has both.
            guard (parentID == nil) == (level == 0), (parentID == nil) == !id.contains(".") else { throw .unrecognised }
            func flag(_ name: String) throws(MusicSessionError) -> Bool {
                guard let value = author[name] else { return false }
                guard let flag = value as? Bool else { throw .unrecognised }
                return flag
            }
            let toolbar = entity["toolbar"] as? [String: Any]
            func printed(_ name: String) throws(MusicSessionError) -> String? {
                guard let value = toolbar?[name] else { return nil }
                guard let text = value as? String, text.count <= MusicCommentsParser.maxPrinted else { throw .unrecognised }
                return text.isEmpty ? nil : text
            }
            used.insert(key)
            return MusicComment(id: id, parentID: parentID, replyLevel: level, authorName: name, isVerified: try flag("isVerified"), isCreator: try flag("isCreator"),
                                isArtist: try flag("isArtist"), isCurrentUser: try flag("isCurrentUser"), text: text, publishedTime: time,
                                likeCountText: try printed("likeCountNotliked"), replyCountText: try printed("replyCount"))
        }
    }
}
