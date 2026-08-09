import XCTest
@testable import BeaconAgentCore

final class BeaconTimelineReducerTests: XCTestCase {
    func testV2AdapterStreamsRealToolAndTextLifecycleWithoutLeakingToolPayload() {
        let events = [
            v2(type: "text.start", payload: ["messageId": .string("message-1")]),
            v2(type: "text.delta", payload: ["messageId": .string("message-1"), "delta": .string("**正在")]),
            v2(type: "tool.start", payload: ["toolCallId": .string("tool-1"), "capabilityId": .string("profile.read")]),
            v2(type: "tool.result", payload: ["toolCallId": .string("tool-1"), "result": .object(["weightKilograms": .number(72)])]),
            v2(type: "text.end", payload: ["messageId": .string("message-1"), "finalText": .string("**正在读取档案**")])
        ]

        var state = BeaconTimelineState()
        for event in events {
            guard let timelineEvent = BeaconAgentEventV2Adapter.timelineEvent(from: event, toolTitle: { _ in "读取身体档案" }) else {
                return XCTFail("Expected timeline event")
            }
            state = BeaconTimelineReducer.reduce(state: state, event: timelineEvent)
        }

        XCTAssertEqual(state.messages.map(\.text), ["**正在读取档案**"])
        XCTAssertEqual(state.toolRuns.first?.title, "读取身体档案")
        XCTAssertEqual(state.toolRuns.first?.outputSummary, "本机数据已返回")
        XCTAssertFalse(state.toolRuns.first?.outputSummary?.contains("72") ?? true)
    }

    private func v2(
        type: String,
        payload: [String: BeaconJSONValue]
    ) -> BeaconAgentEventV2 {
        BeaconAgentEventV2(
            schemaVersion: 2,
            eventId: "run-1:\(type)",
            runId: "run-1",
            sequence: 0,
            type: type,
            payload: payload
        )
    }

    func testMessageDeltasAppendOneFinalMessageAndClearBuffer() {
        var state = BeaconTimelineState()

        state = BeaconTimelineReducer.reduce(
            state: state,
            event: .messageStarted(BeaconMessageStartedEvent(messageId: "message-1", role: .assistant))
        )
        state = BeaconTimelineReducer.reduce(
            state: state,
            event: .messageDelta(BeaconMessageDeltaEvent(messageId: "message-1", role: .assistant, delta: "Hello "))
        )
        state = BeaconTimelineReducer.reduce(
            state: state,
            event: .messageDelta(BeaconMessageDeltaEvent(messageId: "message-1", role: .assistant, delta: "world"))
        )
        state = BeaconTimelineReducer.reduce(
            state: state,
            event: .messageFinished(BeaconMessageFinishedEvent(messageId: "message-1", role: .assistant))
        )

        XCTAssertEqual(state.messages, [BeaconTimelineMessage(id: "message-1", role: .assistant, text: "Hello world")])
        XCTAssertTrue(state.activeMessageDeltas.isEmpty)
    }

    func testToolFinishedUpdatesExistingToolRun() {
        var state = BeaconTimelineState()

        state = BeaconTimelineReducer.reduce(
            state: state,
            event: .toolStarted(
                BeaconToolStartedEvent(
                    toolRunId: "tool-1",
                    toolName: "lookup",
                    title: "Lookup",
                    inputSummary: "Searching"
                )
            )
        )

        state = BeaconTimelineReducer.reduce(
            state: state,
            event: .toolFinished(
                BeaconToolFinishedEvent(
                    toolRunId: "tool-1",
                    outputSummary: "Found result"
                )
            )
        )

        XCTAssertEqual(state.toolRuns.count, 1)
        XCTAssertEqual(state.toolRuns[0].id, "tool-1")
        XCTAssertEqual(state.toolRuns[0].status, .succeeded)
        XCTAssertEqual(state.toolRuns[0].outputSummary, "Found result")
    }

    func testToolFailedPreservesFailedStatusAndErrorSummary() {
        var state = BeaconTimelineState()

        state = BeaconTimelineReducer.reduce(
            state: state,
            event: .toolStarted(
                BeaconToolStartedEvent(
                    toolRunId: "tool-1",
                    toolName: "lookup",
                    title: "Lookup",
                    inputSummary: "Searching"
                )
            )
        )
        state = BeaconTimelineReducer.reduce(
            state: state,
            event: .toolFailed(
                BeaconToolFailedEvent(
                    toolRunId: "tool-1",
                    errorSummary: "Gateway failed sk-1234567890abcdef1234567890"
                )
            )
        )

        XCTAssertEqual(state.toolRuns.count, 1)
        XCTAssertEqual(state.toolRuns[0].status, .failed)
        XCTAssertEqual(state.toolRuns[0].errorSummary, "Gateway failed [secret redacted]")
        XCTAssertEqual(state.toolRuns[0].summary, "Gateway failed [secret redacted]")
    }

    func testCardUpdatedReplacesCardWithSameId() {
        var state = BeaconTimelineState()
        let draft = BeaconCardEnvelope(
            id: "card-1",
            kind: "reference.result",
            title: "Draft",
            subtitle: "Needs review",
            status: .needsReview,
            source: BeaconCardSource(type: .local, description: "Local"),
            privacy: .localOnlyReview,
            accent: .system,
            payload: .text("Draft")
        )
        let updated = BeaconCardEnvelope(
            id: "card-1",
            kind: "reference.result",
            title: "Updated",
            subtitle: "Confirmed",
            status: .confirmed,
            source: BeaconCardSource(type: .local, description: "Local"),
            privacy: .localOnlyReview,
            accent: .system,
            payload: .text("Updated")
        )

        state = BeaconTimelineReducer.reduce(state: state, event: .cardCreated(BeaconCardCreatedEvent(card: draft)))
        state = BeaconTimelineReducer.reduce(state: state, event: .cardUpdated(BeaconCardUpdatedEvent(card: updated)))

        XCTAssertEqual(state.cards, [updated])
    }
}
