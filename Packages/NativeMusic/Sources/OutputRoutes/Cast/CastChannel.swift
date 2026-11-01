import Foundation

// W39. The seam between the Cast protocol and the network. `CastChannel` is one open, authenticated-by-TLS connection to one receiver (port 8009);
// the real one is `NWCastChannel`, which only the app composition constructs. Every test, and every isolated launch, gets a simulated receiver instead
// (`SimulatedCastReceiver`), so no automated run opens a socket to a device.

public enum CastChannelEvent: Sendable, Equatable {
    case message(CastMessage)
    /// The connection ended (the reason is a short, non-identifying phrase).
    case closed(String?)
}

public protocol CastChannel: AnyObject, Sendable {
    var events: AsyncStream<CastChannelEvent> { get }
    func send(_ message: CastMessage) async throws
    func close()
    /// The Mac's own IPv4 address on the interface this connection uses, and the receiver's. The relay binds to the first and serves only the second.
    var localAddress: String? { get }
    var remoteAddress: String? { get }
}

public protocol CastChannelFactory: Sendable {
    func open(_ device: CastDevice) async throws -> any CastChannel
}

/// The receivers currently visible, with the same observation shape as the output directory. Browsing starts only when `startBrowsing()` is called, and
/// the app calls it only when the person opens the picker (Local Network permission is never requested at launch).
public protocol CastDirectory: AnyObject, Sendable {
    func devices() -> [CastDevice]
    @MainActor func observe(_ onChange: @escaping @MainActor () -> Void) -> OutputObservation
    @MainActor func startBrowsing()
    @MainActor func stopBrowsing()
}

public enum CastError: Error, Equatable, Sendable {
    case notConnected, closed, timedOut
    case launchFailed(String?)
    case loadFailed(String?)
    case commandRefused(String?)
    case noMedia
    case superseded
    case networkNotPermitted
    case sourceNotCastable(String)
    case relayUnavailable(String)
}
