import AccountSession
import Foundation
import Testing
@testable import Features

private func lines(_ starts: [Double]) -> [MusicTimedLyricLine] { starts.enumerated().map { MusicTimedLyricLine(text: "Line \($0.offset)", start: $0.element, end: nil) } }

/// T18.4: exactly one timed line is current; manual scrolling is stable; return and line seeks work only when supported; Reduce Motion avoids the animation.
@Suite struct TimedLyricsTests {
    @Test func exactlyOneLineIsCurrentAndNoneBeforeTheFirst() {
        let list = lines([2, 5, 9])
        #expect(TimedLyrics.currentIndex(in: list, at: 0) == nil && TimedLyrics.currentIndex(in: list, at: 1.99) == nil)
        #expect(TimedLyrics.currentIndex(in: list, at: 2) == 0 && TimedLyrics.currentIndex(in: list, at: 4.99) == 0)
        #expect(TimedLyrics.currentIndex(in: list, at: 5) == 1 && TimedLyrics.currentIndex(in: list, at: 8.5) == 1)
        #expect(TimedLyrics.currentIndex(in: list, at: 9) == 2 && TimedLyrics.currentIndex(in: list, at: 10_000) == 2)
    }
    @Test func theCurrentLineNeverMovesBackwardsAsTimeAdvances() {
        let list = lines([0, 1.5, 1.5, 4, 8.25, 8.25, 20])
        var previous = -1
        for tenth in 0...300 {
            let now = Double(tenth) / 10
            let index = TimedLyrics.currentIndex(in: list, at: now) ?? -1
            #expect(index >= previous, Comment(rawValue: "t=\(now)"))
            // The answer is the LAST line whose start has passed: an independent linear scan agrees.
            let expected = list.lastIndex(where: { $0.start <= now }) ?? -1
            #expect(index == expected, Comment(rawValue: "t=\(now)"))
            previous = index
        }
    }
    @Test func noLinesOrANonFinitePositionHasNoCurrentLine() {
        #expect(TimedLyrics.currentIndex(in: [], at: 12) == nil)
        #expect(TimedLyrics.currentIndex(in: lines([0, 1]), at: .nan) == nil && TimedLyrics.currentIndex(in: lines([0, 1]), at: .infinity) == nil)
    }
}

@Suite struct LyricsAutoScrollTests {
    @Test func followingScrollsToTheCurrentLineWhenItChanges() {
        #expect(LyricsAutoScroll.action(current: 3, shown: 2, mode: .following, reduceMotion: false) == LyricsScrollAction(index: 3, animated: true))
        #expect(LyricsAutoScroll.action(current: 3, shown: 3, mode: .following, reduceMotion: false) == nil, "already there")
        #expect(LyricsAutoScroll.action(current: nil, shown: 2, mode: .following, reduceMotion: false) == nil, "before the first line")
    }
    @Test func manualScrollingIsLeftAlone() {
        #expect(LyricsAutoScroll.action(current: 3, shown: 2, mode: .manual, reduceMotion: false) == nil)
    }
    @Test func reduceMotionJumpsWithoutAnimating() {
        let animated = LyricsAutoScroll.action(current: 4, shown: 3, mode: .following, reduceMotion: false)
        let still = LyricsAutoScroll.action(current: 4, shown: 3, mode: .following, reduceMotion: true)
        #expect(animated?.animated == true)
        #expect(still?.index == 4 && still?.animated == false, "the same scroll, without animation")
    }
}

@MainActor @Suite struct LyricsFollowModelTests {
    private func make(canSeek: Box<Bool> = Box(true), seeks: Box<[Double]> = Box([]), seekWorks: Bool = true, starts: [Double] = [1, 5, 9, 14]) -> (LyricsFollowModel, Box<Bool>, Box<[Double]>) {
        let model = LyricsFollowModel(seek: { seconds in seeks.value.append(seconds); return seekWorks }, canSeek: { canSeek.value })
        model.setLines(lines(starts))
        return (model, canSeek, seeks)
    }
    @Test func theHighlightFollowsThePositionAndOnlyOneLineIsCurrent() {
        let (model, _, _) = make()
        model.update(position: 0.5)
        #expect(model.current == nil)
        model.update(position: 6)
        #expect(model.current == 1)
        model.update(position: 14.2)
        #expect(model.current == 3)
    }
    @Test func scrollingByHandStopsTheFollowingAndStaysStillWhilePlaybackMoves() {
        let (model, _, _) = make()
        model.update(position: 6)
        model.didScroll(to: 1)
        #expect(model.mode == .following && model.pendingScroll(reduceMotion: false) == nil)
        model.userScrolled()
        model.update(position: 10)
        #expect(model.current == 2, "the highlight still follows the song")
        #expect(model.mode == .manual && model.pendingScroll(reduceMotion: false) == nil, "but the panel is not moved under the reader")
        model.update(position: 15)
        #expect(model.pendingScroll(reduceMotion: false) == nil)
    }
    @Test func returnToCurrentIsOfferedOnlyAfterManualScrollAndFollowsAgain() {
        let (model, _, _) = make()
        #expect(!model.canReturn)
        model.update(position: 6)
        model.userScrolled()
        #expect(model.canReturn)
        model.returnToCurrent()
        #expect(model.mode == .following && !model.canReturn)
        #expect(model.pendingScroll(reduceMotion: false) == LyricsScrollAction(index: 1, animated: true))
        #expect(model.pendingScroll(reduceMotion: true) == LyricsScrollAction(index: 1, animated: false))
    }
    @Test func returnIsNotOfferedBeforeAnyLineIsCurrent() {
        let (model, _, _) = make()
        model.update(position: 0.2)
        model.userScrolled()
        #expect(!model.canReturn, "there is no current line to return to")
    }
    @Test func aLineSeeksToTheStartTheSourcePrintedWhenSeekingIsSupported() async {
        let (model, _, seeks) = make()
        model.update(position: 6)
        model.userScrolled()
        #expect(model.linesSeekable)
        let done = await model.seek(toLine: 2)
        #expect(done && seeks.value == [9] && model.mode == .following, "seeking also returns to following")
    }
    @Test func aLineDoesNotSeekWhenThePlayerWillNotTakeIt() async {
        let (model, canSeek, seeks) = make(canSeek: Box(false))
        #expect(!model.linesSeekable)
        #expect(await model.seek(toLine: 1) == false && seeks.value.isEmpty, "an ad, a stream with no window, or nothing loaded")
        canSeek.value = true
        #expect(await model.seek(toLine: 99) == false && seeks.value.isEmpty, "a line that does not exist")
    }
    @Test func aRefusedSeekChangesNothing() async {
        let (model, _, seeks) = make(seekWorks: false)
        model.update(position: 6); model.userScrolled()
        #expect(await model.seek(toLine: 2) == false)
        #expect(seeks.value == [9] && model.mode == .manual)
    }
    @Test func untimedLyricsHaveNoLinesNoHighlightAndNoSeek() async {
        let model = LyricsFollowModel(seek: { _ in true }, canSeek: { true })
        model.setLines([])
        for position in stride(from: 0.0, through: 300, by: 7.5) { model.update(position: position) }
        #expect(model.current == nil && !model.linesSeekable && !model.canReturn)
        model.userScrolled()
        #expect(model.mode == .following, "a plain page has nothing to follow, so scrolling it is just reading")
        #expect(await model.seek(toLine: 0) == false)
    }
    @Test func newLinesStartFollowingFromScratch() {
        let (model, _, _) = make()
        model.update(position: 10); model.userScrolled(); model.didScroll(to: 2)
        model.setLines(lines([0, 3]))
        #expect(model.current == nil && model.mode == .following && model.shown == nil)
    }
}
