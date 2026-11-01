import Foundation
import SystemIntegration
import WidgetShared

// W25 (MAC06, ARCH03, T25.2). The app's side of the widget's command channel. A widget button reaches the app as `WidgetTransportIntent`, which the system
// runs in this process; this bridge refuses it unless the (account, session) it was drawn under is still the live one, and otherwise sends it through W24's
// command channel: the same `PlaybackModel.remote(_:)` admission the media keys, Siri and the window use (capabilities, advertisement rules, Play here).

@MainActor final class WidgetCommandBridge {
    private unowned let surface: any IntentAppSurface
    private let hub: IntentHub
    private let launch: String
    init(surface: any IntentAppSurface, hub: IntentHub, launch: String = WidgetLaunch.nonce) { self.surface = surface; self.hub = hub; self.launch = launch }

    func install(on receiver: WidgetCommandReceiver = .shared) {
        receiver.install { [weak self] kind, stamp in await self?.handle(kind, stamp: stamp) ?? .failure(.appUnavailable) }
    }
    func uninstall(from receiver: WidgetCommandReceiver = .shared) { receiver.uninstall() }

    private func liveScope() async -> WidgetScope? {
        await surface.liveScope().map { WidgetScope(account: $0.accountID, generation: $0.generation, launch: launch) }
    }
    func handle(_ kind: WidgetCommandKind, stamp: WidgetCommandStamp) async -> Result<String, WidgetCommandRefusal> {
        await surface.awaitStartup()
        if case .refuse(let refusal) = WidgetCommandGate.verdict(for: stamp, live: await liveScope()) { return .failure(refusal) }
        guard let channel = await hub.readyChannel() else { return .failure(.appUnavailable) }
        // Checked again right before the command: waiting for the channel is the window in which an account can change.
        if case .refuse(let refusal) = WidgetCommandGate.verdict(for: stamp, live: await liveScope()) { return .failure(refusal) }
        let command: IntentCommand = switch kind { case .playPause: .toggle; case .next: .next; case .previous: .previous }
        switch await channel.perform(command) {
        case .done(let sentence): return .success(sentence)
        case .refused(let refusal): return .failure(.refused(refusal.message))
        }
    }
}
