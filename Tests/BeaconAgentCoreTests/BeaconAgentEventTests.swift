import XCTest
@testable import BeaconAgentCore

final class BeaconAgentEventTests: XCTestCase {
    func testDecodesRunStartedEvent() throws {
        let json = """
        {
          "type": "run.started",
          "id": "event-1",
          "schemaVersion": 1,
          "threadId": "thread-1",
          "runId": "run-1",
          "createdAt": "2026-06-22T12:00:00Z"
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(BeaconAgentEvent.self, from: json)

        XCTAssertEqual(event.type, "run.started")
        XCTAssertEqual(event.id, "event-1")
        XCTAssertEqual(event.schemaVersion, 1)
    }

    func testEncodesMessageDeltaType() throws {
        let event = BeaconAgentEvent.messageDelta(
            BeaconMessageDeltaEvent(
                id: "event-2",
                messageId: "message-1",
                role: .assistant,
                delta: "Hello"
            )
        )

        let data = try JSONEncoder().encode(event)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(object?["type"] as? String, "message.delta")
    }

    func testDecodesUnknownEventAsCustom() throws {
        let json = """
        {
          "type": "vendor.extra",
          "id": "event-3",
          "schemaVersion": 7,
          "name": "vendor.extra",
          "summary": "Custom summary"
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(BeaconAgentEvent.self, from: json)

        XCTAssertEqual(event.type, "vendor.extra")
        XCTAssertEqual(event.schemaVersion, 7)
        if case let .custom(custom) = event {
            XCTAssertEqual(custom.name, "vendor.extra")
            XCTAssertEqual(custom.summary, "Custom summary")
        } else {
            XCTFail("Expected custom event")
        }
    }
}
