import CryptoKit
import Foundation
import BeaconAgentCore
import BeaconAgentDevice
import BeaconAgentMemory
import BeaconAgentPersistence

public struct LocalNote: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let body: String
    public let updatedAt: Date

    public init(id: String, title: String, body: String, updatedAt: Date) {
        self.id = id
        self.title = title
        self.body = body
        self.updatedAt = updatedAt
    }
}

public struct LocalNotesModelDraft: Equatable, Sendable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

public protocol LocalNotesModel: Sendable {
    func makeDraft(prompt: String, existingNotes: [LocalNote]) async throws -> LocalNotesModelDraft
}

public struct LocalNotesPendingDraft: Equatable, Sendable {
    public let threadID: String
    public let runID: String
    public let approvalID: String
    public let commitToolCallID: String
    public let idempotencyKey: String
    public let title: String
    public let body: String

    public init(
        threadID: String,
        runID: String,
        approvalID: String,
        commitToolCallID: String,
        idempotencyKey: String,
        title: String,
        body: String
    ) {
        self.threadID = threadID
        self.runID = runID
        self.approvalID = approvalID
        self.commitToolCallID = commitToolCallID
        self.idempotencyKey = idempotencyKey
        self.title = title
        self.body = body
    }
}

public struct LocalNotesRestoredState: Equatable, Sendable {
    public let status: String
    public let pendingDraft: LocalNotesPendingDraft?
    public let pendingCommandCount: Int
    public let notes: [LocalNote]
    public let activeMemorySummaries: [String]
    public let eventTypes: [String]

    public init(
        status: String,
        pendingDraft: LocalNotesPendingDraft?,
        pendingCommandCount: Int,
        notes: [LocalNote],
        activeMemorySummaries: [String],
        eventTypes: [String]
    ) {
        self.status = status
        self.pendingDraft = pendingDraft
        self.pendingCommandCount = pendingCommandCount
        self.notes = notes
        self.activeMemorySummaries = activeMemorySummaries
        self.eventTypes = eventTypes
    }
}

public enum LocalNotesAssistantError: Error, Equatable, Sendable {
    case invalidIdentity
    case invalidDraft
    case invalidToolOutput
    case missingPendingDraft
    case stalePendingDraft
    case corruptStore
    case idempotencyConflict
}

/// A deliberately small host example. Ordering, terminal-state validation,
/// durable events and the approval outbox remain owned by BeaconAgentKit.
public actor LocalNotesAssistantSession {
    private static let threadID = "local-notes-thread"
    private static let schemaVersion = 2
    private static let registryRevision = "local-notes-v1"

    private let accountID: String
    private let profileID: String
    private let model: any LocalNotesModel
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> String
    private let store: LocalNotesFileStore
    private let journal: BeaconRunJournal
    private let memoryRepository: BeaconMemoryFileRepository
    private let dispatcher: BeaconDeviceToolDispatcher

    public init(
        rootURL: URL,
        accountID: String,
        deviceID: String,
        profileID: String,
        model: any LocalNotesModel,
        now: @escaping @Sendable () -> Date = { Date() },
        makeID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) throws {
        do {
            try BeaconAgentWireValidation.validateIdentifier(accountID, field: "accountID")
            try BeaconAgentWireValidation.validateIdentifier(deviceID, field: "deviceID")
            try BeaconAgentWireValidation.validateIdentifier(profileID, field: "profileID")
        } catch {
            throw LocalNotesAssistantError.invalidIdentity
        }

        let store = LocalNotesFileStore(
            url: rootURL.appendingPathComponent("notes.json", isDirectory: false)
        )
        let readHandler = LocalNotesReadHandler(store: store)
        let draftHandler = LocalNotesDraftHandler()
        let commitHandler = LocalNotesCommitHandler(store: store, now: now, makeID: makeID)
        let scopes: Set<String> = ["notes.read", "notes.write"]

        self.accountID = accountID
        self.profileID = profileID
        self.model = model
        self.now = now
        self.makeID = makeID
        self.store = store
        journal = try BeaconRunJournal(
            storage: BeaconFilePersistenceStorage(
                url: rootURL.appendingPathComponent("agent-journal.json", isDirectory: false)
            )
        )
        memoryRepository = BeaconMemoryFileRepository(
            rootURL: rootURL.appendingPathComponent("memory", isDirectory: true)
        )
        dispatcher = BeaconDeviceToolDispatcher(
            advertisements: Self.advertisements,
            policies: Self.policies,
            handlers: [readHandler, draftHandler, commitHandler],
            trustedHostContext: BeaconTrustedHostContext(
                accountID: accountID,
                deviceID: deviceID,
                authorizedScopes: scopes,
                now: now()
            ),
            clock: now
        )
    }

    public func begin(prompt: String) async throws -> LocalNotesPendingDraft {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalNotesAssistantError.invalidDraft
        }
        let runID = makeID()
        let turnID = makeID()
        let readToolCallID = makeID()
        let draftToolCallID = makeID()
        let approvalID = makeID()
        let commitToolCallID = makeID()
        let idempotencyKey = makeID()
        var sequence = 0

        try await append(runID: runID, turnID: turnID, sequence: &sequence, type: "run.started")
        let readObservation = try await runTool(
            runID: runID,
            turnID: turnID,
            toolCallID: readToolCallID,
            capabilityID: LocalNotesReadHandler.capability,
            requestedScopes: ["notes.read"],
            arguments: [:],
            idempotencyKey: nil,
            confirmed: false,
            sequence: &sequence
        )
        let existingNotes = try Self.notes(from: readObservation.payload)
        let modelDraft = try await model.makeDraft(prompt: prompt, existingNotes: existingNotes)
        try Self.validate(draft: modelDraft)

        let draftObservation = try await runTool(
            runID: runID,
            turnID: turnID,
            toolCallID: draftToolCallID,
            capabilityID: LocalNotesDraftHandler.capability,
            requestedScopes: ["notes.write"],
            arguments: ["title": .string(modelDraft.title), "body": .string(modelDraft.body)],
            idempotencyKey: nil,
            confirmed: false,
            sequence: &sequence
        )
        guard let title = draftObservation.payload.localString("title"),
              let body = draftObservation.payload.localString("body") else {
            throw LocalNotesAssistantError.invalidToolOutput
        }
        let pending = LocalNotesPendingDraft(
            threadID: Self.threadID,
            runID: runID,
            approvalID: approvalID,
            commitToolCallID: commitToolCallID,
            idempotencyKey: idempotencyKey,
            title: title,
            body: body
        )
        try await append(
            runID: runID,
            turnID: turnID,
            sequence: &sequence,
            type: "approval.requested",
            payload: pending.approvalPayload
        )
        return pending
    }

    public func confirm(_ draft: LocalNotesPendingDraft) async throws -> LocalNote {
        guard draft.threadID == Self.threadID,
              let persisted = try await pendingDraft(runID: draft.runID) else {
            throw LocalNotesAssistantError.missingPendingDraft
        }
        guard persisted == draft else { throw LocalNotesAssistantError.stalePendingDraft }
        let events = await journal.events(threadId: Self.threadID, runId: draft.runID)
        guard let turnID = events.first?.turnId else {
            throw LocalNotesAssistantError.missingPendingDraft
        }
        var sequence = await journal.cursor(threadId: Self.threadID, runId: draft.runID) + 1
        let command = BeaconOutboxCommand(
            idempotencyKey: draft.idempotencyKey,
            commandId: "command-\(draft.approvalID)",
            threadId: Self.threadID,
            runId: draft.runID,
            payload: .approvalResume(approvalId: draft.approvalID, approved: true)
        )
        _ = try await journal.enqueue(command)

        if !events.contains(where: {
            $0.type == "approval.resolved"
                && $0.payload.localString("approvalId") == draft.approvalID
        }) {
            try await append(
                runID: draft.runID,
                turnID: turnID,
                sequence: &sequence,
                type: "approval.resolved",
                payload: ["approvalId": .string(draft.approvalID), "approved": .bool(true)]
            )
        }
        let observation = try await runTool(
            runID: draft.runID,
            turnID: turnID,
            toolCallID: draft.commitToolCallID,
            capabilityID: LocalNotesCommitHandler.capability,
            requestedScopes: ["notes.write"],
            arguments: ["title": .string(draft.title), "body": .string(draft.body)],
            idempotencyKey: draft.idempotencyKey,
            confirmed: true,
            sequence: &sequence
        )
        let note = try Self.note(from: observation.payload)
        try await append(
            runID: draft.runID,
            turnID: turnID,
            sequence: &sequence,
            type: "receipt.committed",
            payload: [
                "idempotencyKey": .string(draft.idempotencyKey),
                "noteId": .string(note.id),
                "capabilityId": .string(LocalNotesCommitHandler.capability)
            ]
        )
        try remember(note: note, runID: draft.runID, approvalID: draft.approvalID)
        _ = try await journal.acknowledge(idempotencyKey: draft.idempotencyKey)
        try await append(
            runID: draft.runID,
            turnID: turnID,
            sequence: &sequence,
            type: "run.finished",
            payload: ["resultKind": .string("success")]
        )
        return note
    }

    public func notes() throws -> [LocalNote] {
        try store.notes()
    }

    public func pendingDraft(runID: String) async throws -> LocalNotesPendingDraft? {
        let events = await journal.events(threadId: Self.threadID, runId: runID)
        guard !events.contains(where: {
            $0.type == "run.finished"
                || $0.type == "run.error"
                || $0.type == "permission.denied"
        }),
        let request = events.last(where: { $0.type == "approval.requested" }) else {
            return nil
        }
        return try LocalNotesPendingDraft(payload: request.payload)
    }

    public func restoredState(runID: String) async throws -> LocalNotesRestoredState {
        let projection = try await journal.projection(threadId: Self.threadID, runId: runID)
        let events = await journal.events(threadId: Self.threadID, runId: runID)
        let memory = try memoryRepository.load(scopeID: profileID)
        return LocalNotesRestoredState(
            status: projection.status,
            pendingDraft: try await pendingDraft(runID: runID),
            pendingCommandCount: await journal.pendingCommands(threadId: Self.threadID).count,
            notes: try store.notes(),
            activeMemorySummaries: BeaconMemoryPolicy.activeRecords(in: memory, at: now())
                .map(\.displaySummary),
            eventTypes: events.map(\.type)
        )
    }

    private func runTool(
        runID: String,
        turnID: String,
        toolCallID: String,
        capabilityID: String,
        requestedScopes: Set<String>,
        arguments: [String: BeaconJSONValue],
        idempotencyKey: String?,
        confirmed: Bool,
        sequence: inout Int
    ) async throws -> BeaconToolObservation {
        try await append(
            runID: runID,
            turnID: turnID,
            sequence: &sequence,
            type: "tool.start",
            payload: ["toolCallId": .string(toolCallID), "capabilityId": .string(capabilityID)]
        )
        let observation = try await dispatcher.dispatch(
            BeaconDeviceToolRequest(
                runID: runID,
                toolCallID: toolCallID,
                capabilityID: capabilityID,
                schemaVersion: Self.schemaVersion,
                registryRevision: Self.registryRevision,
                requestedScopes: requestedScopes,
                arguments: arguments,
                idempotencyKey: idempotencyKey,
                expiresAt: now().addingTimeInterval(300)
            ),
            authorization: BeaconDeviceRunAuthorization(
                accountID: accountID,
                confirmedToolCallIDs: confirmed ? [toolCallID] : []
            )
        )
        try await append(
            runID: runID,
            turnID: turnID,
            sequence: &sequence,
            type: "tool.result",
            payload: observation.payload.merging([
                "toolCallId": .string(toolCallID),
                "capabilityId": .string(capabilityID)
            ]) { _, new in new }
        )
        return observation
    }

    private func append(
        runID: String,
        turnID: String,
        sequence: inout Int,
        type: String,
        payload: [String: BeaconJSONValue] = [:]
    ) async throws {
        let current = sequence
        let event = BeaconAgentEventV2(
            schemaVersion: Self.schemaVersion,
            eventId: "\(runID)-\(current)",
            runId: runID,
            turnId: turnID,
            attemptId: "attempt-1",
            segmentId: "segment-1",
            sequence: current,
            type: type,
            payload: payload
        )
        _ = try await journal.append(event, threadId: Self.threadID)
        sequence += 1
    }

    private func remember(note: LocalNote, runID: String, approvalID: String) throws {
        let snapshot = try memoryRepository.load(scopeID: profileID)
        let timestamp = now()
        let record = BeaconMemoryRecord(
            id: makeID(),
            scopeID: profileID,
            semanticKey: "last-confirmed-note",
            kind: "confirmed_note",
            value: note.title,
            displaySummary: "Last confirmed note: \(note.title)",
            purpose: "continuity",
            sensitivity: "standard",
            source: "explicit_confirmation",
            status: .active,
            evidenceReferences: ["run:\(runID)"],
            authorizationReferences: ["approval:\(approvalID)"],
            reviewAt: timestamp.addingTimeInterval(30 * 86_400),
            expiresAt: timestamp.addingTimeInterval(365 * 86_400),
            confirmedAt: timestamp,
            createdAt: timestamp,
            updatedAt: timestamp,
            deletedAt: nil,
            revision: snapshot.revision
        )
        _ = try memoryRepository.upsert(record, baseRevision: snapshot.revision)
    }

    private static func validate(draft: LocalNotesModelDraft) throws {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !body.isEmpty,
              title.count <= 160, body.count <= 20_000,
              !draft.title.contains("\n") else {
            throw LocalNotesAssistantError.invalidDraft
        }
    }

    private static func notes(from payload: [String: BeaconJSONValue]) throws -> [LocalNote] {
        guard case let .array(values)? = payload["notes"] else {
            throw LocalNotesAssistantError.invalidToolOutput
        }
        return try values.map { value in
            guard case let .object(object) = value else {
                throw LocalNotesAssistantError.invalidToolOutput
            }
            return try note(from: object)
        }
    }

    private static func note(from payload: [String: BeaconJSONValue]) throws -> LocalNote {
        guard let id = payload.localString("id"),
              let title = payload.localString("title"),
              let body = payload.localString("body"),
              let timestamp = payload.localNumber("updatedAt") else {
            throw LocalNotesAssistantError.invalidToolOutput
        }
        return LocalNote(id: id, title: title, body: body, updatedAt: Date(timeIntervalSince1970: timestamp))
    }

    private static let advertisements = [
        LocalNotesReadHandler.capability,
        LocalNotesDraftHandler.capability,
        LocalNotesCommitHandler.capability
    ].map {
        BeaconDeviceCapabilityAdvertisement(
            capabilityID: $0,
            version: "1.0.0",
            supportedSchemaVersions: [schemaVersion],
            enabled: true
        )
    }

    private static let policies = [
        BeaconDevicePolicy(
            capabilityID: LocalNotesReadHandler.capability,
            requiredScopes: ["notes.read"],
            confirmation: .never,
            inputSchema: objectSchema(properties: [:], required: []),
            outputSchema: objectSchema(
                properties: ["notes": .object(["type": .string("array"), "items": .object(noteSchema)])],
                required: ["notes"]
            )
        ),
        BeaconDevicePolicy(
            capabilityID: LocalNotesDraftHandler.capability,
            requiredScopes: ["notes.write"],
            confirmation: .never,
            inputSchema: draftSchema,
            outputSchema: draftSchema
        ),
        BeaconDevicePolicy(
            capabilityID: LocalNotesCommitHandler.capability,
            requiredScopes: ["notes.write"],
            confirmation: .beforeCommit,
            inputSchema: draftSchema,
            outputSchema: noteSchema
        )
    ]

    private static let draftSchema = objectSchema(
        properties: [
            "title": .object(["type": .string("string"), "minLength": .number(1)]),
            "body": .object(["type": .string("string"), "minLength": .number(1)])
        ],
        required: ["title", "body"]
    )

    private static let noteSchema: [String: BeaconJSONValue] = objectSchema(
        properties: [
            "id": .object(["type": .string("string"), "minLength": .number(1)]),
            "title": .object(["type": .string("string"), "minLength": .number(1)]),
            "body": .object(["type": .string("string"), "minLength": .number(1)]),
            "updatedAt": .object(["type": .string("number")])
        ],
        required: ["id", "title", "body", "updatedAt"]
    )

    private static func objectSchema(
        properties: [String: BeaconJSONValue],
        required: [String]
    ) -> [String: BeaconJSONValue] {
        [
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "required": .array(required.map(BeaconJSONValue.string)),
            "properties": .object(properties)
        ]
    }
}

private struct LocalNotesReadHandler: BeaconDeviceToolHandler {
    static let capability = "notes.read"
    let store: LocalNotesFileStore
    var capabilityID: String { Self.capability }

    func execute(_ request: BeaconAuthorizedToolRequest) async throws -> BeaconToolObservation {
        let values = try store.notes().map { BeaconJSONValue.object($0.payload) }
        return BeaconToolObservation(
            toolCallID: request.toolCallID,
            capabilityID: capabilityID,
            payload: ["notes": .array(values)]
        )
    }
}

private struct LocalNotesDraftHandler: BeaconDeviceToolHandler {
    static let capability = "notes.draft"
    var capabilityID: String { Self.capability }

    func execute(_ request: BeaconAuthorizedToolRequest) async throws -> BeaconToolObservation {
        guard let title = request.arguments.localString("title"),
              let body = request.arguments.localString("body") else {
            throw LocalNotesAssistantError.invalidDraft
        }
        return BeaconToolObservation(
            toolCallID: request.toolCallID,
            capabilityID: capabilityID,
            payload: ["title": .string(title), "body": .string(body)]
        )
    }
}

private struct LocalNotesCommitHandler: BeaconDeviceToolHandler {
    static let capability = "notes.commit"
    let store: LocalNotesFileStore
    let now: @Sendable () -> Date
    let makeID: @Sendable () -> String
    var capabilityID: String { Self.capability }

    func execute(_ request: BeaconAuthorizedToolRequest) async throws -> BeaconToolObservation {
        guard let title = request.arguments.localString("title"),
              let body = request.arguments.localString("body"),
              let idempotencyKey = request.idempotencyKey else {
            throw LocalNotesAssistantError.invalidDraft
        }
        let note = try store.commit(
            title: title,
            body: body,
            idempotencyKey: idempotencyKey,
            noteID: makeID(),
            updatedAt: now()
        )
        return BeaconToolObservation(
            toolCallID: request.toolCallID,
            capabilityID: capabilityID,
            payload: note.payload
        )
    }
}

private final class LocalNotesFileStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    init(url: URL) {
        self.url = url
    }

    func notes() throws -> [LocalNote] {
        try lock.withLock { try load().notes.sorted { $0.id < $1.id } }
    }

    func commit(
        title: String,
        body: String,
        idempotencyKey: String,
        noteID: String,
        updatedAt: Date
    ) throws -> LocalNote {
        try lock.withLock {
            var document = try load()
            let signature = Self.signature(title: title, body: body)
            if let receipt = document.receipts[idempotencyKey] {
                guard receipt.signature == signature else {
                    throw LocalNotesAssistantError.idempotencyConflict
                }
                guard let note = document.notes.first(where: { $0.id == receipt.noteID }) else {
                    throw LocalNotesAssistantError.corruptStore
                }
                return note
            }
            let note = LocalNote(id: noteID, title: title, body: body, updatedAt: updatedAt)
            document.notes.append(note)
            document.receipts[idempotencyKey] = Receipt(noteID: note.id, signature: signature)
            try save(document)
            return note
        }
    }

    private func load() throws -> Document {
        guard FileManager.default.fileExists(atPath: url.path) else { return Document() }
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        } catch {
            throw LocalNotesAssistantError.corruptStore
        }
        guard document.version == 1,
              Set(document.notes.map(\.id)).count == document.notes.count,
              document.receipts.values.allSatisfy({ receipt in
                  document.notes.contains(where: { $0.id == receipt.noteID })
              }) else {
            throw LocalNotesAssistantError.corruptStore
        }
        return document
    }

    private func save(_ document: Document) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #if os(iOS)
        try encoder.encode(document).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        #else
        try encoder.encode(document).write(to: url, options: .atomic)
        #endif
    }

    private static func signature(title: String, body: String) -> String {
        SHA256.hash(data: Data("\(title)\u{0}\(body)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private struct Document: Codable, Equatable, Sendable {
    let version: Int
    var notes: [LocalNote]
    var receipts: [String: Receipt]

    init(version: Int = 1, notes: [LocalNote] = [], receipts: [String: Receipt] = [:]) {
        self.version = version
        self.notes = notes
        self.receipts = receipts
    }
}

private struct Receipt: Codable, Equatable, Sendable {
    let noteID: String
    let signature: String
}

private extension LocalNote {
    var payload: [String: BeaconJSONValue] {
        [
            "id": .string(id),
            "title": .string(title),
            "body": .string(body),
            "updatedAt": .number(updatedAt.timeIntervalSince1970)
        ]
    }
}

private extension LocalNotesPendingDraft {
    init(payload: [String: BeaconJSONValue]) throws {
        guard let threadID = payload.localString("threadId"),
              let runID = payload.localString("runId"),
              let approvalID = payload.localString("approvalId"),
              let commitToolCallID = payload.localString("commitToolCallId"),
              let idempotencyKey = payload.localString("idempotencyKey"),
              let title = payload.localString("title"),
              let body = payload.localString("body") else {
            throw LocalNotesAssistantError.invalidToolOutput
        }
        self.init(
            threadID: threadID,
            runID: runID,
            approvalID: approvalID,
            commitToolCallID: commitToolCallID,
            idempotencyKey: idempotencyKey,
            title: title,
            body: body
        )
    }

    var approvalPayload: [String: BeaconJSONValue] {
        [
            "approvalId": .string(approvalID),
            "threadId": .string(threadID),
            "runId": .string(runID),
            "commitToolCallId": .string(commitToolCallID),
            "idempotencyKey": .string(idempotencyKey),
            "title": .string(title),
            "body": .string(body)
        ]
    }
}

private extension Dictionary where Key == String, Value == BeaconJSONValue {
    func localString(_ key: String) -> String? {
        guard case let .string(value)? = self[key] else { return nil }
        return value
    }

    func localNumber(_ key: String) -> Double? {
        guard case let .number(value)? = self[key] else { return nil }
        return value
    }
}
