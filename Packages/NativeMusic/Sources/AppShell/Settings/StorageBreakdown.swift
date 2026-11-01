import Artwork
import Domain
import Foundation

/// W27 (section 16: "Display storage breakdown by account and by pinned/automatic/cache data"; T27.3). The numbers come from the owners' own accounting and are
/// RECONCILED, not merely derived:
///  * each listed account's download bytes are read from its own ledger directory (the summary the budget itself sums);
///  * the bytes of ledger directories NO listed account owns are ENUMERATED from those directories (`usageOutside`), not computed as "total minus listed", so an account
///    that is under-counted is not silently absorbed into the unlisted line;
///  * the listed accounts plus that enumeration must equal the ledger's whole (stored, pinned and automatic separately), and the artwork rows plus the artwork the
///    roster does not own must equal the pipeline's whole disk counter;
///  * the ledger's stored bytes are compared with what the W14 encrypted object store actually holds on disk (`objectStoreBytes`), reported separately.
struct StorageBreakdown: Equatable {
    struct AccountRow: Equatable, Identifiable {
        let account: AccountContext
        let label: String
        var pinnedBytes: Int64
        var automaticBytes: Int64
        var cacheBytes: Int64
        /// Bytes of downloads not attributed to pinned or automatic (a file kept for a collection, or an unlisted remainder).
        var otherDownloadBytes: Int64
        var id: UUID { account.accountID }
        var totalBytes: Int64 { pinnedBytes + automaticBytes + otherDownloadBytes + cacheBytes }
    }
    var accounts: [AccountRow]
    /// Downloads in ledger directories the roster does not list (enumerated).
    var unlistedDownloads: AccountDownloadUsage
    /// Artwork cache bytes under owners the roster no longer lists: the pipeline's whole minus the listed rows (the pipeline offers no per-owner listing).
    var unattributedCacheBytes: Int64
    /// The owners' own whole-store figures.
    var ledgerTotals: AccountDownloadUsage
    var artworkDiskBytes: Int64
    /// What the W14 encrypted object store holds on disk.
    var objectStoreBytes: Int64

    var unattributedDownloadBytes: Int64 { unlistedDownloads.storedBytes }
    var totalPinned: Int64 { accounts.reduce(0) { $0 + $1.pinnedBytes } }
    var totalAutomatic: Int64 { accounts.reduce(0) { $0 + $1.automaticBytes } }
    var totalCache: Int64 { accounts.reduce(0) { $0 + $1.cacheBytes } + unattributedCacheBytes }
    var totalDownloads: Int64 { accounts.reduce(0) { $0 + $1.pinnedBytes + $1.automaticBytes + $1.otherDownloadBytes } + unlistedDownloads.storedBytes }
    var totalBytes: Int64 { totalDownloads + totalCache }

    /// The listed accounts and the enumerated unlisted directories add up to the ledger's whole, stored, pinned and automatic separately; and the artwork adds up.
    var reconciles: Bool {
        totalDownloads == ledgerTotals.storedBytes && totalPinned + unlistedDownloads.pinnedBytes == ledgerTotals.pinnedBytes
            && totalAutomatic + unlistedDownloads.automaticBytes == ledgerTotals.automaticBytes && totalCache == artworkDiskBytes
    }
    /// The ledger's stored bytes against the object store's files on disk. They measure the same thing from two sides.
    var objectStoreAgrees: Bool { objectStoreBytes == ledgerTotals.storedBytes - ledgerTotals.unlistedBytes }

    @MainActor static func make(accounts: [(account: AccountContext, label: String)],
                                usage: (AccountContext) async -> AccountDownloadUsage, unlisted: AccountDownloadUsage, ledgerTotals: AccountDownloadUsage,
                                cache: (AccountContext) async -> Int, artworkDiskBytes: Int, objectStoreBytes: Int64 = 0) async -> StorageBreakdown {
        var rows: [AccountRow] = []
        var listedCache: Int64 = 0
        for entry in accounts {
            let u = await usage(entry.account), c = Int64(await cache(entry.account))
            listedCache += c
            // The budget counts an unlisted remainder as pinned; the other bytes are stored minus pinned minus automatic.
            let other = max(0, u.storedBytes - u.pinnedBytes - u.automaticBytes)
            rows.append(AccountRow(account: entry.account, label: entry.label, pinnedBytes: u.pinnedBytes, automaticBytes: u.automaticBytes, cacheBytes: c, otherDownloadBytes: other))
        }
        return StorageBreakdown(accounts: rows, unlistedDownloads: unlisted, unattributedCacheBytes: max(0, Int64(artworkDiskBytes) - listedCache),
                                ledgerTotals: ledgerTotals, artworkDiskBytes: Int64(artworkDiskBytes), objectStoreBytes: objectStoreBytes)
    }
}
