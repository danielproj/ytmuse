import AccountSession
import Foundation
import Testing
@testable import YouTubeMusicAdapter

private func radioFixture() throws -> Data {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    return try Data(contentsOf: root.appendingPathComponent("Fixtures/R1-real/next-radio.json"))
}
private actor RadioWire: SignedMusicTransport, PublicHTTPTransport {
    var sent: [(URLRequest, Int)] = []
    let data: Data
    init(_ data: Data) { self.data = data }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> SignedMusicWireResponse {
        try SignedMusicPolicy.validate(request, maximumBytes: maximumBytes)
        sent.append((request, maximumBytes))
        return .init(status: 200, body: data, contentType: "application/json")
    }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> PublicHTTPResponse {
        sent.append((request, maximumBytes))
        if request.url?.path == "/" {
            return .init(data: Data(#"{"INNERTUBE_CLIENT_VERSION":"1.20261103.01.00","clientName":"WEB_REMIX"}"#.utf8), status: 200)
        }
        return .init(data: data, status: 200)
    }
    func requests() -> [(URLRequest, Int)] { sent }
}
@Suite struct RadioQueueReadTests {
    private let action = MusicRadioAction(playlistID: "RDAMVMkhnokW3Mw24", videoID: "khnokW3Mw24", params: "published%3D")
    @Test func signedAndAnonymousReadsUseBoundedNextAndExactPublishedParameters() async throws {
        for signed in [true, false] {
            let wire = RadioWire(try radioFixture())
            let publicClient = try PublicMusicClient(transport: wire)
            let client = SignedMusicClient(transport: wire, clock: FixedWallClock(), anonymous: publicClient) { "1.20261103.01.00" }
            let result = try await client.radioQueue(action: action, session: signed ? syntheticSession() : nil)
            #expect(result.value.chips.count == 13)
            let sent = await wire.requests()
            #expect(sent.count == (signed ? 1 : 2))
            let (request, cap) = try #require(sent.last)
            #expect(request.url?.absoluteString == "https://music.youtube.com/youtubei/v1/next?prettyPrint=false")
            #expect(cap == 4_000_000 && request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "User-Agent") != nil)
            #expect((request.value(forHTTPHeaderField: "Cookie") != nil) == signed)
            #expect((request.value(forHTTPHeaderField: "Authorization") != nil) == signed)
            let bytes = try #require(request.httpBody)
            let body = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            #expect(body["playlistId"] as? String == action.playlistID && body["params"] as? String == action.params)
            #expect(body["videoId"] as? String == action.videoID && body["tunerSettingValue"] == nil)
        }
    }
    @Test func malformedBodyIsNotASuccessfulEmptyQueue() async throws {
        let wire = RadioWire(Data("{}".utf8))
        let client = SignedMusicClient(transport: wire, clock: FixedWallClock()) { "1.20261103.01.00" }
        await #expect(throws: MusicSessionError.unrecognised) { try await client.radioQueue(action: action, session: syntheticSession()) }
    }
}
