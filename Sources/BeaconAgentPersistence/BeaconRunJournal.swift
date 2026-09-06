import Foundation
import BeaconAgentCore

public protocol BeaconAgentPersistenceStorage: Sendable {
    func load() throws -> Data?
    func compareAndSave(_ data: Data, replacing expectedData: Data?) throws
}

public enum BeaconAgentPersistenceStorageError: Error, Equatable, Sendable {
    case conflict
}

public enum BeaconRunJournalError: Error, Equatable, Sendable {
    case unsupportedDocumentVersion(Int)
    case invalidRunIdentity
    case nonContiguousEvent(expected: Int, actual: Int)
}

public struct BeaconFilePersistenceStorage: BeaconAgentPersistenceStorage, Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func compareAndSave(_ data: Data, replacing expectedData: Data?) throws {
        try Self.mutationLock.withLock {
            let currentData = try load()
            guard currentData == expectedData else {
                throw BeaconAgentPersistenceStorageError.conflict
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            #else
            try data.write(to: url, options: .atomic)
            #endif
        }
    }

    private static let mutationLock = NSLock()
}

public actor BeaconRunJournal {
    private static let documentVersion = 1

    private let storage: any BeaconAgentPersistenceStorage
    private var document: Document
    private var persistedData: Data?

    public init(storage: any BeaconAgentPersistenceStorage) throws {
        self.storage = storage
        guard let data = try storage.load() else {
            document = Document()
            persistedData = nil
            return
        }
        let decoded = try JSONDecoder().decode(Document.self, from: data)
        guard decoded.version == Self.documentVersion else {
            throw BeaconRunJournalError.unsupportedDocumentVersion(decoded.version)
        }
        document = decoded
        persistedData = data
    }

    @discardableResult
    public func append(
        _ event: BeaconAgentEventV2,
        threadId: String
    ) throws -> BeaconAgentStateV2 {
        guard !threadId.isEmpty, !event.runId.isEmpty else {
            throw BeaconRunJournalError.invalidRunIdentity
        }
        let key = Self.key(threadId: threadId, runId: event.runId)
        let existing = document.runs[key] ?? Record(
            threadId: threadId,
            runId: event.runId,
            events: [],
            cursor: -1
        )
        var projection = try Self.replay(existing.events)

        if let persisted = existing.events.first(where: { $0.eventId == event.eventId }) {
            guard persisted != event else { return projection }
            try projection.ingest(event)
            return projection
        }

        let expectedSequence = existing.cursor + 1
        guard event.sequence == expectedSequence else {
            throw BeaconRunJournalError.nonContiguousEvent(
                expected: expectedSequence,
                actual: event.sequence
            )
        }

        try projection.ingest(event)
        var candidate = document
        var nextRecord = existing
        nextRecord.events.append(event)
        nextRecord.cursor = projection.nextSequence - 1
        candidate.runs[key] = nextRecord
        try persist(candidate)
        document = candidate
        return projection
    }

    public func projection(threadId: String, runId: String) throws -> BeaconAgentStateV2 {
        let persistedEvents = document.runs[Self.key(threadId: threadId, runId: runId)]?.events ?? []
        return try Self.replay(persistedEvents)
    }

    public func events(threadId: String, runId: String) -> [BeaconAgentEventV2] {
        document.runs[Self.key(threadId: threadId, runId: runId)]?.events ?? []
    }

    public func cursor(threadId: String, runId: String) -> Int {
        document.runs[Self.key(threadId: threadId, runId: runId)]?.cursor ?? -1
    }

    public func runIds(threadId: String) -> [String] {
        document.runs.values
            .filter { $0.threadId == threadId }
            .map(\.runId)
            .sorted()
    }

    @discardableResult
    public func enqueue(_ command: BeaconOutboxCommand) throws -> Bool {
        var candidate = document
        let inserted = try candidate.outbox.enqueue(command)
        guard inserted else { return false }
        try persist(candidate)
        document = candidate
        return true
    }

    @discardableResult
    public func acknowledge(idempotencyKey: String) throws -> Bool {
        var candidate = document
        let removed = candidate.outbox.acknowledge(idempotencyKey: idempotencyKey)
        guard removed else { return false }
        try persist(candidate)
        document = candidate
        return true
    }

    public func pendingCommands(threadId: String? = nil) -> [BeaconOutboxCommand] {
        document.outbox.pending(threadId: threadId)
    }

    private func persist(_ candidate: Document) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(candidate)
        try storage.compareAndSave(encoded, replacing: persistedData)
        persistedData = encoded
    }

    private static func replay(_ events: [BeaconAgentEventV2]) throws -> BeaconAgentStateV2 {
        var state = BeaconAgentStateV2()
        for event in events {
            try state.ingest(event)
        }
        return state
    }

    private static func key(threadId: String, runId: String) -> String {
        "\(threadId.utf8.count):\(threadId)\(runId)"
    }
}

private struct Document: Codable, Equatable, Sendable {
    let version: Int
    var runs: [String: Record]
    var outbox: BeaconOutbox

    init() {
        version = 1
        runs = [:]
        outbox = BeaconOutbox()
    }
}

private struct Record: Codable, Equatable, Sendable {
    let threadId: String
    let runId: String
    var events: [BeaconAgentEventV2]
    var cursor: Int
}
