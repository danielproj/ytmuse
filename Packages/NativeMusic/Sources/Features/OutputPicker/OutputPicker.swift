import DesignSystem
import SwiftUI

// W22 (ROUTE01, ROUTE03, ROUTE09, PLAY17). The output picker and the route-loss / Play here / remote-timer banner. The views read plain values: the app
// shell builds them from the output coordinator, so this module needs no knowledge of CoreAudio or AirPlay. Every control states what the route can do,
// and what it cannot do from inside the app.

public struct OutputPickerContent: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public enum State: Equatable, Sendable { case available, current, unavailable }
        public var id: String
        public var title: String
        public var detail: String?
        public var symbol: String
        public var state: State
        /// A person can choose this row here. False for rows the system picker or Control Center owns.
        public var selectable: Bool
        /// Route-specific volume and the actions this route does not support, as plain sentences.
        public var volume: String
        public var unsupported: [String]
        public init(id: String, title: String, detail: String?, symbol: String, state: State, selectable: Bool, volume: String, unsupported: [String]) {
            self.id = id; self.title = title; self.detail = detail; self.symbol = symbol; self.state = state; self.selectable = selectable; self.volume = volume; self.unsupported = unsupported
        }
    }
    public var currentName: String
    public var symbol: String
    /// The engine's own statement when it cannot be pointed anywhere ("YouTube Music plays through this Mac's sound output ...").
    public var statement: String?
    public var rows: [Row]
    public var notice: String?
    /// The system AirPlay picker button is shown (only where it can reach the engine).
    public var showsSystemPicker: Bool
    public var airPlayHint: String?
    public var loss: Loss?
    /// W39: sentences about Cast that belong to the picker as a whole (what is being looked for, what quitting does, what cannot be cast). Plain values.
    public var castNotes: [String]
    public struct Loss: Equatable, Sendable {
        public var message: String
        public var canReconnect: Bool
        public init(message: String, canReconnect: Bool) { self.message = message; self.canReconnect = canReconnect }
    }
    public init(currentName: String, symbol: String, statement: String?, rows: [Row], notice: String?, showsSystemPicker: Bool, airPlayHint: String?, loss: Loss?, castNotes: [String] = []) {
        self.currentName = currentName; self.symbol = symbol; self.statement = statement; self.rows = rows; self.notice = notice
        self.showsSystemPicker = showsSystemPicker; self.airPlayHint = airPlayHint; self.loss = loss; self.castNotes = castNotes
    }
}

/// What must be confirmed before sound may start (Play here) or before a timer is enabled on a receiver that cannot fade (PLAY17).
public struct OutputPromptContent: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable { case playHere(canReconnect: Bool), timer }
    public var id: UUID
    public var kind: Kind
    public var title: String
    public var message: String
    public var confirmTitle: String
    public init(id: UUID, kind: Kind, title: String, message: String, confirmTitle: String) { self.id = id; self.kind = kind; self.title = title; self.message = message; self.confirmTitle = confirmTitle }
}

@MainActor public struct OutputPickerActions {
    public var select: (String) -> Void
    public var reconnect: () -> Void
    public var playHere: () -> Void
    /// W39: the picker was opened or closed. Looking for Cast receivers (and the system's Local Network question) starts only when a person opens it.
    public var opened: () -> Void
    public var closed: () -> Void
    public init(select: @escaping (String) -> Void, reconnect: @escaping () -> Void, playHere: @escaping () -> Void, opened: @escaping () -> Void = {}, closed: @escaping () -> Void = {}) {
        self.select = select; self.reconnect = reconnect; self.playHere = playHere; self.opened = opened; self.closed = closed
    }
}

/// The output button of a transport: the current route, and a popover with every route and what it can and cannot do.
private struct OutputPickerRequestKey: EnvironmentKey { static let defaultValue = 0 }
extension EnvironmentValues {
    /// W28 (A11Y01): raised by "Choose Output…" in the menu bar and the command palette; the output button of the window that sees a newer value opens its popover.
    public var outputPickerRequest: Int {
        get { self[OutputPickerRequestKey.self] }
        set { self[OutputPickerRequestKey.self] = newValue }
    }
}
public struct OutputPickerButton<SystemPicker: View>: View {
    let content: OutputPickerContent
    let actions: OutputPickerActions
    let systemPicker: SystemPicker
    @State private var shown = false
    @Environment(\.outputPickerRequest) private var request
    public init(content: OutputPickerContent, actions: OutputPickerActions, @ViewBuilder systemPicker: () -> SystemPicker) {
        self.content = content; self.actions = actions; self.systemPicker = systemPicker()
    }
    public var body: some View {
        Button { shown.toggle() } label: { Label("Output", systemImage: content.loss == nil ? content.symbol : "exclamationmark.triangle") }
            .help(Text("Output: \(content.currentName)"))
            .accessibilityLabel(Text("Output: \(content.currentName)"))
            .accessibilityIdentifier("outputPicker")
            .popover(isPresented: $shown, arrowEdge: .top) { OutputPickerPanel(content: content, actions: actions, systemPicker: systemPicker) }
            .onChange(of: request) { _, _ in shown = true }
            .onChange(of: shown) { _, isShown in if isShown { actions.opened() } else { actions.closed() } }
    }
}

struct OutputPickerPanel<SystemPicker: View>: View {
    let content: OutputPickerContent
    let actions: OutputPickerActions
    let systemPicker: SystemPicker
    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            Text("Output").font(.headline)
            if let loss = content.loss {
                VStack(alignment: .leading, spacing: MusicSpace.xs) {
                    Label(loss.message, systemImage: "exclamationmark.triangle").font(.callout).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: MusicSpace.xs) {
                        if loss.canReconnect { Button("Reconnect") { actions.reconnect() }.accessibilityIdentifier("outputReconnect") }
                        Button("Play Here…") { actions.playHere() }.accessibilityIdentifier("outputPlayHere")
                    }.musicButtons()
                }.accessibilityElement(children: .contain).accessibilityIdentifier("outputLoss")
            }
            if let statement = content.statement {
                Text(statement).font(.callout).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("outputStatement")
            }
            ForEach(content.castNotes, id: \.self) { note in
                Text(note).font(.caption).foregroundStyle(MusicStyle.secondaryText).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("outputCastNote")
            }
            if let notice = content.notice {
                Text(notice).font(.caption).foregroundStyle(MusicStyle.secondaryText).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("outputNotice")
            }
            VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                ForEach(content.rows) { row in OutputPickerRow(row: row) { actions.select(row.id) } }
            }
            if content.showsSystemPicker {
                HStack(spacing: MusicSpace.xs) {
                    systemPicker.frame(width: MusicSpace.lg, height: MusicSpace.lg)
                    Text(content.airPlayHint ?? String(localized: "AirPlay")).font(.caption).foregroundStyle(MusicStyle.secondaryText).fixedSize(horizontal: false, vertical: true)
                }.accessibilityElement(children: .contain)
            }
        }.padding(MusicSpace.md).frame(minWidth: 300, maxWidth: 380, alignment: .leading)
    }
}

struct OutputPickerRow: View {
    let row: OutputPickerContent.Row
    let choose: () -> Void
    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: MusicSpace.xs) {
                Image(systemName: row.state == .current ? "checkmark" : row.symbol).frame(width: MusicSpace.md)
                VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                    Text(row.title).font(.body)
                    if let detail = row.detail { Text(detail).font(.caption).foregroundStyle(MusicStyle.secondaryText) }
                    Text(row.volume).font(.caption).foregroundStyle(MusicStyle.secondaryText)
                    ForEach(row.unsupported, id: \.self) { Text($0).font(.caption).foregroundStyle(MusicStyle.secondaryText) }
                }.fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: MusicSpace.xs)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!row.selectable || row.state == .unavailable)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(row.state == .current ? .isSelected : [])
        .accessibilityIdentifier("outputRoute-" + row.id)
    }
}

/// The inline banner that asks before sound starts on speakers after a route loss, or before a timer is enabled on a receiver that cannot fade it.
/// Inline rather than a confirmation dialog: the decision flips the model synchronously (the dialog dismisses before an asynchronous button action runs).
public struct OutputPromptBanner: View {
    let prompt: OutputPromptContent
    let confirm: () -> Void
    let cancel: () -> Void
    public init(prompt: OutputPromptContent, confirm: @escaping () -> Void, cancel: @escaping () -> Void) { self.prompt = prompt; self.confirm = confirm; self.cancel = cancel }
    public var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            Label(prompt.title, systemImage: "speaker.wave.2").font(.headline)
            Text(prompt.message).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: MusicSpace.xs) {
                Button(prompt.confirmTitle, action: confirm).musicButtons(prominent: true).accessibilityIdentifier("outputPromptConfirm")
                Button("Cancel", role: .cancel, action: cancel).musicButtons().accessibilityIdentifier("outputPromptCancel")
            }
        }
        .padding(MusicSpace.sm).musicSurface(.panel)
        .accessibilityElement(children: .contain).accessibilityIdentifier("outputPrompt")
    }
}
