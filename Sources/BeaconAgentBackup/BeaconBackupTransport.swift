import Foundation

public struct BeaconRemoteBackupMetadata: Codable, Equatable, Sendable {
    public let backupID: String
    public let profileID: String
    public let keyID: String
    public let createdAt: Date
    public let byteCount: Int

    public init(backupID: String, profileID: String, keyID: String, createdAt: Date, byteCount: Int) {
        self.backupID = backupID
        self.profileID = profileID
        self.keyID = keyID
        self.createdAt = createdAt
        self.byteCount = byteCount
    }
}

public struct BeaconBackupUploadDescriptor: Codable, Equatable, Sendable {
    public let metadata: BeaconRemoteBackupMetadata
    public let chunkCount: Int
    public let chunkByteCount: Int
    public let archiveSHA256: String

    public init(
        metadata: BeaconRemoteBackupMetadata,
        chunkCount: Int,
        chunkByteCount: Int,
        archiveSHA256: String
    ) {
        self.metadata = metadata
        self.chunkCount = chunkCount
        self.chunkByteCount = chunkByteCount
        self.archiveSHA256 = archiveSHA256
    }
}

public struct BeaconBackupUploadState: Codable, Equatable, Sendable {
    public let uploadedChunkIndices: Set<Int>
    public let isCommitted: Bool

    public init(uploadedChunkIndices: Set<Int>, isCommitted: Bool) {
        self.uploadedChunkIndices = uploadedChunkIndices
        self.isCommitted = isCommitted
    }
}

public enum BeaconBackupTransportFailure: Error, Equatable, Sendable {
    case accountUnavailable
    case networkUnavailable
    case quotaExceeded
    case invalidRemoteState
    case permissionDenied
}

public protocol BeaconBackupTransport: Sendable {
    func currentAccountScope() async throws -> String
    func prepareUpload(_ descriptor: BeaconBackupUploadDescriptor) async throws -> BeaconBackupUploadState
    func uploadChunk(_ data: Data, backupID: String, index: Int) async throws
    func commitUpload(_ descriptor: BeaconBackupUploadDescriptor) async throws
    func abandonUpload(backupID: String) async throws
    func download(backupID: String) async throws -> Data
    func list(profileID: String) async throws -> [BeaconRemoteBackupMetadata]
    func listAll() async throws -> [BeaconRemoteBackupMetadata]
    func delete(backupID: String) async throws
    func cleanupIncomplete(olderThan: Date) async throws
}

public extension BeaconBackupTransport {
    /// Cross-device discovery is optional for transports that cannot enumerate
    /// an account-private namespace. Callers must handle the stable failure and
    /// keep manual encrypted-file recovery available.
    func listAll() async throws -> [BeaconRemoteBackupMetadata] {
        throw BeaconBackupTransportFailure.invalidRemoteState
    }
}
