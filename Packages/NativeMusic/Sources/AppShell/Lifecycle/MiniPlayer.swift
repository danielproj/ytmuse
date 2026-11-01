import AppKit
import Domain
import DesignSystem
import Features
import Observation
import Playback
import SwiftUI

/// W21 (WIN05). The mini-player: a separate, resizable utility panel, about 360 x 160 points compact, with a larger artwork mode and a
/// pin-on-top option. It is a non-activating panel that is never the main window: showing it, a track change or any metadata update never
/// takes keyboard focus or makes it key, and it is never counted as a regular window, listed in the Windows menu or cycled with Command-`.
final class MiniPlayerPanel: NSPanel {
    override var canBecomeMain: Bool { false }
}

@MainActor final class MiniPlayerController: NSObject, NSWindowDelegate {
    private(set) var panel: MiniPlayerPanel?
    private let preferencesStore: UserDefaults
    private(set) var preferences: MiniPlayerPreferences
    private let makeContent: @MainActor (MiniPlayerController) -> AnyView
    var isShown: Bool { panel?.isVisible ?? false }
    /// Called when the panel is shown or closed, so the shell can register the window and count.
    var onVisibilityChange: ((NSWindow?) -> Void)?
    init(preferences store: UserDefaults, content: @escaping @MainActor (MiniPlayerController) -> AnyView) {
        preferencesStore = store; preferences = MiniPlayerPreferences.load(from: store); makeContent = content
    }
    /// The one place a mini-player panel is configured, so a test can assert the rules on a bare panel.
    static func configure(_ panel: NSPanel, preferences: MiniPlayerPreferences) {
        panel.isFloatingPanel = preferences.pinned
        panel.level = preferences.pinned ? .floating : .normal
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isExcludedFromWindowsMenu = true
        panel.isReleasedWhenClosed = false
        panel.worksWhenModal = false
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.hasShadow = true
        panel.contentMinSize = preferences.minimumSize
        // Never a document window: out of Command-` cycling; visible on every Space only while pinned.
        panel.collectionBehavior = preferences.pinned ? [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary] : [.ignoresCycle, .fullScreenAuxiliary]
        panel.setAccessibilityIdentifier("miniPlayerWindow")
    }
    /// Shows the panel without making it key (`orderFrontRegardless`), at the compact or expanded default size the first time.
    func show() {
        if let panel { panel.orderFrontRegardless(); return }
        let panel = MiniPlayerPanel(contentRect: NSRect(origin: .zero, size: preferences.defaultSize),
                                    styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        Self.configure(panel, preferences: preferences)
        panel.title = String(localized: "Mini-player")
        let hosting = NSHostingView(rootView: makeContent(self))
        hosting.sizingOptions = []   // the window's size is the person's; the content never resizes it
        panel.contentView = hosting
        panel.delegate = self
        // TH2: AppKit's frame autosave writes `NSWindow Frame YTMuseMiniPlayer` into the process's STANDARD defaults domain. In a test process that is the test runner's shared,
        // persistent domain (W28 left the key there for every lane); in an isolated QA launch it is the account holder's. So an isolated process neither saves nor restores a frame.
        if ProcessIsolation.isIsolated { panel.center() } else {
            panel.setFrameAutosaveName("YTMuseMiniPlayer")
            if !panel.setFrameUsingName("YTMuseMiniPlayer") { panel.center() }
        }
        self.panel = panel
        onVisibilityChange?(panel)
        panel.orderFrontRegardless()
    }
    func close() { panel?.close() }
    func windowWillClose(_ notification: Notification) {
        panel?.delegate = nil; panel = nil
        onVisibilityChange?(nil)
    }
    func setPinned(_ pinned: Bool) {
        preferences.pinned = pinned; preferences.save(to: preferencesStore)
        if let panel { Self.configure(panel, preferences: preferences) }
    }
    /// Compact and expanded are the person's choice; the window keeps its origin at the top-left and takes the matching default size.
    func setExpanded(_ expanded: Bool) {
        preferences.expanded = expanded; preferences.save(to: preferencesStore)
        guard let panel else { return }
        Self.configure(panel, preferences: preferences)
        var frame = panel.frame
        let content = panel.contentRect(forFrameRect: frame).size
        let target = CGSize(width: max(content.width, preferences.minimumSize.width), height: preferences.defaultSize.height)
        let newFrame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: target))
        frame.origin.y += frame.height - newFrame.height
        frame.size = newFrame.size
        panel.setFrame(frame, display: true, animate: ShellMotion.animatesWindows)
    }
}

/// The mini-player's content (GLASS01, GLASS11), composed from V02's surfaces. Compact: the cover, title, artist and Ad pill, V02's transport, Like, queue,
/// volume, pin and expand, over V02's timeline. Expanded: V02's `ExpandedPlayer` itself (hero, timeline, transport, accessories), with the pin and
/// Like above it. During an advertisement seek, skip and Previous are off (V02's controls and timeline read the same snapshot) and the Ad pill shows.
struct MiniPlayerView: View {
    let shell: ShellCoordinator
    let controller: MiniPlayerController
    @State private var pinned: Bool
    @State private var expanded: Bool
    @State private var visible = false
    @State private var accent: MusicTint?
    init(shell: ShellCoordinator, controller: MiniPlayerController) {
        self.shell = shell; self.controller = controller
        _pinned = State(initialValue: controller.preferences.pinned); _expanded = State(initialValue: controller.preferences.expanded)
    }
    var body: some View {
        Group {
            if expanded {
                VStack(spacing: MusicSpace.xs) {
                    HStack(spacing: MusicSpace.xs) { likeButton; Spacer(minLength: 0); pinButton }.musicButtons().audit("miniToolbar", group: "miniExpandedRows", within: "miniPlayer")
                    ShellExpandedPlayer(shell: shell, collapse: { setExpanded(false) }, showQueue: { shell.showQueue() }, compact: true) { EmptyView() }
                        .audit("miniExpandedPlayer", group: "miniExpandedRows", kind: .layer)
                }.padding([.horizontal, .bottom], MusicSpace.xs).padding(.top, Self.titlebar)
            } else {
                compact.padding([.horizontal, .bottom], MusicSpace.sm).padding(.top, Self.titlebar)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .audit("miniPlayer", group: "outer", kind: .region)
        .background { MusicCanvas(artworkAccent: accent?.color) }
        .background(WindowVisibility { visible = $0 })
        .modifier(PlaybackObservation(model: shell.playback))
        .musicAnimation(.reveal, value: expanded)
        .accessibilityElement(children: .contain).accessibilityLabel(Text("Mini-player")).accessibilityIdentifier("miniPlayer")
    }
    /// The title bar's own height (the traffic lights sit in it, over the content: the panel is full-size-content).
    static let titlebar = MusicSpace.lg + MusicSpace.xxs

    private func setExpanded(_ value: Bool) { expanded = value; controller.setExpanded(value) }
    private var pinButton: some View {
        Button { pinned.toggle(); controller.setPinned(pinned) } label: { Label(pinned ? "Unpin" : "Keep on Top", systemImage: pinned ? "pin.fill" : "pin") }
            .labelStyle(.iconOnly).help(Text(pinned ? "Stop keeping the mini-player on top" : "Keep the mini-player on top"))
            .accessibilityIdentifier("miniPin").accessibilityValue(Text(pinned ? "On" : "Off"))
    }
    private var expandButton: some View {
        Button { setExpanded(true) } label: { Label("Expanded", systemImage: "arrow.up.left.and.arrow.down.right") }
            .labelStyle(.iconOnly).help(Text("Expanded size")).accessibilityIdentifier("miniExpand")
    }
    private var compact: some View {
        let state = shell.transport
        return MusicGlassGroup {
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                HStack(spacing: MusicSpace.sm) {
                    ShellCover(shell: shell, edge: Self.coverEdge, visible: visible, accentChanged: { accent = $0 }).audit("miniArtwork", group: "miniHeader", within: "miniPlayer")
                    VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                        HStack(spacing: MusicSpace.xs) {
                            Text(state.hasItem ? state.title : String(localized: "Nothing playing")).font(.headline).lineLimit(1).accessibilityIdentifier("miniTitle")
                            if state.isAd { MusicBadge("Ad", style: .advertisement).accessibilityLabel(Text("Advertisement playing")).accessibilityIdentifier("miniAdBadge") }
                        }
                        Text(state.statusLine).font(.caption).foregroundStyle(MusicStyle.secondaryText).lineLimit(1).accessibilityIdentifier("miniDetail")
                        SleepTimerLine(model: shell.playback, episode: shell.playback.playingEpisode(shell.playback.episodes), identifier: "miniSleepRemaining")
                    }.audit("miniTitleBlock", group: "miniHeader", within: "miniPlayer")
                    Spacer(minLength: 0)
                    HStack(spacing: MusicSpace.xs) { pinButton; expandButton }.labelStyle(.iconOnly).musicButtons().audit("miniWindowControls", group: "miniHeader", within: "miniPlayer")
                }
                HStack(spacing: MusicSpace.xs) {
                    ShellControls(shell: shell).audit("miniControls", group: "miniControlRow", within: "miniPlayer")
                    Spacer(minLength: 0)
                    HStack(spacing: MusicSpace.xs) {
                        likeButton
                        Button { shell.showQueue() } label: { Label("Queue", systemImage: "list.bullet") }.labelStyle(.iconOnly).help(Text("Queue")).accessibilityIdentifier("miniQueue")
                        Slider(value: Binding(get: { state.volume }, set: { shell.setVolume($0) }), in: 0...1) { Text("Volume") }.labelsHidden().tint(MusicStyle.accent)
                            .frame(width: Self.volumeWidth).disabled(!state.hasItem).accessibilityIdentifier("miniVolume")
                    }.musicButtons().audit("miniAccessories", group: "miniControlRow", within: "miniPlayer")
                }
                ShellTimeline(shell: shell).audit("miniTimeline", group: "miniRows", within: "miniPlayer")
            }
        }
    }
    static let coverEdge: CGFloat = 48
    static let volumeWidth: CGFloat = 48
    @ViewBuilder private var likeButton: some View {
        let availability = shell.likeAvailability()
        let control = availability.control
        let reason = availability.reason ?? ""
        Button { if let control { Task { await shell.pressLike(control) } } } label: { Label(control?.title ?? "Like", systemImage: control?.symbol ?? "heart") }
            .labelStyle(.iconOnly).disabled(control == nil)
            .help(Text(control?.title ?? reason)).accessibilityHint(Text(reason))
            .accessibilityIdentifier("miniLike")
    }
}
