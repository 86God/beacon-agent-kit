import XCTest
@testable import BeaconAgentCore

final class BeaconTimelineReducerTests: XCTestCase {
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
