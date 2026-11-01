import Foundation

// W25 (MAC06, T25.1/T25.2). What the widget draws, decided from the cached snapshot alone. Pure: the provider, the views and the tests all go through it.

public enum WidgetRedaction: Equatable, Sendable {
    case signedOut, locked
    /// No readable snapshot (never written, deleted, from another schema): the widget does not guess.
    case unknown
}

public struct WidgetItemDisplay: Equatable, Sendable {
    public let title: String
    public let artist: String?
    public let artwork: Data?
    public let playing: Bool
    public let advertisement: Bool
    public let capabilities: WidgetCapabilities
    public let scope: WidgetScope
}

public enum WidgetDisplay: Equatable, Sendable {
    /// The widget gallery's preview and the system's placeholder: fixed sample text, never the person's music.
    case placeholder
    case redacted(WidgetRedaction)
    case idle(WidgetScope)
    case item(WidgetItemDisplay)

    public init(_ result: WidgetReadResult) {
        switch result {
        case .missing, .unreadable: self = .redacted(.unknown)
        case .snapshot(let snapshot):
            switch snapshot.state {
            case .signedOut: self = .redacted(.signedOut)
            case .locked: self = .redacted(.locked)
            case .idle: self = snapshot.scope.map { .idle($0) } ?? .redacted(.unknown)
            case .advertisement, .playing, .paused:
                guard let scope = snapshot.scope else { self = .redacted(.unknown); return }
                if snapshot.state == .advertisement {
                    self = .item(WidgetItemDisplay(title: String(localized: "Advertisement"), artist: nil, artwork: nil, playing: true, advertisement: true, capabilities: snapshot.capabilities, scope: scope))
                } else {
                    self = .item(WidgetItemDisplay(title: snapshot.title ?? "", artist: snapshot.artist, artwork: snapshot.artwork, playing: snapshot.state == .playing, advertisement: false,
                                                   capabilities: snapshot.capabilities, scope: scope))
                }
            }
        }
    }

    /// The system hides content on a surface where it must not show (a locked screen, a privacy setting): the widget then draws the locked state.
    public func applying(privacyRedaction: Bool) -> WidgetDisplay { privacyRedaction ? .redacted(.locked) : self }
}

/// What a view shows, as plain data, so a test can assert what text and which buttons exist without reading pixels.
public struct WidgetContent: Equatable, Sendable {
    public enum Button: Equatable, Sendable { case previous, playPause(playing: Bool), next }
    public struct Control: Equatable, Sendable { public let button: Button; public let enabled: Bool; public let label: String }
    public var texts: [String]
    public var hasArtwork: Bool
    public var controls: [Control]
    public var scope: WidgetScope?

    public static func make(_ display: WidgetDisplay, family: Family) -> WidgetContent {
        switch display {
        case .placeholder:
            return WidgetContent(texts: [String(localized: "Song title"), String(localized: "Artist")], hasArtwork: false, controls: controls(.none, playing: false, family: family, enabled: false), scope: nil)
        case .redacted(let reason):
            return WidgetContent(texts: [String(localized: "YTMuse"), message(reason)], hasArtwork: false, controls: [], scope: nil)
        case .idle(let scope):
            return WidgetContent(texts: [String(localized: "Nothing playing")], hasArtwork: false, controls: [], scope: scope)
        case .item(let item):
            var texts = [item.title]
            if let artist = item.artist, !artist.isEmpty { texts.append(artist) }
            return WidgetContent(texts: texts, hasArtwork: item.artwork != nil, controls: controls(item.capabilities, playing: item.playing, family: family, enabled: true), scope: item.scope)
        }
    }
    public enum Family: Sendable { case small, medium }
    static func controls(_ capabilities: WidgetCapabilities, playing: Bool, family: Family, enabled: Bool) -> [Control] {
        let playPause = Control(button: .playPause(playing: playing), enabled: enabled && capabilities.playPause, label: playing ? String(localized: "Pause") : String(localized: "Play"))
        guard family == .medium else { return [playPause] }
        return [Control(button: .previous, enabled: enabled && capabilities.previous, label: String(localized: "Previous Song")), playPause,
                Control(button: .next, enabled: enabled && capabilities.next, label: String(localized: "Next Song"))]
    }
    static func message(_ reason: WidgetRedaction) -> String {
        switch reason {
        case .signedOut: String(localized: "Sign in to YouTube Music in YTMuse.")
        case .locked: String(localized: "Locked. Unlock to see what is playing.")
        case .unknown: String(localized: "Open YTMuse to start playing.")
        }
    }
}
