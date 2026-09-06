import CryptoKit
import Foundation
import Testing
@testable import BeaconAgentBackup

@Suite("Authenticated backup archive")
struct BeaconArchiveCryptoTests {
    @Test("round trip authenticates the manifest and every chunk without leaking plaintext")
    func roundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let bundle = try fixture(key: key)

        let encrypted = try BeaconArchiveCrypto.encrypt(bundle, using: key)
        let encoded = try JSONEncoder().encode(encrypted)

        #expect(!String(decoding: encoded, as: UTF8.self).contains("confirmed shoulder preference"))
        #expect(try BeaconArchiveCrypto.decrypt(encrypted, using: key) == bundle)
    }

    @Test("wrong keys and changed ciphertext fail authentication")
    func authenticationFailures() throws {
        let key = SymmetricKey(size: .bits256)
        let encrypted = try BeaconArchiveCrypto.encrypt(try fixture(key: key), using: key)

        #expect(throws: BeaconBackupError.authenticationFailed) {
            _ = try BeaconArchiveCrypto.decrypt(encrypted, using: SymmetricKey(size: .bits256))
        }

        var changed = encrypted.sealedPayload
        changed[changed.startIndex] ^= 0x01
        let tampered = BeaconEncryptedBackup(
            schemaVersion: encrypted.schemaVersion,
            backupID: encrypted.backupID,
            keyID: encrypted.keyID,
            chunkCount: encrypted.chunkCount,
            sealedPayload: changed
        )
        #expect(throws: BeaconBackupError.authenticationFailed) {
            _ = try BeaconArchiveCrypto.decrypt(tampered, using: key)
        }

        let changedHeader = BeaconEncryptedBackup(
            schemaVersion: encrypted.schemaVersion,
            backupID: "substituted-backup",
            keyID: encrypted.keyID,
            chunkCount: encrypted.chunkCount,
            sealedPayload: encrypted.sealedPayload
        )
        #expect(throws: BeaconBackupError.authenticationFailed) {
            _ = try BeaconArchiveCrypto.decrypt(changedHeader, using: key)
        }
    }

    @Test("old schemas, traversal, duplicate indices, oversized chunks, and missing data fail closed")
    func structuralValidation() throws {
        let key = SymmetricKey(size: .bits256)
        let keyID = BeaconArchiveCrypto.keyID(for: key)
        let data = Data("value".utf8)

        #expect(throws: BeaconBackupError.unsupportedSchemaVersion(0)) {
            _ = try BeaconBackupBundle.make(
                schemaVersion: 0,
                backupID: "backup-a",
                profileID: "profile-a",
                createdAt: .distantPast,
                keyID: keyID,
                chunks: [.init(index: 0, relativePath: "data.json", data: data)]
            )
        }
        #expect(throws: BeaconBackupError.unsafeRelativePath("../memory.json")) {
            _ = try BeaconBackupBundle.make(
                backupID: "backup-a",
                profileID: "profile-a",
                createdAt: .distantPast,
                keyID: keyID,
                chunks: [.init(index: 0, relativePath: "../memory.json", data: data)]
            )
        }
        #expect(throws: BeaconBackupError.duplicateChunkIndex(0)) {
            _ = try BeaconBackupBundle.make(
                backupID: "backup-a",
                profileID: "profile-a",
                createdAt: .distantPast,
                keyID: keyID,
                chunks: [
                    .init(index: 0, relativePath: "a.json", data: data),
                    .init(index: 0, relativePath: "b.json", data: data)
                ]
            )
        }
        #expect(throws: BeaconBackupError.duplicateChunkPath("same.json")) {
            _ = try BeaconBackupBundle.make(
                backupID: "backup-a",
                profileID: "profile-a",
                createdAt: .distantPast,
                keyID: keyID,
                chunks: [
                    .init(index: 0, relativePath: "same.json", data: data),
                    .init(index: 1, relativePath: "same.json", data: data)
                ]
            )
        }
        #expect(throws: BeaconBackupError.chunkTooLarge("large.bin")) {
            _ = try BeaconBackupBundle.make(
                backupID: "backup-a",
                profileID: "profile-a",
                createdAt: .distantPast,
                keyID: keyID,
                limits: .init(maxChunkCount: 4, maxChunkBytes: 4, maxArchiveBytes: 16),
                chunks: [.init(index: 0, relativePath: "large.bin", data: Data(repeating: 1, count: 5))]
            )
        }

        var valid = try fixture(key: key)
        valid.chunks.removeLast()
        #expect(throws: BeaconBackupError.missingChunk("memory/confirmed.json")) {
            try BeaconBackupValidator.validate(valid)
        }
    }

    @Test("resumable transport descriptor preserves committed and uploaded state")
    func transportDescriptorRoundTrip() throws {
        let descriptor = BeaconBackupUploadDescriptor(
            metadata: BeaconRemoteBackupMetadata(
                backupID: "backup-a",
                profileID: "profile-a",
                keyID: "key-a",
                createdAt: Date(timeIntervalSinceReferenceDate: 10),
                byteCount: 12
            ),
            chunkCount: 3,
            chunkByteCount: 4,
            archiveSHA256: String(repeating: "a", count: 64)
        )
        let state = BeaconBackupUploadState(uploadedChunkIndices: [0, 2], isCommitted: false)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        #expect(try decoder.decode(BeaconBackupUploadDescriptor.self, from: encoder.encode(descriptor)) == descriptor)
        #expect(try decoder.decode(BeaconBackupUploadState.self, from: encoder.encode(state)) == state)
    }

    private func fixture(key: SymmetricKey) throws -> BeaconBackupBundle {
        try BeaconBackupBundle.make(
            backupID: "backup-a",
            profileID: "profile-a",
            createdAt: Date(timeIntervalSinceReferenceDate: 123),
            keyID: BeaconArchiveCrypto.keyID(for: key),
            chunks: [
                .init(index: 0, relativePath: "defaults/business.json", data: Data("daily record".utf8)),
                .init(index: 1, relativePath: "memory/confirmed.json", data: Data("confirmed shoulder preference".utf8))
            ]
        )
    }
}
