import SwiftUI

/// Original procedural welcome/empty artwork. MIT licensed with this repository.
/// Static geometry, semantic foreground text rendered separately on opaque surfaces.
public struct ResonanceArtwork: View {
    public init() {}
    public var body: some View {
        GeometryReader { geometry in
            let edge = min(geometry.size.width, geometry.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: edge * 0.14).fill(MusicStyle.accent.opacity(0.12))
                ForEach(0..<5) { index in
                    Ellipse().stroke(MusicStyle.accent.opacity(0.18 + Double(index) * 0.1), lineWidth: max(1, edge * 0.018))
                        .padding(edge * (0.08 + Double(index) * 0.075)).rotationEffect(.degrees(-28))
                }
                Image(systemName: "music.note").font(.system(size: edge * 0.28, weight: .medium)).foregroundStyle(MusicStyle.accent)
            }.frame(width: edge, height: edge).clipped()
        }.aspectRatio(1, contentMode: .fit).accessibilityHidden(true)
    }
}

public struct MediaRow: View {
    let title: String; let subtitle: String; let status: LocalizedStringKey?; let selected: Bool; let pending: Bool
    let action: () -> Void
    public init(title: String, subtitle: String, status: LocalizedStringKey? = nil, selected: Bool = false, pending: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.subtitle = subtitle; self.status = status; self.selected = selected; self.pending = pending; self.action = action
    }
    public var body: some View {
        Button(action: action) {
            HStack(spacing: MusicSpace.sm) {
                Image(systemName: selected ? "checkmark.circle.fill" : "music.note").frame(width: MusicSpace.lg).contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                    Text(title).font(.body).fixedSize(horizontal: false, vertical: true)
                    Text(subtitle).font(.caption).foregroundStyle(MusicStyle.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: MusicSpace.xs)
                if pending { ProgressView().controlSize(.small).accessibilityLabel(Text("Pending")) }
                if let status { Text(status).font(.caption).foregroundStyle(MusicStyle.secondaryText) }
            }.padding(.vertical, MusicSpace.xs).padding(.horizontal, MusicSpace.xs).contentShape(Rectangle())
                .musicSelectionBackground(selected).musicHoverHighlight()
                .musicAnimation(.selection, value: selected)
        }.buttonStyle(.borderless).accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isSelected] : []).disabled(pending)
    }
}
public struct ArtworkCard<Artwork: View>: View {
    let title: String; let subtitle: String; let artwork: Artwork; let action: () -> Void
    public init(title: String, subtitle: String, @ViewBuilder artwork: () -> Artwork, action: @escaping () -> Void) {
        self.title = title; self.subtitle = subtitle; self.artwork = artwork(); self.action = action
    }
    public var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                artwork.aspectRatio(1, contentMode: .fit).musicClip(.artwork)
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(MusicStyle.secondaryText)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.musicTile(.artwork)).accessibilityElement(children: .combine)
    }
}
public struct SectionShelf<Content: View>: View {
    let title: LocalizedStringKey; let content: Content
    public init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    public var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) { LazyHStack(alignment: .top, spacing: MusicSpace.lg) { content } }.scrollIndicators(.hidden)
        }
    }
}
public struct QueueRow: Identifiable, Sendable {
    public let id: UUID; public let title: String; public let segment: String; public let current: Bool; public let enabled: Bool; public let editable: Bool
    public init(id: UUID, title: String, segment: String, current: Bool, enabled: Bool = true, editable: Bool = true) { self.id = id; self.title = title; self.segment = segment; self.current = current; self.enabled = enabled; self.editable = editable }
}
public struct QueueList: View {
    let rows: [QueueRow]; let boundary: QueuePageBoundary; let select: (UUID) -> Void; let move: (([UUID], UUID?) -> Void)?
    /// Each queue page is its own scroll context: a new page opens at its first row
    /// instead of inheriting the previous page's offset (where its rows would be offscreen).
    let page: Int
    public init(rows: [QueueRow], boundary: QueuePageBoundary = .init(), page: Int = 0, move: (([UUID], UUID?) -> Void)? = nil, select: @escaping (UUID) -> Void) { self.rows = rows; self.boundary = boundary; self.page = page; self.move = move; self.select = select }
    public var body: some View {
        List {
            ForEach(rows) { row in
                MediaRow(title: row.title, subtitle: row.segment, selected: row.current) { select(row.id) }.disabled(!row.enabled)
                    .moveDisabled(!row.editable || move == nil)
                    // W28 (A11Y01): reordering without dragging and without opening a menu. VoiceOver offers these in the item's actions rotor; the
                    // context menu below keeps the same three for a pointer. Each uses the same move rule as the drag, so an impossible move is not offered.
                    .accessibilityActions {
                        if let move, row.editable, let index = rows.firstIndex(where: { $0.id == row.id }) {
                            if let intent = QueuePageMoves.up(rows: rows, boundary: boundary, index: index) { Button("Move up") { move(intent.occurrences, intent.before) } }
                            if let intent = QueuePageMoves.down(rows: rows, boundary: boundary, index: index) { Button("Move down") { move(intent.occurrences, intent.before) } }
                            if let intent = QueuePageMoves.drag(rows: rows, boundary: boundary, source: IndexSet(integer: index), destination: rows.count) { Button("Move to end of page") { move(intent.occurrences, intent.before) } }
                        }
                    }
                    .contextMenu {
                        if let move, row.editable, let index = rows.firstIndex(where: { $0.id == row.id }) {
                            Button("Move to end of page") { if let intent = QueuePageMoves.drag(rows: rows, boundary: boundary, source: IndexSet(integer: index), destination: rows.count) { move(intent.occurrences, intent.before) } }.disabled(QueuePageMoves.drag(rows: rows, boundary: boundary, source: IndexSet(integer: index), destination: rows.count) == nil)
                            Button("Move up") { if let intent = QueuePageMoves.up(rows: rows, boundary: boundary, index: index) { move(intent.occurrences, intent.before) } }.disabled(QueuePageMoves.up(rows: rows, boundary: boundary, index: index) == nil)
                            Button("Move down") { if let intent = QueuePageMoves.down(rows: rows, boundary: boundary, index: index) { move(intent.occurrences, intent.before) } }.disabled(QueuePageMoves.down(rows: rows, boundary: boundary, index: index) == nil)
                        }
                    }
            }.onMove { source, destination in
                guard let move, let intent = QueuePageMoves.drag(rows: rows, boundary: boundary, source: source, destination: destination) else { return }
                move(intent.occurrences, intent.before)
            }
        }.scrollContentBackground(.hidden).id(page)
        .overlay { if rows.isEmpty { EmptyState(title: "Your queue is empty", message: "Choose an item to start listening.") } }
        .accessibilityLabel(Text("Queue")).accessibilityIdentifier("queueList")
    }
}
public struct LyricsPanel: View {
    let text: String?; let attribution: String?
    public init(text: String?, attribution: String? = nil) { self.text = text; self.attribution = attribution }
    public var body: some View {
        ScrollView {
            if let text { VStack(alignment: .leading, spacing: MusicSpace.lg) { Text(text).textSelection(.enabled); if let attribution { Text(attribution).font(.caption) } }.padding() }
            else { EmptyState(title: "Lyrics unavailable", message: "Lyrics appear when supplied by the source.") }
        }.accessibilityLabel(Text("Lyrics"))
    }
}
public struct DownloadRow: View {
    let title: String; let status: LocalizedStringKey; let progress: Double?; let recovery: (() -> Void)?
    public init(title: String, status: LocalizedStringKey, progress: Double? = nil, recovery: (() -> Void)? = nil) { self.title = title; self.status = status; self.progress = progress; self.recovery = recovery }
    public var body: some View {
        VStack(alignment: .leading) {
            HStack { Text(title); Spacer(); Text(status); if let recovery { Button("Retry", action: recovery) } }
            if let progress { ProgressView(value: min(1, max(0, progress))).tint(MusicStyle.accent).accessibilityLabel(Text("Download progress")).musicAnimation(.reveal, value: progress) }
        }.padding(.vertical, MusicSpace.xs).accessibilityElement(children: .contain)
    }
}
public struct AccountSwitcher: View {
    let label: LocalizedStringKey; let pending: Bool; let action: () -> Void
    public init(label: LocalizedStringKey, pending: Bool = false, action: @escaping () -> Void) { self.label = label; self.pending = pending; self.action = action }
    public var body: some View { Button(action: action) { Label(label, systemImage: "person.crop.circle") }.disabled(pending).accessibilityLabel(Text("Manage accounts")).help(Text("Manage accounts")) }
}
public struct RoutePicker: View {
    let current: String
    public init(current: String) { self.current = current }
    public var body: some View {
        Menu { Label(current, systemImage: "checkmark"); Text("Output selection is not available yet.") } label: { Label("Output", systemImage: "hifispeaker") }
            .accessibilityLabel(Text("Current output: \(current)"))
    }
}
public struct ErrorState: View {
    let title: LocalizedStringKey; let message: LocalizedStringKey; let recovery: LocalizedStringKey; let action: () -> Void
    public init(title: LocalizedStringKey, message: LocalizedStringKey, recovery: LocalizedStringKey = "Retry", action: @escaping () -> Void) { self.title = title; self.message = message; self.recovery = recovery; self.action = action }
    public var body: some View {
        ContentUnavailableView { Label(title, systemImage: "exclamationmark.circle") } description: { Text(message) } actions: { Button(recovery, action: action).musicButtons() }
    }
}
public struct EmptyState: View {
    let title: LocalizedStringKey; let message: LocalizedStringKey
    public init(title: LocalizedStringKey, message: LocalizedStringKey) { self.title = title; self.message = message }
    public var body: some View { ContentUnavailableView { Label(title, systemImage: "music.note.list") } description: { Text(message) } }
}
