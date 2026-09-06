import Foundation

public enum BeaconMemoryStatus: String, Codable, Equatable, Sendable {
    case active
    case paused
    case needsReview = "needs_review"
    case expired
    case deleted
}

public struct BeaconMemoryMigrationAudit: Codable, Equatable, Sendable {
    public let sourceSchema: String
    public let sourceRecordCount: Int
    public let migratedActiveCount: Int
    public let migratedNeedsReviewCount: Int
    public let skippedRecordCount: Int
    public let migratedAt: Date

    public init(
        sourceSchema: String,
        sourceRecordCount: Int,
        migratedActiveCount: Int,
        migratedNeedsReviewCount: Int,
        skippedRecordCount: Int,
        migratedAt: Date
    ) {
        self.sourceSchema = sourceSchema
        self.sourceRecordCount = sourceRecordCount
        self.migratedActiveCount = migratedActiveCount
        self.migratedNeedsReviewCount = migratedNeedsReviewCount
        self.skippedRecordCount = skippedRecordCount
        self.migratedAt = migratedAt
    }
}

public struct BeaconMemoryRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let scopeID: String
    public let semanticKey: String
    public let kind: String
    public let value: String
    public let displaySummary: String
    public let purpose: String
    public let sensitivity: String
    public let source: String
    public let status: BeaconMemoryStatus
    public let evidenceReferences: [String]
    public let authorizationReferences: [String]
    public let reviewAt: Date
    public let expiresAt: Date
    public let confirmedAt: Date
    public let createdAt: Date
    public let updatedAt: Date
    public let deletedAt: Date?
    public let revision: Int

    public init(
        id: String,
        scopeID: String,
        semanticKey: String,
        kind: String,
        value: String,
        displaySummary: String,
        purpose: String,
        sensitivity: String,
        source: String,
        status: BeaconMemoryStatus,
        evidenceReferences: [String],
        authorizationReferences: [String],
        reviewAt: Date,
        expiresAt: Date,
        confirmedAt: Date,
        createdAt: Date,
        updatedAt: Date,
        deletedAt: Date?,
        revision: Int
    ) {
        self.id = id
        self.scopeID = scopeID
        self.semanticKey = semanticKey
        self.kind = kind
        self.value = value
        self.displaySummary = displaySummary
        self.purpose = purpose
        self.sensitivity = sensitivity
        self.source = source
        self.status = status
        self.evidenceReferences = evidenceReferences
        self.authorizationReferences = authorizationReferences
        self.reviewAt = reviewAt
        self.expiresAt = expiresAt
        self.confirmedAt = confirmedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.revision = revision
    }

    func committed(
        id: String,
        revision: Int,
        createdAt: Date
    ) -> BeaconMemoryRecord {
        .init(
            id: id,
            scopeID: scopeID,
            semanticKey: semanticKey,
            kind: kind,
            value: value,
            displaySummary: displaySummary,
            purpose: purpose,
            sensitivity: sensitivity,
            source: source,
            status: status,
            evidenceReferences: evidenceReferences,
            authorizationReferences: authorizationReferences,
            reviewAt: reviewAt,
            expiresAt: expiresAt,
            confirmedAt: confirmedAt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt,
            revision: revision
        )
    }

    func tombstoned(at date: Date, revision: Int) -> BeaconMemoryRecord {
        .init(
            id: id,
            scopeID: scopeID,
            semanticKey: semanticKey,
            kind: kind,
            value: "",
            displaySummary: "",
            purpose: purpose,
            sensitivity: sensitivity,
            source: source,
            status: .deleted,
            evidenceReferences: [],
            authorizationReferences: [],
            reviewAt: reviewAt,
            expiresAt: expiresAt,
            confirmedAt: confirmedAt,
            createdAt: createdAt,
            updatedAt: date,
            deletedAt: date,
            revision: revision
        )
    }
}

public struct BeaconMemorySnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let scopeID: String
    public let revision: Int
    public let records: [BeaconMemoryRecord]
    public let migrationAudit: BeaconMemoryMigrationAudit?

    public init(
        schemaVersion: Int = BeaconMemorySnapshot.currentSchemaVersion,
        scopeID: String,
        revision: Int,
        records: [BeaconMemoryRecord],
        migrationAudit: BeaconMemoryMigrationAudit? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.scopeID = scopeID
        self.revision = revision
        self.records = records
        self.migrationAudit = migrationAudit
    }
}
