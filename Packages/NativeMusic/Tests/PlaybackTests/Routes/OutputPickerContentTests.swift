import Features
import Foundation
import OutputRoutes
import Testing
@testable import Playback
@testable import AppShell

/// ROUTE01 / T22.4 at the surface: what the picker says for each engine, and the sentences a person reads before an audible action.
@Suite @MainActor struct OutputPickerContentTests {
    private func content(_ rig: OutputRig) -> OutputPickerContent { OutputPickerMapping.content(for: rig.controller) }

    @Test func theHiddenPlayersPickerSaysItFollowsTheMacAndOffersNothingItCannotHonour() async throws {
        let rig = try await OutputRig.make()
        _ = try await rig.play()
        let value = content(rig)
        #expect(rig.controller.subject == .youTubeMusic)
        #expect(value.statement == "YouTube Music plays through this Mac's sound output. Change it in Control Center.")
        #expect(value.rows.allSatisfy { !$0.selectable }, "no per-app selection it cannot honour (ROUTE01)")
        #expect(!value.showsSystemPicker, "no AirPlay choice for the hidden page")
        for row in value.rows {
            #expect(row.unsupported.contains("This player can't be pointed at an output; it follows the Mac."), "\(row.title)")
            #expect(row.unsupported.contains("AirPlay can't be chosen from this player."))
            #expect(row.unsupported.contains("This app never changes the Mac's volume."))
            #expect(row.volume == "App volume applies. The output's own volume is the Mac's.")
        }
        #expect(value.rows.first?.title == "System output" && value.rows.first?.detail == "Synthetic Buds" && value.rows.first?.state == .current)
    }
    @Test func theNativePlayersPickerOffersEveryLiveOutputButNotAnAirPlayDeviceByName() async throws {
        let rig = try await OutputRig.make(devices: [routeSpeakers, routeBuds, routeReceiver], defaultUID: routeSpeakers.uid)
        #expect(rig.controller.subject == .localMedia)
        let value = content(rig)
        #expect(value.statement == nil)
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
    /// The panel says each sentence once: a player that follows the Mac lists only the output in use, and the sentences every listed row shares move under Details.
    @Test func thePanelListsOnlyTheOutputInUseWhenThePlayerFollowsTheMacAndSaysSharedSentencesOnce() async throws {
        let rig = try await OutputRig.make()
        _ = try await rig.play()
        let value = content(rig)
        #expect(value.followsMac)
        #expect(value.visibleRows.count == 1 && value.visibleRows.first?.state == .current && value.visibleRows.first?.title == "System output")
        let row = try #require(value.visibleRows.first)
        #expect(value.notes(for: row).isEmpty, "a single row carries nothing of its own")
        #expect(value.detailNotes.contains("This app never changes the Mac's volume.") && value.detailNotes.contains("Casting YouTube Music isn't available from this app."))
        #expect(value.visibleCastNotes.isEmpty)
        #expect(Set(value.detailNotes).count == value.detailNotes.count, "no sentence repeats")

        let native = try await OutputRig.make(devices: [routeSpeakers, routeBuds, routeReceiver], defaultUID: routeSpeakers.uid)
        let local = OutputPickerMapping.content(for: native.controller)
        #expect(!local.followsMac && local.visibleRows.count == local.rows.count, "every output a person can choose is listed")
        #expect(local.sharedNotes.contains("Grouping receivers is left to the system picker, as far as it offers it."))
        for row in local.visibleRows { #expect(Set(local.notes(for: row)).isDisjoint(with: local.sharedNotes)) }
    }
    @Test func everySentenceTheCapabilityTableCanProduceHasText() {
        for limit in RouteCapabilities.Limit.allCases {
            for engine in [OutputEngineKind.youTubeMusic, .localMedia] { #expect(!OutputPickerMapping.sentence(limit, engine: engine).isEmpty) }
        }
        for reason in [RouteLossReason.headphonesUnplugged, .deviceDisconnected, .receiverDisconnected] { #expect(OutputPickerMapping.lossMessage(reason).hasSuffix("playback paused.")) }
    }
}
