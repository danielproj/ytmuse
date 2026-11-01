import Testing
import Foundation
import Domain
import AccountSession
import Playback
import DesignSystem
@testable import AppShell
@testable import Features

// W28 T28.6: VoiceOver is told about state, error and account changes, never the playback clock or a lyric line, and never the same thing twice in a burst.

@Suite struct AnnouncementPolicyTests {
  private let t0 = Date(timeIntervalSince1970: 1_000)
  @Test func thereIsNoKindForTheClockOrALyricLine() {
    #expect(Set(AnnouncementKind.allCases.map(\.rawValue)) == ["transport", "error", "account", "download", "confirmation"])
  }
  @Test func theSameWordsAreNotRepeatedWithinTheWindow() {
    var policy = AnnouncementPolicy()
    #expect(policy.decide("Paused", kind: .transport, at: t0) == .speak)
    #expect(policy.decide("Paused", kind: .transport, at: t0.addingTimeInterval(3)) == .repeated)
    #expect(policy.decide("Paused", kind: .transport, at: t0.addingTimeInterval(9)) == .speak, "after the window it may be said again")
    #expect(policy.decide("  ", kind: .error, at: t0) == .empty)
  }
  @Test func aRetryLoopThatFailsTheSameWayEverySecondIsOneAnnouncement() {
    var policy = AnnouncementPolicy(); var spoken = 0
    for second in 0..<60 { if policy.decide("YouTube Music couldn’t be reached.", kind: .error, at: t0.addingTimeInterval(Double(second))) == .speak { spoken += 1 } }
    #expect(spoken <= 8, "60 identical failures were spoken \(spoken) times")
    #expect(spoken >= 1)
  }
  @Test func downloadBurstsAreBounded() {
    var downloads = AnnouncementPolicy(); var spoken = 0
    for index in 0..<20 { if downloads.decide("Download \(index) finished", kind: .download, at: t0.addingTimeInterval(Double(index) * 0.1)) == .speak { spoken += 1 } }
    #expect(spoken == downloads.burstLimit, "twenty distinct downloads in two seconds: only \(downloads.burstLimit) are spoken (got \(spoken))")
  }
  @Test func errorsAndAccountChangesAlwaysGetThrough() {
    var policy = AnnouncementPolicy()
    for index in 0..<10 { #expect(policy.decide("Failure \(index)", kind: .error, at: t0.addingTimeInterval(Double(index) * 0.01)) == .speak) }
    #expect(policy.decide("Signed out.", kind: .account, at: t0.addingTimeInterval(0.2)) == .speak, "an account change is spoken even after a burst")
  }
  @MainActor @Test func theAnnouncerSpeaksOnlyWhatThePolicyAdmits() {
    var spoken: [String] = []; var now = t0
    let announcer = Announcer(clock: { now }, sink: { spoken.append($0) })
    announcer.post("Failure A", kind: .error); announcer.post("Failure A", kind: .error)
    now = now.addingTimeInterval(20); announcer.post("Failure A", kind: .error)
    #expect(spoken == ["Failure A", "Failure A"], "the repeat inside the window is dropped, the same words after it are spoken again")
  }
  /// F4: on rapid skips the LATEST track is the one announced (the first used to win, and the comment said otherwise).
  @MainActor @Test func rapidSkipsAnnounceTheLatestTrackAndOnlyThat() {
    var spoken: [String] = []; var now = t0
    var scheduled: [(seconds: Double, work: @MainActor () -> Void, cancelled: Bool)] = []
    final class Flags { var cancelled: [Int: Bool] = [:] }
    let flags = Flags()
    let announcer = Announcer(clock: { now }, sink: { spoken.append($0) }, scheduler: { seconds, work in
      let index = scheduled.count; scheduled.append((seconds, work, false))
      return { flags.cancelled[index] = true }
    })
    announcer.post("Now playing “A”.", kind: .transport)
    announcer.post("Now playing “B”.", kind: .transport)
    announcer.post("Now playing “C”.", kind: .transport)
    #expect(spoken.isEmpty, "nothing is spoken while skipping")
    #expect(scheduled.count == 3 && flags.cancelled[0] == true && flags.cancelled[1] == true && flags.cancelled[2] != true, "each newer message cancels the older flush")
    for (index, item) in scheduled.enumerated() where flags.cancelled[index] != true { now = now.addingTimeInterval(item.seconds); item.work() }
    #expect(spoken == ["Now playing “C”."], "the announcement says C: \(spoken)")
    // A track a person listens to is announced, and so is a later pause.
    now = now.addingTimeInterval(30)
    announcer.post("Paused", kind: .transport);
    let last = scheduled.count - 1; now = now.addingTimeInterval(1); scheduled[last].work()
    #expect(spoken == ["Now playing “C”.", "Paused"])
  }
  @MainActor @Test func aQuickPauseAfterPlayAnnouncesTheFinalStateOnly() {
    var spoken: [String] = []; var scheduled: [@MainActor () -> Void] = []
    let announcer = Announcer(clock: { Date(timeIntervalSince1970: 5_000) }, sink: { spoken.append($0) }, scheduler: { _, work in scheduled.append(work); return {} })
    announcer.post("Playing", kind: .transport); announcer.post("Paused", kind: .transport)
    scheduled.last?()   // the superseded flush is cancelled in production; here only the newest one runs
    #expect(spoken == ["Paused"])
  }
  @Test func nothingBypassesTheAnnouncer() {
    var offenders: [String] = []
    for (path, text) in Repo.swiftFiles(under: "Packages/NativeMusic/Sources") + Repo.swiftFiles(under: "App/Sources") + Repo.swiftFiles(under: "Extensions/Sources") {
      let name = (path as NSString).lastPathComponent
      let code = Repo.code(text)
      if code.contains("AccessibilityNotification.Announcement") && name != "Announcer.swift" { offenders.append(path) }
      if code.contains("NSAccessibility.post") && code.contains("announcementRequested") { offenders.append(path) }
      // The clock and the lyrics never speak: nothing under Features/Lyrics, and no file that defines a timeline, may reach the announcer.
      let isLyrics = path.contains("/Features/Lyrics/") || name.hasPrefix("Lyrics")
      let isTimeline = code.contains("struct WebMusicTimelineView") || code.contains("PlaybackTimeline") || name.contains("Timeline")
      if (isLyrics || isTimeline) && code.contains("Announcer.") { offenders.append(path + " (announces from a lyrics or timeline file)") }
    }
    #expect(offenders.isEmpty, "announcements outside Announcer: \(offenders)")
  }
}

@Suite struct TransportAnnouncementTests {
  typealias State = TransportAnnouncementState
  private func playing(_ title: String = "Song", artist: String? = "Artist", id: String = "v1") -> State { State(phase: .playing, videoID: id, title: title, artist: artist) }
  @Test func thePlaybackClockNeverChangesTheState() {
    // The announcement state is built from phase, identity and ad flag only; a snapshot whose position changes is the same state.
    var a = WebMusicSnapshot(); a.phase = .playing; a.videoID = "v1"; a.title = "Song"; a.artist = "Artist"; a.position = 10; a.duration = 200
    var b = a; b.position = 11; b.duration = 200
    #expect(State(a) == State(b))
    var c = a; c.volume = 0.3; c.atLiveEdge = false
    #expect(State(a) == State(c), "volume and live-edge changes are not announced either")
    #expect(TransportAnnouncement.message(from: State(a), to: State(b)) == nil)
  }
  @Test func meaningfulTransportChangesAreSpoken() {
    let started = TransportAnnouncement.message(from: State(phase: .loading), to: playing())
    #expect(started?.text == "Now playing “Song” by Artist." && started?.kind == .transport)
    let noArtist = TransportAnnouncement.message(from: State(phase: .loading), to: playing(artist: nil))
    #expect(noArtist?.text == "Now playing “Song”.")
    #expect(TransportAnnouncement.message(from: playing(), to: State(phase: .paused, videoID: "v1", title: "Song", artist: "Artist"))?.text == "Paused")
    #expect(TransportAnnouncement.message(from: State(phase: .paused, videoID: "v1", title: "Song", artist: "Artist"), to: playing())?.text == "Playing")
    let next = TransportAnnouncement.message(from: playing(), to: playing("Next", artist: "Other", id: "v2"))
    #expect(next?.text == "Now playing “Next” by Other.")
    let ad = TransportAnnouncement.message(from: playing(), to: State(phase: .playing, videoID: "v1", title: "Song", artist: "Artist", isAd: true))
    #expect(ad?.text == "Advertisement playing")
    let adEnd = TransportAnnouncement.message(from: State(phase: .playing, videoID: "v1", title: "Song", artist: "Artist", isAd: true), to: playing())
    #expect(adEnd?.text == "Advertisement ended")
    let failed = TransportAnnouncement.message(from: playing(), to: State(phase: .failed("YouTube Music couldn’t start this. Try again."), videoID: "v1", title: "Song"))
    #expect(failed?.kind == .error && failed?.text == "YouTube Music couldn’t start this. Try again.")
  }
  @Test func noiseIsNotSpoken() {
    #expect(TransportAnnouncement.message(from: playing(), to: State(phase: .buffering, videoID: "v1", title: "Song", artist: "Artist")) == nil, "buffering")
    #expect(TransportAnnouncement.message(from: State(phase: .buffering, videoID: "v1", title: "Song", artist: "Artist"), to: playing()) == nil, "buffering ended")
    #expect(TransportAnnouncement.message(from: State(phase: .idle), to: State(phase: .loading)) == nil, "loading")
    // Metadata arriving late for the same track is not a new track.
    #expect(TransportAnnouncement.message(from: State(phase: .playing, videoID: "v1", title: "Song", artist: nil), to: playing()) == nil, "late artist metadata for the same track")
    let failedTwice = State(phase: .failed("x"))
    #expect(TransportAnnouncement.message(from: failedTwice, to: failedTwice) == nil, "the same failure is not announced again")
  }
}

@Suite struct AccountAnnouncementTests {
  private func context(_ n: Int) throws -> AccountContext { try AccountContext(accountID: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(n)")!, channelID: ID<ChannelTag>("c\(n)"), region: "DE") }
  @Test func onlyAChangeOfWhoIsSignedInOrWhetherTheSessionWorksIsSpoken() throws {
    let a = try context(1), b = try context(2)
    typealias S = AccountAnnouncementState
    let none = S(active: nil, name: nil, expired: false, hasIdentities: false)
    let signedA = S(active: a, name: "Ana", expired: false, hasIdentities: true)
    #expect(AccountAnnouncement.message(from: none, to: signedA) == "Signed in as Ana.")
    #expect(AccountAnnouncement.message(from: signedA, to: S(active: b, name: "Ben", expired: false, hasIdentities: true)) == "Switched to Ben.")
    #expect(AccountAnnouncement.message(from: signedA, to: S(active: a, name: "Ana", expired: true, hasIdentities: true)) == "The session for Ana ended. Sign in again.")
    #expect(AccountAnnouncement.message(from: S(active: a, name: "Ana", expired: true, hasIdentities: true), to: signedA) == "Signed in again as Ana.")
    #expect(AccountAnnouncement.message(from: signedA, to: none) == "Signed out.")
    #expect(AccountAnnouncement.message(from: signedA, to: signedA) == nil, "a refresh that changes nothing says nothing")
    #expect(AccountAnnouncement.message(from: none, to: none) == nil)
    #expect(AccountAnnouncement.message(from: signedA, to: S(active: a, name: "Ana (work)", expired: false, hasIdentities: true)) == nil, "a rename is visible on screen and not announced")
  }
}
