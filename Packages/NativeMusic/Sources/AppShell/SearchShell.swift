import DesignSystem
import Features
import SwiftUI

/// What the menu bar can ask of the focused window.
struct ShellActions {
    var find: @MainActor () -> Void
    var palette: @MainActor () -> Void
}
private struct ShellActionsKey: FocusedValueKey { typealias Value = ShellActions }
extension FocusedValues {
    var shellActions: ShellActions? {
        get { self[ShellActionsKey.self] }
        set { self[ShellActionsKey.self] = newValue }
    }
}

/// Hosts the window's Command-F and Command-K entry points, the command palette sheet, and
/// the account/library notifications that keep search results honest.
struct SearchPaletteHost: ViewModifier {
    let accounts: LocalAccountBootstrap
    let navigation: BrowserNavigation
    let search: SearchModel
    @Binding var focusToken: Int
    let toggleQueue: @MainActor () -> Void
    let toggleLyrics: @MainActor () -> Void
    let manageAccounts: @MainActor () -> Void
    @State private var palette: CommandPaletteModel?

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.shellActions, ShellActions(find: { find() }, palette: { present() }))
            .sheet(item: $palette) { model in CommandPaletteView(model: model).musicCanvas() }
            .onChange(of: accounts.searchScopeToken) { _, _ in search.accountChanged(); palette?.search.accountChanged(); search.recents?.reload(); accounts.catalog.accountChanged(); accounts.library.accountChanged(); accounts.discovery.accountChanged(); accounts.social.accountChanged(); accounts.podcasts.accountChanged() }
            .onChange(of: accounts.model.identities.map(\.id)) { _, ids in
                // A removed account takes its recent searches and items with it.
                SearchRecents.prune(defaults: AppPreferences.store, keeping: Set(ids.map { $0.accountID.uuidString } + ["none"]))
            }
            .onChange(of: accounts.model.proof) { _, _ in search.refreshLocal(); palette?.search.refreshLocal() }
    }
    private func find() { navigation.open(.search); focusToken += 1 }
    private func present() {
        let results = accounts.makeSearchModel()
        results.opener = BrowserShell.opener(accounts: accounts, navigation: navigation) { palette = nil }
        palette = CommandPaletteModel(search: results, commands: commands()) { palette = nil }
    }
    private func commands() -> [PaletteCommand] {
        var result: [PaletteCommand] = BrowserDestination.allCases.filter { $0 != .queue }.map { destination in
            PaletteCommand(id: "go-" + destination.rawValue, title: String(localized: "Go to \(destination.title)"), symbol: destination.symbol,
                           keywords: [destination.title, String(localized: "Open")]) { navigation.open(destination) }
        }
        result.append(PaletteCommand(id: "find", title: String(localized: "Search YouTube Music"), symbol: "magnifyingglass", keywords: [String(localized: "Find")], shortcut: "⌘F") { find() })
        result.append(PaletteCommand(id: "queue", title: String(localized: "Show Queue"), symbol: "list.bullet", keywords: [String(localized: "Up next")], run: toggleQueue))
        result.append(PaletteCommand(id: "output", title: String(localized: "Choose Output…"), symbol: "speaker.wave.2", keywords: [String(localized: "Output"), "AirPlay"]) { accounts.shell.showOutputPicker() })
        result.append(PaletteCommand(id: "lyrics", title: String(localized: "Show Lyrics"), symbol: "quote.bubble", run: toggleLyrics))
        result.append(PaletteCommand(id: "accounts", title: String(localized: "Manage Accounts…"), symbol: "person.crop.circle", keywords: [String(localized: "Sign in")], run: manageAccounts))
        result.append(PaletteCommand(id: "back", title: String(localized: "Back"), symbol: "chevron.left",
                                     unavailable: navigation.session.canBack ? nil : String(localized: "There is nothing to go back to.")) { navigation.back() })
        result.append(PaletteCommand(id: "forward", title: String(localized: "Forward"), symbol: "chevron.right",
                                     unavailable: navigation.session.canForward ? nil : String(localized: "There is nothing to go forward to.")) { navigation.forward() })
        return result
    }
}
