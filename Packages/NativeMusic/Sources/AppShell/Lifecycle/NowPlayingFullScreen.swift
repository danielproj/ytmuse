import AppKit
import DesignSystem
import Features
import Observation
import Playback
import SwiftUI

/// W21 (WIN06). Full-screen Now Playing: a native window that goes through macOS full screen and shows V02's `ExpandedPlayer` (the cover, or, for a YouTube
/// Music music video or live stream, the hidden player's own picture, never covered, ads included; the transport, the timeline and the accessories), with
/// the queue and lyrics beside it on request. Entering and leaving it neither moves focus nor touches playback; normal full-screen browsing stays available.
@MainActor final class NowPlayingFullScreen {
    let presenter = VideoWindowPresenter()
    private weak var shell: ShellCoordinator?
    var isOpen: Bool { presenter.isOpen }
    var window: NSWindow? { presenter.window }
    var onWindow: ((NSWindow?) -> Void)?
    init() {
        // Closing lets the picture go back (the inline surface leaves with the window). It never pauses, reloads or restarts anything.
        presenter.onClose = { [weak self] in self?.onWindow?(nil) }
    }
    /// Opens the window (one owner of the picture: a separate video window is closed first) and enters full screen unless already there.
    func show(shell: ShellCoordinator, enterFullScreen: Bool = true) {
        self.shell = shell
        shell.playback.webVideoWindows.closeAll()
        presenter.show(title: String(localized: "Now Playing"), identifier: "nowPlayingFullScreen") {
            NowPlayingFullScreenView(shell: shell, leave: { [weak self] in self?.leave() })
                .appAppearance()
        }
        onWindow?(presenter.window)
        if enterFullScreen, !presenter.isFullScreen { presenter.toggleFullScreen() }
    }
    /// Collapse (Escape or the chevron): out of full screen first, then the window closes.
    func leave() {
        if presenter.isFullScreen { presenter.toggleFullScreen() } else { presenter.close() }
    }
    func close() { presenter.close() }
}

struct NowPlayingFullScreenView: View {
    enum Panel: String, CaseIterable { case none = "None", queue = "Queue", lyrics = "Lyrics" }
    let shell: ShellCoordinator
    let leave: () -> Void
    @State private var panel: Panel
    init(shell: ShellCoordinator, leave: @escaping () -> Void, initialPanel: Panel = .none) { self.shell = shell; self.leave = leave; _panel = State(initialValue: initialPanel) }
    var body: some View {
        ShellExpandedPlayer(shell: shell, collapse: leave, showQueue: { panel = panel == .queue ? .none : .queue }, pictureWidth: Self.pictureWidth, compact: false) {
            if panel != .none {
                VStack(spacing: MusicSpace.xs) {
                    Picker("Panel", selection: $panel) { ForEach([Panel.queue, .lyrics], id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().padding([.horizontal, .top], MusicSpace.sm).accessibilityIdentifier("fullScreenPanelPicker")
                    if panel == .queue { shell.queuePanel() } else { shell.lyricsPanel() }
                }.frame(width: Self.panelWidth).musicSurface(.panel).audit("fullScreenPanel", group: "expandedRow", within: "playerExpanded")
                    .accessibilityElement(children: .contain).accessibilityIdentifier("fullScreenPanel")
            }
        }
        .padding(MusicSpace.xs)
        .background { MusicCanvas() }
        .audit("fullScreenNowPlaying", group: "outer", kind: .region)
        .accessibilityElement(children: .contain).accessibilityIdentifier("nowPlayingFullScreenRoot")
    }
    /// A video picture in full screen may be far wider than the page's preview.
    static let pictureWidth: CGFloat = 1280
    static let panelWidth: CGFloat = 340
}
