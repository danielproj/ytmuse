import AccountSession
import Foundation
import Testing
@testable import Features

private let songA = "khnokW3Mw24", songB = "dQw4w9WgXcQ"
private let plain = MusicLyricsDocument(body: .plain("Line one\nLine two\n\nLine four"), sourceFooter: "Source: Musixmatch")

/// Scripted lyrics reads: each call is counted, answers come from closures, and a read can be held until the test releases it.
private actor LyricsScript {
    private(set) var calls: [String] = []
    var answers: [String: Result<MusicLyricsResult, MusicSessionError>] = [:]
    var held: [CheckedContinuation<Void, Never>] = []
    var hold = false
    func set(_ id: String, _ answer: Result<MusicLyricsResult, MusicSessionError>) { answers[id] = answer }
    func setHold(_ value: Bool) { hold = value }
    func release() { let all = held; held = []; for c in all { c.resume() } }
    func read(_ id: String) async throws -> MusicBrowseReply<MusicLyricsResult> {
        calls.append(id)
        if hold { await withCheckedContinuation { held.append($0) } }
        switch answers[id] ?? .failure(.unrecognised) {
        case .success(let value): return MusicBrowseReply(value: value, mode: .anonymous, accountGeneration: 1)
        case .failure(let error): throw error
        }
    }
    var count: Int { calls.count }
}

/// T18.3: missing and untimed lyrics stay missing and plain; "no lyrics" is not "could not load".
@MainActor @Suite struct LyricsModelTests {
    private func make(_ script: LyricsScript, scope: Box<String> = Box("a")) -> LyricsModel {
        LyricsModel(reader: { try await script.read($0) }, accountScope: { scope.value })
    }
    @Test func plainLyricsAreShownAsSuppliedWithTheirSource() async {
        let script = LyricsScript(); await script.set(songA, .success(.lyrics(plain)))
        let model = make(script)
        await model.show(videoID: songA)
        #expect(model.state == .loaded(plain) && model.videoID == songA)
        if case .loaded(let document) = model.state { #expect(!document.isTimed && document.sourceFooter == "Source: Musixmatch") }
    }
    @Test func noLyricsAndCouldNotLoadAreDifferentStates() async {
        let script = LyricsScript()
        await script.set(songA, .success(.none(.notOffered))); await script.set(songB, .failure(.network))
        let model = make(script)
        await model.show(videoID: songA)
        #expect(model.state == .unavailable(.notOffered))
        await model.show(videoID: songB)
        #expect(model.state == .failed(.offline))
        #expect(model.state != .unavailable(.notOffered))
    }
    @Test func eachFailureHasItsOwnWording() async {
        let cases: [(MusicSessionError, LyricsFailure)] = [(.network, .offline), (.timedOut, .offline), (.rateLimited, .rateLimited), (.unrecognised, .unreadable), (.oversized, .unreadable), (.server, .unavailable)]
        for (error, expected) in cases {
            let script = LyricsScript(); await script.set(songA, .failure(error))
            let model = make(script)
            await model.show(videoID: songA)
            #expect(model.state == .failed(expected), Comment(rawValue: "\(error)"))
        }
        #expect(Set([LyricsFailure.offline, .rateLimited, .unreadable, .unavailable].map(\.message)).count == 4)
    }
    @Test func tryAgainReadsAgainAndOnlyAfterAFailure() async {
        let script = LyricsScript(); await script.set(songA, .failure(.network))
        let model = make(script)
        await model.show(videoID: songA)
        await script.set(songA, .success(.lyrics(plain)))
        await model.retry()
        #expect(model.state == .loaded(plain) && model.readCount == 2)
        await model.retry()
        #expect(model.readCount == 2, "a loaded song is not read again")
        await script.set(songB, .success(.none(.emptyPage)))
        await model.show(videoID: songB)
        await model.retry()
        #expect(model.readCount == 3 && model.state == .unavailable(.emptyPage), "no lyrics is not retried")
    }
    @Test func theSameSongIsReadOnceAndAnAnsweredSongComesFromTheSessionCache() async {
        let script = LyricsScript(); await script.set(songA, .success(.lyrics(plain))); await script.set(songB, .success(.none(.notOffered)))
        let model = make(script)
        await model.show(videoID: songA); await model.show(videoID: songA)
        await model.show(videoID: songB); await model.show(videoID: songA)
        let reads = await script.count
        #expect(reads == 2 && model.state == .loaded(plain))
    }
    @Test func aSlowAnswerForAnEarlierSongNeverReplacesTheSongOnScreen() async {
        let script = LyricsScript(); await script.set(songA, .success(.lyrics(plain))); await script.set(songB, .success(.none(.notOffered)))
        let model = make(script)
        await script.setHold(true)
        let first = Task { await model.show(videoID: songA) }
        await settle()
        await script.setHold(false)
        await model.show(videoID: songB)
        await script.release()
        await first.value
        #expect(model.videoID == songB && model.state == .unavailable(.notOffered))
    }
    @Test func anAnswerReadForAnotherAccountIsDropped() async {
        let script = LyricsScript(); await script.set(songA, .success(.lyrics(plain)))
        let scope = Box("a")
        let model = make(script, scope: scope)
        await script.setHold(true)
        let read = Task { await model.show(videoID: songA) }
        await settle()
        scope.value = "b"
        await script.release()
        await read.value
        #expect(model.state == .loading, "the old account's answer is not shown under the new account")
        model.accountChanged()
        #expect(model.state == .idle && model.videoID == nil)
    }
    @Test func nothingPlayingOrAnUnreadableIdClearsThePanelAndReadsNothing() async {
        let script = LyricsScript(); await script.set(songA, .success(.lyrics(plain)))
        let model = make(script)
        await model.show(videoID: songA)
        await model.show(videoID: nil)
        #expect(model.state == .idle)
        await model.show(videoID: "not an id")
        let reads = await script.count
        #expect(model.state == .idle && reads == 1)
    }
    @Test func aSignedReadIsRecordedAsSigned() async {
        let reader: LyricsModel.Reader = { _ in MusicBrowseReply(value: .lyrics(plain), mode: .signedIn, accountGeneration: 1) }
        let model = LyricsModel(reader: reader)
        await model.show(videoID: songA)
        #expect(model.readSigned)
    }
}
