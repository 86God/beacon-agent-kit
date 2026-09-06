import Foundation
import Testing
import BeaconAgentCore
@testable import BeaconAgentPersistence

@Suite
struct BeaconAgentPersistenceTests {
    @Test
    func registeredRunSurvivesRestartBeforeFirstEvent() async throws {
        let storage = MemoryPersistenceStorage()
        let journal = try BeaconRunJournal(storage: storage)

        #expect(try await journal.registerRun(threadId: "thread-a", runId: "run-a"))
        #expect(try await !journal.registerRun(threadId: "thread-a", runId: "run-a"))

        let restored = try BeaconRunJournal(storage: storage)
        let runs = try await restored.runs()
        #expect(runs == [
            BeaconRunJournalRun(
                threadId: "thread-a",
                runId: "run-a",
                cursor: -1,
                status: "idle"
            )
        ])
    }

    @Test
    func duplicateReplayPersistsOneEventAndRestoresSameProjection() async throws {
        let storage = MemoryPersistenceStorage()
        let journal = try BeaconRunJournal(storage: storage)
        let started = event(sequence: 0, type: "run.started")

        try await journal.append(started, threadId: "thread-a")
        try await journal.append(started, threadId: "thread-a")
        try await journal.append(started, threadId: "thread-a")

        #expect(await journal.events(threadId: "thread-a", runId: "run-a") == [started])
        let beforeRestart = try await journal.projection(threadId: "thread-a", runId: "run-a")

        let restored = try BeaconRunJournal(storage: storage)
        let afterRestart = try await restored.projection(threadId: "thread-a", runId: "run-a")
        #expect(try beforeRestart.normalizedJSON() == afterRestart.normalizedJSON())
        #expect(await restored.cursor(threadId: "thread-a", runId: "run-a") == 0)
    }

    @Test
    func storageFailureDoesNotAdvanceCursorOrPublishEvent() async throws {
        let storage = MemoryPersistenceStorage()
        let journal = try BeaconRunJournal(storage: storage)
        try await journal.append(event(sequence: 0, type: "run.started"), threadId: "thread-a")
        storage.failNextSave()

        await #expect(throws: PersistenceProbeError.self) {
            try await journal.append(
                event(
                    sequence: 1,
                    type: "text.start",
                    payload: ["messageId": .string("message-a")]
                ),
                threadId: "thread-a"
            )
        }

        #expect(await journal.cursor(threadId: "thread-a", runId: "run-a") == 0)
        #expect(await journal.events(threadId: "thread-a", runId: "run-a").count == 1)
    }

    @Test
    func outOfOrderEventsAreNotPersistedAndCanBeRecoveredAfterRestart() async throws {
        let storage = MemoryPersistenceStorage()
        let journal = try BeaconRunJournal(storage: storage)
        await #expect(throws: BeaconRunJournalError.nonContiguousEvent(expected: 0, actual: 2)) {
            try await journal.append(
            event(
                sequence: 2,
                type: "text.end",
                    payload: ["messageId": .string("message-a")]
                ),
                threadId: "thread-a"
            )
        }
        #expect(await journal.events(threadId: "thread-a", runId: "run-a").isEmpty)
        #expect(await journal.cursor(threadId: "thread-a", runId: "run-a") == -1)

        let restored = try BeaconRunJournal(storage: storage)
        try await restored.append(event(sequence: 0, type: "run.started"), threadId: "thread-a")
        try await restored.append(
            event(
                sequence: 1,
                type: "text.start",
                payload: ["messageId": .string("message-a")]
            ),
            threadId: "thread-a"
        )
        try await restored.append(
            event(
                sequence: 2,
                type: "text.end",
                payload: ["messageId": .string("message-a"), "finalText": .string("完成")]
            ),
            threadId: "thread-a"
        )
        #expect(await restored.cursor(threadId: "thread-a", runId: "run-a") == 2)
    }

    @Test
    func terminalRunRejectsLateEventWithoutChangingDurableProjection() async throws {
        let journal = try BeaconRunJournal(storage: MemoryPersistenceStorage())
        let terminal = event(sequence: 0, type: "run.error", payload: ["summary": .string("失败")])
        try await journal.append(terminal, threadId: "thread-a")
        let before = try await journal.projection(threadId: "thread-a", runId: "run-a")

        await #expect(throws: BeaconAgentReplayError.self) {
            try await journal.append(
                event(
                    sequence: 1,
                    type: "text.start",
                    payload: ["messageId": .string("late")]
                ),
                threadId: "thread-a"
            )
        }

        let after = try await journal.projection(threadId: "thread-a", runId: "run-a")
        #expect(try before.normalizedJSON() == after.normalizedJSON())
        #expect(await journal.cursor(threadId: "thread-a", runId: "run-a") == 0)
    }

    @Test
    func threadsAndRunsRemainIsolated() async throws {
        let journal = try BeaconRunJournal(storage: MemoryPersistenceStorage())
        try await journal.append(event(sequence: 0, runId: "run-a"), threadId: "thread-a")
        try await journal.append(event(sequence: 0, runId: "run-b"), threadId: "thread-b")

        #expect(await journal.runIds(threadId: "thread-a") == ["run-a"])
        #expect(await journal.runIds(threadId: "thread-b") == ["run-b"])
        #expect(await journal.events(threadId: "thread-a", runId: "run-a").count == 1)
        #expect(await journal.events(threadId: "thread-a", runId: "run-b").isEmpty)
    }

    @Test
    func deletingThreadRemovesRunsAndOutboxWithoutLaterResurrection() async throws {
        let storage = MemoryPersistenceStorage()
        let journal = try BeaconRunJournal(storage: storage)
        try await journal.append(event(sequence: 0, runId: "run-a"), threadId: "thread-a")
        try await journal.append(event(sequence: 0, runId: "run-b"), threadId: "thread-b")
        try await journal.enqueue(
            BeaconOutboxCommand(
                idempotencyKey: "command-a",
                commandId: "command-a",
                threadId: "thread-a",
                runId: "run-a",
                payload: .approvalResume(approvalId: "approval-a", approved: true)
            )
        )

        #expect(try await journal.deleteThread(threadId: "thread-a") == 2)
        #expect(await journal.runIds(threadId: "thread-a").isEmpty)
        #expect(await journal.pendingCommands(threadId: "thread-a").isEmpty)

        try await journal.append(
            event(sequence: 1, runId: "run-b", type: "run.finished"),
            threadId: "thread-b"
        )
        let restored = try BeaconRunJournal(storage: storage)
        #expect(await restored.runIds(threadId: "thread-a").isEmpty)
        #expect(await restored.pendingCommands(threadId: "thread-a").isEmpty)
        #expect(await restored.cursor(threadId: "thread-b", runId: "run-b") == 1)
    }

    @Test
    func deletingOneRunKeepsOtherRunsInTheSameThread() async throws {
        let storage = MemoryPersistenceStorage()
        let journal = try BeaconRunJournal(storage: storage)
        try await journal.append(event(sequence: 0, runId: "run-a"), threadId: "thread-a")
        try await journal.append(event(sequence: 0, runId: "run-b"), threadId: "thread-a")
        try await journal.enqueue(
            BeaconOutboxCommand(
                idempotencyKey: "command-a",
                commandId: "command-a",
                threadId: "thread-a",
                runId: "run-a",
                payload: .approvalResume(approvalId: "approval-a", approved: true)
            )
        )

        #expect(try await journal.deleteRun(threadId: "thread-a", runId: "run-a") == 2)
        #expect(await journal.runIds(threadId: "thread-a") == ["run-b"])
        #expect(await journal.pendingCommands(threadId: "thread-a").isEmpty)
    }

    @Test
    func outboxIsIdempotentAndFailedAcknowledgementKeepsCommand() async throws {
        let storage = MemoryPersistenceStorage()
        let journal = try BeaconRunJournal(storage: storage)
        let command = BeaconOutboxCommand(
            idempotencyKey: "command-key-a",
            commandId: "command-a",
            threadId: "thread-a",
            runId: "run-a",
            payload: .approvalResume(approvalId: "approval-a", approved: true)
        )

        #expect(try await journal.enqueue(command))
        #expect(try await !journal.enqueue(command))
        #expect(await journal.pendingCommands(threadId: "thread-a") == [command])

        storage.failNextSave()
        await #expect(throws: PersistenceProbeError.self) {
            try await journal.acknowledge(idempotencyKey: command.idempotencyKey)
        }
        #expect(await journal.pendingCommands(threadId: "thread-a") == [command])

        #expect(try await journal.acknowledge(idempotencyKey: command.idempotencyKey))
        #expect(await journal.pendingCommands(threadId: "thread-a").isEmpty)
    }

    @Test
    func conflictingEventAndCommandIdentitiesFailClosed() async throws {
        let journal = try BeaconRunJournal(storage: MemoryPersistenceStorage())
        try await journal.append(event(sequence: 0, type: "run.started"), threadId: "thread-a")

        await #expect(throws: BeaconAgentReplayError.self) {
            try await journal.append(
                event(sequence: 0, type: "step.started"),
                threadId: "thread-a"
            )
        }

        let first = BeaconOutboxCommand(
            idempotencyKey: "same-key",
            commandId: "command-a",
            threadId: "thread-a",
            runId: "run-a",
            payload: .approvalResume(approvalId: "approval-a", approved: true)
        )
        let conflict = BeaconOutboxCommand(
            idempotencyKey: "same-key",
            commandId: "command-b",
            threadId: "thread-a",
            runId: "run-a",
            payload: .approvalResume(approvalId: "approval-a", approved: true)
        )
        #expect(try await journal.enqueue(first))
        await #expect(throws: BeaconOutboxError.self) {
            try await journal.enqueue(conflict)
        }
    }

    @Test
    func staleJournalInstanceFailsClosedInsteadOfErasingAnotherWriter() async throws {
        let storage = MemoryPersistenceStorage()
        let first = try BeaconRunJournal(storage: storage)
        let stale = try BeaconRunJournal(storage: storage)

        try await first.append(event(sequence: 0, runId: "run-a"), threadId: "thread-a")
        await #expect(throws: BeaconAgentPersistenceStorageError.conflict) {
            try await stale.append(event(sequence: 0, runId: "run-b"), threadId: "thread-b")
        }

        let recovered = try BeaconRunJournal(storage: storage)
        try await recovered.append(event(sequence: 0, runId: "run-b"), threadId: "thread-b")
        #expect(await recovered.events(threadId: "thread-a", runId: "run-a").count == 1)
        #expect(await recovered.events(threadId: "thread-b", runId: "run-b").count == 1)
    }

    @Test
    func fileStorageUsesTheSameCompareAndSwapBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("journal.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = BeaconFilePersistenceStorage(url: url)
        let first = try BeaconRunJournal(storage: storage)
        let stale = try BeaconRunJournal(storage: storage)

        try await first.append(event(sequence: 0, runId: "run-a"), threadId: "thread-a")
        await #expect(throws: BeaconAgentPersistenceStorageError.conflict) {
            try await stale.append(event(sequence: 0, runId: "run-b"), threadId: "thread-b")
        }

        let recovered = try BeaconRunJournal(storage: storage)
        #expect(await recovered.events(threadId: "thread-a", runId: "run-a").count == 1)
        #expect(await recovered.events(threadId: "thread-b", runId: "run-b").isEmpty)
    }

    @Test
    func outboxRejectsInvalidOrPrivatePayloadsBeforePersistence() async throws {
        let journal = try BeaconRunJournal(storage: MemoryPersistenceStorage())

        let blankIdentifier = BeaconOutboxCommand(
            idempotencyKey: " ",
            commandId: "command-a",
            threadId: "thread-a",
            runId: "run-a",
            payload: .approvalResume(approvalId: "approval-a", approved: true)
        )
        await #expect(throws: BeaconOutboxError.invalidCommand) {
            try await journal.enqueue(blankIdentifier)
        }

        let oversized = BeaconOutboxCommand(
            idempotencyKey: "command-key-b",
            commandId: "command-b",
            threadId: "thread-a",
            runId: "run-a",
            payload: .deviceToolResume(
                toolCallId: String(
                    repeating: "x",
                    count: BeaconAgentEventV2WireLimits.identifierMaxCharacters + 1
                )
            )
        )
        await #expect(throws: BeaconOutboxError.invalidCommand) {
            try await journal.enqueue(oversized)
        }
        #expect(await journal.pendingCommands().isEmpty)
    }

    @Test
    func typedOutboxPayloadRejectsUnknownPrivateFields() throws {
        for privateField in ["observation", "draftText", "userPrompt", "photoBytes"] {
            let json = """
            {
              "type": "device_tool.resume",
              "toolCallId": "tool-a",
              "\(privateField)": "data:image/png;base64,AAAA"
            }
            """
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(
                    BeaconOutboxCommandPayload.self,
                    from: Data(json.utf8)
                )
            }
        }
    }

    private func event(
        sequence: Int,
        runId: String = "run-a",
        type: String = "run.started",
        payload: [String: BeaconJSONValue] = [:]
    ) -> BeaconAgentEventV2 {
        BeaconAgentEventV2(
            schemaVersion: 2,
            eventId: "\(runId):\(sequence)",
            runId: runId,
            turnId: "turn-\(runId)",
            attemptId: "attempt-1",
            segmentId: "segment-1",
            sequence: sequence,
            type: type,
            payload: payload
        )
    }
}

private enum PersistenceProbeError: Error {
    case saveFailed
}

private final class MemoryPersistenceStorage: BeaconAgentPersistenceStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var shouldFailNextSave = false

    func load() throws -> Data? {
        lock.withLock { data }
    }

    func compareAndSave(_ data: Data, replacing expectedData: Data?) throws {
        try lock.withLock {
            if shouldFailNextSave {
                shouldFailNextSave = false
                throw PersistenceProbeError.saveFailed
            }
            guard self.data == expectedData else {
                throw BeaconAgentPersistenceStorageError.conflict
            }
            self.data = data
        }
    }

    func failNextSave() {
        lock.withLock {
            shouldFailNextSave = true
        }
    }
}
