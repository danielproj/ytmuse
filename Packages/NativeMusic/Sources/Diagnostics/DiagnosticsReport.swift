import Foundation

/// A value the app may not know. DIAG01 asks for the ACTUAL media quality: where the player has not reported one, the screen and the bundle say so and why,
/// instead of showing the setting as if it were the result.
public enum Observed<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    case value(Value)
    case unknown(reason: String)
    public var value: Value? { if case .value(let v) = self { v } else { nil } }
    public var unknownReason: String? { if case .unknown(let r) = self { r } else { nil } }
}

public struct MediaQualityObservation: Codable, Sendable, Equatable {
    public var codec: Observed<String>
    public var bitrateKbps: Observed<Int>
    public var sampleRateHz: Observed<Int>
    public var route: Observed<String>
    public init(codec: Observed<String>, bitrateKbps: Observed<Int>, sampleRateHz: Observed<Int>, route: Observed<String>) { self.codec = codec; self.bitrateKbps = bitrateKbps; self.sampleRateHz = sampleRateHz; self.route = route }
    public static func unknown(_ reason: String) -> MediaQualityObservation {
        MediaQualityObservation(codec: .unknown(reason: reason), bitrateKbps: .unknown(reason: reason), sampleRateHz: .unknown(reason: reason), route: .unknown(reason: reason))
    }
    /// Names every field that is not known, for the "quality unknowns" line.
    public var unknownFields: [String] {
        [("codec", codec.unknownReason), ("bitrate", bitrateKbps.unknownReason), ("sample rate", sampleRateHz.unknownReason), ("output route", route.unknownReason)].compactMap { $0.1 == nil ? nil : $0.0 }
    }
}

/// DIAG01: the Diagnostics screen's content, and the body of the support bundle. Every field is a fact about the app, the Mac or the service, never about
/// the person: there is no account name, handle, email, avatar, playlist or search term in it by construction.
public struct DiagnosticsReport: Codable, Sendable, Equatable {
    public struct App: Codable, Sendable, Equatable {
        public var name: String, version: String, build: String, osVersion: String, architecture: String
        public init(name: String, version: String, build: String, osVersion: String, architecture: String) { self.name = name; self.version = version; self.build = build; self.osVersion = osVersion; self.architecture = architecture }
    }
    public struct Adapter: Codable, Sendable, Equatable {
        public var name: String, version: String
        /// What the signed-in session can do with the service, in words and without identity: "Music session verified", "Session expired", "Not signed in".
        public var capabilityStatus: String
        public init(name: String, version: String, capabilityStatus: String) { self.name = name; self.version = version; self.capabilityStatus = capabilityStatus }
    }
    public struct Playback: Codable, Sendable, Equatable {
        /// "YouTube Music web player (hidden)", "Native engine", or "None".
        public var engine: String
        public var engineVersion: String
        public var quality: MediaQualityObservation
        public init(engine: String, engineVersion: String, quality: MediaQualityObservation) { self.engine = engine; self.engineVersion = engineVersion; self.quality = quality }
    }
    public struct Storage: Codable, Sendable, Equatable {
        public var artworkCacheBytes: Int64, pinnedDownloadBytes: Int64, automaticDownloadBytes: Int64, unlistedDownloadBytes: Int64
        public init(artworkCacheBytes: Int64, pinnedDownloadBytes: Int64, automaticDownloadBytes: Int64, unlistedDownloadBytes: Int64) { self.artworkCacheBytes = artworkCacheBytes; self.pinnedDownloadBytes = pinnedDownloadBytes; self.automaticDownloadBytes = automaticDownloadBytes; self.unlistedDownloadBytes = unlistedDownloadBytes }
    }
    public var generatedAt: Date
    public var app: App
    public var adapter: Adapter
    public var accounts: Int
    public var playback: Playback
    public var storage: Storage
    /// Whether the previous run ended without a clean quit (a local crash), and whether recent source faults point at the service.
    public var previousRunEndedUnexpectedly: Bool
    public var errorSummary: [DiagnosticLog.CategoryCount]
    public var recentErrors: [DiagnosticEntry]
    /// The settings that differ from their defaults, by id only for settings whose value is private; the value for the rest.
    public var changedSettings: [SettingChange]
    public var profiling: ProfilingStatus
    /// A plain statement of what is in the bundle and what never is.
    public var exclusions: [String]
    public init(generatedAt: Date, app: App, adapter: Adapter, accounts: Int, playback: Playback, storage: Storage, previousRunEndedUnexpectedly: Bool, errorSummary: [DiagnosticLog.CategoryCount], recentErrors: [DiagnosticEntry], changedSettings: [SettingChange], profiling: ProfilingStatus, exclusions: [String] = DiagnosticsReport.standardExclusions) {
        self.generatedAt = generatedAt; self.app = app; self.adapter = adapter; self.accounts = accounts; self.playback = playback; self.storage = storage; self.previousRunEndedUnexpectedly = previousRunEndedUnexpectedly
        self.errorSummary = errorSummary; self.recentErrors = recentErrors; self.changedSettings = changedSettings; self.profiling = profiling; self.exclusions = exclusions
    }
    public static let standardExclusions = [
        "No media files, artwork or downloaded audio.", "No cookies, tokens, passwords or Keychain items.", "No account name, handle, email or photo.",
        "No playlist names, search terms or listening history.", "URLs are reduced to their host.",
    ]

    /// DIAG02: the one line that tells a source outage from a crash.
    public var faultVerdict: FaultVerdict {
        if previousRunEndedUnexpectedly { return .localCrash }
        let recent = recentErrors.suffix(10)
        if recent.contains(where: { $0.category == .sourceOutage || $0.category == .sourceChanged }) { return .sourceOutage }
        if recent.contains(where: { $0.category == .networkOffline }) { return .networkOffline }
        return recentErrors.isEmpty ? .noFaults : .localFault
    }
    public enum FaultVerdict: String, Codable, Sendable, Equatable { case noFaults, sourceOutage, networkOffline, localCrash, localFault }
}

public struct SettingChange: Codable, Sendable, Equatable { public let id: String; public let value: String?; public init(id: String, value: String?) { self.id = id; self.value = value } }

/// What the opt-in profiler is doing (DIAG02), for the screen and the bundle.
public struct ProfilingStatus: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var sampleCount: Int
    public var fileBytes: Int
    public var maxFileBytes: Int
    public init(enabled: Bool, sampleCount: Int, fileBytes: Int, maxFileBytes: Int) { self.enabled = enabled; self.sampleCount = sampleCount; self.fileBytes = fileBytes; self.maxFileBytes = maxFileBytes }
    public static let off = ProfilingStatus(enabled: false, sampleCount: 0, fileBytes: 0, maxFileBytes: LocalProfiler.Limits.standard.maxFileBytes)
}
