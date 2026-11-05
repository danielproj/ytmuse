#if DEBUG
import AccountSession
import Features
import Foundation

/// Debug-only, labelled development data for the isolated UI tests of Samples, the tuner, Recap, badges and comments. It exists only when
/// `YTMUSE_UI_DEVELOPMENT_DATA=1`, `YTMUSE_UI_DEVELOPMENT_LIBRARY=1`, `YTMUSE_UI_DEVELOPMENT_DISCOVERY=1` and QA isolation are all set,
/// every screen labels it "Development data · Not YouTube Music", and no Release build contains it. It is not a capture of the service,
/// performs no network request, plays no audio, and its transports change nothing anywhere.
@MainActor final class DevelopmentDiscovery {
    nonisolated static func isEnabled(_ environment: [String: String]) -> Bool {
        DevelopmentLibrary.isEnabled(environment) && environment["YTMUSE_UI_DEVELOPMENT_DISCOVERY"] == "1"
    }
    let samples = ScriptedSamples()
    let summaries = ScriptedSummaries()
    let controls = ScriptedControls()
    let performer = ScriptedPerformer()
    let engine: ScriptedPreviewEngine
    /// `YTMUSE_UI_PREVIEW_CONDITIONS` = `lowpower` | `constrained` pins the device conditions the previews read.
    let lowPowerMode: Bool, constrainedNetwork: Bool

    init(environment: [String: String]) {
        let condition = environment["YTMUSE_UI_PREVIEW_CONDITIONS"]
        lowPowerMode = condition == "lowpower"; constrainedNetwork = condition == "constrained"
        engine = ScriptedPreviewEngine(performer: performer)
    }
    func seed(_ book: RadioSeedBook) {
        book.note(items: [
            MusicCatalogItem(kind: .song, title: "Development song", details: ["Development Artist"], videoID: "devprev0001",
                             radio: MusicRadioAction(playlistID: "RDAMVMdevprev0001", videoID: "devprev0001", params: "wAEB")),
            MusicCatalogItem(kind: .playlist, title: "Development mix", details: ["Development"], browseID: "VLPLdevelopmentmix1",
                             radio: MusicRadioAction(playlistID: "RDAMPLPLdevelopmentmix1", params: "wAEB"))])
    }
    static func comments() -> ScriptedComments { ScriptedComments() }

    /// A readout the UI tests read: what the scripted preview engine and the scripted shared player are doing.
    var readout: String { "preview=\(engine.active ?? "none") player=\(performer.playing ?? "none") overlap=\(engine.overlaps) handoffs=\(performer.starts)" }
}

struct ScriptedSamples: SamplesSource {
    var unresolved: String? { nil }
    func clips() async throws -> [SampleClip] {
        [SampleClip(id: "devclip00001", title: "Development clip one", artist: "Development Artist", playlistID: "RDAMVMdevclip00001"),
         SampleClip(id: "devclip00002", title: "Development clip two", artist: "Another Artist", playlistID: "RDAMVMdevclip00002")]
    }
}
struct ScriptedSummaries: AccountSummarySource {
    var unresolved: String? { nil }
    func recap() async throws -> SummaryAnswer<RecapPayload> {
        .payload(RecapPayload(title: "Development recap", period: "Development period", entries: [
            SummaryEntry(id: "d1", title: "Development entry one", value: "Development value one", caption: "Supplied text"),
            SummaryEntry(id: "d2", title: "Development entry two", value: "Development value two")]))
    }
    func badges() async throws -> SummaryAnswer<BadgePayload> { .noPayload }
}
struct ScriptedControls: RadioControlsSource {
    var unresolved: String? { nil }
    func controls(for context: RadioContext) async -> [TunerControl] {
        [TunerControl(id: "devmix", title: "Development mix", options: [
            TunerOption(id: "devfamiliar", title: "Familiar", selected: true, params: "devfamiliarparams"),
            TunerOption(id: "devdiscover", title: "Discover", params: "devdiscoverparams")])]
    }
}
/// The shared player, scripted: it records what it was asked to play and never makes a sound.
@MainActor final class ScriptedPerformer: SearchActionPerformer {
    private(set) var playing: String?
    private(set) var starts = 0
    func play(playlistID: String, title: String) async -> SearchPlayOutcome { await play(playlistID: playlistID, title: title, videoID: nil, params: nil) }
    func play(playlistID: String, title: String, videoID: String?, params: String?) async -> SearchPlayOutcome {
        starts += 1; playing = videoID ?? playlistID; return .started
    }
    func pause() { playing = nil }
    func setPlaying(_ id: String?) { playing = id }
    func copy(link: URL) {}
}
@MainActor final class ScriptedPreviewEngine: PreviewEngine {
    private let performer: ScriptedPerformer
    private(set) var active: String?
    private(set) var overlaps = 0
    init(performer: ScriptedPerformer) { self.performer = performer }
    func start(_ clip: SampleClip) async -> Bool {
        if active != nil { overlaps += 1 }
        active = clip.id; performer.setPlaying(clip.id); return true
    }
    func stop() async { active = nil; performer.pause() }
    var otherPlaybackBusy: Bool { false }
}

/// Labelled development comments for the isolated UI tests ("Development data · Not YouTube Music" is shown wherever they appear). Nothing here is
/// a capture of the service, nothing is sent anywhere, and it is the one comments transport that says it can write: its writes change only this actor.
actor ScriptedComments: CommentsTransport {
    nonisolated var unresolved: String? { nil }
    nonisolated var writesUnresolved: String? { nil }
    private let top = CommentsSortOption(title: "Top", isSelected: true, token: CommentsToken("devsorttop"))
    private let newest = CommentsSortOption(title: "Newest", isSelected: false, token: CommentsToken("devsortnew"))
    private var comments = [
        SocialComment(id: "devc1", author: "Development Listener", text: "A development comment.", posted: "Development time",
                      moderation: [ModerationOffer(id: "devhide", title: "Hide", destructive: true)], likeCountText: "7", replyCountText: "2"),
        SocialComment(id: "devc2", author: "Another Listener", text: "A comment with nothing offered on it.")]
    private func header(selected: Int) -> CommentsHeader {
        CommentsHeader(countText: "Development comments",
                       sorts: [CommentsSortOption(title: top.title, isSelected: selected == 0, token: top.token), CommentsSortOption(title: newest.title, isSelected: selected == 1, token: newest.token)])
    }
    private func threads(_ list: [SocialComment]) -> [CommentThread] {
        list.map { CommentThread(comment: $0, repliesToken: $0.id == "devc1" ? CommentsToken("devreplies1") : nil) }
    }
    func open(_ subject: SocialSubject) async throws -> CommentsOpening {
        .page(CommentsPage(header: header(selected: 0), threads: threads(comments), next: CommentsToken("devmore1"), canPost: true))
    }
    func page(_ token: CommentsToken, on subject: SocialSubject) async throws -> CommentsPage {
        switch token.rawValue {
        case "devsortnew": CommentsPage(header: header(selected: 1), threads: threads(comments.reversed()), next: nil, canPost: true)
        case "devsorttop": CommentsPage(header: header(selected: 0), threads: threads(comments), next: CommentsToken("devmore1"), canPost: true)
        default: CommentsPage(header: nil, threads: [CommentThread(comment: SocialComment(id: "devc9", author: "Later Listener", text: "A development comment on the second page."))], next: nil, canPost: true)
        }
    }
    func replies(_ token: CommentsToken, of thread: SocialComment, on subject: SocialSubject) async throws -> CommentsReplies {
        CommentsReplies(parentID: thread.id, replies: [SocialComment(id: thread.id + ".r1", author: "Replying Listener", text: "A development reply.", level: 1)], next: nil)
    }
    func post(_ text: String, on subject: SocialSubject) async throws -> SocialWriteAnswer {
        comments.append(SocialComment(id: "devc" + String(comments.count + 1), author: "You (development)", text: text)); return .confirmed
    }
    func moderate(_ offer: ModerationOffer, comment: SocialComment, on subject: SocialSubject) async throws -> SocialWriteAnswer {
        comments.removeAll { $0.id == comment.id }; return .confirmed
    }
}
#endif
