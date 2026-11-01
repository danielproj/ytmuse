import Foundation
import Network

/// One listener per attempt. Callback material stays in memory and is delivered
/// to the flow, which alone validates state, deadline and initiating generation.
/// All mutable state is confined to queue; close drains it before returning.
public protocol OAuthCallbackListener: OAuthLoopbackListener {
    var callbacks: AsyncStream<OAuthCallback> { get }
}
public final class NativeOAuthLoopback: OAuthCallbackListener, @unchecked Sendable {
    // Accessed exclusively on the listener queue, including state callbacks.
    private final class Binding: @unchecked Sendable { var waiting = true }
    private let queue = DispatchQueue(label: "local.native-music.oauth-loopback")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var port: UInt16?
    private var continuation: AsyncStream<OAuthCallback>.Continuation?
    public let callbacks: AsyncStream<OAuthCallback>

    public init() {
        let pair = AsyncStream<OAuthCallback>.makeStream(bufferingPolicy: .bufferingOldest(1))
        callbacks = pair.stream; continuation = pair.continuation
    }
    public func bind() async throws -> URL {
        try await withCheckedThrowingContinuation { result in
            queue.async { [self] in
                guard listener == nil, continuation != nil else { result.resume(throwing: DesktopOAuthError.busy); return }
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let server = try NWListener(using: parameters)
                    listener = server
                    let binding = Binding()
                    server.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            guard binding.waiting, let value = server.port?.rawValue else { return }
                            binding.waiting = false; self.port = value
                            server.stateUpdateHandler = nil
                            result.resume(returning: URL(string: "http://127.0.0.1:\(value)/oauth2callback")!)
                        case .failed, .cancelled:
                            server.stateUpdateHandler = nil
                            if binding.waiting { binding.waiting = false; result.resume(throwing: DesktopOAuthError.invalidCallback) }
                        default: break
                        }
                    }
                    server.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                    server.start(queue: queue)
                } catch { result.resume(throwing: DesktopOAuthError.invalidConfiguration) }
            }
        }
    }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 4 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.connections.removeValue(forKey: id)?.cancel()
        }
        receive(connection, id: id, data: Data())
    }
    private func receive(_ connection: NWConnection, id: UUID, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_385 - data.count) { [weak self] bytes, _, complete, error in
            guard let self, self.connections[id] != nil else { return }
            var accumulated = data; if let bytes { accumulated.append(bytes) }
            guard accumulated.count <= 16_384, error == nil else { self.connections.removeValue(forKey: id)?.cancel(); return }
            if accumulated.range(of: Data("\r\n\r\n".utf8)) != nil {
                let callback = self.port.flatMap { try? Self.parse(accumulated, port: $0) }
                if let callback { self.continuation?.yield(callback) }
                let response = Self.receiptResponse(parsed: callback != nil)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                self.connections.removeValue(forKey: id)
            } else if complete { self.connections.removeValue(forKey: id)?.cancel() }
            else { self.receive(connection, id: id, data: accumulated) }
        }
    }
    static let receiptBody = Data("<!doctype html><meta charset=utf-8><title>YTMuse callback</title><p>Callback received. Return to YTMuse for the actual authorization result.</p>".utf8)
    static func receiptResponse(parsed: Bool) -> Data {
        let body = parsed ? receiptBody : Data("<!doctype html><title>YTMuse callback</title><p>Request not accepted. Return to YTMuse.</p>".utf8)
        let status = parsed ? "200 OK" : "400 Bad Request"
        return Data("HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\n\r\n".utf8) + body
    }
    static func parse(_ data: Data, port: UInt16) throws -> OAuthCallback {
        guard data.count <= 16_384, let text = String(data: data, encoding: .utf8), text.hasSuffix("\r\n\r\n") else { throw DesktopOAuthError.invalidCallback }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[0] == "GET", first[2] == "HTTP/1.1", first[1].hasPrefix("/oauth2callback?"),
              !first[1].contains("#"), !first[1].contains("\\") else { throw DesktopOAuthError.invalidCallback }
        var hosts: [String] = []
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw DesktopOAuthError.invalidCallback }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard name != "transfer-encoding", name != "content-length" else { throw DesktopOAuthError.invalidCallback }
            if name == "host" { hosts.append(value) }
        }
        let host = "127.0.0.1:\(port)"
        guard hosts == [host], let url = URL(string: "http://\(host)\(first[1])"), url.path == "/oauth2callback" else { throw DesktopOAuthError.invalidCallback }
        return OAuthCallback(method: "GET", url: url, host: host)
    }
    public func close() async {
        await withCheckedContinuation { result in
            queue.async { [self] in
                listener?.cancel(); listener = nil; port = nil
                for connection in connections.values { connection.cancel() }
                connections.removeAll(); continuation?.finish(); continuation = nil
                result.resume()
            }
        }
    }
}
