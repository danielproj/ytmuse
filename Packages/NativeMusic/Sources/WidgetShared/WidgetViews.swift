import AppIntents
import AppKit
import DesignSystem
import SwiftUI
import WidgetKit

// W25 (MAC06, V02). Small and medium views over `WidgetContent`. Spacing and corners come from the design system's tokens; the buttons are App Intent
// buttons (they run in the app, see `WidgetCommand.swift`). Redacted, idle and placeholder states have no buttons and no title.

public struct NowPlayingWidgetView: View {
    let entry: NowPlayingWidgetEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.redactionReasons) private var redactionReasons
    public init(entry: NowPlayingWidgetEntry) { self.entry = entry }
    public var body: some View {
        let display = entry.display.applying(privacyRedaction: redactionReasons.contains(.privacy))
        Group {
            if family == .systemMedium { MediumNowPlayingView(display: display) } else { SmallNowPlayingView(display: display) }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct WidgetArtworkView: View {
    let data: Data?
    let edge: CGFloat
    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFill() }
            else { Image(systemName: "music.note").font(.title2).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary) }
        }
        .frame(width: edge, height: edge)
        .musicClip(.thumbnail, edge: edge)
        .accessibilityHidden(true)
    }
}

struct WidgetControlButton: View {
    let control: WidgetContent.Control
    let scope: WidgetScope?
    var body: some View {
        if let scope {
            Button(intent: WidgetTransportIntent(command: kind, scope: scope)) { Image(systemName: symbol).frame(maxWidth: .infinity) }
                .disabled(!control.enabled)
                .accessibilityLabel(control.label)
        }
    }
    private var kind: WidgetCommandKind {
        switch control.button { case .previous: .previous; case .next: .next; case .playPause: .playPause }
    }
    private var symbol: String {
        switch control.button {
        case .previous: "backward.fill"; case .next: "forward.fill"
        case .playPause(let playing): playing ? "pause.fill" : "play.fill"
        }
    }
}

public struct SmallNowPlayingView: View {
    let display: WidgetDisplay
    public init(display: WidgetDisplay) { self.display = display }
    public var body: some View {
        let content = WidgetContent.make(display, family: .small)
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            HStack(alignment: .top, spacing: MusicSpace.xs) {
                if content.hasArtwork || content.scope != nil, case .item(let item) = display { WidgetArtworkView(data: item.artwork, edge: MusicSpace.xxl) }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            WidgetTextBlock(content: content)
            if let first = content.controls.first { WidgetControlButton(control: first, scope: content.scope) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

public struct MediumNowPlayingView: View {
    let display: WidgetDisplay
    public init(display: WidgetDisplay) { self.display = display }
    public var body: some View {
        let content = WidgetContent.make(display, family: .medium)
        HStack(alignment: .center, spacing: MusicSpace.md) {
            if case .item(let item) = display { WidgetArtworkView(data: item.artwork, edge: 96) }
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                WidgetTextBlock(content: content)
                if !content.controls.isEmpty {
                    HStack(spacing: MusicSpace.xs) { ForEach(Array(content.controls.enumerated()), id: \.offset) { _, control in WidgetControlButton(control: control, scope: content.scope) } }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct WidgetTextBlock: View {
    let content: WidgetContent
    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xxs) {
            ForEach(Array(content.texts.enumerated()), id: \.offset) { index, text in
                Text(text).font(index == 0 ? .headline : .subheadline).foregroundStyle(index == 0 ? .primary : .secondary).lineLimit(index == 0 ? 2 : 1)
            }
        }
    }
}
