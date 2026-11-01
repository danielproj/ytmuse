import Foundation
import Synchronization

/// Issued synchronously at the UI event, before its Task can be queued behind an
/// account barrier. A permit cannot be forged or transferred between authorities.
struct OwnedStartRequest: Sendable {
    fileprivate let authority: UUID
    fileprivate let epoch: UInt64
    fileprivate let serial: UInt64
}
/// TH1 (rework 1): the latest LEGITIMATE request wins, and a request that is refused never takes part.
/// A permit is captured at the request (so an account barrier anywhere after it rejects it: `invalidate()` starts a new epoch), but it only becomes the
/// holder when the authority first ACCEPTS it, i.e. once the request was admitted and is really starting something. A request refused before that point
/// (a foreign or stale account, an item with nothing to play, a start already in progress or held for Play here) never reaches the authority, so it can
/// never cancel a legitimate start that is in flight. Before, `capture()` itself superseded every earlier permit, so a refused intent that happened to
/// capture later than a legitimate one made the legitimate start fail `staleContext`.
/// Among permits that are accepted, the later capture still wins: an older permit is refused once a newer one has been accepted.
final class OwnedStartGate: Sendable {
    private struct State { var epoch: UInt64 = 0; var serial: UInt64 = 0; var holder: UInt64 = 0 }
    private let id = UUID()
    private let state = Mutex(State())
    func capture() -> OwnedStartRequest {
        state.withLock { $0.serial += 1; return OwnedStartRequest(authority: id, epoch: $0.epoch, serial: $0.serial) }
    }
    func invalidate() { state.withLock { $0.epoch += 1; $0.holder = 0 } }
    func accepts(_ request: OwnedStartRequest) -> Bool {
        guard request.authority == id else { return false }
        return state.withLock { state in
            guard request.epoch == state.epoch, request.serial >= state.holder else { return false }
            state.holder = request.serial
            return true
        }
    }
}
