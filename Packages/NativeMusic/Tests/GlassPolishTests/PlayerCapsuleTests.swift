import Testing
import Foundation
import SwiftUI
import DesignSystem
import Domain
@testable import AppShell

/// PLAYER-1: the floating capsule's place, size and the identifiers the UI tests and VoiceOver rely on.
@Suite struct PlayerCapsuleTests {
    private let column = CGRect(x: 236, y: 52, width: 900, height: 760)

    @Test func theCapsuleIsCentredInTheColumnWithTheMarginsAbove() {
        // The brief's numbers, stated as literals: a test that restates the constant it checks cannot fail.
        #expect(PlayerCapsule.margin == 16 && PlayerCapsule.panelGap == 12 && PlayerCapsule.maximumWidth == 960 && PlayerCapsule.regularHeight == 56)
        let frame = PlayerCapsule.frame(column: column, windowHeight: 820, compact: false)
        #expect(frame.height == 56)
        #expect(frame.width == 900 - 2 * PlayerCapsule.margin)
        #expect(abs(frame.midX - column.midX) < 0.01)
        #expect(frame.minX == column.minX + PlayerCapsule.margin)
        #expect(frame.maxY == 820 - PlayerCapsule.margin, "the margin above the window's bottom")
    }
    @Test func theCapsuleIsCappedAtNineHundredSixtyAndStaysCentred() {
        let wide = CGRect(x: 236, y: 52, width: 1700, height: 900)
        let frame = PlayerCapsule.frame(column: wide, windowHeight: 960, compact: false)
        #expect(frame.width == 960)
        #expect(abs(frame.midX - wide.midX) < 0.01)
    }
    @Test func theCompactCapsuleIsFortyEightTall() {
        let frame = PlayerCapsule.frame(column: column, windowHeight: 820, compact: true)
        #expect(frame.height == 48)
        #expect(PlayerCapsule.coverEdge(compact: true) == 32 && PlayerCapsule.coverEdge(compact: false) == 40)
        #expect(PlayerCapsule.coverRadius(compact: true) == 10 && PlayerCapsule.coverRadius(compact: false) == 12)
    }
    @Test func aColumnNarrowerThanTheMarginsGivesNoNegativeWidth() {
        #expect(PlayerCapsule.frame(column: CGRect(x: 0, y: 0, width: 20, height: 100), windowHeight: 100, compact: false).width == 0)
    }
    @Test func thePanelsReserveTheCapsuleItsMarginAndTheGap() {
        #expect(PlayerCapsule.bottomReserve(compact: false) == PlayerCapsule.margin + 56 + PlayerCapsule.panelGap)
        #expect(PlayerCapsule.bottomReserve(compact: true) == PlayerCapsule.margin + 48 + PlayerCapsule.panelGap)
    }
    @Test func theSeekRunsFromTheTitleToTheCornerRadiusAndNeverUnderTheCover() {
        // Measured from the row's edges, which sit 8 pt inside the capsule: the cover plus the 12 pt gap, and the corner radius less the 8 pt.
        #expect(PlayerCapsule.seekLeading(compact: false) == 40 + 12 && PlayerCapsule.seekLeading(compact: true) == 32 + 12)
        #expect(PlayerCapsule.seekTrailing(compact: false) == 28 - 8 && PlayerCapsule.seekTrailing(compact: true) == 24 - 8)
        #expect(PlayerCapsule.seekRestThickness == 2 && PlayerCapsule.seekHoverThickness == 4)
    }
    /// The brief's invariants in numbers, for both capsule heights: the track and the thumb stay at least 2 pt inside the capsule and clear of the Play circle.
    @Test(arguments: [false, true]) func theTrackAndTheThumbStayInsideTheCapsuleAndClearOfThePlayCircle(compact: Bool) {
        let height = PlayerCapsule.height(compact: compact), thumb = PlayerCapsule.thumbEdge(compact: compact)
        let centre = height - PlayerCapsule.seekCentre(compact: compact)             // y of the seek's centre line
        let trackBottom = centre + PlayerCapsule.seekHoverThickness / 2, thumbBottom = centre + thumb / 2
        let trackTop = centre - PlayerCapsule.seekHoverThickness / 2, thumbTop = centre - thumb / 2
        #expect(height - trackBottom >= 2 && height - thumbBottom >= 2, "at least 2 pt inside: track \(height - trackBottom), thumb \(height - thumbBottom)")
        let play = PlayerCapsule.playEdge(compact: compact)
        let circleBottom = (height + play) / 2 - PlayerCapsule.transportLift
        #expect(trackTop > circleBottom && thumbTop > circleBottom, "clear of the Play circle (bottom \(circleBottom)): track top \(trackTop), thumb top \(thumbTop)")
        #expect(thumb == (compact ? 6 : 8))
    }
    @Test func theSeekStatesShowTimesAndThumbAsTheBriefSays() {
        #expect(MusicSeekState(hovering: false, dragging: false, focused: false) == .rest)
        #expect(MusicSeekState(hovering: true, dragging: false, focused: false) == .hover)
        #expect(MusicSeekState(hovering: true, dragging: true, focused: false) == .active)
        #expect(MusicSeekState(hovering: false, dragging: false, focused: true) == .active)
        #expect(!MusicSeekState.rest.showsTimes && MusicSeekState.hover.showsTimes && MusicSeekState.active.showsTimes)
        #expect(!MusicSeekState.rest.showsThumb && !MusicSeekState.hover.showsThumb && MusicSeekState.active.showsThumb, "a thumb only while dragging or focused")
        #expect(MusicSeekState.rest.thickness == 2 && MusicSeekState.hover.thickness == 4 && MusicSeekState.active.thickness == 4)
    }
    @Test func theSlimSliderShowsItsKnobOnlyWhenActive() {
        #expect(!MusicSlimSlider<EmptyView>.showsKnob(active: false, enabled: true))
        #expect(MusicSlimSlider<EmptyView>.showsKnob(active: true, enabled: true))
        #expect(!MusicSlimSlider<EmptyView>.showsKnob(active: true, enabled: false))
        #expect(PlayerCapsule.slimTrackThickness == 3 && PlayerCapsule.slimKnobEdge == 8)
    }
    @Test func theTimesTakeASlotOnlyWhereThereIsRoom() {
        #expect(PlayerCapsule.timeSlot(compact: false) == 40 && PlayerCapsule.timeSlot(compact: true) == 0)
    }

    // MARK: Identifiers

    private static let root: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static func appShellSource() throws -> String {
        let directory = root.appendingPathComponent("Packages/NativeMusic/Sources/AppShell")
        let walker = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        var text = ""
        for case let url as URL in walker where url.pathExtension == "swift" { text += try String(contentsOf: url, encoding: .utf8) }
        return text
    }
    /// The identifiers the capsule must still carry (the UI tests, VoiceOver and the sleep-timer surfaces read them).
    @Test func everyIdentifierTheBarHadIsStillDeclared() throws {
        let text = try Self.appShellSource()
        #expect(text.count > 100_000, "the sweep read the real AppShell sources")
        let identifiers = ["musicTitle", "musicArtist", "musicAdBadge", "musicPrevious", "musicPlayPause", "musicNext", "musicShuffle", "musicRepeat", "musicVolume",
                           "transportQueue", "musicTimeline", "musicElapsed", "musicRemaining", "musicShowVideo", "musicGoLive", "musicLiveBadge", "musicSleepRemaining",
                           "musicFailure", "musicNotice", "musicRefusal", "musicSleepTimerMenu", "sleepTimerMenu", "transportPrevious", "transportPlayPause", "transportNext",
                           "transportMute", "appVolume", "transportTimeline", "transportElapsed", "sleepRemaining", "playbackState", "currentMediaTitle", "playbackError",
                           "outputPromptConfirm", "transportDuration", "sleepTimerSubmenu"]
        let missing = identifiers.filter { !text.contains("\"\($0)\"") && !(try! String(contentsOf: Self.root.appendingPathComponent("Packages/NativeMusic/Sources/Features/OutputPicker/OutputPicker.swift"), encoding: .utf8)).contains("\"\($0)\"") }
        #expect(missing.isEmpty, "identifiers no longer declared: \(missing)")
    }
    /// The seek stays a real Slider; the times are invisible at rest by their COLOUR, never by opacity 0 (a view at opacity 0 leaves the accessibility tree, and
    /// the times are read by VoiceOver and by tests); the volume is a real Slider under the slim drawing.
    @Test func theSeekIsARealSliderAndItsTimesStayInTheAccessibilityTree() throws {
        let capsule = try String(contentsOf: Self.root.appendingPathComponent("Packages/NativeMusic/Sources/DesignSystem/PlayerCapsule.swift"), encoding: .utf8)
        #expect(capsule.contains("visible && slot > 0 ? MusicStyle.secondaryText : Color.clear") && capsule.contains("control.controlSize(.mini).opacity(0.02)"))
        #expect(!capsule.contains(".opacity(visible ? 1 : 0)") && !capsule.contains(".opacity(hovering ? 1 : 0)"))
        let views = try String(contentsOf: Self.root.appendingPathComponent("Packages/NativeMusic/Sources/AppShell/PlayerCapsuleViews.swift"), encoding: .utf8)
        #expect(views.contains("Slider(value:") && views.contains("\"musicTimeline\"") && views.contains("\"transportTimeline\""))
        #expect(views.contains("Slider(value: Binding(get: { level }, set: set), in: range, onEditingChanged: { dragging = $0 })"), "the volume is a real Slider")
        // Seeking stays refused whenever it was (an ad, a live stream): the real slider is disabled by the snapshot's own rule.
        #expect(views.contains(".disabled(!snapshot.canSeek)"))
    }
    /// The expanded player's controls match the capsule's: plain glyphs, the accent Play circle, the volume glyph with a slim slider (no "Mute" text button) and
    /// a ⋯ with no box. The mini player and the popover (ShellPlayerSurfaces) keep the boxed controls.
    @Test func theExpandedPlayerUsesThePlainControlsAndTheMiniPlayerDoesNot() throws {
        let expanded = try String(contentsOf: Self.root.appendingPathComponent("Packages/NativeMusic/Sources/AppShell/ExpandedPlayer.swift"), encoding: .utf8)
        #expect(expanded.contains("WebMusicControlsView(player: player, large: true, namespace: namespace, plain: true)"))
        #expect(expanded.contains("OwnedControlsView(model: model, large: true, namespace: namespace, plain: true)"))
        #expect(expanded.contains("WebMusicTimelineView(player: player, plain: true)") && expanded.contains(", plain: true)\n                    .audit(\"nowPlayingTimeline\""))
        #expect(expanded.contains("WebCapsuleSecondary(player: player, compact: compact, expanded: true") && expanded.contains("OwnedCapsuleSecondary(model: model, compact: compact, expanded: true"))
        let surfaces = try String(contentsOf: Self.root.appendingPathComponent("Packages/NativeMusic/Sources/AppShell/Lifecycle/ShellPlayerSurfaces.swift"), encoding: .utf8)
        #expect(!surfaces.contains("plain: true"), "the mini player and the status item are out of scope")
    }
    @Test func theOwnedMenuShowsTheCurrentShuffleAndRepeatMode() {
        let off = OwnedQueueModeState(seed: nil, repeatMode: .off), on = OwnedQueueModeState(seed: 7, repeatMode: .all)
        #expect(!off.shuffled && off.repeatMode == .off)
        #expect(on.shuffled && on.repeatMode == .all)
    }
}
