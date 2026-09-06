import Foundation
import Testing
@testable import BeaconAgentMemory

@Suite("Beacon memory repository")
struct BeaconMemoryRepositoryTests {
    @Test("confirmed evidence survives persistence and stale revisions fail closed")
    func evidenceAndRevisionConflict() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = BeaconMemoryFileRepository(rootURL: root)

        let first = try repository.upsert(record("exercise:raise"), baseRevision: 0)
        #expect(first.revision == 1)
        #expect(first.records[0].evidenceReferences == ["turn:1"])
        #expect(first.records[0].authorizationReferences == ["confirm:1"])

        #expect(throws: BeaconMemoryRepositoryError.revisionConflict(expected: 0, actual: 1)) {
            try repository.upsert(record("exercise:row"), baseRevision: 0)
        }
    }

    @Test("same semantic key is replaced without duplicate active values")
    func semanticKeyReplacement() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = BeaconMemoryFileRepository(rootURL: root)

        _ = try repository.upsert(record("exercise:raise", value: "prefer"), baseRevision: 0)
        let updated = try repository.upsert(record("exercise:raise", value: "avoid"), baseRevision: 1)

        #expect(updated.records.count == 1)
        #expect(updated.records[0].value == "avoid")
        #expect(updated.records[0].revision == 2)
    }

    @Test("active memory without authorization evidence is rejected")
    func authorizationEvidenceRequired() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = BeaconMemoryFileRepository(rootURL: root)

        #expect(throws: BeaconMemoryRepositoryError.invalidRecord) {
            try repository.upsert(
                record("exercise:raise", authorizationReferences: []),
                baseRevision: 0
            )
        }
    }

    @Test("review, expiry, and tombstones never enter active recall")
    func policyAndTombstone() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = BeaconMemoryFileRepository(rootURL: root)
        let now = Date(timeIntervalSinceReferenceDate: 100)

        var item = record("availability", reviewAt: now.addingTimeInterval(10), expiresAt: now.addingTimeInterval(20))
        var snapshot = try repository.upsert(item, baseRevision: 0)
        #expect(BeaconMemoryPolicy.disposition(of: snapshot.records[0], at: now) == .active)
        #expect(BeaconMemoryPolicy.disposition(of: snapshot.records[0], at: now.addingTimeInterval(10)) == .needsReview)
        #expect(BeaconMemoryPolicy.disposition(of: snapshot.records[0], at: now.addingTimeInterval(20)) == .expired)

        item = snapshot.records[0]
        snapshot = try repository.tombstone(
            recordID: item.id,
            scopeID: "profile-a",
            baseRevision: snapshot.revision,
            deletedAt: now
        )
        #expect(snapshot.records[0].status == .deleted)
        #expect(snapshot.records[0].value.isEmpty)
        #expect(snapshot.records[0].evidenceReferences.isEmpty)
        #expect(BeaconMemoryPolicy.activeRecords(in: snapshot, at: now).isEmpty)
    }

    @Test("serialized concurrent upserts do not lose distinct keys")
    func concurrentUpserts() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repositories = (0..<4).map { _ in BeaconMemoryFileRepository(rootURL: root) }

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<24 {
                group.addTask {
                    _ = try? repositories[index % repositories.count].upsert(
                        record("key:\(index)", value: "value-\(index)"),
                        baseRevision: nil
                    )
                }
            }
        }

        let loaded = try repositories[0].load(scopeID: "profile-a")
        #expect(loaded.revision == 24)
        #expect(BeaconMemoryPolicy.activeRecords(in: loaded, at: Date(timeIntervalSinceReferenceDate: 100)).count == 24)
    }

    @Test("profiles are isolated and corrupt data is quarantined without empty overwrite")
    func scopeIsolationAndQuarantine() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = BeaconMemoryFileRepository(rootURL: root)
        _ = try repository.upsert(record("only-a"), baseRevision: 0)
        #expect(try repository.load(scopeID: "profile-b").records.isEmpty)

        let file = root.appendingPathComponent("beacon-memory-profile-a.json")
        try Data("not-json".utf8).write(to: file, options: .atomic)
        #expect(throws: BeaconMemoryRepositoryError.self) {
            try repository.load(scopeID: "profile-a")
        }
        #expect(try Data(contentsOf: file) == Data("not-json".utf8))
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("quarantine"),
            includingPropertiesForKeys: nil
        )
        #expect(quarantined.count == 1)
    }

    private func record(
        _ semanticKey: String,
        value: String = "prefer",
        authorizationReferences: [String] = ["confirm:1"],
        reviewAt: Date = Date(timeIntervalSinceReferenceDate: 1_000),
        expiresAt: Date = Date(timeIntervalSinceReferenceDate: 2_000)
    ) -> BeaconMemoryRecord {
        BeaconMemoryRecord(
            id: UUID().uuidString.lowercased(),
            scopeID: "profile-a",
            semanticKey: semanticKey,
            kind: "preference",
            value: value,
            displaySummary: "A confirmed preference",
            purpose: "planning",
            sensitivity: "standard",
            source: "explicit-user-statement",
            status: .active,
            evidenceReferences: ["turn:1"],
            authorizationReferences: authorizationReferences,
            reviewAt: reviewAt,
            expiresAt: expiresAt,
            confirmedAt: Date(timeIntervalSinceReferenceDate: 50),
            createdAt: Date(timeIntervalSinceReferenceDate: 50),
            updatedAt: Date(timeIntervalSinceReferenceDate: 50),
            deletedAt: nil,
            revision: 0
        )
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeaconMemoryRepositoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
