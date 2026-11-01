import Domain
import Foundation
import Testing

@Suite("T02.4 Entity invariants") struct EntityTests {
    @Test func identityMetadataAndUnknownMeasurements() throws {
        let a = try account(); let id = try sid()
        let accountModel = try Account(id: a.accountID, serviceIdentity: id, context: a, displayName: "Synthetic", credential: ID("keychain-reference"))
        #expect(accountModel.context == a)
        #expect(throws: DomainError.invalidInput(.contextMismatch)) { try Account(id: UUID(), serviceIdentity: id, context: a, displayName: "", credential: nil) }
        #expect(throws: DomainError.invalidInput(.emptyIdentifier)) { try sid(" ") }
        #expect(throws: DomainError.invalidInput(.region)) { try account(region: "us") }
        let media = try MediaItem(id: id, kind: .song, title: "Synthetic", artists: [], duration: nil, artwork: [], explicit: nil, availability: .unknown)
        #expect(media.duration == nil && media.explicit == nil && media.availability == .unknown)
        #expect(throws: DomainError.invalidInput(.negativeValue)) { try MediaItem(id: id, kind: .song, title: "", artists: [], duration: .nan, artwork: [], explicit: nil, availability: .available) }
        let metadata = CatalogMetadata(id: id, title: "Synthetic")
        let album = Album(metadata: metadata, tracks: Page(items: [media])); let artist = Artist(metadata: metadata, releases: Page(items: [metadata])); let podcast = Podcast(metadata: metadata, episodes: Page(items: [media]))
        #expect(album.tracks.items.count == 1 && artist.releases.items.count == 1 && podcast.episodes.items.count == 1)
        let playlist = Playlist(metadata: metadata, owner: id, permissions: [:], providerVersion: nil, snapshotVersion: 1)
        #expect(playlist.privacy == .private && playlist.providerVersion == nil)
        let v = try variant(); #expect(v.bitrate == nil && v.sampleRate == nil)
        #expect(throws: DomainError.invalidInput(.negativeValue)) { try MediaVariant(id: id, codec: "", container: "", bitrate: 0, sampleRate: nil, expiresAt: nil, seekable: true, authorization: ID("reference")) }
    }
    @Test func duplicateMediaRetainsOccurrencesAndRejectsDuplicateIdentity() throws {
        let a = try account(); let id = try sid()
        let first = try QueueEntry(media: id, segment: .user, originalOrder: 0)
        let second = try QueueEntry(media: id, segment: .context, originalOrder: 1)
        let queue = try QueueSession(account: a, version: 1, entries: [first, second], currentOccurrence: second.id, position: 2, shuffleSeed: 42, repeatMode: .all, autoplay: true)
        #expect(queue.entries.count == 2 && queue.entries[0].id != queue.entries[1].id && queue.currentOccurrence == second.id)
        #expect(throws: DomainError.invalidInput(.duplicateOccurrence)) { try QueueSession(account: a, version: 1, entries: [first, first], currentOccurrence: nil, position: 0, shuffleSeed: nil, repeatMode: .off, autoplay: false) }
        #expect(throws: DomainError.invalidInput(.missingCurrentOccurrence)) { try QueueSession(account: a, version: 1, entries: [first], currentOccurrence: UUID(), position: 0, shuffleSeed: nil, repeatMode: .off, autoplay: false) }
        let p1 = PlaylistItem(occurrence: .synthetic(UUID()), media: id), p2 = PlaylistItem(occurrence: .synthetic(UUID()), media: id)
        #expect(p1.occurrence != p2.occurrence && p1.media == p2.media)
    }
    @Test func downloadRangesVerificationHistoryAndPreferences() throws {
        let a = try account(); let id = try sid()
        let range = try ByteRange(lower: 0, upper: 9)
        #expect(throws: DomainError.invalidInput(.invalidRange)) { try ByteRange(lower: 10, upper: 9) }
        #expect(throws: DomainError.invalidInput(.invalidRange)) { try DownloadJob(account: a, media: id, variant: id, ranges: [range, range], state: .running, size: 10, retries: 0, references: [], verification: .unknown) }
        #expect(throws: DomainError.invalidInput(.invalidRange)) { try DownloadJob(account: a, media: id, variant: id, ranges: [range], state: .running, size: 9, retries: 0, references: [], verification: .unknown) }
        #expect(throws: DomainError.invalidInput(.invalidTransition)) { try DownloadJob(account: a, media: id, variant: id, ranges: [range], state: .completed, size: 10, retries: 0, references: [], verification: .unknown) }
        let job = try DownloadJob(account: a, media: id, variant: id, ranges: [range], state: .completed, size: 10, retries: 1, references: [id], verification: .verified(hash: "synthetic", at: testWall))
        #expect(job.references.contains(id) && job.size == 10)
        #expect(throws: DomainError.invalidInput(.invalidRange)) { try HistoryEntry(account: a, item: id, startedAt: testWall, endedAt: testWall.addingTimeInterval(-1), provenance: .local, sync: .localOnly) }
        let history = try HistoryEntry(account: a, item: id, startedAt: testWall, endedAt: nil, provenance: .local, sync: .localOnly)
        #expect(history.provenance == .local && history.sync == .localOnly)
        let membership = LibraryMembership(account: a, entity: id, serviceStatus: nil, sync: .needsReconciliation, sortDate: nil, sortKey: "")
        #expect(membership.serviceStatus == nil && membership.sync == .needsReconciliation)
        let mutation = try PendingMutation(account: a, target: id, intent: .playlist(.remove([.synthetic(UUID())])), precondition: MutationPrecondition(providerVersion: nil, snapshotVersion: 1), outcome: .needsReconciliation)
        #expect(mutation.intent.requiredFeature == .playlistMutation && mutation.attempts == 0)
        #expect(throws: DomainError.invalidInput(.negativeValue)) { try ArtworkCacheEntry(sourceKey: id, width: 0, height: 1, policy: .noStore, contentHash: "", bytes: 0, lastUsedAt: testWall) }
        let artwork = try ArtworkCacheEntry(sourceKey: id, width: 10, height: 10, policy: .revalidate, contentHash: "synthetic", bytes: 100, lastUsedAt: testWall)
        #expect(artwork.policy == .revalidate)
        for scope in [PreferenceScope.global, .account(a), .window(UUID())] {
            let preferences = try Preferences(scope: scope, schemaVersion: 1, values: ["appearance": .text("system")])
            #expect(preferences.scope == scope && preferences.schemaVersion == 1)
        }
        #expect(throws: DomainError.invalidInput(.negativeValue)) { try Preferences(scope: .global, schemaVersion: 0, values: [:]) }
    }
}
