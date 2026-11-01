import Foundation
import CryptoKit
import YouTubeMusicAdapter

/// Sanitized categories only. Never archive localized errors, URLs, queries or
/// arbitrary exception descriptions from network/framework errors.
func observationErrorCategory(_ error: any Error) -> String {
    if error is CancellationError { return "cancelled" }
    if let url = error as? URLError {
        switch url.code {
        case .timedOut: return "timeout"
        case .cancelled: return "cancelled"
        default: return "network"
        }
    }
    if let connection = error as? ConnectionError {
        switch connection {
        case .shape: return "shape"
        case .http: return "http"
        case .service: return "service"
        case .oversized: return "size"
        case .origin: return "origin"
        case .stale: return "stale"
        case .expired: return "expired"
        case .invalidInput: return "input"
        }
    }
    if error is DecodingError { return "shape" }
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain, ns.code == 3840 { return "shape" }
    return "unexpected"
}
func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// Pinned historical fixtures are never a destination. Every invocation gets a
/// fresh UUID directory, and every file uses exclusive creation. Record hashes
/// for the actual projections, separately from original provider-body hashes.
@discardableResult func saveObservation(root: URL, receipt: [String: Any], projections: [Data]) throws -> URL {
    let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var receipt = receipt
    var hashes: [[String: Any]] = []
    for (index, projection) in projections.enumerated() {
        let name = "projection-\(index).json"
        try projection.write(to: directory.appendingPathComponent(name), options: [.withoutOverwriting])
        hashes.append(["path": name, "bytes": projection.count, "sha256": sha256(projection)])
    }
    receipt["projections"] = hashes
    let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
    try data.write(to: directory.appendingPathComponent("receipt.json"), options: [.withoutOverwriting])
    return directory
}
