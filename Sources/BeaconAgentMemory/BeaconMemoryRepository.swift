import CryptoKit
import Foundation

public enum BeaconMemoryRepositoryError: Error, Equatable, Sendable {
    case invalidScope
    case invalidRecord
    case revisionConflict(expected: Int, actual: Int)
    case corruptStoreQuarantined
}

public protocol BeaconMemoryRepository: Sendable {
    func load(scopeID: String) throws -> BeaconMemorySnapshot

    @discardableResult
    func upsert(
        _ record: BeaconMemoryRecord,
        baseRevision: Int?
    ) throws -> BeaconMemorySnapshot

    @discardableResult
    func tombstone(
        recordID: String,
        scopeID: String,
        baseRevision: Int?,
        deletedAt: Date
    ) throws -> BeaconMemorySnapshot

    @discardableResult
    func tombstoneAll(
        scopeID: String,
        baseRevision: Int?,
        deletedAt: Date
    ) throws -> BeaconMemorySnapshot
}

public final class BeaconMemoryFileRepository: BeaconMemoryRepository, @unchecked Sendable {
    public let rootURL: URL

    private let fileManager: FileManager
    private let lock: NSLock
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var locksByRoot: [String: NSLock] = [:]

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        lock = Self.sharedLock(for: rootURL.standardizedFileURL.path)
    }

    public func load(scopeID: String) throws -> BeaconMemorySnapshot {
        try locked {
            try loadUnlocked(scopeID: scopeID)
        }
    }

    @discardableResult
    public func upsert(
        _ record: BeaconMemoryRecord,
        baseRevision: Int?
    ) throws -> BeaconMemorySnapshot {
        try locked {
            guard Self.isSafeScopeID(record.scopeID), Self.isValid(record) else {
                throw BeaconMemoryRepositoryError.invalidRecord
            }
            let snapshot = try loadUnlocked(scopeID: record.scopeID)
            try check(baseRevision: baseRevision, actual: snapshot.revision)
            let nextRevision = snapshot.revision + 1
            var records = snapshot.records
            if let index = records.firstIndex(where: { $0.semanticKey == record.semanticKey }) {
                let existing = records[index]
                records[index] = record.committed(
                    id: existing.id,
                    revision: nextRevision,
                    createdAt: existing.createdAt
                )
            } else {
                records.append(record.committed(
                    id: record.id,
                    revision: nextRevision,
                    createdAt: record.createdAt
                ))
            }
            records.sort { $0.id < $1.id }
            return try writeUnlocked(.init(
                scopeID: snapshot.scopeID,
                revision: nextRevision,
                records: records,
                migrationAudit: snapshot.migrationAudit
            ))
        }
    }

    @discardableResult
    public func tombstone(
        recordID: String,
        scopeID: String,
        baseRevision: Int?,
        deletedAt: Date
    ) throws -> BeaconMemorySnapshot {
        try locked {
            let snapshot = try loadUnlocked(scopeID: scopeID)
            try check(baseRevision: baseRevision, actual: snapshot.revision)
            guard let index = snapshot.records.firstIndex(where: { $0.id == recordID }),
                  snapshot.records[index].status != .deleted else {
                return snapshot
            }
            let nextRevision = snapshot.revision + 1
            var records = snapshot.records
            records[index] = records[index].tombstoned(at: deletedAt, revision: nextRevision)
            return try writeUnlocked(.init(
                scopeID: snapshot.scopeID,
                revision: nextRevision,
                records: records,
                migrationAudit: snapshot.migrationAudit
            ))
        }
    }

    @discardableResult
    public func tombstoneAll(
        scopeID: String,
        baseRevision: Int?,
        deletedAt: Date
    ) throws -> BeaconMemorySnapshot {
        try locked {
            let snapshot = try loadUnlocked(scopeID: scopeID)
            try check(baseRevision: baseRevision, actual: snapshot.revision)
            guard snapshot.records.contains(where: { $0.status != .deleted }) else {
                return snapshot
            }
            let nextRevision = snapshot.revision + 1
            let records = snapshot.records.map { record in
                record.status == .deleted
                    ? record
                    : record.tombstoned(at: deletedAt, revision: nextRevision)
            }
            return try writeUnlocked(.init(
                scopeID: snapshot.scopeID,
                revision: nextRevision,
                records: records,
                migrationAudit: snapshot.migrationAudit
            ))
        }
    }

    private func loadUnlocked(scopeID: String) throws -> BeaconMemorySnapshot {
        guard Self.isSafeScopeID(scopeID) else {
            throw BeaconMemoryRepositoryError.invalidScope
        }
        let url = fileURL(scopeID: scopeID)
        guard fileManager.fileExists(atPath: url.path) else {
            return .init(scopeID: scopeID, revision: 0, records: [])
        }
        do {
            let snapshot = try JSONDecoder().decode(
                BeaconMemorySnapshot.self,
                from: Data(contentsOf: url)
            )
            guard snapshot.schemaVersion == BeaconMemorySnapshot.currentSchemaVersion,
                  snapshot.scopeID == scopeID,
                  snapshot.revision >= 0,
                  Set(snapshot.records.map(\.semanticKey)).count == snapshot.records.count,
                  snapshot.records.allSatisfy({
                      $0.scopeID == scopeID
                          && $0.revision <= snapshot.revision
                          && Self.isValid($0)
                  }) else {
                throw BeaconMemoryRepositoryError.corruptStoreQuarantined
            }
            return snapshot
        } catch {
            try quarantineCopy(of: url)
            throw BeaconMemoryRepositoryError.corruptStoreQuarantined
        }
    }

    private func writeUnlocked(_ snapshot: BeaconMemorySnapshot) throws -> BeaconMemorySnapshot {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: fileURL(scopeID: snapshot.scopeID), options: .atomic)
        return snapshot
    }

    private func quarantineCopy(of url: URL) throws {
        let directory = rootURL.appendingPathComponent("quarantine", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", $0) }
            .joined()
        let destination = directory.appendingPathComponent(
            "\(url.lastPathComponent).\(digest).corrupt"
        )
        guard !fileManager.fileExists(atPath: destination.path) else { return }
        try fileManager.copyItem(at: url, to: destination)
    }

    private func check(baseRevision: Int?, actual: Int) throws {
        guard let baseRevision else { return }
        guard baseRevision == actual else {
            throw BeaconMemoryRepositoryError.revisionConflict(expected: baseRevision, actual: actual)
        }
    }

    private func fileURL(scopeID: String) -> URL {
        rootURL.appendingPathComponent("beacon-memory-\(scopeID).json", isDirectory: false)
    }

    private func locked<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private static func sharedLock(for rootPath: String) -> NSLock {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = locksByRoot[rootPath] { return existing }
        let created = NSLock()
        locksByRoot[rootPath] = created
        return created
    }

    private static func isSafeScopeID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil
    }

    private static func isValid(_ record: BeaconMemoryRecord) -> Bool {
        guard isSafeScopeID(record.scopeID),
              isOpaque(record.id, maxLength: 128),
              isOpaque(record.semanticKey, maxLength: 256),
              isInline(record.kind, maxLength: 128),
              isInline(record.purpose, maxLength: 64),
              isInline(record.sensitivity, maxLength: 64),
              isInline(record.source, maxLength: 64),
              record.revision >= 0,
              record.reviewAt <= record.expiresAt,
              record.evidenceReferences.count <= 16,
              record.authorizationReferences.count <= 16,
              record.evidenceReferences.allSatisfy({ isOpaque($0, maxLength: 160) }),
              record.authorizationReferences.allSatisfy({ isOpaque($0, maxLength: 160) }) else {
            return false
        }
        if record.status == .deleted {
            return record.value.isEmpty && record.displaySummary.isEmpty && record.deletedAt != nil
                && record.evidenceReferences.isEmpty
                && record.authorizationReferences.isEmpty
        }
        guard record.status != .active
                || (!record.evidenceReferences.isEmpty && !record.authorizationReferences.isEmpty) else {
            return false
        }
        return isInline(record.value, maxLength: 1_024)
            && isInline(record.displaySummary, maxLength: 512)
            && record.deletedAt == nil
    }

    private static func isInline(_ value: String, maxLength: Int) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= maxLength && !value.contains("\n")
    }

    private static func isOpaque(_ value: String, maxLength: Int) -> Bool {
        value.range(
            of: "^[A-Za-z0-9_.:-]{1,\(maxLength)}$",
            options: .regularExpression
        ) != nil
    }
}
