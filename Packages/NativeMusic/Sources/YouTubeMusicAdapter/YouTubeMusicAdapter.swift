// YouTubeMusicAdapter boundary. Behavior is implemented by its assigned harness node.
import Foundation
import Domain
import AccountSession

/// W27 (DIAG01). What Diagnostics reports as the adapter's version. Bump it with any change to a route, a request shape or a parser, so a support bundle says which
/// parser produced a failure. The captures the parsers are checked against live in the Fixtures folder.
public enum YouTubeMusicAdapterInfo {
    public static let version = "web-session-1"
}
