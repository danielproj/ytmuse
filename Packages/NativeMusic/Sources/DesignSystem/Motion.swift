import SwiftUI

public enum MusicMotion: String, CaseIterable, Sendable {
    case hoverPress, navigation, artworkExpansion, queueReorder, playPause, artworkColor, lyrics, miniPlayer, loading
    /// V02: row/chip selection feedback, content appearing after loading, and the mini-player to Now Playing morph.
    case selection, reveal, playerMorph
    public var seconds: Double {
        switch self {
        case .hoverPress: 0.11; case .navigation: 0.21; case .artworkExpansion: 0.32
        case .queueReorder: 0; case .playPause: 0.12; case .artworkColor: 0.75
        case .lyrics: 0.22; case .miniPlayer: 0.24; case .loading: 0.13
        case .selection: 0.16; case .reveal: 0.26; case .playerMorph: 0.34
        }
    }
    /// Reduce Motion keeps only the short crossfade-equivalents.
    var keepsCrossfade: Bool { self == .hoverPress || self == .loading || self == .reveal || self == .playerMorph }
    public func duration(reduceMotion: Bool, lowPower: Bool, visible: Bool) -> Double {
        guard visible else { return 0 }
        if reduceMotion { return keepsCrossfade ? 0.1 : 0 }
        if lowPower && (self == .artworkColor || self == .artworkExpansion || self == .playerMorph) { return 0 }
        return seconds
    }
    /// Springs and smooth curves with the same perceptual duration as the budget, so the MOTION table still holds.
    public func animation(reduceMotion: Bool, lowPower: Bool, visible: Bool) -> Animation? {
        let value = duration(reduceMotion: reduceMotion, lowPower: lowPower, visible: visible)
        guard value > 0 else { return nil }
        if reduceMotion { return .easeInOut(duration: value) }
        switch self {
        case .hoverPress, .selection, .playPause: return .snappy(duration: value)
        case .artworkExpansion, .miniPlayer, .playerMorph: return .spring(duration: value, bounce: 0.14)
        case .navigation, .artworkColor, .lyrics, .loading, .reveal, .queueReorder: return .smooth(duration: value)
        }
    }
}

public struct BrowserLayout: Equatable, Sendable {
    public static let sidebar: ClosedRange<Double> = 200...280
    public static let trailing: ClosedRange<Double> = 300...420
    public let showsTrailing: Bool
    public let compactPlayer: Bool
    public init(width: Double) { showsTrailing = width >= 1120; compactPlayer = width < 1000 }
}
