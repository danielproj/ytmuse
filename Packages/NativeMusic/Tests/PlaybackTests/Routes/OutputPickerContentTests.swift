import Features
import Foundation
import OutputRoutes
import Testing
@testable import Playback
@testable import AppShell

/// ROUTE01 / T22.4 at the surface: what the picker says for each engine, and the sentences a person reads before an audible action.
@Suite @MainActor struct OutputPickerContentTests {
    private func content(_ rig: OutputRig) -> OutputPickerContent { OutputPickerMapping.content(for: rig.controller) }

    /// The hidden player follows the Mac's sound output, so it has no picker: nothing it could offer would be a choice (ROUTE01).
    @Test func theHiddenPlayerOffersNoPicker() async throws {
        let rig = try await OutputRig.make()
        #expect(rig.controller.offersPicker, "the native engine has a picker")
        _ = try await rig.play()
        #expect(rig.controller.subject == .youTubeMusic)
        #expect(!rig.controller.offersPicker, "no output button, and Choose Output… is unavailable, while YouTube Music owns playback")
    }
    @Test func theNativePlayersPickerOffersEveryLiveOutputButNotAnAirPlayDeviceByName() async throws {
        let rig = try await OutputRig.make(devices: [routeSpeakers, routeBuds, routeReceiver], defaultUID: routeSpeakers.uid)
        #expect(rig.controller.subject == .localMedia)
        let value = content(rig)
        let byTitle = Dictionary(uniqueKeysWithValues: value.rows.map { ($0.title, $0) })
        #expect(byTitle["Synthetic Buds"]?.selectable == true && byTitle["Synthetic Speakers"]?.selectable == true && byTitle["System output"]?.selectable == true)
        #expect(byTitle["Synthetic Receiver"]?.selectable == false, "an AirPlay receiver is chosen in the system picker")
        #expect(byTitle["Synthetic Receiver"]?.detail == "AirPlay")
        #expect(value.rows.allSatisfy { $0.unsupported.contains("Grouping receivers is left to the system picker, as far as it offers it.") }, "no row offers app-level grouping")
        #expect(!value.showsSystemPicker, "the system picker button needs a local AVPlayer to attach to")
    }
    @Test func aMissingRememberedOutputIsExplainedAndNeverSubstituted() async throws {
        let base = try await LifecycleRig.make()
        let directory = PlaybackScriptedDirectory([routeSpeakers], defaultUID: routeSpeakers.uid)
        let controller = OutputController(coordinator: OutputRouteCoordinator(directory: directory, store: MemoryPreferredRoute(.device(uid: routeBuds.uid))), applier: NoOutputApplier())
        await controller.bind(to: base.model)
        let value = OutputPickerMapping.content(for: controller)
        #expect(value.notice == "The output you chose before isn't connected, so the Mac's sound output is in use.")
        #expect(controller.coordinator.selection == .systemDefault)
    }
    @Test func aLossIsStatedWithItsReasonAndOffersReconnectOnlyWhenTheOutputIsBack() async throws {
        let rig = try await OutputRig.make()
        _ = try await rig.play()
        rig.unplug(); await rig.coordinator.settled()
        var value = content(rig)
        #expect(value.loss?.message == "The output was disconnected, so playback paused." && value.loss?.canReconnect == false)
        rig.replug()
        value = content(rig)
        #expect(value.loss?.canReconnect == true)
    }
    @Test func thePlayHerePromptNamesWhereSoundWouldComeOutAndTheTimerPromptSaysItCannotFade() async throws {
        let rig = try await OutputRig.make()
        let (player, _) = try await rig.play()
        rig.unplug(); await rig.coordinator.settled()
        await player.resume()
        let here = try #require(OutputPickerMapping.prompt(for: rig.controller))
        #expect(here.title == "Play on this Mac?" && here.confirmTitle == "Play Here")
        #expect(here.message.contains("Playing now uses Synthetic Speakers.") && here.message.contains("so playback paused"))
        rig.coordinator.cancel(here.id)
        #expect(OutputPickerMapping.prompt(for: rig.controller) == nil)

        let remote = try await OutputRig.make()
        _ = await remote.coordinator.remoteBegan()
        await remote.coordinator.perform(.enableTimer, engine: .localMedia) {}
        let timer = try #require(OutputPickerMapping.prompt(for: remote.controller))
        #expect(timer.kind == .timer && timer.message.contains("can't fade") && timer.confirmTitle == "Turn On Timer")
    }
    /// The panel says each sentence once: the sentences every row shares move under Details.
    @Test func thePanelSaysSharedSentencesOnce() async throws {
        let native = try await OutputRig.make(devices: [routeSpeakers, routeBuds, routeReceiver], defaultUID: routeSpeakers.uid)
        let local = OutputPickerMapping.content(for: native.controller)
        #expect(local.sharedNotes.contains("Grouping receivers is left to the system picker, as far as it offers it."))
        #expect(Set(local.sharedNotes).count == local.sharedNotes.count, "no sentence repeats")
        for row in local.rows { #expect(Set(local.notes(for: row)).isDisjoint(with: local.sharedNotes)) }
    }
    @Test func everySentenceTheCapabilityTableCanProduceHasText() {
        for limit in RouteCapabilities.Limit.allCases {
            #expect(!OutputPickerMapping.sentence(limit).isEmpty)
        }
        for reason in [RouteLossReason.headphonesUnplugged, .deviceDisconnected, .receiverDisconnected] { #expect(OutputPickerMapping.lossMessage(reason).hasSuffix("playback paused.")) }
    }
}
