import AccountSession
@testable import Features
import Foundation
import Testing

/// The read-back that turns an unknown removal into "removed": gone only on positive grounds.
@MainActor @Suite struct UploadListEvidenceTests {
    private func target(entity: String = "t_po_target0001", video: String? = "devupsong01") -> UploadRemovalModel.Target {
        let item = MusicCatalogItem(kind: .song, title: "Home Recording", videoID: video, isUpload: true, uploadEntityID: entity)
        return UploadRemovalModel(remover: { _ in MusicWriteReply(outcome: .confirmed, accountGeneration: 0) }).target(for: item)!
    }
    private func row(_ title: String, video: String, entity: String?) -> MusicCatalogItem {
        MusicCatalogItem(kind: .song, title: title, videoID: video, isUpload: true, uploadEntityID: entity)
    }
    private func reply(_ items: [MusicCatalogItem], continuation: String? = nil, mode: MusicSearchReply.Mode = .signedIn, skipped: Int = 0, unsupported: Int = 0) -> MusicBrowseReply<MusicBrowsePage> {
        var accounting = MusicParseAccounting()
        accounting.items = items.count + skipped + unsupported; accounting.classified = items.count; accounting.skipped = skipped; accounting.unsupported = unsupported
        let shelf = MusicShelf(key: "k", title: nil, layout: .list, items: items, continuation: continuation)
        return MusicBrowseReply(value: MusicBrowsePage(shelves: [shelf], accounting: accounting), mode: mode, accountGeneration: 0)
    }

    @Test func aRowWithTheTargetsEntityIdIsStillListed() {
        #expect(UploadListEvidence.stillListed(target(), in: reply([row("Other", video: "devupsong09", entity: "x_other_00001"), row("Home Recording", video: "devupsong01", entity: "t_po_target0001")])) == true)
    }
    @Test func theSameUploadWithoutItsMenuIsStillListedNotRemoved() {
        // Rows that lost their menus (no entity id anywhere) but still name the same video: the upload is there.
        #expect(UploadListEvidence.stillListed(target(), in: reply([row("Home Recording", video: "devupsong01", entity: nil), row("Other", video: "devupsong09", entity: nil)])) == true)
    }
    @Test func aCompleteRecognisedListWithoutItIsGone() {
        #expect(UploadListEvidence.stillListed(target(), in: reply([row("Other", video: "devupsong09", entity: "x_other_00001")])) == false)
    }
    @Test func everythingElseCannotTell() {
        let others = [row("Other", video: "devupsong09", entity: "x_other_00001")]
        #expect(UploadListEvidence.stillListed(target(), in: reply(others, continuation: "more")) == nil, "a further page might hold it")
        #expect(UploadListEvidence.stillListed(target(), in: reply(others, mode: .anonymous)) == nil, "an anonymous answer says nothing about the account")
        #expect(UploadListEvidence.stillListed(target(), in: reply([])) == nil, "no rows: an empty list and an unreadable one look alike")
        #expect(UploadListEvidence.stillListed(target(), in: reply(others, skipped: 1)) == nil, "a row the parser skipped might be it")
        #expect(UploadListEvidence.stillListed(target(), in: reply(others, unsupported: 1)) == nil)
        // …but a match anywhere still wins over every doubt: it is positive evidence of presence.
        #expect(UploadListEvidence.stillListed(target(), in: reply(others + [row("Home Recording", video: "devupsong01", entity: nil)], continuation: "more", skipped: 1)) == true)
    }
}
