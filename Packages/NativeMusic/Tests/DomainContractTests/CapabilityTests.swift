import Domain
import Foundation
import Testing

@Suite("T02.1 Capability decisions") struct CapabilityTests {
    @Test func fiveStatesPreserveProvenanceAndSeparateUnknown() throws {
        let a = try account()
        let states: [CapabilityState] = [.supported, .restricted(.regionRestricted), .temporarilyUnavailable(.offline), .unknown, .failed(.malformedResponse)]
        let expected: [CapabilityDecision] = [.allowed, .denied(.regionRestricted), .retry(.offline), .verify(.capabilityUnknown), .retry(.malformedResponse)]
        for (state, decision) in zip(states, expected) {
            let value = try permission(a, state)
            #expect(value.decision(for: a, now: testWall) == decision)
            #expect(value.context.accountID == a.accountID && value.context.region == "US")
            #expect(value.source == "Synthetic W02 test provider")
            #expect(value.checkedAt == testWall && value.expiresAt == testWall.addingTimeInterval(60))
            #expect(value.decision(for: a, now: testWall.addingTimeInterval(60)) == .verify(.capabilityExpired))
            #expect(value.decision(for: a, now: testWall.addingTimeInterval(-1)) == .verify(.capabilityExpired))
            #expect(value.decision(for: try account(), now: testWall) == .verify(.staleContext))
        }
        let empty = try AccountCapabilities(context: a, features: [:])
        #expect(empty.decision(.offline, now: testWall) == .verify(.capabilityUnknown))
        #expect(throws: DomainError.capabilityUnknown) { try empty.require(.offline, now: testWall) }
        #expect(throws: DomainError.invalidInput(.contextMismatch)) { try AccountCapabilities(context: account(), features: [.playback: permission(a)]) }
    }
    @Test func fixtureGateRefusesLiveClassification() throws {
        let manifest = try FixtureManifest.load()
        #expect(!manifest.id.isEmpty && !manifest.label.isEmpty && !manifest.provenance.isEmpty)
        #expect(manifest.seeds.count >= 6)
        try manifest.require(layer: "fixture")
        try manifest.require(layer: "domain")
        #expect(throws: DomainError.forbidden) { try manifest.require(layer: "live-service") }
        #expect(throws: DomainError.forbidden) { try manifest.require(layer: "release") }
    }
    @Test func everyOriginUsesSameUnknownPermissionCheck() async throws {
        let context = request(try account()); let engine = TestEngine()
        let useCases = try commands(context, engine: engine, state: .unknown)
        for origin in CommandOrigin.allCases {
            let response = await useCases.execute(.select(media: try sid(), occurrence: UUID()), context: context, origin: origin)
            #expect(response.context == context)
            #expect(throws: DomainError.capabilityUnknown) { try response.outcome.get() }
        }
        #expect(await engine.recorded().allSatisfy { $0 == "stop" })
    }
}
