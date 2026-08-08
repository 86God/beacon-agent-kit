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
