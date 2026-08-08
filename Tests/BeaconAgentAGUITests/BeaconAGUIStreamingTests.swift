import Foundation
import Testing
import BeaconAgentCore
@testable import BeaconAgentAGUI

struct BeaconAGUIStreamingTests {
    @Test
    func parsesSplitChunksCRLFLFMultilineDataAndIDs() throws {
        let source = Data(
            """
            id: 41\r
            retry: 1500\r
            data: {"schemaVersion":2,"eventId":"event-0",\r
            data: "runId":"run-1","sequence":0,"type":"run.started","payload":{}}\r
            \r
            data: {"schemaVersion":2,"eventId":"event-1","runId":"run-1","sequence":1,"type":"text.delta","payload":{"messageId":"message-1","delta":"  你好  "}}
            
            """.utf8
        )
        var parser = BeaconAGUISSEParser()
        var messages: [BeaconSSEMessage] = []
        let splitPoints = [1, 7, 23, 64, 113, source.count - 2]
        var start = 0
        for end in splitPoints + [source.count] where end > start {
            messages += try parser.append(source.subdata(in: start..<end))
            start = end
        }
        messages += try parser.finish()

        #expect(messages.count == 2)
        #expect(messages[0].id == "41")
        #expect(messages[0].retryMilliseconds == 1500)
        #expect(messages[0].data.contains("\n"))
        let event = try BeaconAGUIEventDecoder.decodeV2Event(messages[1].data)
        #expect(event.payload["delta"] == .string("  你好  "))
    }

    @Test
    func resumeCursorSkipsDuplicatesReportsGapsAndSetsReconnectHeader() throws {
        var cursor = BeaconAGUIResumeCursor()
        let event0 = event(id: "event-0", sequence: 0)
        let event1 = event(id: "event-1", sequence: 1)
        let event2 = event(id: "event-2", sequence: 2)

        #expect(try cursor.accept(event0, serverEventID: "server-0") == .accepted)
        #expect(try cursor.accept(event0, serverEventID: "server-0") == .duplicate)
        #expect(try cursor.accept(event2, serverEventID: "server-2") == .gap(expected: 1, received: 2))
        #expect(try cursor.accept(event1, serverEventID: "server-1") == .accepted)
        var request = URLRequest(url: URL(string: "https://example.com/v1/runs")!)
        cursor.apply(to: &request)

        #expect(request.value(forHTTPHeaderField: "Last-Event-ID") == "server-1")
        #expect(cursor.nextSequence == 2)
    }

    @Test
    func textDeltasPreserveMarkdownWhitespaceAndEqualFinalText() throws {
        let frames = """
        data: {"schemaVersion":2,"eventId":"text-0","runId":"run-text","sequence":0,"type":"text.start","payload":{"messageId":"message-1"}}

        data: {"schemaVersion":2,"eventId":"text-1","runId":"run-text","sequence":1,"type":"text.delta","payload":{"messageId":"message-1","delta":"## 标题\\n\\n"}}

        data: {"schemaVersion":2,"eventId":"text-2","runId":"run-text","sequence":2,"type":"text.delta","payload":{"messageId":"message-1","delta":"  缩进内容  "}}

        data: {"schemaVersion":2,"eventId":"text-3","runId":"run-text","sequence":3,"type":"text.end","payload":{"messageId":"message-1","finalText":"## 标题\\n\\n  缩进内容  "}}

        """
        var parser = BeaconAGUISSEParser()
        let messages = try parser.append(Data(frames.utf8)) + parser.finish()
        let events = try messages.map { try BeaconAGUIEventDecoder.decodeV2Event($0.data) }
        let deltas = events.compactMap { $0.payload.string("delta") }.joined()
        let finalText = events.compactMap { $0.payload.string("finalText") }.last

        #expect(deltas == "## 标题\n\n  缩进内容  ")
        #expect(deltas == finalText)
    }

    private func event(id: String, sequence: Int) -> BeaconAgentEventV2 {
        BeaconAgentEventV2(
            schemaVersion: 2,
            eventId: id,
            runId: "run-1",
            sequence: sequence,
            type: "activity.delta",
            payload: [:]
        )
    }
}

private extension Dictionary where Key == String, Value == BeaconJSONValue {
    func string(_ key: String) -> String? {
        guard case let .string(value)? = self[key] else { return nil }
        return value
    }
}
