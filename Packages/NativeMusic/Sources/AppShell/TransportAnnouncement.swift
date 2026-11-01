import DesignSystem
import Playback
import SwiftUI

/// W28 (A11Y04, T28.6): the transport changes worth speaking. The playing position and the lyric line are never inputs: the key below is
/// built from phase, track identity and ad state only, so a position tick cannot change it.
struct TransportAnnouncementState: Equatable {
    enum Phase: Equatable { case idle, loading, playing, paused, buffering, ended, failed(String) }
    var phase: Phase
    var videoID: String?
    var title: String?
    var artist: String?
    var isAd: Bool
    init(_ snapshot: WebMusicSnapshot) {
        switch snapshot.phase {
        case .idle: phase = .idle
        case .loading: phase = .loading
        case .playing: phase = .playing
        case .paused: phase = .paused
        case .buffering: phase = .buffering
        case .ended: phase = .ended
        case .failed(let failure): phase = .failed(failure.message)
        }
        videoID = snapshot.videoID; title = snapshot.title; artist = snapshot.artist; isAd = snapshot.isAd
    }
    init(phase: Phase, videoID: String? = nil, title: String? = nil, artist: String? = nil, isAd: Bool = false) {
        self.phase = phase; self.videoID = videoID; self.title = title; self.artist = artist; self.isAd = isAd
    }
}
enum TransportAnnouncement {
    /// The announcement for a change, or nil when the change is not worth speaking (loading, buffering, metadata arriving late).
    static func message(from old: TransportAnnouncementState, to new: TransportAnnouncementState) -> (text: String, kind: AnnouncementKind)? {
        if case .failed(let text) = new.phase { return old.phase == new.phase ? nil : (text, .error) }
        if new.isAd != old.isAd { return (new.isAd ? String(localized: "Advertisement playing") : String(localized: "Advertisement ended"), .transport) }
        if new.isAd { return nil }
        // A different track starting to play: name it once, with the artist when known.
        if new.phase == .playing, let title = new.title, !title.isEmpty, (old.videoID != new.videoID || old.title != new.title) {
            if let artist = new.artist, !artist.isEmpty { return (String(localized: "Now playing “\(title)” by \(artist)."), .transport) }
            return (String(localized: "Now playing “\(title)”."), .transport)
        }
        switch (old.phase, new.phase) {
        case (.playing, .paused): return (String(localized: "Paused"), .transport)
        case (.paused, .playing) where old.videoID == new.videoID: return (String(localized: "Playing"), .transport)
        case (_, .ended) where old.phase != .ended: return (String(localized: "Ended"), .transport)
        default: return nil
        }
    }
}
extension View {
    func announcesTransport(_ snapshot: WebMusicSnapshot) -> some View {
        onChange(of: TransportAnnouncementState(snapshot)) { old, new in
            if let item = TransportAnnouncement.message(from: old, to: new) { Announcer.post(item.text, kind: item.kind) }
        }
    }
}
