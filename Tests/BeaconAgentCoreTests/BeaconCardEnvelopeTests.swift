import XCTest
@testable import BeaconAgentCore

final class BeaconCardEnvelopeTests: XCTestCase {
    func testCardEnvelopeKeepsGenericPayload() throws {
        let card = BeaconCardEnvelope(
            id: "card-1",
            kind: "reference.result",
            title: "Reference Result",
            subtitle: "1 match",
            status: .needsReview,
            confidence: 120,
            source: BeaconCardSource(type: .local, provider: nil, description: "Local cache"),
            privacy: BeaconCardPrivacy(requiresUserReview: true, containsRawMedia: false, containsHealthData: false, localOnly: true),
            accent: .system,
            payload: .json(type: "reference.result", value: .object(["count": .number(1)])),
            actions: [BeaconCardAction(id: "confirm", title: "Confirm", role: .primary)]
        )

        let data = try JSONEncoder().encode(card)
        let decoded = try JSONDecoder().decode(BeaconCardEnvelope.self, from: data)

        XCTAssertEqual(decoded.kind, "reference.result")
        XCTAssertEqual(decoded.confidence, 100)
        XCTAssertEqual(decoded.payload, .json(type: "reference.result", value: .object(["count": .number(1)])))
    }
}
