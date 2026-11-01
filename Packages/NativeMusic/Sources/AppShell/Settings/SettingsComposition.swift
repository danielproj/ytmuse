import AccountSession
import Artwork
import Diagnostics
import Domain
import Downloads
import Features
import Foundation
import Playback
import Queue
import SwiftUI
import SystemIntegration

// W27. Builds the settings store, the diagnostics and the destructive-action eraser from the objects the session really uses. The eraser is given the roots this
// session injected (`LocalDataRoots`) and nothing else; it computes no path of its own.

extension LocalAccountBootstrap {
    /// The settings store over the app's one preferences store (the throwaway plist under QA isolation). A store written by a NEWER build is never overwritten: an
    /// in-memory store is used instead and the newer one is left as it is.
    func makeSettingsStore() -> SettingsStore {
        let account: @MainActor () -> UUID? = { [weak self] in self?.model.active?.accountID }
        let store = (try? SettingsStore(backing: AppPreferences.guarded, account: account)) ?? (try! SettingsStore(backing: MemorySettingsBacking(), account: account))
        SettingsOwners.attach(to: store, shell: shell, downloads: downloads, downloadMirror: downloadMirror, outputs: { [weak self] in self?.outputs }, profiler: { [weak self] in self?.profiler })
        playback.effectsProvider = { [weak store] in store.flatMap { ChosenAudioEffects.make(from: $0) } }
        playback.restoreEnabled = { [weak store] in store?.bool("restoreSession") ?? true }
        playback.replacementPreference = { [weak store] in ReplacementPreference(rawValue: store?.text("replaceExplicitQueue") ?? "ask") ?? .ask }
        playback.faultSink = { [weak self] category, component, detail in
            self?.diagnosticLog.record(category, component: component, detail: detail)
            if category == .authExpired { self?.announceSignInNeeded() }
        }
        playback.profileSink = { [weak self] event, milliseconds in self?.profiler?.record(event, milliseconds: milliseconds) }
        return store
    }
    /// Settings > Artwork accent: off removes the tint entirely. The Browser shell asks here, so the setting and the shell cannot disagree.
    func playerAccent<T>(web: T?, artwork: T?, usesWebPlayer: Bool) -> T? { ArtworkAccentPolicy.accent(enabled: settings.bool("artworkAccent"), web: web, artwork: artwork, usesWebPlayer: usesWebPlayer) }
    /// Everything the app knows to be private right now (SEC03): account names and handles, library playlist names, search terms.
    func diagnosticsPrivateContext() -> RedactionContext {
        PrivateContext.make(identities: model.identities, proof: model.proof, searchTerms: SearchRecents.recordedTerms(defaults: AppPreferences.store))
    }

    /// Called once the account directory and lifecycle exist.
    func configureLocalData(appDirectory: URL, lifecycle: AccountLifecycle) {
        let marker = RunMarker(directory: appDirectory.appendingPathComponent("diagnostics", isDirectory: true))
        runMarker = marker
        let profiler = LocalProfiler(directory: appDirectory.appendingPathComponent("diagnostics", isDirectory: true))
        self.profiler = profiler
        let center = DiagnosticsCenter(log: diagnosticLog, profiler: profiler, sources: diagnosticsSources(appDirectory: appDirectory))
        center.noteLaunch(previous: marker.begin())
        diagnostics = center
        if settings.bool("profiling") { profiler.setEnabled(true) }

        let roots = makeRoots(appDirectory: appDirectory)
        localRoots = roots
        let files = GuardedFileSystem(root: appDirectory)
        let artwork = self.artwork
        let widget = widgetPublisher, spotlight = spotlight
        let shell = shell
        let authority = playback.authority
        let backing = AppPreferences.guarded
        let sessionVault = self.sessionVaultNamespace, ownedNamespace = authority.ownedKeychainNamespace
        let resolvedSearchIndex = resolvedServices?.searchIndex
        let targets = LocalDataEraser.Targets(
            identities: { await lifecycle.snapshot().directory.identities.map(\.id) },
            removeAccount: { try await lifecycle.remove($0) },
            clearAccountCaches: { try await artwork?.clearCache(accountID: $0.accountID) },
            clearAllCaches: { try await artwork?.clearCaches() },
            clearSpotlight: { try await spotlight?.eraseAll() },
            clearWidgetSnapshot: { try widget?.eraseSnapshot() },
            eraseOwnedAudio: { try await authority.eraseOwnedAudio() },
            resetPreferences: { [weak self] in
                guard let self else { return }
                try await self.settings.resetAll()
                try PreferencesEraser.removeAll(in: backing)
                self.settings.refreshAfterErase()
            },
            diagnosticsFiles: ["diagnostics/profile.json", "diagnostics/run-marker.json"],
            clearDiagnosticsLog: { [weak self] in self?.diagnosticLog.clear(); self?.profiler?.setEnabled(false) },
            turnOffLoginItem: { if shell.loginItem.isOn { shell.loginItem.setEnabled(false) } },
            touches: {
                // What the destructive objects ACTUALLY hold, read from the live objects (not from the declarations above).
                LocalDataTouches(artworkDirectory: artwork?.cacheDirectory, widgetDirectory: widget?.directory, ownedAudioDirectory: authority.ownedAudioDirectory,
                                 keychainNamespaces: [sessionVault, ownedNamespace].compactMap { $0 },
                                 preferences: backing.isRealDomain ? .standardDomain(backing.domain) : (roots.preferences == .memory ? .memory : .isolatedPlist(backing.domain)),
                                 searchIndex: resolvedSearchIndex is InMemorySearchableIndex || resolvedSearchIndex == nil ? .inMemory : .system)
            })
        eraser = LocalDataEraser(roots: roots, fileSystem: files, targets: targets)
        // Every Restore Defaults, from any caller, runs the same guard first (the person's confirmation is supplied only by the button that pressed it).
        settings.preflight = { [weak self] in
            guard let self, let eraser = self.eraser else { return }
            try eraser.verify(confirmation: self.pendingRestoreConfirmation)
        }
        Task { await downloadMirror.refresh() }
        // W27 (Download/error notifications): a finished or failed download is announced (in the app always; as a system notification only when the person opted in).
        beats.append(Task { [weak self] in
            var detector = DownloadEventDetector()
            guard let stream = await self?.lateDownloads.updates() else { return }
            for await snapshot in stream {
                guard !Task.isCancelled, let self else { return }
                for event in detector.ingest(snapshot.rows) { await self.shell.notifications?.statusEvent(event) }
            }
        })
    }
    /// A sign-in that ended is told once an hour at most.
    func announceSignInNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastSignInNotice ?? .distantPast) > 3600 else { return }
        lastSignInNotice = now
        Task { await shell.notifications?.statusEvent(.make(.signInNeeded)) }
    }

    /// A category's Restore Defaults (the page's button) or the explicit forgetting of the remembered output. Guarded first; touches only that category's settings.
    func restoreDefaults(_ category: SettingCategory?, only id: String? = nil, confirmed: Bool) async -> String? {
        pendingRestoreConfirmation = confirmed && localRoots?.isolated != true ? PersonConfirmation.fromConfirmationButton() : nil
        defer { pendingRestoreConfirmation = nil }
        do {
            if let id { try await settings.restoreOne(id) } else if let category { try await settings.reset(category) }
            return nil
        } catch { return LocalDataEraser.describe(error) }
    }

    func makeRoots(appDirectory: URL) -> LocalDataRoots {
        #if DEBUG
        if let isolated = isolatedStorage {
            return LocalDataRoots(applicationDirectory: appDirectory, ownedAudioDirectory: playback.authority.ownedAudioDirectory,
                                  keychainNamespaces: [isolated.sessionVault.serviceNamespace, isolated.ownedVault.serviceNamespace],
                                  preferences: AppPreferences.resolved.isolatedPath.map { .isolatedPlist($0) } ?? .memory,
                                  groupDirectory: resolvedServices?.groupDirectory, searchIndex: .inMemory, isolated: true)
        }
        #endif
        return LocalDataRoots(applicationDirectory: appDirectory, ownedAudioDirectory: playback.authority.ownedAudioDirectory, keychainNamespaces: [RealStores.sessionKeychainNamespace],
                              preferences: .standardDomain(AppPreferences.guarded.domain),
                              groupDirectory: resolvedServices?.groupDirectory, searchIndex: .system, isolated: false)
    }

    func diagnosticsSources(appDirectory: URL) -> DiagnosticsCenter.Sources {
        var sources = DiagnosticsCenter.Sources()
        sources.adapterName = musicReader == nil ? "No service adapter" : "YouTube Music web session"
        sources.adapterVersion = musicReader?.adapterVersion ?? "none"
        sources.capabilityStatus = { [weak self] in
            guard let self, self.model.active != nil else { return "Not signed in" }
            return self.model.activeConnected ? "Signed in; Music session active" : (self.model.activeExpired ? "Session expired; sign in again" : "Signed in; session not active")
        }
        sources.accounts = { [weak self] in self?.model.identities.count ?? 0 }
        sources.playback = { [weak self] in self?.playbackObservation() ?? DiagnosticsReport.Playback(engine: "None", engineVersion: "n/a", quality: .unknown("Nothing is playing.")) }
        sources.changedSettings = { [weak self] in (self?.settings.changedSettings() ?? []).map { SettingChange(id: $0.id, value: $0.value) } }
        sources.privateStrings = { [weak self] in self?.diagnosticsPrivateContext().privateStrings ?? [] }
        sources.storage = { [weak self] in
            guard let self else { return DiagnosticsReport.Storage(artworkCacheBytes: 0, pinnedDownloadBytes: 0, automaticDownloadBytes: 0, unlistedDownloadBytes: 0) }
            let totals = await self.lateDownloads.usageAcrossAccounts()
            let art = Int64(await self.artwork?.diskSnapshot().bytes ?? 0)
            return DiagnosticsReport.Storage(artworkCacheBytes: art, pinnedDownloadBytes: totals.pinnedBytes, automaticDownloadBytes: totals.automaticBytes, unlistedDownloadBytes: totals.unlistedBytes)
        }
        return sources
    }

    /// What the engine in use really reports. The hidden YouTube Music player reports a video quality level at most, never an audio codec, bitrate or sample rate:
    /// those are shown as unknown, with the reason.
    func playbackObservation() -> DiagnosticsReport.Playback {
        let route = outputs?.coordinator.snapshot.defaultDevice?.name
        if let player = playback.music {
            let why = "The YouTube Music web player does not report this to the app."
            return .init(engine: "YouTube Music web player (hidden)", engineVersion: "web client; no version reported",
                         quality: MediaQualityObservation(codec: .unknown(reason: why), bitrateKbps: .unknown(reason: why), sampleRateHz: .unknown(reason: why),
                                                          route: route == nil ? .unknown(reason: "The system output could not be read.") : .value("system output")))
            _ = player
        }
        if let media = playback.state?.media {
            return .init(engine: "Native engine (AVFoundation)", engineVersion: "system",
                         quality: MediaQualityObservation(codec: media.codec.map { .value($0) } ?? .unknown(reason: "The file did not report a codec."),
                                                          bitrateKbps: media.bitrate.map { .value(Int($0 / 1000)) } ?? .unknown(reason: "The file did not report a bitrate."),
                                                          sampleRateHz: media.sampleRate.map { .value(Int($0)) } ?? .unknown(reason: "The file did not report a sample rate."),
                                                          route: .value(media.route ?? "system output")))
        }
        return .init(engine: "None", engineVersion: "n/a", quality: .unknown("Nothing is playing."))
    }

    /// Cached storage rows for the Settings > Storage pane.
    func storageBreakdown() async -> StorageBreakdown {
        let identities = model.identities
        let artwork = self.artwork
        let downloads = lateDownloads
        let totals = await downloads.usageAcrossAccounts()
        let unlisted = await downloads.usageOutside(identities.map(\.id))
        return await StorageBreakdown.make(accounts: identities.map { ($0.id, $0.account.displayName) }, usage: { await downloads.usage(for: $0) }, unlisted: unlisted, ledgerTotals: totals,
                                           cache: { await artwork?.cacheBytes(accountID: $0.accountID) ?? 0 }, artworkDiskBytes: await artwork?.diskSnapshot().bytes ?? 0,
                                           objectStoreBytes: await downloads.objectStoreBytes())
    }
}

/// Emptying the session's preferences root (SEC08, privacy reset). It can only be the store the guard wraps: a real domain refuses at the call while isolated.
enum PreferencesEraser {
    static func removeAll(in store: GuardedDefaults) throws { try store.removeAll() }
}

/// W27 (Crossfade / EQ / normalization, default off / flat and off / off): what the person chose, as the engine's own effect request.
enum ChosenAudioEffects {
    @MainActor static func make(from store: SettingsStore) -> AudioEffects? {
        try? AudioEffects(bands: EqualizerPreset(rawValue: store.text("equalizer"))?.bands ?? EqualizerPreset.flat.bands, normalize: store.bool("normalization"), crossfade: store.double("crossfade"))
    }
}

/// The strings a diagnostic must never carry, collected from the same objects the app shows them from. One function, so the app and the tests agree on what is private.
enum PrivateContext {
    static func make(identities: [LocalIdentity], proof: MusicProofState, searchTerms: [String]) -> RedactionContext {
        var strings = Set<String>()
        for identity in identities { strings.insert(identity.account.displayName) }
        if case .signedIn(let proof) = proof {
            strings.insert(proof.identity.displayName)
            if let handle = proof.identity.handle { strings.insert(handle); strings.insert(handle.trimmingCharacters(in: CharacterSet(charactersIn: "@"))) }
            for playlist in proof.library.playlists { strings.insert(playlist.title) }
        }
        strings.formUnion(searchTerms)
        return RedactionContext(privateStrings: strings)
    }
}
