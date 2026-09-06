import Foundation
import Testing
@testable import BeaconAgentCore

@Suite
struct BeaconAgentProtocolNegotiationTests {
    @Test
    func sharedNegotiationCasesMatchExpectedResults() throws {
        let data = try Data(contentsOf: fixtureURL)
        let cases = try JSONDecoder().decode([NegotiationCase].self, from: data)

        for item in cases {
            let result = BeaconAgentProtocolNegotiator.negotiate(
                localSupported: item.localSupported,
                peerSupported: item.peerSupported,
                diagnosticId: item.diagnosticId
            )
            #expect(result == item.expected, "case: \(item.name)")
        }
    }

    @Test
    func replayErrorsMapToStablePublicFailures() {
        let unsupported = BeaconAgentReplayError.unsupportedSchemaVersion(3)
            .publicFailure(diagnosticId: "diag-schema")
        #expect(unsupported.code == "protocol.unsupported_schema_version")
        #expect(unsupported.retryable == false)
        #expect(unsupported.diagnosticId == "diag-schema")
        #expect(unsupported.requiredSchemaVersion == 3)

        let collision = BeaconAgentReplayError.eventCollision("private-event-id")
            .publicFailure(diagnosticId: "diag-collision")
        #expect(collision.code == "protocol.event_collision")
        #expect(collision.diagnosticId == "diag-collision")
        #expect(!String(describing: collision).contains("private-event-id"))

        let expectedCodes: [(BeaconAgentReplayError, String)] = [
            (.mixedRunIds, "protocol.mixed_run"),
            (.mixedTurnIds, "protocol.mixed_turn"),
            (.eventAfterTerminal(3), "protocol.event_after_terminal"),
            (.unsupportedCriticalEvent("future.required"), "protocol.unsupported_critical_event"),
            (.unsupportedPatch, "protocol.unsupported_patch"),
            (.malformedPayload("private payload"), "protocol.invalid_event")
        ]
        for (error, expectedCode) in expectedCodes {
            let failure = error.publicFailure(diagnosticId: "diag-shared-error")
            #expect(failure.code == expectedCode)
            #expect(!String(describing: failure).contains("private"))
        }
    }

    @Test
    func sharedWireFailuresMatchStablePublicFailures() throws {
        let data = try Data(contentsOf: publicFailureFixtureURL)
        let cases = try JSONDecoder().decode([PublicFailureCase].self, from: data)

        for item in cases {
            var state = BeaconAgentStateV2()
            var captured: BeaconAgentReplayError?
            do {
                for event in item.events {
                    try state.ingest(event)
                }
            } catch let error as BeaconAgentReplayError {
                captured = error
            }

            let failure = captured?.publicFailure(
                diagnosticId: item.expectedFailure.diagnosticId
            )
            #expect(failure == item.expectedFailure, "case: \(item.name)")
        }
    }

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("contracts/fixtures/protocol-negotiation-cases.json")
    }

    private var publicFailureFixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("contracts/fixtures/public-failure-cases.json")
    }
}

private struct NegotiationCase: Decodable {
    let name: String
    let localSupported: [Int]
    let peerSupported: [Int]
    let diagnosticId: String
    let expected: BeaconAgentProtocolNegotiationResult
}

private struct PublicFailureCase: Decodable {
    let name: String
    let events: [BeaconAgentEventV2]
    let expectedFailure: BeaconAgentProtocolFailureV2
}
