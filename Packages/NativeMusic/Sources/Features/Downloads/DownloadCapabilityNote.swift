import DesignSystem
import Domain
import SwiftUI

/// What stands where a person would expect a Download button on a YouTube Music item. It is words, not a control: there
/// is nothing to press, and nothing is queued behind it.
public struct DownloadCapabilityNote: View {
    let media: ServiceID
    public init(media: ServiceID) { self.media = media }
    public var body: some View {
        if case .notOffered = DownloadEligibility.of(media) {
            Label(DownloadsText.youTubeMusicExplanation, systemImage: "arrow.down.circle.dotted")
                .font(.caption).foregroundStyle(MusicStyle.secondaryText)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("downloadCapabilityNote")
        }
    }
}
