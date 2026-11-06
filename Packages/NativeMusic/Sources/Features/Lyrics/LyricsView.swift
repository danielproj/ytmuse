import AccountSession
import DesignSystem
import SwiftUI

/// The lyrics panel for whatever the player is on. It shows the source's text exactly as supplied with the source's own attribution line, and
/// it says plainly when there is no timing: lines are highlighted and tappable only when the source printed their times.
public struct LyricsPanelView: View {
    @Bindable var model: LyricsModel
    @Bindable var follow: LyricsFollowModel
    /// The song the player is on (nil: nothing, an ad, or something that is not a song) and its position in seconds.
    let videoID: String?
    let position: () -> Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let motion = MusicMotionContext()
    public init(model: LyricsModel, follow: LyricsFollowModel, videoID: String?, position: @escaping () -> Double) {
        self.model = model; self.follow = follow; self.videoID = videoID; self.position = position
    }
    public var body: some View {
        Group {
            switch model.state {
            case .idle:
                EmptyState(title: "No song is playing", message: "Lyrics appear here for the song that is playing.")
            case .loading:
                LoadingState("Loading lyrics…")
            case .unavailable:
                // The service was read and has no lyrics for this song: a different state from a failed read.
                EmptyState(title: "No lyrics available", message: "YouTube Music has no lyrics for this song.").accessibilityIdentifier("lyricsUnavailable")
            case .failed(let failure):
                ErrorState(title: "Lyrics couldn’t be loaded", detail: failure.message, retryIdentifier: "lyricsRetry") { Task { await model.retry() } }
                    .accessibilityElement(children: .contain).accessibilityLabel(Text(verbatim: failure.message)).accessibilityIdentifier("lyricsFailed")
            case .loaded(let document):
                loaded(document).id(model.videoID ?? "")
            }
        }
        .task(id: videoID) { await model.show(videoID: videoID) }
        .accessibilityElement(children: .contain).accessibilityLabel(Text("Lyrics")).accessibilityIdentifier("lyricsPanel")
    }

    @ViewBuilder private func loaded(_ document: MusicLyricsDocument) -> some View {
        switch document.body {
        case .plain(let text):
            ScrollView {
                VStack(alignment: .leading, spacing: MusicSpace.md) {
                    Text(verbatim: text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("lyricsText")
                    if let footer = document.sourceFooter { Text(verbatim: footer).font(.caption).foregroundStyle(MusicStyle.secondaryText).textSelection(.enabled).accessibilityIdentifier("lyricsSource") }
                    // Honest about what the source supplied: no times, so no highlight, no seek.
                    Label("These lyrics came without timing, so they don’t follow the song. Scroll to read.", systemImage: "info.circle")
                        .font(MusicPageStyle.note).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("lyricsUntimedNote")
                }.padding(MusicSpace.lg)
            }
        case .timed(let lines):
            timed(lines, footer: document.sourceFooter)
        }
    }
    private func timed(_ lines: [MusicTimedLyricLine], footer: String?) -> some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: MusicSpace.lg) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            let isCurrent = follow.current == index
                            Group {
                                if follow.linesSeekable {
                                    Button { Task { await follow.seek(toLine: index) } } label: { lineText(line.text, current: isCurrent) }
                                        .buttonStyle(.plain).accessibilityHint(Text("Moves playback to this line"))
                                } else { lineText(line.text, current: isCurrent) }
                            }
                            .id(index).accessibilityAddTraits(isCurrent ? .isSelected : []).accessibilityIdentifier("lyricsLine-\(index)")
                        }
                        if let footer { Text(verbatim: footer).font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("lyricsSource") }
                    }.padding(MusicSpace.lg)
                }
                .onScrollPhaseChange { _, phase in if phase == .interacting || phase == .decelerating { follow.userScrolled() } }
                if follow.canReturn {
                    Button { follow.returnToCurrent(); scroll(proxy) } label: { Label("Return to Current Line", systemImage: "arrow.down.to.line") }
                        .musicPageAction(prominent: true).padding().accessibilityIdentifier("lyricsReturn")
                }
            }
            .onAppear { follow.setLines(lines); follow.update(position: position()); scroll(proxy) }
            .onChange(of: position()) { _, value in follow.update(position: value) }
            .onChange(of: follow.current) { _, _ in scroll(proxy) }
        }
    }
    private func lineText(_ text: String, current: Bool) -> some View {
        Text(verbatim: text).font(current ? .title2.weight(.semibold) : .title3).lineSpacing(MusicSpace.xxs).foregroundStyle(current ? Color.primary : MusicStyle.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            // Highlight moves without animation under Reduce Motion.
            .musicAnimation(.selection, value: current)
    }
    private func scroll(_ proxy: ScrollViewProxy) {
        guard let action = follow.pendingScroll(reduceMotion: reduceMotion) else { return }
        if action.animated { motion.perform(.navigation) { proxy.scrollTo(action.index, anchor: .center) } }
        else { proxy.scrollTo(action.index, anchor: .center) }
        follow.didScroll(to: action.index)
    }
}
