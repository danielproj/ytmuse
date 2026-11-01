import AppKit
import DesignSystem
import Observation
import Playback
import SwiftUI

/// W21 (WIN01). The permanent status item: a compact template mark, an optional track tooltip, a native glass popover on a plain click and a
/// context menu on a secondary click. Every action goes through `ShellCommanding` (ARCH03). The item stays while no window is open.
@MainActor final class StatusItemController: NSObject, NSPopoverDelegate, NSMenuDelegate {
    private let shell: ShellCoordinator
    private let statusBar: NSStatusBar
    private let preferences: UserDefaults
    private(set) var item: NSStatusItem?
    private var popover: NSPopover?
    private var tracking = false
    var isPopoverShown: Bool { popover?.isShown ?? false }
    var isInstalled: Bool { item != nil }
    init(shell: ShellCoordinator, statusBar: NSStatusBar = .system, preferences: UserDefaults) {
        self.shell = shell; self.statusBar = statusBar; self.preferences = preferences
    }
    func install() {
        guard item == nil else { return }
        let item = statusBar.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = Self.markImage()
            button.imagePosition = .imageOnly
            button.target = self; button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel(String(localized: "YTMuse"))
            button.setAccessibilityIdentifier("statusItem")
            button.toolTip = nil
        }
        self.item = item
        refresh()
    }
    func remove() {
        popover?.close(); popover = nil
        if let item { statusBar.removeStatusItem(item) }
        item = nil
    }
    /// The brand's template mark (adaptable to the menu bar's appearance, GLASS03); a system symbol when the resource is unavailable.
    static func markImage() -> NSImage {
        if let image = BrandAssets.menuBarTemplate() { image.size = NSSize(width: 18, height: 18); return image }
        let image = NSImage(systemSymbolName: "music.note", accessibilityDescription: String(localized: "YTMuse")) ?? NSImage()
        image.isTemplate = true; return image
    }
    /// Re-reads what the tooltip says; observation re-arms itself, so it follows the coarse transport state and never the position clock.
    func refresh() {
        guard item != nil else { return }
        let state = shell.transport
        item?.button?.toolTip = ShellPreferences.tooltipEnabled(preferences) ? state.tooltip : nil
        guard !tracking else { return }
        tracking = true
        withObservationTracking({ _ = shell.transport }, onChange: { [weak self] in
            Task { @MainActor in self?.tracking = false; self?.refresh() }
        })
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true { showMenu(from: sender) } else { togglePopover(from: sender) }
    }
    func togglePopover(from button: NSView? = nil) {
        if let popover, popover.isShown { popover.close(); return }
        guard let button = button ?? item?.button else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = ShellMotion.animatesWindows
        popover.delegate = self
        // The content exists only while the popover does, so a closed popover costs no view updates, artwork decoding or observation.
        popover.contentViewController = NSHostingController(rootView: StatusPopoverView(shell: shell))
        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    func popoverDidClose(_ notification: Notification) {
        popover?.contentViewController = nil; popover = nil
    }
    private func showMenu(from button: NSStatusBarButton) {
        popover?.close()
        let menu = makeMenu()
        item?.menu = menu   // the supported way to show a status menu under the item; removed again so a plain click keeps opening the popover
        button.performClick(nil)
        item?.menu = nil
    }
    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "YTMuse")
        menu.autoenablesItems = false
        for entry in StatusMenuModel.entries(for: shell.transport) {
            switch entry {
            case .separator: menu.addItem(.separator())
            case .item(let command, let title, let enabled):
                let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = command.rawValue; item.isEnabled = enabled
                item.setAccessibilityIdentifier("statusMenu-" + command.rawValue)
                menu.addItem(item)
            }
        }
        return menu
    }
    @objc private func choose(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let command = ShellMenuCommand(rawValue: raw) else { return }
        StatusMenuModel.perform(command, on: shell)
    }
}

/// The popover's content (GLASS01), composed from V02's views: the cover, V02's transport (an advertisement turns Previous and Next off, as in the bar),
/// the Ad pill, a volume slider through the shared command layer, and Show Window.
struct StatusPopoverView: View {
    let shell: ShellCoordinator
    @State private var windowVisible = false
    var body: some View {
        let state = shell.transport
        MusicGlassGroup {
            VStack(alignment: .leading, spacing: MusicSpace.sm) {
                HStack(spacing: MusicSpace.sm) {
                    ShellCover(shell: shell, edge: Self.coverEdge, visible: windowVisible).audit("statusCover", group: "statusHeader", within: "statusPopover")
                    VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                        HStack(spacing: MusicSpace.xs) {
                            Text(state.hasItem ? state.title : String(localized: "YTMuse")).font(.headline).lineLimit(2).accessibilityIdentifier("statusTitle")
                            if state.isAd { MusicBadge("Ad", style: .advertisement).accessibilityLabel(Text("Advertisement playing")).accessibilityIdentifier("statusAdBadge") }
                        }
                        Text(state.statusLine).font(.caption).foregroundStyle(MusicStyle.secondaryText).lineLimit(1).accessibilityIdentifier("statusDetail")
                        SleepTimerLine(model: shell.playback, episode: shell.playback.playingEpisode(shell.playback.episodes), identifier: "statusSleepRemaining")
                    }
                    Spacer(minLength: 0)
                }
                HStack { Spacer(minLength: 0); ShellControls(shell: shell).audit("statusControls", group: "statusColumn", within: "statusPopover"); Spacer(minLength: 0) }
                HStack(spacing: MusicSpace.xs) {
                    Image(systemName: "speaker.fill").foregroundStyle(MusicStyle.secondaryText).accessibilityHidden(true)
                    Slider(value: Binding(get: { state.volume }, set: { shell.setVolume($0) }), in: 0...1) { Text("Volume") }.labelsHidden().tint(MusicStyle.accent)
                        .disabled(!state.hasItem).accessibilityIdentifier("statusVolume")
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(MusicStyle.secondaryText).accessibilityHidden(true)
                }.audit("statusVolumeRow", group: "statusColumn", within: "statusPopover")
                HStack {
                    Button { shell.showMainWindow() } label: { Label("Show Window", systemImage: "macwindow") }.accessibilityIdentifier("statusShowWindow")
                    Button { shell.showMiniPlayer() } label: { Label("Mini-player", systemImage: "rectangle.on.rectangle") }.labelStyle(.iconOnly).help(Text("Mini-player"))
                        .accessibilityIdentifier("statusMiniPlayer")
                    Spacer(minLength: 0)
                }.musicButtons().audit("statusActions", group: "statusColumn", within: "statusPopover")
                #if DEBUG
                // Debug only: the window census and policy, so a UI run can state why the Dock icon is where it is.
                Text(shell.windows.debugCensus).font(.caption2).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("shellCensus")
                Text(shell.playback.nowPlayingCensus).font(.caption2).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("nowPlayingCensus")
                #endif
            }
        }.padding(MusicSpace.md).frame(width: Self.width)
            .audit("statusPopover", group: "outer", kind: .region)
            .modifier(PlaybackObservation(model: shell.playback))
            .background(WindowVisibility { windowVisible = $0 })
            .accessibilityElement(children: .contain).accessibilityIdentifier("statusPopover")
    }
    static let width: CGFloat = 300
    static let coverEdge: CGFloat = 64
}
