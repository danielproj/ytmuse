import DesignSystem
import Observation
import SwiftUI

/// A native command the palette can run. The closure is the same one a menu item or
/// toolbar button uses, so the palette adds a way to reach a command, not a second command.
public struct PaletteCommand: Identifiable {
    public let id: String
    public let title: String
    public let symbol: String
    public let keywords: [String]
    public let shortcut: String?
    /// Non-nil when the command cannot run now; the reason is shown on the row.
    public let unavailable: String?
    public let run: @MainActor () -> Void
    public init(id: String, title: String, symbol: String, keywords: [String] = [], shortcut: String? = nil, unavailable: String? = nil, run: @escaping @MainActor () -> Void) {
        self.id = id; self.title = title; self.symbol = symbol; self.keywords = keywords; self.shortcut = shortcut; self.unavailable = unavailable; self.run = run
    }
}
public enum PaletteEntry: Identifiable {
    case command(PaletteCommand)
    case result(SearchResult)
    public var id: String {
        switch self { case .command(let command): "command:" + command.id; case .result(let result): "result:" + result.id }
    }
}

/// Command-K: commands first (matched with the same tolerant matcher), then the search
/// results, all behind one field. Return runs the selected command or acts on the selected
/// result; Escape clears the field and then closes the palette.
@MainActor @Observable public final class CommandPaletteModel: Identifiable {
    public let id = UUID()
    public let search: SearchModel
    public private(set) var commands: [PaletteCommand]
    public var selection: String?
    public private(set) var failure: [String: String] = [:]
    @ObservationIgnored private let dismiss: @MainActor () -> Void

    public init(search: SearchModel, commands: [PaletteCommand], dismiss: @escaping @MainActor () -> Void) {
        self.search = search; self.commands = commands; self.dismiss = dismiss
    }
    public func setCommands(_ commands: [PaletteCommand]) { self.commands = commands }

    public var matchingCommands: [PaletteCommand] {
        let query = FoldedQuery(search.query)
        guard !query.isEmpty else { return commands }
        return commands.compactMap { command -> (PaletteCommand, SearchMatchQuality)? in
            let best = ([command.title] + command.keywords).compactMap { query.match($0) }.max()
            return best.map { (command, $0) }
        }.sorted { $0.1 > $1.1 }.map(\.0)
    }
    public var entries: [PaletteEntry] {
        matchingCommands.map(PaletteEntry.command) + search.results.map(PaletteEntry.result)
    }
    public var selectedEntry: PaletteEntry? { selection.flatMap { id in entries.first { $0.id == id } } }

    public func move(by delta: Int) {
        let ids = entries.map(\.id)
        guard !ids.isEmpty else { return }
        guard let current = selection.flatMap(ids.firstIndex(of:)) else { selection = delta >= 0 ? ids.first : ids.last; return }
        selection = ids[min(ids.count - 1, max(0, current + delta))]
    }
    /// Typing selects the best command so Return runs it; it never selects a search result,
    /// so a stray Return after typing cannot start playback.
    public func queryChanged() {
        if let first = matchingCommands.first, !search.trimmedQuery.isEmpty { selection = "command:" + first.id }
        else if let selection, !entries.contains(where: { $0.id == selection }) { self.selection = nil }
    }

    public func handle(_ key: SearchKey, composing: Bool = false) -> SearchKeyOutcome {
        guard !composing else { return .passThrough }
        switch key {
        case .down, .up:
            guard !entries.isEmpty else { return .passThrough }
            move(by: key == .down ? 1 : -1); return .handled
        case .returnKey:
            if let entry = selectedEntry { activate(entry); return .handled }
            guard !search.trimmedQuery.isEmpty else { return .passThrough }
            search.submit(); return .handled
        case .escape:
            if !search.query.isEmpty { search.clear(); selection = nil } else { dismiss() }
            return .handled
        case .space, .other:
            return .passThrough
        }
    }
    public func activate(_ entry: PaletteEntry) {
        switch entry {
        case .command(let command):
            if let reason = command.unavailable { failure[entry.id] = reason; return }
            failure[entry.id] = nil
            dismiss(); command.run()
        case .result(let result):
            Task {
                await search.activate(result)
                if case .started = search.feedback[result.id] { dismiss() }
            }
        }
    }
}

public struct CommandPaletteView: View {
    @Bindable var model: CommandPaletteModel
    @FocusState private var focused: Bool
    private let motion = MusicMotionContext()
    public init(model: CommandPaletteModel) { self.model = model }
    public var body: some View {
        MusicGlassGroup(spacing: MusicSpace.xs) {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            SearchField(model: model.search, prompt: "Type a command or search YouTube Music", focus: $focused, identifier: "paletteField") { model.handle($0, composing: $1) }
            SearchStatusView(model: model.search)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: MusicSpace.xxs) {
                        if !model.matchingCommands.isEmpty {
                            Text("Commands").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                            ForEach(model.matchingCommands) { command in commandRow(command).id("command:" + command.id) }
                        }
                        ForEach(model.search.sections) { section in
                            Text(section.group.title).font(.title3.bold()).padding(.top, MusicSpace.sm).accessibilityAddTraits(.isHeader)
                            ForEach(section.results) { result in
                                SearchResultRow(result: result, selected: model.selection == "result:" + result.id, offers: model.search.offers(for: result),
                                                feedback: model.search.feedback[result.id], select: { model.selection = "result:" + result.id },
                                                perform: { action in model.selection = "result:" + result.id; Task { await model.search.perform(action, on: result) } })
                                    .id("result:" + result.id)
                            }
                        }
                    }.padding(.horizontal, MusicSpace.xxs)
                }.onChange(of: model.selection) { _, id in if let id { motion.perform(.selection) { proxy.scrollTo(id) } } }
            }.accessibilityIdentifier("paletteResults")
            if model.entries.isEmpty && !model.search.isSearching {
                EmptyState(title: "No matches", message: "Try another command, or search for music.")
            }
        }
        .padding(MusicSpace.md)
        }
        .frame(minWidth: 520, minHeight: 420).musicCanvas()
        .task { focused = true }
        .onChange(of: model.search.query) { _, _ in model.queryChanged() }
        .accessibilityElement(children: .contain).accessibilityLabel(Text("Command Palette")).accessibilityIdentifier("commandPalette")
    }
    private func commandRow(_ command: PaletteCommand) -> some View {
        let id = "command:" + command.id
        return VStack(alignment: .leading, spacing: MusicSpace.hairline) {
            HStack(spacing: MusicSpace.sm) {
                Image(systemName: command.symbol).frame(width: 24).foregroundStyle(MusicStyle.secondaryText).accessibilityHidden(true)
                Text(command.title)
                Spacer(minLength: 8)
                if let shortcut = command.shortcut { Text(shortcut).font(.caption).foregroundStyle(MusicStyle.secondaryText) }
            }
            if let reason = model.failure[id] {
                Label(reason, systemImage: "exclamationmark.triangle").font(.caption).accessibilityIdentifier("paletteItemError-" + command.id)
            }
        }
        .padding(.vertical, MusicSpace.xs).padding(.horizontal, MusicSpace.xs)
        .audit("paletteRow-" + command.id, group: "palette-rows", alignLeading: "paletteRows")
        .musicSelectionBackground(model.selection == id).musicHoverHighlight()
        .musicAnimation(.selection, value: model.selection == id)
        .contentShape(Rectangle())
        .onTapGesture { model.selection = id; model.activate(.command(command)) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text([command.title, command.shortcut].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAddTraits(model.selection == id ? [.isSelected, .isButton] : [.isButton])
        .accessibilityIdentifier("paletteCommand-" + command.id)
    }
}
