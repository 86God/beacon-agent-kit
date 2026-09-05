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

    private var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("conformance/fixtures", isDirectory: true)
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
}
