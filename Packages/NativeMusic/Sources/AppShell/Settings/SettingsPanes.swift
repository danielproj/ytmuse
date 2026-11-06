import AppKit
import AccountSession
import DesignSystem
import Diagnostics
import Domain
import Features
import SwiftUI
import UniformTypeIdentifiers

// W27. The panes that are not lists of registry rows: Accounts, Storage, Privacy and Diagnostics.

/// A readout of the GUARD's own verdict on this session (Debug builds only), shown on every Settings page so a UI run can read it before it touches anything:
/// "guard=accepted" is `DestructiveActionGuard.verify` over the declared roots AND what the destructive objects actually hold; it is not the session's own flag.
struct RootsReadout: View {
    let accounts: LocalAccountBootstrap
    var body: some View {
        #if DEBUG
        if let roots = accounts.localRoots {
            Text(Self.text(roots, touches: accounts.eraser?.targets.touches())).font(.caption2).foregroundStyle(MusicStyle.secondaryText).textSelection(.enabled)
                .accessibilityIdentifier("localDataRoots")
        }
        #endif
    }
    static func text(_ roots: LocalDataRoots, touches: LocalDataTouches? = nil) -> String {
        let prefs: String
        switch roots.preferences { case .isolatedPlist: prefs = "plist"; case .memory: prefs = "memory"; case .standardDomain: prefs = "REAL DOMAIN" }
        let index = roots.searchIndex == .inMemory ? "in-memory" : "REAL INDEX"
        let group = roots.groupDirectory == nil ? "none" : (roots.isolated ? "temporary" : "REAL GROUP")
        let verdict = DestructiveActionGuard.verdict(roots, touches: touches)
        let namespaces = roots.keychainNamespaces.map { $0.contains(".test.") ? "test" : "PRODUCTION" }.joined(separator: ",")
        return (roots.isolated ? "roots: isolated" : "roots: REAL STORES") + "; guard=\(verdict); app=\(DestructiveActionGuard.canonical(roots.applicationDirectory)); owned=\(DestructiveActionGuard.canonical(roots.ownedAudioDirectory)); keychain=\(namespaces); prefs=\(prefs); index=\(index); group=\(group)"
    }
}

struct AccountsSettingsPane: View {
    let accounts: LocalAccountBootstrap
    @State private var pendingRemoval: LocalIdentity?
    @State private var message: String?
    var body: some View {
        Section("Accounts") {
            Text("Each account keeps its own settings, downloads and cache on this Mac. Removing an account here deletes its local data only. Nothing is deleted from YouTube Music or your Google account.")
                .font(.footnote).foregroundStyle(MusicStyle.secondaryText)
            if accounts.model.identities.isEmpty { Text("No account is signed in.").foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("settingsNoAccounts") }
            ForEach(accounts.model.identities) { identity in
                HStack {
                    VStack(alignment: .leading) {
                        Text(identity.account.displayName)
                        Text(Self.state(identity.state)).font(.footnote).foregroundStyle(MusicStyle.secondaryText)
                    }
                    Spacer()
                    Button("Clear Cache") { Task { await clear(identity) } }.accessibilityIdentifier("clearCache." + identity.id.accountID.uuidString).musicAction(.secondary)
                    Button("Remove from This Mac…", role: .destructive) { pendingRemoval = identity }.accessibilityIdentifier("removeAccount." + identity.id.accountID.uuidString).musicAction(.secondary)
                }
            }
            if let message { Text(message).font(.footnote).accessibilityIdentifier("settingsAccountMessage") }
        }
        .confirmationDialog("Remove this account from this Mac?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), presenting: pendingRemoval) { identity in
            Button("Remove from This Mac", role: .destructive) { Task { await remove(identity) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("Deletes this account's sign-in, downloads, cache and settings from this Mac. Your YouTube Music library, playlists and Google account are not changed.") }
    }
    static func state(_ state: LocalSessionState) -> String {
        switch state { case .connected: String(localized: "Signed in"); case .expired: String(localized: "Session expired"); case .signedOut: String(localized: "Signed out"); case .removalPending: String(localized: "Removal pending") }
    }
    @MainActor private func clear(_ identity: LocalIdentity) async {
        guard let eraser = accounts.eraser else { return }
        let report = await eraser.clearCaches(of: identity.id, confirmation: confirmation())
        message = report.succeeded ? String(localized: "Cache cleared.") : String(localized: "The cache could not be cleared.")
        await accounts.model.refresh()
    }
    @MainActor private func remove(_ identity: LocalIdentity) async {
        guard let eraser = accounts.eraser else { return }
        let report = await eraser.removeAccount(identity.id, confirmation: confirmation())
        message = report.succeeded ? String(localized: "The account was removed from this Mac.") : String(localized: "The account could not be fully removed. Open Accounts to retry.")
        await accounts.model.refresh()
    }
    @MainActor private func confirmation() -> PersonConfirmation? { accounts.localRoots?.isolated == true ? nil : PersonConfirmation.fromConfirmationButton() }
}

struct StorageSettingsPane: View {
    let accounts: LocalAccountBootstrap
    @State private var breakdown: StorageBreakdown?
    private static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    var body: some View {
        Section("Storage by account") {
            Text("What YTMuse keeps on this Mac. Pinned and automatic are downloads; cache is artwork that can be fetched again.").font(.footnote).foregroundStyle(MusicStyle.secondaryText)
            if let breakdown {
                ForEach(breakdown.accounts) { row in
                    VStack(alignment: .leading, spacing: MusicSpace.hairline) {
                        Text(row.label).font(.headline)
                        HStack {
                            Text("Pinned \(Self.size(row.pinnedBytes))").accessibilityIdentifier("storagePinned." + row.id.uuidString)
                            Text("Automatic \(Self.size(row.automaticBytes))").accessibilityIdentifier("storageAutomatic." + row.id.uuidString)
                            Text("Cache \(Self.size(row.cacheBytes))").accessibilityIdentifier("storageCache." + row.id.uuidString)
                        }.font(.footnote).foregroundStyle(MusicStyle.secondaryText)
                    }
                }
                if breakdown.unattributedDownloadBytes > 0 || breakdown.unattributedCacheBytes > 0 {
                    Text("Not linked to a listed account: downloads \(Self.size(breakdown.unattributedDownloadBytes)), cache \(Self.size(breakdown.unattributedCacheBytes))").font(.footnote)
                        .accessibilityIdentifier("storageUnattributed")
                }
                LabeledContent("Total on this Mac") { Text(Self.size(breakdown.totalBytes)) }.accessibilityIdentifier("storageTotal")
                Text(breakdown.reconciles ? "These figures add up to what the download engine and the artwork cache report." : "These figures do not add up to what the owners report. Open Diagnostics.")
                    .font(.footnote).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("storageReconciles")
            } else { ProgressView().accessibilityIdentifier("storageLoading") }
            Button("Refresh") { Task { breakdown = await accounts.storageBreakdown() } }.accessibilityIdentifier("storageRefresh").musicAction(.secondary)
        }.task { breakdown = await accounts.storageBreakdown() }
    }
}

struct PrivacySettingsPane: View {
    let accounts: LocalAccountBootstrap
    @State private var confirming = false
    @State private var result: String?
    @State private var running = false
    var body: some View {
        Group {
            Section("What leaves this Mac") {
                ForEach(SettingsRegistry.settings(in: .privacy)) { SettingRow(definition: $0, store: accounts.settings) }
                Text("YTMuse talks only to Google for sign-in, YouTube Music for the library and playback, the artwork hosts those pages name, and the devices you pick for AirPlay and Cast. It sends no account data to any other service, and it has no analytics.")
                    .font(.footnote).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("networkDestinations")
            }
            Section("Local data") {
                Text("Resets YTMuse on this Mac: it removes every account's sign-in and local data, clears caches and the Spotlight and widget copies, and restores every setting. It does not delete anything from YouTube Music or your Google account, and it does not send any request.")
                    .font(.footnote).foregroundStyle(MusicStyle.secondaryText)
                RootsReadout(accounts: accounts)
                Button("Reset All Local Data…", role: .destructive) { confirming = true }.disabled(running || accounts.eraser == nil).accessibilityIdentifier("resetLocalData").musicAction(.secondary)
                if let result { Text(result).font(.footnote).accessibilityIdentifier("resetLocalDataResult") }
            }
        }.confirmationDialog("Reset all local data on this Mac?", isPresented: $confirming) {
            Button("Reset All Local Data", role: .destructive) { Task { await run() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Every account is removed from this Mac and every setting is restored. Your YouTube Music library and Google account are not changed.") }
    }
    @MainActor private func run() async {
        guard let eraser = accounts.eraser else { return }
        running = true; defer { running = false }
        let confirmation: PersonConfirmation? = accounts.localRoots?.isolated == true ? nil : PersonConfirmation.fromConfirmationButton()
        let report = await eraser.eraseEverything(confirmation: confirmation)
        await accounts.model.refresh()
        if let refusal = report.refusal { result = String(localized: "Nothing was changed: \(refusal)") }
        else if report.succeeded { result = String(localized: "Local data was reset.") }
        else { result = String(localized: "Some of the local data could not be reset (\(report.failedSteps.joined(separator: ", "))). Run the reset again.") }
    }
}

struct DiagnosticsSettingsPane: View {
    let accounts: LocalAccountBootstrap
    @State private var report: DiagnosticsReport?
    @State private var failed = false
    @State private var bundle: SupportBundle?
    @State private var exportMessage: String?
    var body: some View {
        Group {
            Section("This app") {
                if let report {
                    LabeledContent("App") { Text("\(report.app.name) \(report.app.version) (\(report.app.build))") }.accessibilityIdentifier("diagApp")
                    LabeledContent("macOS") { Text("\(report.app.osVersion), \(report.app.architecture)") }
                    LabeledContent("Service adapter") { Text("\(report.adapter.name) \(report.adapter.version)") }.accessibilityIdentifier("diagAdapter")
                    LabeledContent("Account status") { Text(report.adapter.capabilityStatus) }.accessibilityIdentifier("diagCapability")
                    LabeledContent("Playback engine") { Text("\(report.playback.engine)") }.accessibilityIdentifier("diagEngine")
                    quality(report.playback.quality)
                    LabeledContent("Artwork cache") { Text(ByteCountFormatter.string(fromByteCount: report.storage.artworkCacheBytes, countStyle: .file)) }
                    LabeledContent("Downloads") { Text(ByteCountFormatter.string(fromByteCount: report.storage.pinnedDownloadBytes + report.storage.automaticDownloadBytes, countStyle: .file)) }
                } else if failed { Text("Diagnostics could not be read.").accessibilityIdentifier("diagFailed") } else { ProgressView() }
            }
            Section("Faults") {
                if let report {
                    Text(Self.verdict(report.faultVerdict)).accessibilityIdentifier("diagVerdict")
                    ForEach(report.errorSummary, id: \.category) { row in
                        LabeledContent(Self.categoryName(row.category)) { Text("\(row.count)") }.accessibilityIdentifier("diagCategory." + row.category.rawValue)
                    }
                    if report.errorSummary.isEmpty { Text("No faults recorded.").foregroundStyle(MusicStyle.secondaryText) }
                }
                Text("A source outage means YouTube Music or the network did not answer. A local crash means this app's own process ended unexpectedly.").font(.footnote).foregroundStyle(MusicStyle.secondaryText)
            }
            Section("Performance timings") {
                ForEach(SettingsRegistry.settings(in: .diagnostics)) { SettingRow(definition: $0, store: accounts.settings) }
                if let report { Text(report.profiling.enabled ? "On: \(report.profiling.sampleCount) timings kept, \(report.profiling.fileBytes) of \(report.profiling.maxFileBytes) bytes." : "Off. Nothing is recorded.").font(.footnote).accessibilityIdentifier("diagProfiling") }
            }
            Section("Support bundle") {
                Text("A redacted summary you can read before saving. It holds no media, credentials, names, searches or links, and nothing is sent anywhere.").font(.footnote).foregroundStyle(MusicStyle.secondaryText)
                Button("Preview Support Bundle…") { Task { bundle = await accounts.diagnostics?.bundle() } }.disabled(accounts.diagnostics == nil).accessibilityIdentifier("previewBundle").musicAction(.secondary)
                if let exportMessage { Text(exportMessage).font(.footnote).accessibilityIdentifier("bundleExportMessage") }
            }
        }
        .task { await load() }
        .onChange(of: accounts.settings.revision) { Task { await load() } }
        .sheet(item: Binding(get: { bundle.map(BundleItem.init) }, set: { if $0 == nil { bundle = nil } })) { item in
            BundlePreview(bundle: item.bundle, export: { export(item.bundle) }, close: { bundle = nil })
        }
    }
    @MainActor private func load() async {
        guard let center = accounts.diagnostics else { return }
        do { report = try await center.report(); failed = false } catch { failed = true; accounts.diagnosticLog.record(.internalError, component: "diagnostics", detail: "report failed") }
    }
    @ViewBuilder private func quality(_ q: MediaQualityObservation) -> some View {
        LabeledContent("Actual quality") {
            Text(q.unknownFields.isEmpty ? [q.codec.value, q.bitrateKbps.value.map { "\($0) kbps" }, q.sampleRateHz.value.map { "\($0) Hz" }].compactMap { $0 }.joined(separator: ", ") : String(localized: "Not reported: \(q.unknownFields.joined(separator: ", "))"))
        }.accessibilityIdentifier("diagQuality")
        if let reason = [q.codec.unknownReason, q.bitrateKbps.unknownReason].compactMap({ $0 }).first {
            Text(reason).font(.footnote).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("diagQualityReason")
        }
    }
    static func verdict(_ verdict: DiagnosticsReport.FaultVerdict) -> String {
        switch verdict {
        case .noFaults: String(localized: "No faults recorded.")
        case .sourceOutage: String(localized: "A recent fault came from the service: a source outage or a change on its side. The app itself did not fail.")
        case .networkOffline: String(localized: "A recent fault came from the network: this Mac could not reach the service.")
        case .localCrash: String(localized: "The last run of this app ended unexpectedly: a local crash, not a service outage.")
        case .localFault: String(localized: "A recent fault came from this Mac or the app.")
        }
    }
    static func categoryName(_ category: DiagnosticCategory) -> String {
        switch category {
        case .sourceOutage: String(localized: "Service outage"); case .sourceChanged: String(localized: "Service changed its response"); case .authExpired: String(localized: "Sign-in expired")
        case .networkOffline: String(localized: "Network offline"); case .storage: String(localized: "Storage"); case .playbackFailure: String(localized: "Playback failure")
        case .policyRefusal: String(localized: "Refused by policy"); case .localCrash: String(localized: "Local crash"); case .internalError: String(localized: "Internal error")
        }
    }
    @MainActor private func export(_ bundle: SupportBundle) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "YTMuse-support-bundle.json"; panel.allowedContentTypes = [.json]; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let bytes = try bundle.export(to: url); exportMessage = String(localized: "Saved \(bytes) bytes.") } catch { exportMessage = String(localized: "The bundle could not be saved.") }
    }
    private struct BundleItem: Identifiable { let bundle: SupportBundle; var id: String { String(bundle.text.hashValue) } }
    private struct BundlePreview: View {
        let bundle: SupportBundle
        let export: () -> Void
        let close: () -> Void
        var body: some View {
            VStack(alignment: .leading, spacing: MusicSpace.sm) {
                Text("Support Bundle Preview").font(MusicPageStyle.sheetTitle)
                Text("Exactly this text is saved. \(bundle.redactions) items were redacted. No media, credentials, names, searches or links are included.").font(.footnote).foregroundStyle(MusicStyle.secondaryText)
                ScrollView { Text(bundle.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("bundlePreviewText") }
                    .frame(minHeight: 260)
                HStack { Spacer(); Button("Done", action: close).keyboardShortcut(.cancelAction).accessibilityIdentifier("bundleClose").musicAction(.secondary); Button("Save…", action: export).keyboardShortcut(.defaultAction).accessibilityIdentifier("bundleSave").musicAction(.primary) }
            }.padding(MusicSpace.lg).frame(width: 560, height: 460).musicSheet()
        }
    }
}
