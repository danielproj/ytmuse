import AccountSession
@testable import Features
import Foundation
import Testing

/// T19.4: remote removal names the selected upload and needs explicit confirmation; choosing a local file never implies deletion consent.
@MainActor @Suite struct UploadRemovalTests {
    final class Remote: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [MusicWriteRequest] = []
        var outcome: Result<MusicWriteOutcome, any Error> = .success(.confirmed)
        var gate: Gate?
        var requests: [MusicWriteRequest] { lock.withLock { _requests } }
        func writer() -> LibraryWriteLedger.Writer {
            { [self] request in
                lock.withLock { _requests.append(request) }
                if let gate { await gate.wait() }
                return MusicWriteReply(outcome: try outcome.get(), accountGeneration: 0)
            }
        }
    }
    private let entity = "devupload-song-0001"
    private func song(title: String = "Home Recording", artist: String = "The Artist", entity: String? = "devupload-song-0001") -> MusicCatalogItem {
        MusicCatalogItem(kind: .song, title: title, details: [artist], videoID: "devupsong01", links: [MusicLink(kind: .artist, title: artist, browseID: "UCdevelopmentartist00000000")],
                         isUpload: true, uploadEntityID: entity)
    }
    private func model(_ remote: Remote, listing: @escaping UploadRemovalModel.Lister = { _ in nil }, scope: Box<String>? = nil, signedIn: SearchPlayback = .available,
                       removed: Box<Int>? = nil) -> UploadRemovalModel {
        UploadRemovalModel(remover: remote.writer(), listing: listing, accountScope: { scope?.value ?? "a" }, signedIn: { signedIn }, removed: { removed?.value += 1 })
    }

    @Test func askingNamesTheUploadAndSendsNothingUntilItIsConfirmed() async throws {
        let remote = Remote(), removed = Box(0)
        let m = model(remote, removed: removed)
        m.request(removing: song())
        await settle()
        let target = try #require(m.confirming)
        #expect(target.title == "Home Recording" && target.artist == "The Artist" && target.entityID == entity && target.description == "Home Recording — The Artist")
        #expect(remote.requests.isEmpty && m.sentCount == 0, "asking is not removing")
        m.cancel()
        await settle()
        #expect(m.state == .idle && remote.requests.isEmpty)
        m.request(removing: song()); await m.confirm()
        #expect(remote.requests == [.removeUpload(entityID: entity)], "exactly the one removal that was named")
        #expect(m.state == .removed(target) && removed.value == 1, "the list is read again after the service confirmed")
    }
    @Test func onlyAnUploadThatPublishedItsOwnRemovalTargetOffersRemoval() async throws {
        let remote = Remote()
        let m = model(remote)
        #expect(m.offers(song()) && !m.offers(song(entity: nil)) && !m.offers(song(entity: "bad id!")) && !m.offers(song(entity: "short")))
        m.request(removing: song(entity: nil))
        #expect(m.state == .idle, "nothing to confirm without a target the service published")
        await m.confirm()
        #expect(remote.requests.isEmpty)
    }
    @Test func confirmingTwiceOrWithNothingAskedSendsNothingMore() async throws {
        let remote = Remote()
        let gate = Gate(); remote.gate = gate
        let m = model(remote)
        await m.confirm()
        #expect(remote.requests.isEmpty, "no question was asked")
        m.request(removing: song())
        #expect(m.begin() && !m.begin(), "the first confirmation is taken; a second finds nothing to confirm")
        m.cancel()
        #expect(m.isBusy, "closing the question after the decision cannot undo it")
        let sending = Task { await m.complete() }
        await settle()
        let again = Task { await m.complete() }
        await settle()
        await gate.open()
        await sending.value; await again.value
        #expect(remote.requests.count == 1 && m.sentCount == 1, "one confirmation, one request")
        m.request(removing: song(title: "Other", entity: "devupload-song-0002"))
        #expect(m.confirming?.title == "Other", "a new question can be asked once the first is settled")
    }
    @Test func anotherUploadCannotBeAskedAboutWhileOneIsBeingRemovedOrUnsettled() async throws {
        let remote = Remote(); remote.outcome = .success(.indeterminate(.noAnswer))
        let m = model(remote)
        m.request(removing: song()); await m.confirm()
        guard case .unconfirmed = m.state else { Issue.record("\(m.state)"); return }
        m.request(removing: song(title: "Other", entity: "devupload-song-0002"))
        #expect(m.confirming == nil, "the first removal is unsettled; no second one is started")
    }
    @Test func aServerErrorAfterTheRequestLeftIsNotConfirmedAndTheListIsReadBeforeAnyRepeat() async throws {
        let remote = Remote(); remote.outcome = .success(.rejected(.unavailable))
        let listed = Box<Bool?>(true)
        let m = model(remote, listing: { _ in listed.value })
        m.request(removing: song()); await m.confirm()
        guard case .unconfirmed(_, let unreadable) = m.state else { Issue.record("a 5xx after sending was shown as \(m.state)"); return }
        #expect(!unreadable)
        if case .failed = m.state { Issue.record("\"Nothing was changed\" with nothing to prove it") }
        await m.retry()
        await m.retryUnconfirmed()
        #expect(remote.requests.count == 1, "no repeat before the list has been read")
        await m.check()
        guard case .failed(_, .notApplied) = m.state else { Issue.record("\(m.state)"); return }
        #expect(remote.requests.count == 1)
        // A rate limit was turned away before any processing: that one is a plain refusal.
        let limited = Remote(); limited.outcome = .success(.rejected(.rateLimited))
        let n = model(limited)
        n.request(removing: song()); await n.confirm()
        guard case .failed(_, .rateLimited) = n.state else { Issue.record("\(n.state)"); return }
    }
    @Test func removeIsOfferedOnlyWhenAQuestionCouldStart() async throws {
        let remote = Remote(); remote.outcome = .success(.indeterminate(.noAnswer))
        let m = model(remote)
        #expect(m.canRequest)
        m.request(removing: song()); #expect(m.canRequest, "a question already open can be replaced")
        await m.confirm()
        #expect(!m.canRequest, "unconfirmed: the control is disabled, not inert")
        m.dismiss(); #expect(m.canRequest)
    }
    @Test func aRefusalIsShownAsNothingChangedAndRetryIsTheSameRemovalByExplicitAction() async throws {
        let remote = Remote(); remote.outcome = .success(.rejected(.service))
        let m = model(remote)
        m.request(removing: song()); await m.confirm()
        guard case .failed(_, let failure) = m.state else { Issue.record("\(m.state)"); return }
        #expect(failure == .refused && failure.message.contains("Nothing was changed"))
        #expect(remote.requests.count == 1, "no automatic retry")
        remote.outcome = .success(.confirmed)
        await m.retry()
        #expect(remote.requests == [.removeUpload(entityID: entity), .removeUpload(entityID: entity)])
        guard case .removed = m.state else { Issue.record("\(m.state)"); return }
    }
    @Test func anAnswerWithoutEvidenceIsNotARemovalAndTheListIsReadBeforeAnythingIsSentAgain() async throws {
        let remote = Remote(); remote.outcome = .success(.indeterminate(.unrecognisedAnswer))
        let listed = Box<Bool?>(nil)
        let removed = Box(0)
        let m = model(remote, listing: { _ in listed.value }, removed: removed)
        m.request(removing: song()); await m.confirm()
        guard case .unconfirmed(_, let unreadable) = m.state else { Issue.record("\(m.state)"); return }
        #expect(!unreadable && removed.value == 0, "not shown as removed")
        await m.retryUnconfirmed()
        #expect(remote.requests.count == 1, "no repeat before the list has been read and couldn't say")
        await m.check()
        guard case .unconfirmed(_, true) = m.state else { Issue.record("\(m.state)"); return }
        listed.value = true
        await m.check()   // no longer unreadable-checkable from this state? it is still unconfirmed with checkedUnreadable, so check reads again
        guard case .failed(_, .notApplied) = m.state else { Issue.record("\(m.state)"); return }
        #expect(removed.value == 0)
    }
    @Test func aListThatNoLongerHoldsTheUploadSettlesItAsRemoved() async throws {
        let remote = Remote(); remote.outcome = .success(.indeterminate(.noAnswer))
        let removed = Box(0)
        let m = model(remote, listing: { _ in false }, removed: removed)
        m.request(removing: song()); await m.confirm(); await m.check()
        guard case .removed = m.state else { Issue.record("\(m.state)"); return }
        #expect(removed.value == 1 && remote.requests.count == 1)
    }
    @Test func eachFailureTheTransportCanRaiseIsNamedAndNothingIsClaimed() async throws {
        let cases: [(MusicSessionError, LibraryWriteFailure)] = [(.network, .offline), (.timedOut, .offline), (.signedOut, .sessionEnded), (.notSignedIn, .needsSignIn),
                                                                  (.rateLimited, .rateLimited), (.policy, .notOffered), (.server, .unavailable)]
        for (error, expected) in cases {
            let remote = Remote(); remote.outcome = .failure(error)
            let m = model(remote)
            m.request(removing: song()); await m.confirm()
            guard case .failed(_, let failure) = m.state else { Issue.record("\(error): \(m.state)"); continue }
            #expect(failure == expected, Comment(rawValue: "\(error)"))
        }
    }
    @Test func withoutALiveSessionNothingIsSent() async throws {
        for (playback, expected) in [(SearchPlayback.needsSignIn, LibraryWriteFailure.needsSignIn), (.sessionExpired, .sessionEnded)] {
            let remote = Remote()
            let m = model(remote, signedIn: playback)
            m.request(removing: song()); await m.confirm()
            guard case .failed(_, let failure) = m.state else { Issue.record("\(m.state)"); continue }
            #expect(failure == expected && remote.requests.isEmpty)
            await m.retry()
            #expect(remote.requests.isEmpty && m.sentCount == 0, "trying again without a session sends nothing either")
            guard case .failed(_, expected) = m.state else { Issue.record("\(m.state)"); continue }
        }
    }
    @Test func anAccountSwitchDropsTheQuestionAndAnyLateAnswer() async throws {
        let remote = Remote(), gate = Gate(); remote.gate = gate
        let scope = Box("a"), removed = Box(0)
        let m = model(remote, scope: scope, removed: removed)
        m.request(removing: song())
        m.accountChanged()
        #expect(m.state == .idle, "an open question doesn't carry over to another account")
        m.request(removing: song()); m.begin()
        let sending = Task { await m.complete() }
        await settle()
        scope.value = "b"; m.accountChanged()
        await gate.open(); await sending.value
        #expect(m.state == .idle && removed.value == 0, "the late answer from the old account is ignored")
    }
    @Test func choosingOrQueueingALocalFileNeverReachesTheRemovalPath() async throws {
        let remote = Remote()
        let removal = model(remote)
        let h = try Harness()
        let url = try h.scratch.wav("Home Recording.wav")
        let before = try h.scratch.data(url)
        await h.queue.add([url])
        await h.until("completed") { h.phase("Home Recording.wav") == .completed }
        h.queue.dismiss(try #require(h.job("Home Recording.wav")).id)
        #expect(remote.requests.isEmpty && removal.sentCount == 0 && removal.state == .idle, "selecting, uploading and dismissing a file asked nothing of the removal flow")
        // Removing a remote upload that shares the local file's title doesn't touch the local file either.
        removal.request(removing: song(title: "Home Recording")); await removal.confirm()
        let after = try h.scratch.data(url)
        #expect(FileManager.default.fileExists(atPath: url.path) && after == before, "the local file is exactly as it was")
        #expect(remote.requests == [.removeUpload(entityID: entity)])
    }
}
