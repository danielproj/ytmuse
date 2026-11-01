import AccountSession
import Foundation
import Observation

/// The discovery extras behind Explore: Samples, the music tuner, Recap and badges. One value per window group, held by the shell.
@MainActor @Observable public final class DiscoverySurface {
    public let samples: SamplesModel
    public let tuner: TunerModel
    public let summaries: AccountSummaryModel
    /// The labelled development data answers instead of the service (Debug, isolated UI runs only).
    public let development: Bool
    public var arbiter: PreviewArbiter { samples.arbiter }

    public init(samples: SamplesModel, tuner: TunerModel, summaries: AccountSummaryModel, development: Bool = false) {
        self.samples = samples; self.tuner = tuner; self.summaries = summaries; self.development = development
    }
    /// A page or entries the catalog read: radios they published become seeds the tuner can offer. Nothing is requested.
    public func note(page: MusicBrowsePage) { tuner.seedBook.note(page: page); tuner.seedBook.note(items: page.shelves.flatMap(\.items)) }
    public func note(items: [MusicCatalogItem]) { tuner.seedBook.note(items: items) }
    public func accountChanged() { samples.accountChanged(); tuner.accountChanged(); summaries.accountChanged() }
}
