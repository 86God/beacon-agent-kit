import Foundation
import Testing
@testable import BeaconAgentCore

struct BeaconAgentV2ConformanceTests {
    @Test
    func tomorrowFixtureMatchesCanonicalTerminalJSON() throws {
        let events = try loadEvents("tomorrow-training-run.jsonl")
        var state = BeaconAgentStateV2()
        for event in events {
            try state.ingest(event)
        }

        let expected = try String(
            contentsOf: fixtureDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("expected/tomorrow-training-run.normalized.json"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(try state.normalizedJSON() == expected)
    }

    @Test
    func sequenceGapsBufferAndDrainDeterministically() throws {
        let events = try loadEvents("tomorrow-training-run.jsonl")
        var ordered = BeaconAgentStateV2()
        for event in events {
            try ordered.ingest(event)
        }

        var reordered = BeaconAgentStateV2()
        for index in [0, 2, 4, 1, 3] + Array(5..<events.count) {
            try reordered.ingest(events[index])
        }

        #expect(try reordered.normalizedJSON() == ordered.normalizedJSON())
    }

    @Test
    func identicalDuplicateIsIdempotent() throws {
        let events = try loadEvents("surface-stream.jsonl")
        var state = BeaconAgentStateV2()
        try state.ingest(events[0])
        try state.ingest(events[1])
        try state.ingest(events[1])
        for event in events.dropFirst(2) {
            try state.ingest(event)
        }

        #expect(state.nextSequence == events.count)
    }

    @Test
    func conflictingDuplicateFailsClosed() throws {
        let events = try loadEvents("surface-stream.jsonl")
        let collisionData = Data(
            """
            {"schemaVersion":2,"eventId":"surface-0","runId":"run-surface","sequence":0,"type":"run.started","payload":{"unexpected":true}}
            """.utf8
        )
        let collision = try JSONDecoder().decode(BeaconAgentEventV2.self, from: collisionData)
        var state = BeaconAgentStateV2()
        try state.ingest(events[0])

        #expect(throws: BeaconAgentReplayError.self) {
            try state.ingest(collision)
        }
    }

    @Test
    func terminalStateRejectsLateEventsWithoutChangingProjection() throws {
        var state = BeaconAgentStateV2()
        let terminal = BeaconAgentEventV2(
            schemaVersion: 2,
            eventId: "terminal-0",
            runId: "run-terminal",
            sequence: 0,
            type: "run.error",
            payload: ["message": .string("请重试")]
        )
        try state.ingest(terminal)
        let terminalProjection = try state.normalizedJSON()

        try state.ingest(terminal)
        #expect(try state.normalizedJSON() == terminalProjection)

        let lateText = BeaconAgentEventV2(
            schemaVersion: 2,
            eventId: "late-1",
            runId: "run-terminal",
            sequence: 1,
            type: "text.start",
            payload: ["messageId": .string("late-message")]
        )
        #expect(throws: BeaconAgentReplayError.self) {
            try state.ingest(lateText)
        }
        #expect(try state.normalizedJSON() == terminalProjection)
    }

    @Test
    func bufferedEventsAfterTerminalSequenceAreDiscarded() throws {
        var state = BeaconAgentStateV2()
        try state.ingest(
            BeaconAgentEventV2(
                schemaVersion: 2,
                eventId: "run-0",
                runId: "run-buffered-terminal",
                sequence: 0,
                type: "run.started",
                payload: [:]
            )
        )
        let lateText = BeaconAgentEventV2(
            schemaVersion: 2,
            eventId: "late-2",
            runId: "run-buffered-terminal",
            sequence: 2,
            type: "text.start",
            payload: ["messageId": .string("late-message")]
        )
        try state.ingest(lateText)
        try state.ingest(
            BeaconAgentEventV2(
                schemaVersion: 2,
                eventId: "terminal-1",
                runId: "run-buffered-terminal",
                sequence: 1,
                type: "run.finished",
                payload: [:]
            )
        )

        #expect(state.nextSequence == 2)
        #expect(!(try state.normalizedJSON()).contains("late-message"))
        #expect(throws: BeaconAgentReplayError.self) {
            try state.ingest(lateText)
        }
    }

    @Test
    func interruptedSegmentCanResumeUntilRunFinishes() throws {
        let events = try loadEvents("tool-interrupt-resume.jsonl")
        var state = BeaconAgentStateV2()
        for event in events {
            try state.ingest(event)
        }

        #expect(state.nextSequence == events.count)
        #expect(try state.normalizedJSON().contains("\"status\":\"finished\""))
    }

    @Test
    func unsupportedSchemaVersionFailsBeforeProjectionChanges() throws {
        var state = BeaconAgentStateV2()
        let unsupported = BeaconAgentEventV2(
            schemaVersion: 3,
            eventId: "future-0",
            runId: "run-future",
            sequence: 0,
            type: "run.started",
            payload: [:]
        )

        #expect(throws: BeaconAgentReplayError.self) {
            try state.ingest(unsupported)
        }
        #expect(state.nextSequence == 0)
        #expect(try state.normalizedJSON().contains("\"status\":\"idle\""))
    }

    @Test
    func wireFieldsRejectBlankAndOversizedUTF8BeforeProjectionChanges() throws {
        var state = BeaconAgentStateV2()
        let oversizedEmojiIdentifier = String(repeating: "🧭", count: 65)
        let invalidEvents = [
            BeaconAgentEventV2(
                schemaVersion: 2,
                eventId: " ",
                runId: "run-bounds",
                sequence: 0,
                type: "run.started",
                payload: [:]
            ),
            BeaconAgentEventV2(
                schemaVersion: 2,
                eventId: oversizedEmojiIdentifier,
                runId: "run-bounds",
                sequence: 0,
                type: "run.started",
                payload: [:]
            ),
            BeaconAgentEventV2(
                schemaVersion: 2,
                eventId: "event-0",
                runId: "\n",
                sequence: 0,
                type: "run.started",
                payload: [:]
            ),
            BeaconAgentEventV2(
                schemaVersion: 2,
                eventId: "\u{200B}",
                runId: "run-bounds",
                sequence: 0,
                type: "run.started",
                payload: [:]
            ),
            BeaconAgentEventV2(
                schemaVersion: 2,
                eventId: "\u{001C}",
                runId: "run-bounds",
                sequence: 0,
                type: "run.started",
                payload: [:]
            ),
            BeaconAgentEventV2(
                schemaVersion: 2,
                eventId: "event-0",
                runId: "run-bounds",
                sequence: 0,
                type: " ",
                payload: [:]
            )
        ]

        for event in invalidEvents {
            #expect(throws: BeaconAgentReplayError.self) {
                try state.ingest(event)
            }
            #expect(state.nextSequence == 0)
            #expect(try state.normalizedJSON().contains("\"status\":\"idle\""))
        }
    }

    @Test
    func wireFieldsAcceptMultibyteIdentifierAtUTF8Boundary() throws {
        let boundaryIdentifier = String(repeating: "🧭", count: 64)
        var state = BeaconAgentStateV2()

        try state.ingest(
            BeaconAgentEventV2(
                schemaVersion: 2,
                eventId: boundaryIdentifier,
                runId: boundaryIdentifier,
                sequence: 0,
                type: "run.started",
                payload: [:]
            )
        )

        #expect(state.nextSequence == 1)
        #expect(state.status == "running")
    }

    @Test
    func oversizedPayloadFailsBeforeProjectionChanges() throws {
        var state = BeaconAgentStateV2()
        let event = BeaconAgentEventV2(
            schemaVersion: 2,
            eventId: "event-large",
            runId: "run-large",
            sequence: 0,
            type: "text.delta",
            payload: [
                "messageId": .string("message-large"),
                "delta": .string(String(repeating: "x", count: 262_144))
            ]
        )

        #expect(throws: BeaconAgentReplayError.self) {
            try state.ingest(event)
        }
        #expect(state.nextSequence == 0)
        #expect(try state.normalizedJSON().contains("\"text\":{}"))
    }

    @Test
    func payloadAtExactUTF8BoundaryIsAccepted() throws {
        var state = BeaconAgentStateV2()
        let exactBoundaryPayload = String(repeating: "x", count: 262_132)

        try state.ingest(
            BeaconAgentEventV2(
                schemaVersion: 2,
                eventId: "event-boundary",
                runId: "run-boundary",
                sequence: 0,
                type: "run.started",
                payload: ["delta": .string(exactBoundaryPayload)]
            )
        )

        #expect(state.nextSequence == 1)
        #expect(state.status == "running")
    }

    @Test
    func numericHeavyPayloadUsesSharedStructuralBudget() throws {
        var state = BeaconAgentStateV2()
        let event = BeaconAgentEventV2(
            schemaVersion: 2,
            eventId: "event-numeric-heavy",
            runId: "run-numeric-heavy",
            sequence: 0,
            type: "run.started",
            payload: [
                "values": .array(Array(repeating: .number(1), count: 70_000))
            ]
        )

        #expect(throws: BeaconAgentReplayError.self) {
            try state.ingest(event)
        }
        #expect(state.nextSequence == 0)
    }

    @Test
    func sharedMobileContractPublishesWireBounds() throws {
        let contractURL = fixtureDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("contracts/mobile-agent-contract.json")
        #expect(FileManager.default.fileExists(atPath: contractURL.path))
        guard FileManager.default.fileExists(atPath: contractURL.path) else { return }
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: contractURL)) as? [String: Any]
        )
        let wireLimits = try #require(object["wireLimits"] as? [String: Int])

        #expect(wireLimits["identifierMaxCharacters"] == 128)
        #expect(wireLimits["identifierMaxUTF8Bytes"] == 256)
        #expect(wireLimits["eventTypeMaxCharacters"] == 96)
        #expect(wireLimits["eventTypeMaxUTF8Bytes"] == 384)
        #expect(wireLimits["payloadMaxBytes"] == 262_144)
        let characterCounting = try #require(object["characterCounting"] as? [String: Any])
        let blankCodePoints = try #require(characterCounting["blankCodePoints"] as? [String])
        let payloadSizing = try #require(object["payloadSizing"] as? [String: Any])
        let optionalEnvelopeFields = try #require(object["optionalEnvelopeFields"] as? [String])
        let identifierSemantics = try #require(object["identifierSemantics"] as? [String: String])
        let runStatusValues = try #require(object["runStatusValues"] as? [String])
        let resultKindValues = try #require(object["resultKindValues"] as? [String])
        let diagnosticFields = try #require(object["diagnosticFields"] as? [String])
        let criticalEventSemantics = try #require(object["criticalEventSemantics"] as? [String: String])
        let segmentStates = try #require(object["segmentStates"] as? [String])
        let terminalStates = try #require(object["terminalStates"] as? [String])

        #expect(blankCodePoints.contains("001C-0020"))
        #expect(blankCodePoints.contains("2000-200B"))
        #expect(payloadSizing["algorithm"] as? String == "decoded-json-structural-budget-v1")
        #expect(payloadSizing["numberBytes"] as? Int == 32)
        #expect(optionalEnvelopeFields == ["turnId", "attemptId", "segmentId"])
        #expect(identifierSemantics["toolCallId"]?.hasPrefix("payload_identifier") == true)
        #expect(identifierSemantics["commandId"]?.hasPrefix("payload_identifier") == true)
        #expect(runStatusValues.contains("waiting_device"))
        #expect(runStatusValues.contains("waiting_approval"))
        #expect(runStatusValues.contains("permission_denied"))
        #expect(resultKindValues == ["success", "empty", "text_fallback"])
        #expect(diagnosticFields == ["code", "retryable", "diagnosticId"])
        #expect(criticalEventSemantics["marker"] == "payload.critical=true")
        #expect(segmentStates.contains("device.waiting"))
        #expect(terminalStates.contains("permission.denied"))
    }

    @Test
    func executionIdentityFixtureMatchesSharedGoldenJSON() throws {
        var state = BeaconAgentStateV2()
        for event in try loadContractEvents("execution-identity-run.jsonl") {
            try state.ingest(event)
        }
        let expected = try String(
            contentsOf: contractFixtureDirectory
                .appendingPathComponent("execution-identity-run.normalized.json"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(try state.normalizedJSON() == expected)
    }

    @Test(arguments: ["success-run", "empty-query-run", "text-fallback-run", "permission-denied-run"])
    func publicOutcomeFixtureMatchesSharedGoldenJSON(_ fixtureName: String) throws {
        var state = BeaconAgentStateV2()
        for event in try loadContractEvents("\(fixtureName).jsonl") {
            try state.ingest(event)
        }
        let expected = try String(
            contentsOf: contractFixtureDirectory
                .appendingPathComponent("\(fixtureName).normalized.json"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(try state.normalizedJSON() == expected)
    }

    @Test
    func waitingStatesAreExplicitAndResumeWithoutBecomingTerminal() throws {
        var state = BeaconAgentStateV2()
        try state.ingest(
            BeaconAgentEventV2(
                schemaVersion: 2,
                eventId: "waiting-0",
                runId: "run-waiting",
                sequence: 0,
                type: "run.started",
                payload: [:]
            )
        )
        try state.ingest(
            BeaconAgentEventV2(
                schemaVersion: 2,
                eventId: "waiting-1",
                runId: "run-waiting",
                sequence: 1,
                type: "device.waiting",
                payload: [
                    "code": .string("device.unavailable"),
                    "retryable": .bool(true),
                    "diagnosticId": .string("diag-waiting-1")
                ]
            )
        )
        #expect(state.status == "waiting_device")

        try state.ingest(
            BeaconAgentEventV2(
                schemaVersion: 2,
                eventId: "waiting-2",
                runId: "run-waiting",
                sequence: 2,
                type: "run.started",
                payload: [:]
            )
        )
        #expect(state.status == "running")
        try state.ingest(
            BeaconAgentEventV2(
                schemaVersion: 2,
                eventId: "waiting-3",
                runId: "run-waiting",
                sequence: 3,
                type: "approval.requested",
                payload: ["approvalId": .string("approval-waiting")]
            )
        )
        #expect(state.status == "waiting_approval")
    }

    @Test
    func malformedDiagnosticGroupFailsAtomically() throws {
        var state = BeaconAgentStateV2()
        let before = try state.normalizedJSON()

        #expect(throws: BeaconAgentReplayError.self) {
            try state.ingest(
                BeaconAgentEventV2(
                    schemaVersion: 2,
                    eventId: "diagnostic-invalid",
                    runId: "run-diagnostic",
                    sequence: 0,
                    type: "permission.denied",
                    payload: [
                        "code": .string("device.permission_denied"),
                        "retryable": .bool(false)
                    ]
                )
            )
        }
        #expect(try state.normalizedJSON() == before)
    }

    @Test
    func legacyRunErrorWithCodeAndSummaryRemainsCompatible() throws {
        var state = BeaconAgentStateV2()
        try state.ingest(
            BeaconAgentEventV2(
                schemaVersion: 2,
                eventId: "legacy-error-0",
                runId: "run-legacy-error",
                sequence: 0,
                type: "run.error",
                payload: [
                    "code": .string("provider_error"),
                    "summary": .string("retry later")
                ]
            )
        )

        #expect(state.status == "error")
        #expect(state.nextSequence == 1)
        #expect(!(try state.normalizedJSON()).contains("\"failure\""))
    }

    @Test(arguments: [
        BeaconJSONValue.null,
        BeaconJSONValue.number(1),
        BeaconJSONValue.bool(true),
        BeaconJSONValue.object([:])
    ])
    func wrongTypedResultKindFailsAtomically(_ resultKind: BeaconJSONValue) throws {
        var state = BeaconAgentStateV2()
        let before = try state.normalizedJSON()

        #expect(throws: BeaconAgentReplayError.self) {
            try state.ingest(
                BeaconAgentEventV2(
                    schemaVersion: 2,
                    eventId: "result-kind-invalid",
                    runId: "run-result-kind-invalid",
                    sequence: 0,
                    type: "run.finished",
                    payload: ["resultKind": resultKind]
                )
            )
        }
        #expect(try state.normalizedJSON() == before)
    }

    @Test
    func unknownCriticalEventFailsWithoutChangingProjection() throws {
        var state = BeaconAgentStateV2()
        let before = try state.normalizedJSON()

        #expect(throws: BeaconAgentReplayError.self) {
            try state.ingest(
                BeaconAgentEventV2(
                    schemaVersion: 2,
                    eventId: "critical-0",
                    runId: "run-critical",
                    sequence: 0,
                    type: "future.command.required",
                    payload: [
                        "critical": .bool(true),
                        "requiredSchemaVersion": .number(3)
                    ]
                )
            )
        }
        #expect(try state.normalizedJSON() == before)
    }

    @Test
    func blankExecutionIdentityFailsBeforeProjectionChanges() throws {
        let document = """
        {"schemaVersion":2,"eventId":"identity-invalid","runId":"run-identity","turnId":"\u{200B}","attemptId":"attempt-1","segmentId":"segment-1","sequence":0,"type":"run.started","payload":{}}
        """
        let event = try JSONDecoder().decode(BeaconAgentEventV2.self, from: Data(document.utf8))
        var state = BeaconAgentStateV2()

        #expect(throws: BeaconAgentReplayError.self) {
            try state.ingest(event)
        }
        #expect(state.nextSequence == 0)
    }

    @Test
    func mixedTurnIdentityFailsWithoutChangingProjection() throws {
        var state = BeaconAgentStateV2()
        try state.ingest(
            BeaconAgentEventV2(
                schemaVersion: 2,
                eventId: "identity-turn-a",
                runId: "run-identity",
                turnId: "turn-a",
                attemptId: "attempt-1",
                segmentId: "segment-1",
                sequence: 0,
                type: "run.started",
                payload: [:]
            )
        )
        let validProjection = try state.normalizedJSON()

        #expect(throws: BeaconAgentReplayError.self) {
            try state.ingest(
                BeaconAgentEventV2(
                    schemaVersion: 2,
                    eventId: "identity-turn-b",
                    runId: "run-identity",
                    turnId: "turn-b",
                    attemptId: "attempt-1",
                    segmentId: "segment-1",
                    sequence: 1,
                    type: "step.started",
                    payload: [:]
                )
            )
        }
        #expect(try state.normalizedJSON() == validProjection)
    }

    @Test
    func outOfOrderIdentityConflictFailsWithoutChangingBufferedProjection() throws {
        var state = BeaconAgentStateV2()
        try state.ingest(
            BeaconAgentEventV2(
                schemaVersion: 2,
                eventId: "identity-late",
                runId: "run-a",
                turnId: "turn-a",
                sequence: 1,
                type: "step.started",
                payload: [:]
            )
        )
        let bufferedProjection = try state.normalizedJSON()

        #expect(throws: BeaconAgentReplayError.self) {
            try state.ingest(
                BeaconAgentEventV2(
                    schemaVersion: 2,
                    eventId: "identity-first",
                    runId: "run-b",
                    turnId: "turn-b",
                    sequence: 0,
                    type: "run.started",
                    payload: [:]
                )
            )
        }
        #expect(try state.normalizedJSON() == bufferedProjection)
    }

    @Test
    func malformedEventRollsBackIdentityAndDuplicateBookkeeping() throws {
        var state = BeaconAgentStateV2()
        try state.ingest(
            BeaconAgentEventV2(
                schemaVersion: 2,
                eventId: "identity-start",
                runId: "run-atomic",
                turnId: "turn-atomic",
                attemptId: "attempt-1",
                segmentId: "segment-1",
                sequence: 0,
                type: "run.started",
                payload: [:]
            )
        )
        let validProjection = try state.normalizedJSON()
        let malformed = BeaconAgentEventV2(
            schemaVersion: 2,
            eventId: "identity-delta",
            runId: "run-atomic",
            turnId: "turn-atomic",
            attemptId: "attempt-2",
            segmentId: "segment-2",
            sequence: 1,
            type: "text.delta",
            payload: ["delta": .string("hello")]
        )

        #expect(throws: BeaconAgentReplayError.self) {
            try state.ingest(malformed)
        }
        #expect(try state.normalizedJSON() == validProjection)

        try state.ingest(
            BeaconAgentEventV2(
                schemaVersion: 2,
                eventId: "identity-delta",
                runId: "run-atomic",
                turnId: "turn-atomic",
                attemptId: "attempt-2",
                segmentId: "segment-2",
                sequence: 1,
                type: "text.delta",
                payload: [
                    "messageId": .string("message-atomic"),
                    "delta": .string("hello")
                ]
            )
        )
        #expect(state.attemptId == "attempt-2")
        #expect(state.segmentId == "segment-2")
        #expect(try state.normalizedJSON().contains("message-atomic"))
    }

    @Test
    func bufferedMalformedEventIsEvictedWhenGapCloses() throws {
        var state = BeaconAgentStateV2()
        try state.ingest(
            BeaconAgentEventV2(
                schemaVersion: 2,
                eventId: "buffered-delta",
                runId: "run-buffered-invalid",
                turnId: "turn-buffered-invalid",
                attemptId: "attempt-2",
                segmentId: "segment-2",
                sequence: 1,
                type: "text.delta",
                payload: ["delta": .string("hello")]
            )
        )

        #expect(throws: BeaconAgentReplayError.self) {
            try state.ingest(
                BeaconAgentEventV2(
                    schemaVersion: 2,
                    eventId: "buffered-start",
                    runId: "run-buffered-invalid",
                    turnId: "turn-buffered-invalid",
                    attemptId: "attempt-1",
                    segmentId: "segment-1",
                    sequence: 0,
                    type: "run.started",
                    payload: [:]
                )
            )
        }

        #expect(state.nextSequence == 1)
        #expect(state.attemptId == "attempt-1")
        #expect(state.segmentId == "segment-1")
        #expect(!(try state.normalizedJSON()).contains("\"bufferedSequences\":[1]"))

        try state.ingest(
            BeaconAgentEventV2(
                schemaVersion: 2,
                eventId: "buffered-delta",
                runId: "run-buffered-invalid",
                turnId: "turn-buffered-invalid",
                attemptId: "attempt-2",
                segmentId: "segment-2",
                sequence: 1,
                type: "text.delta",
                payload: [
                    "messageId": .string("message-buffered-invalid"),
                    "delta": .string("hello")
                ]
            )
        )
        #expect(state.nextSequence == 2)
        #expect(try state.normalizedJSON().contains("message-buffered-invalid"))
    }

    @Test
    func decoderRejectsUnknownTopLevelEnvelopeFields() throws {
        let document = """
        {"schemaVersion":2,"eventId":"strict-0","runId":"run-strict","sequence":0,"type":"tool.start","toolCallId":"wrong-layer","payload":{"toolCallId":"tool-1"}}
        """

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(BeaconAgentEventV2.self, from: Data(document.utf8))
        }
    }

    private var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("conformance/fixtures", isDirectory: true)
    }

    private var contractFixtureDirectory: URL {
        fixtureDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("contracts/fixtures", isDirectory: true)
    }

    private func loadEvents(_ name: String) throws -> [BeaconAgentEventV2] {
        let text = try String(
            contentsOf: fixtureDirectory.appendingPathComponent(name),
            encoding: .utf8
        )
        return try text
            .split(whereSeparator: \.isNewline)
            .map { try JSONDecoder().decode(BeaconAgentEventV2.self, from: Data($0.utf8)) }
    }

    private func loadContractEvents(_ name: String) throws -> [BeaconAgentEventV2] {
        let text = try String(
            contentsOf: contractFixtureDirectory.appendingPathComponent(name),
            encoding: .utf8
        )
        return try text
            .split(whereSeparator: \.isNewline)
            .map { try JSONDecoder().decode(BeaconAgentEventV2.self, from: Data($0.utf8)) }
    }
}
