import AVKit
import Features
import OutputRoutes
import SwiftUI

// W22. The picker and the prompt as the transports mount them, and the system's own AirPlay picker button.

/// `AVRoutePickerView` for the local `AVPlayer`: the public system UI for AirPlay (the app cannot enumerate receivers itself). It acts on this
/// app's player only. The delegate tells the controller when a person is using it, so a change right after is read as their choice, not a loss.
struct SystemRoutePickerButton: NSViewRepresentable {
    let player: AVPlayer?
    let interacted: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(interacted: interacted) }
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        view.delegate = context.coordinator
        view.player = player
        view.setAccessibilityIdentifier("systemAirPlayPicker")
        view.setAccessibilityLabel(String(localized: "AirPlay"))
        return view
    }
    func updateNSView(_ view: AVRoutePickerView, context: Context) {
        if view.player !== player { view.player = player }
        context.coordinator.interacted = interacted
    }
    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        var interacted: () -> Void
        init(interacted: @escaping () -> Void) { self.interacted = interacted }
        func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) { interacted() }
        func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) { interacted() }
    }
}

struct OutputPickerHost: View {
    let controller: OutputController
    var body: some View {
        OutputPickerButton(content: OutputPickerMapping.content(for: controller), actions: OutputPickerActions(
            select: { id in
                guard let route = OutputRouteID(persisted: id) else { return }
                Task { _ = await controller.coordinator.select(route, engine: controller.subject) }
            },
            reconnect: { Task { _ = await controller.coordinator.reconnect() } },
            playHere: { Task { await controller.requestPlayHere() } },
            opened: { controller.pickerOpened() }, closed: { controller.pickerClosed() })) {
            // An isolated launch never creates the real AirPlay picker (it starts system AirPlay discovery): a stand-in glyph holds its place.
            if controller.usesRealSystemPicker { SystemRoutePickerButton(player: controller.pickerPlayer, interacted: { controller.pickerInteracted() }) }
            else { Image(systemName: "airplayaudio").accessibilityLabel(Text("AirPlay")).accessibilityIdentifier("systemAirPlayPickerStandIn") }
        }
    }
}

/// Play here / remote-timer confirmation, inline in the transport. Nothing sounds until its button is pressed.
struct OutputPromptHost: View {
    let controller: OutputController
    var body: some View {
        if let prompt = OutputPickerMapping.prompt(for: controller) {
            OutputPromptBanner(prompt: prompt, confirm: { Task { await controller.coordinator.confirm(prompt.id) } }, cancel: { controller.coordinator.cancel(prompt.id) })
        }
    }
}

extension OutputController {
    /// "Play Here…" from the picker: asks first (the loss is still pending), then resumes whichever engine holds the session.
    func requestPlayHere() async {
        guard let model else { return }
        if let player = model.music, !player.isClosed {
            await coordinator.perform(.start, engine: .youTubeMusic) { await player.resumeAfterAdmission() }
        } else if let session = model.session {
            await coordinator.perform(.start, engine: .localMedia) { try? await session.resume(); await model.refresh() }
        } else {
            await coordinator.perform(.start, engine: .localMedia) {}
        }
    }
}
