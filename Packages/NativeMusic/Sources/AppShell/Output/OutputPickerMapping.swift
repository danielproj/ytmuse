import Features
import Foundation
import OutputRoutes

// W22 (ROUTE01). Coordinator state -> the picker's plain values. All the sentences live here, in one place, so a test can read what a person is told.
enum OutputPickerMapping {
    static func transportName(_ transport: OutputTransport?) -> String? {
        switch transport {
        case .builtIn?: String(localized: "Built-in")
        case .usb?: String(localized: "USB")
        case .bluetooth?: String(localized: "Bluetooth")
        case .airPlay?: String(localized: "AirPlay")
        case .hdmi?: String(localized: "HDMI or DisplayPort")
        case .thunderbolt?: String(localized: "Thunderbolt or FireWire")
        case .virtual?, .aggregate?: String(localized: "Software device")
        case .other?, nil: nil
        }
    }
    static func symbol(_ transport: OutputTransport?, headphones: Bool = false) -> String {
        if headphones { return "headphones" }
        switch transport {
        case .bluetooth?: return "headphones"
        case .airPlay?: return "airplayaudio"
        case .hdmi?: return "tv"
        case .usb?, .thunderbolt?: return "cable.connector"
        default: return "hifispeaker"
        }
    }
    static func volumeSentence(_ capabilities: RouteCapabilities) -> String {
        switch capabilities.volume {
        case .appLevel: String(localized: "App volume applies. The output's own volume is the Mac's.")
        case .receiver: String(localized: "The receiver sets the volume.")
        }
    }
    static func sentence(_ limit: RouteCapabilities.Limit, engine: OutputEngineKind) -> String {
        switch limit {
        case .chooseOutputInApp: String(localized: "This player can't be pointed at an output; it follows the Mac.")
        case .chooseAirPlayInApp: engine == .youTubeMusic ? String(localized: "AirPlay can't be chosen from this player.") : String(localized: "AirPlay isn't available for this kind of playback.")
        case .groupReceivers: String(localized: "Grouping receivers is left to the system picker, as far as it offers it.")
        case .fadeOnReceiver: String(localized: "A sleep timer pauses here but can't fade.")
        case .changeDeviceVolume: String(localized: "This app never changes the Mac's volume.")
        case .castYouTubeMusic: String(localized: "Casting YouTube Music isn't available from this app.")
        case .castIgnoresAudioEffects: String(localized: "The receiver plays the original file, so the equalizer and normalization don't apply.")
        }
    }
    static func castNotice(_ notice: CastNotice) -> String {
        switch notice {
        case .itemNotCastable(.keptDownload): String(localized: "Downloads kept for offline listening can't be cast: they stay encrypted on this Mac.")
        case .itemNotCastable(.youTubeMusic): String(localized: "YouTube Music can't be cast from this app.")
        case .itemNotCastable(.noFile), .itemNotCastable(.unsupportedType): String(localized: "This item has no audio file that can be cast.")
        case .receiverCouldNotPlay: String(localized: "The receiver couldn't play this item, so playback paused here.")
        case .connectionFailed: String(localized: "Couldn't connect to the receiver.")
        case .relayUnavailable: String(localized: "This Mac couldn't prepare the audio for the receiver.")
        case .networkNotAllowed: String(localized: "Cast needs this Mac to be on a private home network.")
        }
    }
    static func lossMessage(_ reason: RouteLossReason, cast: Bool) -> String {
        cast && reason == .receiverDisconnected ? String(localized: "The Cast receiver disconnected, so playback paused.") : lossMessage(reason)
    }
    static func lossMessage(_ reason: RouteLossReason) -> String {
        switch reason {
        case .headphonesUnplugged: String(localized: "Headphones were unplugged, so playback paused.")
        case .deviceDisconnected: String(localized: "The output was disconnected, so playback paused.")
        case .receiverDisconnected: String(localized: "The AirPlay receiver disconnected, so playback paused.")
        }
    }

    @MainActor static func content(for controller: OutputController) -> OutputPickerContent {
        let coordinator = controller.coordinator
        let kind = controller.subject
        let current = coordinator.currentOutput(for: kind)
        let remote = coordinator.remote != nil
        let remoteCast = coordinator.remote?.isCast == true
        let currentName = remote ? (remoteCast ? (controller.cast?.liveDeviceName ?? String(localized: "Cast receiver")) : String(localized: "AirPlay receiver")) : (current?.name ?? String(localized: "No output"))
        var rows: [OutputPickerContent.Row] = []
        for entry in coordinator.entries(for: kind) {
            if entry.id.isCast {
                // W39: Cast receivers are rows for the native engine only. For YouTube Music the picker states that it cannot be cast instead of listing targets.
                guard kind == .localMedia else { continue }
                let title = entry.name.isEmpty ? String(localized: "Remembered Cast receiver") : entry.name
                let detail = entry.isPreferred ? String(localized: "Cast · Used last time") : String(localized: "Cast")
                rows.append(.init(id: entry.id.rawValue, title: title, detail: detail, symbol: "hifispeaker.2", state: entry.connection == .unavailable ? .unavailable : (entry.isCurrent ? .current : .available),
                                  selectable: entry.connection == .connected && entry.capabilities.selection == .appSelectable, volume: volumeSentence(entry.capabilities),
                                  unsupported: entry.capabilities.limits.map { sentence($0, engine: kind) }))
                continue
            }
            let isDefaultRow = entry.id.isSystemDefault
            let title = isDefaultRow ? String(localized: "System output") : entry.name
            let detail = isDefaultRow ? (entry.name.isEmpty ? nil : entry.name) : transportName(entry.transport)
            let selectable = kind == .localMedia && (!remote || remoteCast) && entry.capabilities.selection == .appSelectable
            let state: OutputPickerContent.Row.State = entry.connection == .unavailable ? .unavailable : (entry.isCurrent ? .current : .available)
            let headphones = entry.id.deviceUID.flatMap { coordinator.snapshot.device(uid: $0)?.isHeadphones } ?? false
            rows.append(.init(id: entry.id.rawValue, title: title, detail: detail, symbol: symbol(entry.transport, headphones: headphones),
                              state: state, selectable: selectable, volume: volumeSentence(entry.capabilities),
                              unsupported: entry.capabilities.limits.map { sentence($0, engine: kind) }))
        }
        let statement: String? = kind == .youTubeMusic
            ? String(localized: "YouTube Music plays through this Mac's sound output. Change it in Control Center.") : nil
        let notice: String? = coordinator.launchNotice == .preferredUnavailable
            ? String(localized: "The output you chose before isn't connected, so the Mac's sound output is in use.") : nil
        let showsPicker = coordinator.offersSystemPicker(for: kind) && controller.pickerPlayer != nil
        let hint = controller.multipleAirPlayRoutes
            ? String(localized: "AirPlay receivers are chosen in the system picker. Grouping is left to it, as far as the system offers it.")
            : String(localized: "AirPlay receivers are chosen in the system picker.")
        let loss = coordinator.loss(for: kind).map { OutputPickerContent.Loss(message: lossMessage($0.reason, cast: $0.lostRoute.isCast), canReconnect: coordinator.lossCanReconnect(for: kind)) }
        // W39: the picker for YouTube Music states plainly that it cannot be cast from this app (no sanctioned way to hand a receiver the account's playback).
        var castNotes: [String] = kind == .youTubeMusic ? [sentence(.castYouTubeMusic, engine: .youTubeMusic)] : []
        if kind == .localMedia, controller.castDirectory != nil {
            if let notice = controller.cast?.notice { castNotes.append(castNotice(notice)) }
            if remoteCast, coordinator.capabilities(for: .localMedia).quit == .stopsBecauseMacRelays {
                castNotes.append(String(localized: "Playback on the receiver stops when you quit, because this Mac is serving the audio."))
            }
            if coordinator.castDevices.isEmpty { castNotes.append(String(localized: "Looking for Cast receivers on your network. The first time, macOS asks to allow Local Network access.")) }
            castNotes.append(String(localized: "Only owned and local audio can be cast. YouTube Music can't be cast from this app."))
        }
        return OutputPickerContent(currentName: currentName, symbol: symbol(current?.transport, headphones: current?.isHeadphones ?? false),
                                   statement: statement, rows: rows, notice: notice, showsSystemPicker: showsPicker, airPlayHint: hint, loss: loss, castNotes: castNotes)
    }

    @MainActor static func prompt(for controller: OutputController) -> OutputPromptContent? {
        switch controller.coordinator.prompt {
        case .playHere(let value)?:
            let place = value.output.map { String(localized: "Playing now uses \($0).") } ?? String(localized: "Playing now uses this Mac's sound output.")
            let reconnect = value.canReconnect ? " " + String(localized: "The output you were using is back; choose Reconnect in the Output menu to continue there.") : ""
            let castLoss = controller.coordinator.loss(for: value.engine)?.lostRoute.isCast ?? false
            return .init(id: value.id, kind: .playHere(canReconnect: value.canReconnect), title: String(localized: "Play on this Mac?"),
                         message: lossMessage(value.reason, cast: castLoss) + " " + place + reconnect, confirmTitle: String(localized: "Play Here"))
        case .timer(let value)?:
            return .init(id: value.id, kind: .timer, title: String(localized: "This receiver can't fade the sleep timer"),
                         message: String(localized: "The sleep timer will pause playback on the receiver when it ends, but it can't fade the sound first. Turn it on anyway?"),
                         confirmTitle: String(localized: "Turn On Timer"))
        case nil: return nil
        }
    }
}
