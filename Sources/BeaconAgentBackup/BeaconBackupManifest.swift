import CryptoKit
import Foundation

public struct BeaconBackupLimits: Equatable, Sendable {
    public static let `default` = BeaconBackupLimits(
        maxChunkCount: 64,
        maxChunkBytes: 2 * 1_024 * 1_024,
        maxArchiveBytes: 16 * 1_024 * 1_024
    )

    public let maxChunkCount: Int
    public let maxChunkBytes: Int
    public let maxArchiveBytes: Int

    public init(maxChunkCount: Int, maxChunkBytes: Int, maxArchiveBytes: Int) {
        self.maxChunkCount = maxChunkCount
        self.maxChunkBytes = maxChunkBytes
        self.maxArchiveBytes = maxArchiveBytes
    }
}

public struct BeaconBackupChunkDescriptor: Codable, Equatable, Sendable {
    public let index: Int
    public let relativePath: String
    public let byteCount: Int
    public let sha256: String
    public let required: Bool

    public init(index: Int, relativePath: String, byteCount: Int, sha256: String, required: Bool = true) {
        self.index = index
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
        self.required = required
    }
}

public struct BeaconBackupChunk: Codable, Equatable, Sendable {
    public let index: Int
    public let relativePath: String
    public let data: Data

    public init(index: Int, relativePath: String, data: Data) {
        self.index = index
        self.relativePath = relativePath
        self.data = data
    }
}

public struct BeaconBackupManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let backupID: String
    public let profileID: String
    public let createdAt: Date
    public let keyID: String
    public let chunks: [BeaconBackupChunkDescriptor]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        backupID: String,
        profileID: String,
        createdAt: Date,
        keyID: String,
        chunks: [BeaconBackupChunkDescriptor]
    ) {
        self.schemaVersion = schemaVersion
        self.backupID = backupID
        self.profileID = profileID
        self.createdAt = createdAt
        self.keyID = keyID
        self.chunks = chunks
    }
}

public struct BeaconBackupBundle: Codable, Equatable, Sendable {
    public var manifest: BeaconBackupManifest
    public var chunks: [BeaconBackupChunk]

    public init(manifest: BeaconBackupManifest, chunks: [BeaconBackupChunk]) {
        self.manifest = manifest
        self.chunks = chunks
    }

    public static func make(
        schemaVersion: Int = BeaconBackupManifest.currentSchemaVersion,
        backupID: String,
        profileID: String,
        createdAt: Date,
        keyID: String,
        limits: BeaconBackupLimits = .default,
        chunks: [BeaconBackupChunk]
    ) throws -> BeaconBackupBundle {
        let descriptors = chunks.map {
            BeaconBackupChunkDescriptor(
                index: $0.index,
                relativePath: $0.relativePath,
                byteCount: $0.data.count,
                sha256: BeaconBackupValidator.digest($0.data)
            )
        }
        let bundle = BeaconBackupBundle(
            manifest: BeaconBackupManifest(
                schemaVersion: schemaVersion,
                backupID: backupID,
                profileID: profileID,
                createdAt: createdAt,
                keyID: keyID,
                chunks: descriptors
            ),
            chunks: chunks
        )
        try BeaconBackupValidator.validate(bundle, limits: limits)
        return bundle
    }
}

public enum BeaconBackupError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidIdentifier
    case unsafeRelativePath(String)
    case duplicateChunkPath(String)
    case duplicateChunkIndex(Int)
    case nonContiguousChunkIndices
    case tooManyChunks
    case chunkTooLarge(String)
    case archiveTooLarge
    case missingChunk(String)
    case unexpectedChunk(String)
    case chunkMetadataMismatch(String)
    case authenticationFailed
    case invalidEnvelope
}

public enum BeaconBackupValidator {
    public static func validate(
        _ bundle: BeaconBackupBundle,
        limits: BeaconBackupLimits = .default
    ) throws {
        let manifest = bundle.manifest
        guard manifest.schemaVersion == BeaconBackupManifest.currentSchemaVersion else {
            throw BeaconBackupError.unsupportedSchemaVersion(manifest.schemaVersion)
        }
        guard !manifest.backupID.isEmpty, !manifest.profileID.isEmpty, !manifest.keyID.isEmpty else {
            throw BeaconBackupError.invalidIdentifier
        }
        guard manifest.chunks.count <= limits.maxChunkCount,
              bundle.chunks.count <= limits.maxChunkCount else {
            throw BeaconBackupError.tooManyChunks
        }

        try validateUniqueDescriptors(manifest.chunks)
        try validateUniqueChunks(bundle.chunks)

        let descriptorIndices = manifest.chunks.map(\.index).sorted()
        guard descriptorIndices == Array(0..<descriptorIndices.count) else {
            throw BeaconBackupError.nonContiguousChunkIndices
        }

        let chunksByPath = Dictionary(uniqueKeysWithValues: bundle.chunks.map { ($0.relativePath, $0) })
        let descriptorsByPath = Dictionary(uniqueKeysWithValues: manifest.chunks.map { ($0.relativePath, $0) })
        var totalBytes = 0
        for descriptor in manifest.chunks {
            guard let chunk = chunksByPath[descriptor.relativePath] else {
                if descriptor.required { throw BeaconBackupError.missingChunk(descriptor.relativePath) }
                continue
            }
            guard chunk.index == descriptor.index,
                  chunk.data.count == descriptor.byteCount,
                  digest(chunk.data) == descriptor.sha256 else {
                throw BeaconBackupError.chunkMetadataMismatch(descriptor.relativePath)
            }
            guard chunk.data.count <= limits.maxChunkBytes else {
                throw BeaconBackupError.chunkTooLarge(chunk.relativePath)
            }
            totalBytes += chunk.data.count
        }
        for chunk in bundle.chunks where descriptorsByPath[chunk.relativePath] == nil {
            throw BeaconBackupError.unexpectedChunk(chunk.relativePath)
        }
        guard totalBytes <= limits.maxArchiveBytes else {
            throw BeaconBackupError.archiveTooLarge
        }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validateUniqueDescriptors(_ descriptors: [BeaconBackupChunkDescriptor]) throws {
        var paths = Set<String>()
        var indices = Set<Int>()
        for descriptor in descriptors {
            try validate(path: descriptor.relativePath)
            guard paths.insert(descriptor.relativePath).inserted else {
                throw BeaconBackupError.duplicateChunkPath(descriptor.relativePath)
            }
            guard indices.insert(descriptor.index).inserted else {
                throw BeaconBackupError.duplicateChunkIndex(descriptor.index)
            }
        }
    }

    private static func validateUniqueChunks(_ chunks: [BeaconBackupChunk]) throws {
        var paths = Set<String>()
        var indices = Set<Int>()
        for chunk in chunks {
            try validate(path: chunk.relativePath)
            guard paths.insert(chunk.relativePath).inserted else {
                throw BeaconBackupError.duplicateChunkPath(chunk.relativePath)
            }
            guard indices.insert(chunk.index).inserted else {
                throw BeaconBackupError.duplicateChunkIndex(chunk.index)
            }
        }
    }

    private static func validate(path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw BeaconBackupError.unsafeRelativePath(path)
        }
    }
}
