import XCTest
@testable import BeaconAgentAGUI
@testable import BeaconAgentCore

final class BeaconAGUIEventDecoderTests: XCTestCase {
    func testDecodesNewlineDelimitedEventsAndSkipsBlankLines() throws {
        let data = """
        {"type":"run.started","id":"event-1","schemaVersion":1,"threadId":"thread-1","runId":"run-1"}

        {"type":"message.delta","id":"event-2","schemaVersion":1,"messageId":"message-1","role":"assistant","delta":"hi"}
        """.data(using: .utf8)!

        let events = try BeaconAGUIEventDecoder.decodeLines(data)

        XCTAssertEqual(events.map(\.type), ["run.started", "message.delta"])
    }

    func testDecoderRedactsUnsafeSummaries() throws {
        let data = """
        {"type":"tool.failed","id":"event-1","schemaVersion":1,"toolRunId":"tool-1","errorSummary":"phone 13800138000"}
        """.data(using: .utf8)!

        let events = try BeaconAGUIEventDecoder.decodeLines(data)

        if case let .toolFailed(event) = events.first {
            XCTAssertEqual(event.errorSummary, "phone [phone redacted]")
        } else {
            XCTFail("Expected tool failed event")
        }
    }
}
