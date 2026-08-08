import Foundation

public enum BeaconCapabilityKind: String, Codable, Sendable {
    case tool, skill, workflow, knowledge, surface
}

public enum BeaconExecutionLocation: String, Codable, Sendable {
    case server, device, either
}

public enum BeaconCapabilityRisk: String, Codable, Sendable {
    case readOnly = "read_only"
    case reversibleDraft = "reversible_draft"
    case consequentialWrite = "consequential_write"
    case destructive
}

public enum BeaconConfirmationPolicy: String, Codable, Sendable {
    case never
    case beforeCommit = "before_commit"
    case always
}

public enum BeaconIdempotencyPolicy: String, Codable, Sendable {
    case none, optional, required
}

public struct BeaconCapabilityManifest: Codable, Equatable, Sendable {
    public static let supportedSchemaVersion = 2

    public let schemaVersion: Int
    public let id: String
    public let version: String
    public let kind: BeaconCapabilityKind
    public let title: String
    public let description: String
    public let intentExamples: [String]
    public let inputSchema: [String: BeaconJSONValue]
    public let outputSchema: [String: BeaconJSONValue]
    public let executionLocation: BeaconExecutionLocation
    public let risk: BeaconCapabilityRisk
    public let requiredScopes: [String]
    public let confirmation: BeaconConfirmationPolicy
    public let idempotency: BeaconIdempotencyPolicy
    public let dependencies: [String]
    public let surface: String?
    public let tags: [String]
    public let fallback: String?
    public let offlineSafe: Bool

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, version, kind, title, description, intentExamples
        case inputSchema, outputSchema, executionLocation, risk, requiredScopes
        case confirmation, idempotency, dependencies, surface, tags, fallback, offlineSafe
    }

    public init(
        schemaVersion: Int = Self.supportedSchemaVersion,
        id: String,
        version: String,
        kind: BeaconCapabilityKind,
        title: String,
        description: String,
        intentExamples: [String],
        inputSchema: [String: BeaconJSONValue],
        outputSchema: [String: BeaconJSONValue],
        executionLocation: BeaconExecutionLocation,
        risk: BeaconCapabilityRisk,
        requiredScopes: [String],
        confirmation: BeaconConfirmationPolicy,
        idempotency: BeaconIdempotencyPolicy,
        dependencies: [String] = [],
        surface: String? = nil,
        tags: [String],
        fallback: String? = nil,
        offlineSafe: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.version = version
        self.kind = kind
        self.title = title
        self.description = description
        self.intentExamples = intentExamples
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.executionLocation = executionLocation
        self.risk = risk
        self.requiredScopes = requiredScopes
        self.confirmation = confirmation
        self.idempotency = idempotency
        self.dependencies = dependencies
        self.surface = surface
        self.tags = tags
        self.fallback = fallback
        self.offlineSafe = offlineSafe
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard (1...Self.supportedSchemaVersion).contains(schemaVersion) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported required capability schema version"
            )
        }
        id = try container.decode(String.self, forKey: .id)
        version = try container.decode(String.self, forKey: .version)
        kind = try container.decode(BeaconCapabilityKind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decode(String.self, forKey: .description)
        intentExamples = try container.decode([String].self, forKey: .intentExamples)
        inputSchema = try container.decode([String: BeaconJSONValue].self, forKey: .inputSchema)
        outputSchema = try container.decode([String: BeaconJSONValue].self, forKey: .outputSchema)
        executionLocation = try container.decode(BeaconExecutionLocation.self, forKey: .executionLocation)
        risk = try container.decode(BeaconCapabilityRisk.self, forKey: .risk)
        requiredScopes = try container.decode([String].self, forKey: .requiredScopes)
        confirmation = try container.decode(BeaconConfirmationPolicy.self, forKey: .confirmation)
        idempotency = try container.decode(BeaconIdempotencyPolicy.self, forKey: .idempotency)
        dependencies = try container.decode([String].self, forKey: .dependencies)
        surface = try container.decodeIfPresent(String.self, forKey: .surface)
        tags = try container.decode([String].self, forKey: .tags)
        fallback = try container.decodeIfPresent(String.self, forKey: .fallback)
        offlineSafe = try container.decodeIfPresent(Bool.self, forKey: .offlineSafe) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(version, forKey: .version)
        try container.encode(kind, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encode(description, forKey: .description)
        try container.encode(intentExamples, forKey: .intentExamples)
        try container.encode(inputSchema, forKey: .inputSchema)
        try container.encode(outputSchema, forKey: .outputSchema)
        try container.encode(executionLocation, forKey: .executionLocation)
        try container.encode(risk, forKey: .risk)
        try container.encode(requiredScopes, forKey: .requiredScopes)
        try container.encode(confirmation, forKey: .confirmation)
        try container.encode(idempotency, forKey: .idempotency)
        try container.encode(dependencies, forKey: .dependencies)
        try container.encodeIfPresent(surface, forKey: .surface)
        try container.encode(tags, forKey: .tags)
        try container.encodeIfPresent(fallback, forKey: .fallback)
        try container.encode(offlineSafe, forKey: .offlineSafe)
    }
}
