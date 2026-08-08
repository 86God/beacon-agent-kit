import Foundation
import BeaconAgentCore
import BeaconAgentA2UI

public struct BeaconMCPTool: Equatable, Sendable {
    public let name: String
    public let title: String?
    public let description: String
    public let inputSchema: [String: BeaconJSONValue]
    public let outputSchema: [String: BeaconJSONValue]?
    public let annotations: [String: BeaconJSONValue]
    public let metadata: [String: BeaconJSONValue]

    public init(
        name: String,
        title: String? = nil,
        description: String,
        inputSchema: [String: BeaconJSONValue],
        outputSchema: [String: BeaconJSONValue]? = nil,
        annotations: [String: BeaconJSONValue] = [:],
        metadata: [String: BeaconJSONValue] = [:]
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.annotations = annotations
        self.metadata = metadata
    }
}

public struct BeaconMCPPolicyProfile: Equatable, Sendable {
    public let capabilityID: String
    public let executionLocation: BeaconExecutionLocation
    public let risk: BeaconCapabilityRisk
    public let requiredScopes: [String]
    public let confirmation: BeaconConfirmationPolicy
    public let idempotency: BeaconIdempotencyPolicy
    public let tags: [String]

    public init(
        capabilityID: String,
        executionLocation: BeaconExecutionLocation,
        risk: BeaconCapabilityRisk,
        requiredScopes: [String],
        confirmation: BeaconConfirmationPolicy,
        idempotency: BeaconIdempotencyPolicy,
        tags: [String]
    ) {
        self.capabilityID = capabilityID
        self.executionLocation = executionLocation
        self.risk = risk
        self.requiredScopes = requiredScopes
        self.confirmation = confirmation
        self.idempotency = idempotency
        self.tags = tags
    }

    public static func readOnly(
        capabilityID: String,
        requiredScopes: [String],
        tags: [String],
        executionLocation: BeaconExecutionLocation = .either
    ) -> Self {
        Self(
            capabilityID: capabilityID,
            executionLocation: executionLocation,
            risk: .readOnly,
            requiredScopes: requiredScopes,
            confirmation: .never,
            idempotency: .none,
            tags: tags
        )
    }
}

public enum BeaconMCPContent: Equatable, Sendable {
    case text(String)
    case resource(BeaconMCPResource)
}

public struct BeaconMCPToolResult: Equatable, Sendable {
    public let content: [BeaconMCPContent]
    public let structuredContent: [String: BeaconJSONValue]
    public let isError: Bool

    public init(
        content: [BeaconMCPContent] = [],
        structuredContent: [String: BeaconJSONValue] = [:],
        isError: Bool = false
    ) {
        self.content = content
        self.structuredContent = structuredContent
        self.isError = isError
    }
}

public struct BeaconNormalizedMCPResult: Equatable, Sendable {
    public let content: [BeaconMCPContent]
    public let structuredContent: [String: BeaconJSONValue]
    public let surface: BeaconA2UISurface?
    public let confirmationRequired: Bool
    public let isError: Bool
}

public struct BeaconMCPResource: Equatable, Sendable {
    public let uri: String
    public let mimeType: String
    public let text: String?
    public let blob: Data?

    public init(uri: String, mimeType: String, text: String? = nil, blob: Data? = nil) {
        self.uri = uri
        self.mimeType = mimeType
        self.text = text
        self.blob = blob
    }
}

public enum BeaconMCPAdapterError: Error, Equatable, Sendable {
    case invalidTool
    case forbiddenTool(String)
    case invalidAppURI(String)
    case invalidStructuredResult
    case invalidSurface
}

public enum BeaconMCPResourceError: Error, Equatable, Sendable {
    case invalidURI(String)
    case notFound(String)
    case invalidMIMEType(String)
    case oversized(String)
}
