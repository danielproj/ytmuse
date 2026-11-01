import Darwin
import Foundation

// W39 app-level test support: a loopback-only HTTP client (it refuses any host but 127.0.0.1) and a polling wait.

enum LoopbackHTTP {
    struct Reply { let status: Int; let body: Data }
    static func get(port: UInt16, path: String) throws -> Reply? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { return nil }
        let request = Data("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
        request.withUnsafeBytes { _ = Darwin.send(descriptor, $0.baseAddress, request.count, 0) }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true { let count = recv(descriptor, &buffer, buffer.count, 0); if count <= 0 { break }; data.append(contentsOf: buffer[0..<count]) }
        guard let split = data.range(of: Data("\r\n\r\n".utf8)), let head = String(data: data[data.startIndex..<split.lowerBound], encoding: .utf8) else { return nil }
        let status = head.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
        return Reply(status: status, body: Data(data[split.upperBound...]))
    }
}

func waitUntil(_ seconds: Double = 3, _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
