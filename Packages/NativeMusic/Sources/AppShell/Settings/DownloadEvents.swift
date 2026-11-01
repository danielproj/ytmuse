import Domain
import Foundation
import SystemIntegration

/// W27 (Download/error notifications). Turns the download engine's snapshots into the few events worth telling the person about: an item that has just finished, an
/// item that has just failed. The first snapshot only seeds (what was already done or failed before is not news), a row is announced once, and nothing here reads or
/// shows anything but a title the person already sees and a fixed phrase.
struct DownloadEventDetector {
    private var seen: [UUID: DownloadPhase] = [:]
    private var seeded = false
    mutating func ingest(_ rows: [DownloadRowModel]) -> [StatusNotification] {
        defer { seeded = true; seen = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.phase) }) }
        guard seeded else { return [] }
        var events: [StatusNotification] = []
        for row in rows {
            let before = seen[row.id]
            if row.phase == .available, before != nil, before != .available, before != .renewing { events.append(.make(.downloadFinished, item: row.title)) }
            if row.phase == .failed, before != nil, before != .failed { events.append(.make(.downloadFailed, item: row.title)) }
        }
        return events
    }
}
