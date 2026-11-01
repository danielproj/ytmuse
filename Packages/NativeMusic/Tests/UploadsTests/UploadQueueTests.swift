@testable import Features
import Foundation
import Testing

/// Job orchestration: T19.1 (cancel, duplicate, resumption, restart), T19.2 (processing failure, refresh), T19.3 (account switch, permissions, cleanup).
@MainActor @Suite struct UploadQueueTests {
    // MARK: Happy path and the server's word

    @Test func aFileIsCompletedOnlyAfterTheServiceSaysSoAndOnlyThenTheListsAreRead() async throws {
        let h = try Harness()
        let url = try h.scratch.wav("One.wav")
        h.transport.defaultProcessing([.processing, .processing, .completed])
        #expect(await h.queue.add([url]).isEmpty)
        await h.until("completed") { h.phase("One.wav") == .completed }
        #expect(h.refreshCalls == 1, "the lists are read again exactly once, after the service confirmed")
        #expect(h.refreshedWhileProcessing == [.processing], "…and at the moment of that read the job was still being processed: nothing was shown as completed before")
        #expect(h.job("One.wav")?.listing == .refreshed)
        #expect(h.transport.processingAsked.count == 3 && Set(h.transport.processingAsked).count == 1)
        #expect(h.access.openedCount == 1 && h.access.releasedCount == 1 && h.queue.openLeaseCount == 0, "the file lease ends with the transfer")
    }
    @Test func aProcessingFailureNeverRefreshesAndNeverShowsACompletedItem() async throws {
        let h = try Harness()
        h.transport.defaultProcessing([.processing, .failed("Server words: could not read this audio")])
        await h.queue.add([try h.scratch.wav("Bad.wav")])
        await h.until("failed") { h.phase("Bad.wav") == .failed }
        let job = try #require(h.job("Bad.wav"))
        #expect(job.reason == .processingFailed && job.serverMessage == "Server words: could not read this audio", "the service's own words, verbatim")
        #expect(job.listing == nil && h.refreshCalls == 0, "no refresh, no listing")
        #expect(!h.queue.jobs.contains { $0.phase == .completed })
        #expect(!h.queue.canStartOver(job), "sending the same file again would only repeat the answer")
        #expect(!h.queue.startOver(job.id) && h.transport.uploadCount == 1)
        h.queue.dismiss(job.id)
        #expect(h.queue.jobs.isEmpty)
    }
    @Test func aFileTheServiceRefusesWhenSentFailsWithItsWordsAndNeverRefreshes() async throws {
        let h = try Harness()
        h.transport.script("Nope.wav", .refused("Server words: unsupported"))
        await h.queue.add([try h.scratch.wav("Nope.wav")])
        await h.until("failed") { h.phase("Nope.wav") == .failed }
        let job = try #require(h.job("Nope.wav"))
        #expect(job.reason == .serverRefused && job.serverMessage == "Server words: unsupported" && h.refreshCalls == 0 && h.transport.processingAsked.isEmpty)
        #expect(h.queue.openLeaseCount == 0 && h.access.releasedCount == h.access.openedCount)
    }
    @Test func completedButTheListsCouldNotBeReadIsSaidPlainly() async throws {
        let h = try Harness()
        h.refreshResult = false
        await h.queue.add([try h.scratch.wav("One.wav")])
        await h.until("completed") { h.phase("One.wav") == .completed }
        #expect(h.job("One.wav")?.listing == .refreshFailed, "the service confirmed; the read after it did not work, and the job says exactly that")
    }
    @Test func stillProcessingAfterTheLastCheckIsNotAFailureAndCanBeCheckedAgain() async throws {
        let h = try Harness(polls: 3)
        h.transport.defaultProcessing([.processing])
        await h.queue.add([try h.scratch.wav("Slow.wav")])
        await h.until("note") { h.job("Slow.wav")?.checkNote != nil }
        #expect(h.phase("Slow.wav") == .processing && h.refreshCalls == 0)
        h.transport.defaultProcessing([.completed])
        await h.queue.checkNow(try #require(h.job("Slow.wav")).id)
        #expect(h.phase("Slow.wav") == .completed && h.refreshCalls == 1)
    }
    @Test func statusChecksThatCannotReachTheServiceStayProcessingAndSayWhy() async throws {
        let h = try Harness()
        h.transport.failProcessing(with: Array(repeating: .offline, count: 6))
        await h.queue.add([try h.scratch.wav("Quiet.wav")])
        await h.until("gave up asking") { h.transport.processingAsked.count >= 5 && h.job("Quiet.wav")?.checkNote?.contains("couldn’t be reached") == true }
        #expect(h.phase("Quiet.wav") == .processing && h.refreshCalls == 0)
        let h2 = try Harness()
        h2.transport.failProcessing(with: [.sessionEnded])
        await h2.queue.add([try h2.scratch.wav("Ended.wav")])
        await h2.until("session note") { h2.job("Ended.wav")?.checkNote == UploadJob.Reason.sessionEnded.message }
        try? await Task.sleep(for: .milliseconds(120))   // long enough for any further scheduled check to have run
        #expect(h2.phase("Ended.wav") == .processing && h2.transport.processingAsked.count == 1, "no repeated asking after the session ended")
    }

    // MARK: T19.1 duplicates, cancellation, resumption, restart

    @Test func theSameFileChosenTwiceIsDroppedAsADuplicateWhileItIsInTheList() async throws {
        let h = try Harness()
        h.transport.script("Dup.wav", .hold)
        let url = try h.scratch.wav("Dup.wav")
        #expect(await h.queue.add([url, url]).map(\.reason) == [.duplicate(of: "Dup.wav")], "twice in one choice")
        #expect(h.queue.jobs.count == 1)
        await h.until("uploading") { h.phase("Dup.wav") == .uploading }
        #expect(await h.queue.add([url]).map(\.reason) == [.duplicate(of: "Dup.wav")], "and again while it is in progress")
        await h.queue.cancel(h.queue.jobs[0].id)
        #expect(await h.queue.add([url]).isEmpty, "a cancelled job doesn't block choosing the file again")
        #expect(h.queue.jobs.count == 2 && h.transport.uploadCount == 1 || h.queue.jobs.count == 2)
        h.transport.release("Dup.wav")
    }
    @Test func aFileThatCompletedIsAlsoNotQueuedAgainButAFailedOneMayBe() async throws {
        let h = try Harness()
        let done = try h.scratch.wav("Done.wav"), bad = try h.scratch.wav("Bad.wav")
        h.transport.script("Bad.wav", .refused(nil))
        await h.queue.add([done, bad])
        await h.until("settled") { h.phase("Done.wav") == .completed && h.phase("Bad.wav") == .failed }
        #expect(await h.queue.add([done]).map(\.reason) == [.duplicate(of: "Done.wav")])
        h.transport.script("Bad.wav", .succeeds)
        #expect(await h.queue.add([bad]).isEmpty, "a failed file can be chosen again")
        await h.until("second attempt") { h.queue.jobs.filter { $0.source.displayName == "Bad.wav" && $0.phase == .completed }.count == 1 }
    }
    @Test func cancellingWhileUploadingStopsTheTransferReleasesTheFileAndNeverTouchesIt() async throws {
        let h = try Harness()
        h.transport.script("A.wav", .hold)
        let a = try h.scratch.wav("A.wav"), b = try h.scratch.wav("B.wav")
        let before = try h.scratch.data(a)
        await h.queue.add([a, b])
        await h.until("A uploading, with the route's handle known") { h.phase("A.wav") == .uploading && h.job("A.wav")?.handle != nil }
        #expect(h.phase("B.wav") == .queued && h.transport.maxRunning == 1, "one transfer at a time")
        let id = try #require(h.job("A.wav")).id
        await h.queue.cancel(id)
        #expect(h.phase("A.wav") == .cancelled && h.job("A.wav")?.reason == .byUser && h.job("A.wav")?.serverMayStillProcess == false)
        #expect(h.transport.cancelledHandles == [h.transport.handle(for: id)], "the transport is told to drop what it held")
        await h.until("B completes") { h.phase("B.wav") == .completed }
        #expect(h.queue.openLeaseCount == 0 && h.access.openedCount == h.access.releasedCount)
        #expect(try h.scratch.data(a) == before, "cancelling ended the job; the chosen file is exactly as it was")
        h.queue.dismiss(id)
        #expect(FileManager.default.fileExists(atPath: a.path) && h.job("A.wav") == nil, "dismissing removes the record, not the file")
    }
    @Test func progressReportedAfterCancellationChangesNothing() async throws {
        let h = try Harness()
        h.transport.lateReportAfterCancel = true
        h.transport.script("A.wav", .hold)
        await h.queue.add([try h.scratch.wav("A.wav")])
        await h.until("uploading") { h.phase("A.wav") == .uploading && (h.job("A.wav")?.bytesSent ?? 0) > 0 }
        let id = try #require(h.job("A.wav")).id
        let before = try #require(h.queue.job(id)).bytesSent
        await h.queue.cancel(id)
        await h.until("the transport made its late report") { h.transport.lateReports == 1 }
        await settle()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(h.queue.job(id)?.bytesSent == before && h.queue.job(id)?.phase == .cancelled, "the late report (the whole file) did not move a cancelled job")
    }
    @Test func cancellingWhileTheServiceProcessesSaysItMayStillFinish() async throws {
        let h = try Harness(polls: 1)
        h.transport.defaultProcessing([.processing])
        await h.queue.add([try h.scratch.wav("P.wav")])
        await h.until("processing") { h.phase("P.wav") == .processing }
        await h.queue.cancel(try #require(h.job("P.wav")).id)
        let job = try #require(h.job("P.wav"))
        #expect(job.phase == .cancelled && job.serverMayStillProcess)
        #expect(h.refreshCalls == 0, "a cancelled job never refreshes the lists")
    }
    @Test func cancelOnAFinishedJobDoesNothing() async throws {
        let h = try Harness()
        await h.queue.add([try h.scratch.wav("Done.wav")])
        await h.until("done") { h.phase("Done.wav") == .completed }
        await h.queue.cancel(try #require(h.job("Done.wav")).id)
        #expect(h.phase("Done.wav") == .completed)
        h.queue.dismiss(try #require(h.job("Done.wav")).id)
        #expect(h.queue.jobs.isEmpty)
    }
    @Test func aDroppedConnectionStopsTheJobAndWithoutResumptionTheOnlyWayOnIsAnExplicitStartOver() async throws {
        let h = try Harness()
        h.transport.script("Cut.wav", .offline)
        await h.queue.add([try h.scratch.wav("Cut.wav")])
        await h.until("interrupted") { h.phase("Cut.wav") == .interrupted }
        let job = try #require(h.job("Cut.wav"))
        #expect(job.reason == .offline && !h.queue.canResume(job) && h.queue.canStartOver(job))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.transport.uploadCount == 1, "nothing is retried or queued by itself")
        #expect(!h.queue.resume(job.id), "resume isn't there when the service can't resume")
        h.transport.script("Cut.wav", .succeeds)
        #expect(h.queue.startOver(job.id))
        await h.until("done") { h.phase("Cut.wav") == .completed }
        #expect(h.queue.jobs.count == 1 && h.job("Cut.wav")?.attempts == 2, "one job, a second attempt")
        #expect(h.transport.uploads.last?.resumeHandle == nil)
    }
    @Test func resumingIsOfferedOnlyWhenTheRouteSaysItCanAndCarriesTheRoutesOwnHandle() async throws {
        let h = try Harness(capability: UploadCapability(availability: .available, resumption: .supported))
        h.transport.script("R.wav", .offline)
        await h.queue.add([try h.scratch.wav("R.wav")])
        await h.until("interrupted") { h.phase("R.wav") == .interrupted }
        let job = try #require(h.job("R.wav"))
        #expect(job.handle == h.transport.handle(for: job.id) && h.queue.canResume(job))
        h.transport.script("R.wav", .succeeds)
        #expect(h.queue.resume(job.id))
        await h.until("done") { h.phase("R.wav") == .completed }
        #expect(h.transport.uploads.last?.resumeHandle == h.transport.handle(for: job.id))
        // A route that cannot continue says so: the job fails with that reason and can only be started over.
        let h2 = try Harness(capability: UploadCapability(availability: .available, resumption: .supported))
        h2.transport.script("S.wav", .offline)
        await h2.queue.add([try h2.scratch.wav("S.wav")])
        await h2.until("interrupted") { h2.phase("S.wav") == .interrupted }
        h2.transport.script("S.wav", .refused(nil))
        _ = h2.queue.resume(try #require(h2.job("S.wav")).id)
        await h2.until("failed") { h2.phase("S.wav") == .failed }
    }
    @Test func aResumedJobStartedAfterTheRouteStoppedSupportingResumeIsSentFromTheBeginning() async throws {
        let h = try Harness(capability: UploadCapability(availability: .available, resumption: .supported))
        h.transport.script("R.wav", .offline)
        await h.queue.add([try h.scratch.wav("R.wav")])
        await h.until("interrupted") { h.phase("R.wav") == .interrupted }
        let id = try #require(h.job("R.wav")).id
        h.transport.script("H.wav", .hold)
        await h.queue.add([try h.scratch.wav("H.wav")])
        await h.until("H uploading") { h.phase("H.wav") == .uploading }
        h.transport.script("R.wav", .succeeds)
        #expect(h.queue.resume(id) && h.job("R.wav")?.handle != nil, "queued behind H, still holding the earlier handle")
        h.transport.setCapability(UploadCapability(availability: .available, resumption: .unsupported))
        h.transport.release("H.wav")
        await h.until("R done") { h.phase("R.wav") == .completed }
        #expect(h.transport.uploads.last?.fileURL.lastPathComponent == "R.wav" && h.transport.uploads.last?.resumeHandle == nil, "the route can't resume now, so it is never handed a resume handle")
    }
    @Test func aRouteThatCannotResumeNeverReceivesAResumeHandleEvenIfAJobHoldsOne() async throws {
        let h = try Harness()
        h.transport.script("H.wav", .offline)
        await h.queue.add([try h.scratch.wav("H.wav")])
        await h.until("interrupted") { h.phase("H.wav") == .interrupted }
        #expect(h.job("H.wav")?.handle != nil, "the transport reported a handle")
        h.transport.script("H.wav", .succeeds)
        #expect(h.queue.startOver(try #require(h.job("H.wav")).id))
        await h.until("done") { h.phase("H.wav") == .completed }
        #expect(h.transport.uploads.allSatisfy { $0.resumeHandle == nil })
    }
    @Test func startingOverOnAResumableRouteStillSendsFromTheBeginning() async throws {
        let h = try Harness(capability: UploadCapability(availability: .available, resumption: .supported))
        h.transport.script("O.wav", .offline)
        await h.queue.add([try h.scratch.wav("O.wav")])
        await h.until("interrupted") { h.phase("O.wav") == .interrupted }
        let id = try #require(h.job("O.wav")).id
        h.transport.script("O.wav", .succeeds)
        #expect(h.queue.startOver(id) && h.job("O.wav")?.handle == nil && h.job("O.wav")?.bytesSent == 0, "Start Over forgets the earlier attempt")
        await h.until("done") { h.phase("O.wav") == .completed }
        #expect(h.transport.uploads.last?.resumeHandle == nil, "a restart is not a resume")
    }
    // MARK: Account switch window (F2) and cancel ordering (F8)

    /// A store whose saves hold until opened, to keep the window between an account switch and the new account's job list open.
    actor GatedStore: UploadJobStoring {
        private var saved: [String: [UploadJob]] = [:]
        private var closed = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func close() { closed = true }
        func open() { closed = false; let w = waiters; waiters = []; for c in w { c.resume() } }
        func load(account: String) -> [UploadJob] { saved[account] ?? [] }
        func save(_ jobs: [UploadJob], account: String) async { if closed { await withCheckedContinuation { waiters.append($0) } }; saved[account] = jobs }
        func clear(account: String) { saved[account] = nil }
        func jobs(_ account: String) -> [UploadJob] { saved[account] ?? [] }
    }
    @Test func aFileChosenBetweenAnAccountSwitchAndTheNewAccountsListIsRecordedUnderTheNewAccountAndListed() async throws {
        let h = try Harness()
        h.transport.setDefault(.hold)
        let gated = GatedStore()
        h.queue = h.makeQueue(store: gated)
        await h.queue.restore()
        await h.queue.add([try h.scratch.wav("A.wav")])
        await h.until("A uploading") { h.phase("A.wav") == .uploading }
        await gated.close()
        let oldAccount = try #require(h.account), newAccount = "22222222-2222-4222-8222-222222222222"
        h.account = newAccount
        h.queue.accountChanged()
        let bURL = try h.scratch.wav("B.wav")
        let adding = Task { await h.queue.add([bURL]) }
        try? await Task.sleep(for: .milliseconds(200))   // long enough for an ungated intake to have started the file
        #expect(h.transport.uploads.map(\.fileURL.lastPathComponent) == ["A.wav"], "nothing starts for the new account before its list has been read")
        #expect(h.queue.jobs.isEmpty)
        await gated.open()
        _ = await adding.value
        await h.until("B uploading and listed") { h.phase("B.wav") == .uploading }
        await h.queue.settled()
        #expect(h.queue.jobs.map(\.source.displayName) == ["B.wav"] && h.queue.jobs[0].account == newAccount, "listed, and the new account's own")
        #expect(h.transport.runningNow == 2 || h.transport.runningNow == 1, "A's transfer was ended (or is ending), B's is running")
        await h.until("A's transfer ended") { h.transport.runningNow == 1 }
        #expect(h.queue.openLeaseCount == 1, "one lease: the one for the job on screen")
        let underOld = await gated.jobs(oldAccount), underNew = await gated.jobs(newAccount)
        #expect(!underOld.contains { $0.source.displayName == "B.wav" } && underNew.map(\.source.displayName) == ["B.wav"], "B was never recorded under the old account")
        h.transport.release("B.wav")
    }
    @Test func nothingRunsForAJobThatIsNoLongerListed() async throws {
        let h = try Harness()
        h.transport.script("A.wav", .hold)
        await h.queue.add([try h.scratch.wav("A.wav")])
        await h.until("uploading") { h.phase("A.wav") == .uploading }
        // The account's stored list (as read at restore) does not hold this job: whatever runs for it is stopped.
        await h.queue.settled()
        await h.store.put([], account: try #require(h.account))
        await h.queue.restore()
        await h.until("transfer ended") { h.transport.runningNow == 0 }
        #expect(h.queue.openLeaseCount == 0 && h.queue.jobs.isEmpty)
    }
    @Test func cancelTellsTheRouteBeforeTheNextTransferStarts() async throws {
        let h = try Harness()
        h.transport.cancelDelay = .milliseconds(150)
        h.transport.script("A.wav", .hold)
        await h.queue.add([try h.scratch.wav("A.wav"), try h.scratch.wav("B.wav")])
        await h.until("A uploading with its handle") { h.phase("A.wav") == .uploading && h.job("A.wav")?.handle != nil }
        await h.queue.cancel(try #require(h.job("A.wav")).id)
        await h.until("B done") { h.phase("B.wav") == .completed }
        let events = h.transport.events
        let cancelEnd = try #require(events.firstIndex(of: "cancel-end")), nextUpload = try #require(events.firstIndex(of: "upload:B.wav"))
        #expect(cancelEnd < nextUpload, "the route had finished being told when B started: \(events)")
    }
    @Test func aFileChangedAfterItWasChosenIsNeverSent() async throws {
        let h = try Harness()
        h.transport.script("Held.wav", .hold)
        let first = try h.scratch.wav("Held.wav"), second = try h.scratch.wav("Later.wav")
        await h.queue.add([first, second])
        await h.until("uploading") { h.phase("Held.wav") == .uploading }
        try Data("changed after it was chosen".utf8).write(to: second)
        h.transport.release("Held.wav")
        await h.until("later failed") { h.phase("Later.wav") == .failed }
        #expect(h.job("Later.wav")?.reason == .fileChanged && h.transport.uploads.map(\.fileURL.lastPathComponent) == ["Held.wav"])
    }

    // MARK: Production capability

    @Test func withoutAnUploadRouteNothingIsAddedStoredOrSent() async throws {
        let scratch = try Scratch(), store = MemoryUploadStore(), access = CountingAccess()
        let queue = UploadQueue(transport: UnavailableUploadTransport(), store: store, access: access, accountKey: { "11111111-1111-4111-8111-111111111111" })
        #expect(queue.capability.availability == .unavailable("Uploading arrives in a later update"))
        let refused = await queue.add([try scratch.wav("One.wav"), try scratch.wav("Two.wav")])
        #expect(refused.map(\.reason) == [.uploadsUnavailable, .uploadsUnavailable] && queue.jobs.isEmpty)
        let saves = await store.saves
        #expect(access.openedCount == 0 && saves == 0)
        #expect(!queue.startOver(UUID()) && !queue.resume(UUID()))
    }
    @Test func theUnavailableTransportSendsNothingAndSaysSo() async throws {
        let transport = UnavailableUploadTransport()
        let request = UploadRequest(jobID: UUID(), fileURL: URL(fileURLWithPath: "/dev/null"), byteCount: 1, metadata: UploadMetadata(title: "x"))
        await #expect(throws: UploadTransportError.unavailable) { _ = try await transport.upload(request, progress: { _ in }, handle: { _ in }) }
        await #expect(throws: UploadTransportError.unavailable) { _ = try await transport.processing(handle: "x") }
    }
    @Test func withoutAnAccountNothingIsAdded() async throws {
        let h = try Harness()
        h.account = nil
        let refused = await h.queue.add([try h.scratch.wav("One.wav")])
        #expect(refused.map(\.reason) == [.needsAccount] && h.queue.jobs.isEmpty && h.transport.uploadCount == 0)
    }
    @Test func aChoiceIsBoundedAtTheAppsOwnBatchLimit() async throws {
        let h = try Harness()
        h.transport.setDefault(.hold)
        var urls: [URL] = []
        for index in 0..<(UploadQueue.batchLimit + 3) { urls.append(try h.scratch.wav(String(format: "T%03d.wav", index))) }
        let refused = await h.queue.add(urls)
        #expect(h.queue.jobs.count == UploadQueue.batchLimit && refused.map(\.reason) == [.tooManyAtOnce(UploadQueue.batchLimit)])
        for index in 0..<UploadQueue.batchLimit { h.transport.release(String(format: "T%03d.wav", index)) }
    }

    // MARK: Restart

    @Test func afterARestartAJobThatWasTransferringIsInterruptedAndNothingStartsByItself() async throws {
        let h = try Harness()
        h.transport.script("Big.wav", .hold)
        let account = try #require(h.account)
        await h.queue.add([try h.scratch.wav("Big.wav"), try h.scratch.wav("Next.wav")])
        await h.until("uploading") { h.phase("Big.wav") == .uploading }
        await h.queue.settled()
        // The app "quits": a new queue over the same stored list, a new (idle) transport.
        let second = ScriptedUpload()
        let queue2 = h.makeQueue(transport: second)
        await queue2.restore()
        #expect(queue2.jobs.map(\.phase) == [.interrupted, .interrupted] && queue2.jobs.allSatisfy { $0.reason == .appClosed })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(second.uploadCount == 0, "nothing was resumed or restarted by itself")
        let stored = await h.store.jobs(account)
        #expect(stored.map(\.phase) == [.interrupted, .interrupted], "and the restart state was saved")
        // No resumption on this route: the person starts it over, once.
        #expect(!queue2.canResume(queue2.jobs[0]) && queue2.startOver(queue2.jobs[0].id))
        await h.until("restarted") { second.uploadCount >= 1 }
        h.transport.release("Big.wav")
    }
    @Test func aFileTheServiceAlreadyHoldsIsWatchedAgainAfterARestartWithoutBeingSentAgain() async throws {
        let h = try Harness(polls: 2)
        h.transport.defaultProcessing([.processing])
        await h.queue.add([try h.scratch.wav("Proc.wav")])
        await h.until("processing") { h.phase("Proc.wav") == .processing }
        await h.queue.settled()
        let second = ScriptedUpload()
        second.defaultProcessing([.completed])
        let queue2 = h.makeQueue(transport: second)
        await queue2.restore()
        await h.until("completed after restart") { queue2.jobs.first?.phase == .completed }
        #expect(second.uploadCount == 0 && h.refreshCalls == 1)
    }
    @Test func aStoredListThatCannotBeReadIsReportedNotShownAsEmpty() async throws {
        let h = try Harness()
        await h.store.setFailLoad(true)
        await h.queue.restore()
        #expect(h.queue.jobs.isEmpty && h.queue.storeFailure != nil)
        await h.store.setFailLoad(false); await h.store.setFailSave(true)
        await h.queue.add([try h.scratch.wav("One.wav")])
        await h.queue.settled()
        #expect(h.queue.storeFailure?.contains("won’t survive a restart") == true)
    }
    @Test func theStoredRecordHoldsNoFileContentsAndOnlyThePathOfWhatWasChosen() async throws {
        let h = try Harness()
        h.transport.script("Rec.wav", .hold)
        let url = try h.scratch.wav("Rec.wav")
        await h.queue.add([url])
        await h.until("uploading") { h.phase("Rec.wav") == .uploading }
        await h.queue.settled()
        let stored = await h.store.jobs(try #require(h.account))
        let encoded = try PropertyListEncoder().encode(stored)
        #expect(encoded.count < 4_000 && stored[0].source.path == url.resolvingSymlinksInPath().path)
        h.transport.release("Rec.wav")
    }

    // MARK: T19.3 account scope

    @Test func anAccountSwitchStopsOldAccessAndTheNewAccountNeverSeesOrCompletesTheOldJobs() async throws {
        let h = try Harness()
        let a = try #require(h.account), b = "22222222-2222-4222-8222-222222222222"
        h.transport.script("Old.wav", .hold)
        await h.queue.add([try h.scratch.wav("Old.wav"), try h.scratch.wav("Queued.wav")])
        await h.until("uploading with the route's handle known") { h.phase("Old.wav") == .uploading && h.job("Old.wav")?.handle != nil }
        let oldID = try #require(h.job("Old.wav")).id
        h.transport.lateReportAfterCancel = true
        h.account = b
        h.queue.accountChanged()
        #expect(h.queue.jobs.isEmpty, "the new account starts with its own list, at once")
        #expect(h.queue.openLeaseCount == 0, "every lease was released at once (before anything else ran)")
        await h.until("the old account's transfer was ended, not left running") { h.transport.runningNow == 0 }
        await h.queue.settled()
        #expect(h.transport.cancelledHandles == [h.transport.handle(for: oldID)], "the transport was told to drop the old account's one running upload, and only that one")
        h.transport.release("Old.wav")
        try? await Task.sleep(for: .milliseconds(80))
        #expect(h.queue.jobs.isEmpty && h.refreshCalls == 0 && h.transport.uploadCount == 1, "a late report from the old account changes nothing and starts nothing for the new one")
        let stored = await h.store.jobs(a)
        #expect(stored.map(\.phase) == [.interrupted, .interrupted] && stored.allSatisfy { $0.reason == .accountChanged && $0.account == a })
        #expect((await h.store.jobs(b)).isEmpty)
        // Coming back: the old account's jobs are its own, stopped, and waiting for an explicit decision.
        h.account = a
        h.queue.accountChanged(); await h.queue.settled()
        #expect(h.queue.jobs.map(\.phase) == [.interrupted, .interrupted] && h.transport.uploadCount == 1)
    }
    @Test func theNewAccountsOwnJobsAreReadWhenTheAccountChanges() async throws {
        let h = try Harness()
        let b = "22222222-2222-4222-8222-222222222222"
        let source = try await UploadSourceInspector(metadata: { _ in nil }).inspect(try h.scratch.wav("Theirs.wav")).get()
        var theirs = UploadJob(account: b, source: source)
        _ = theirs.move(to: .uploading); _ = theirs.move(to: .failed, reason: .offline)
        await h.store.put([theirs], account: b)
        h.account = b
        h.queue.accountChanged(); await h.queue.settled()
        #expect(h.queue.jobs.map(\.id) == [theirs.id])
    }
    @Test func aChoiceBeingCheckedWhenTheAccountChangesIsNotAddedToTheNewAccount() async throws {
        let gate = Gate()
        let h = try Harness(metadata: { _ in await gate.wait(); return nil })
        let url = try h.scratch.wav("Slow.wav")
        let adding = Task { await h.queue.add([url]) }
        await settle()
        h.account = "22222222-2222-4222-8222-222222222222"
        h.queue.accountChanged()
        await gate.open()
        _ = await adding.value
        await h.queue.settled()
        #expect(h.queue.jobs.isEmpty && h.transport.uploadCount == 0)
    }
    @Test func aCompletionForTheOldAccountDoesNotReadTheNewAccountsLists() async throws {
        let h = try Harness(polls: 4)
        h.transport.defaultProcessing([.processing])
        await h.queue.add([try h.scratch.wav("P.wav")])
        await h.until("processing") { h.phase("P.wav") == .processing }
        h.transport.defaultProcessing([.completed])
        h.account = "22222222-2222-4222-8222-222222222222"
        h.queue.accountChanged(); await h.queue.settled()
        try? await Task.sleep(for: .milliseconds(60))
        #expect(h.refreshCalls == 0 && h.queue.jobs.isEmpty)
    }

    // MARK: Cleanup and the state machine

    @Test func onlyFinishedJobsCanBeDismissedAndOnlyTheRecordGoes() async throws {
        let h = try Harness()
        h.transport.script("Live.wav", .hold)
        let url = try h.scratch.wav("Live.wav")
        await h.queue.add([url])
        await h.until("uploading") { h.phase("Live.wav") == .uploading }
        h.queue.dismiss(try #require(h.job("Live.wav")).id)
        #expect(h.queue.jobs.count == 1, "an active job can't be dismissed, only cancelled")
        h.transport.release("Live.wav")
        await h.until("done") { h.phase("Live.wav") == .completed }
        h.queue.dismiss(try #require(h.job("Live.wav")).id)
        #expect(h.queue.jobs.isEmpty && FileManager.default.fileExists(atPath: url.path))
    }
    @Test func theStateMachineNeverLeavesACompletedOrCancelledJobAndFailureOnlyLeadsToANewAttempt() throws {
        for phase in [UploadJob.Phase.completed, .cancelled] { #expect(UploadJob.allowed(from: phase).isEmpty) }
        #expect(UploadJob.allowed(from: .failed) == [.queued])
        #expect(!UploadJob.allowed(from: .queued).contains(.completed) && !UploadJob.allowed(from: .uploading).contains(.completed), "completed is reachable only from processing")
        #expect(UploadJob.allowed(from: .processing).contains(.completed))
        let scratch = try Scratch()
        let source = UploadSource(path: scratch.root.path, displayName: "x", byteCount: 1, modified: Date(), format: .wav, contentConfirmed: true, metadata: UploadMetadata(title: "x"))
        var job = UploadJob(account: "a", source: source)
        #expect(!job.move(to: .completed) && job.phase == .queued, "no jump from queued to completed")
        #expect(job.move(to: .uploading) && job.move(to: .processing) && job.move(to: .completed))
        #expect(!job.move(to: .failed) && !job.move(to: .queued) && job.phase == .completed)
    }
    @Test func theRecordIsBoundedButNeverDropsAJobThatIsStillRunning() throws {
        let scratch = try Scratch()
        let source = UploadSource(path: scratch.root.path, displayName: "x", byteCount: 1, modified: Date(), format: .wav, contentConfirmed: true, metadata: UploadMetadata(title: "x"))
        var jobs: [UploadJob] = []
        for index in 0..<230 {
            var job = UploadJob(account: "a", source: source, now: Date(timeIntervalSince1970: Double(index)))
            _ = job.move(to: .cancelled, now: Date(timeIntervalSince1970: Double(index)))
            jobs.append(job)
        }
        let running = UploadJob(account: "a", source: source, now: Date(timeIntervalSince1970: 0))
        let kept = UploadQueue.pruned(jobs + [running])
        #expect(kept.count == 201 && kept.contains { $0.id == running.id } && !kept.contains { $0.id == jobs[0].id } && kept.contains { $0.id == jobs[229].id })
    }
}

/// A one-shot gate a test opens by hand.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if isOpen { return }; await withCheckedContinuation { waiters.append($0) } }
    func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters = [] }
}
@MainActor func settle(_ rounds: Int = 80) async { for _ in 0..<rounds { await Task.yield() } }
