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

public protocol BeaconBackupTransport: Sendable {
    func upload(encryptedArchive: Data, metadata: BeaconRemoteBackupMetadata) async throws
    func download(backupID: String) async throws -> Data
    func list(profileID: String) async throws -> [BeaconRemoteBackupMetadata]
    func delete(backupID: String) async throws
}
