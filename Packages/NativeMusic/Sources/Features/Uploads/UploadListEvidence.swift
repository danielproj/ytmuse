import AccountSession
import Foundation

/// What a re-read of an Uploads list proves about one upload. This is the only evidence that turns an unknown removal into "removed",
/// so it says "gone" only on positive grounds and "can't tell" otherwise.
public enum UploadListEvidence {
    /// `true`: the upload is still listed. `false`: the list was read completely, recognisably and signed-in, and no row is the upload.
    /// `nil`: the read cannot tell.
    ///
    /// A row is the upload if it carries the removal target's entity id **or** any stable identifier the original row had (item id, video
    /// id, page id), so a list whose rows lost their menus still shows the upload as listed. Absence is concluded only from a signed-in
    /// answer with rows, no further page, and no row the parser skipped or could not classify (it might be the upload).
    public static func stillListed(_ target: UploadRemovalModel.Target, in reply: MusicBrowseReply<MusicBrowsePage>) -> Bool? {
        guard reply.mode == .signedIn else { return nil }
        let page = reply.value
        let items = page.shelves.flatMap(\.items)
        let matches = items.contains { item in
            if let entity = item.uploadEntityID, entity == target.entityID { return true }
            return [item.id, item.videoID, item.browseID].compactMap { $0 }.contains { target.stableIDs.contains($0) }
        }
        if matches { return true }
        guard !items.isEmpty, !page.shelves.contains(where: { $0.continuation != nil }),
              page.accounting.skipped == 0, page.accounting.unsupported == 0 else { return nil }
        return false
    }
}
