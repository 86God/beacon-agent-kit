import CryptoKit
import Foundation

public struct BeaconEncryptedBackup: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let backupID: String
    public let keyID: String
    public let chunkCount: Int
    public let sealedPayload: Data

    public init(schemaVersion: Int, backupID: String, keyID: String, chunkCount: Int, sealedPayload: Data) {
        self.schemaVersion = schemaVersion
        self.backupID = backupID
        self.keyID = keyID
        self.chunkCount = chunkCount
        self.sealedPayload = sealedPayload
    }
}

public enum BeaconArchiveCrypto {
    public static func makeKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    public static func keyID(for key: SymmetricKey) -> String {
        let raw = key.withUnsafeBytes { Data($0) }
        return Data(SHA256.hash(data: raw)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    public static func rawRepresentation(of key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    public static func key(rawRepresentation: Data) throws -> SymmetricKey {
        guard rawRepresentation.count == 32 else { throw BeaconBackupError.invalidEnvelope }
        return SymmetricKey(data: rawRepresentation)
    }

    public static func encrypt(
        _ bundle: BeaconBackupBundle,
        using key: SymmetricKey
    ) throws -> BeaconEncryptedBackup {
        try BeaconBackupValidator.validate(bundle)
        guard bundle.manifest.keyID == keyID(for: key) else {
            throw BeaconBackupError.authenticationFailed
        }
        let header = Header(
            schemaVersion: bundle.manifest.schemaVersion,
            backupID: bundle.manifest.backupID,
            keyID: bundle.manifest.keyID,
            chunkCount: bundle.manifest.chunks.count
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plaintext = try encoder.encode(bundle)
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: try encoder.encode(header))
        guard let combined = sealed.combined else { throw BeaconBackupError.invalidEnvelope }
        return BeaconEncryptedBackup(
            schemaVersion: header.schemaVersion,
            backupID: header.backupID,
            keyID: header.keyID,
            chunkCount: header.chunkCount,
            sealedPayload: combined
        )
    }

    public static func decrypt(
        _ encrypted: BeaconEncryptedBackup,
        using key: SymmetricKey
    ) throws -> BeaconBackupBundle {
        guard encrypted.schemaVersion == BeaconBackupManifest.currentSchemaVersion else {
            throw BeaconBackupError.unsupportedSchemaVersion(encrypted.schemaVersion)
        }
        guard encrypted.keyID == keyID(for: key) else {
            throw BeaconBackupError.authenticationFailed
        }
        let header = Header(
            schemaVersion: encrypted.schemaVersion,
            backupID: encrypted.backupID,
            keyID: encrypted.keyID,
            chunkCount: encrypted.chunkCount
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(combined: encrypted.sealedPayload)
            plaintext = try AES.GCM.open(box, using: key, authenticating: try encoder.encode(header))
        } catch {
            throw BeaconBackupError.authenticationFailed
        }
        let bundle: BeaconBackupBundle
        do {
            bundle = try JSONDecoder().decode(BeaconBackupBundle.self, from: plaintext)
        } catch {
            throw BeaconBackupError.invalidEnvelope
        }
        guard bundle.manifest.schemaVersion == encrypted.schemaVersion,
              bundle.manifest.backupID == encrypted.backupID,
              bundle.manifest.keyID == encrypted.keyID,
              bundle.manifest.chunks.count == encrypted.chunkCount else {
            throw BeaconBackupError.authenticationFailed
        }
        try BeaconBackupValidator.validate(bundle)
        return bundle
    }

    private struct Header: Codable {
        let schemaVersion: Int
        let backupID: String
        let keyID: String
        let chunkCount: Int
    }
}
