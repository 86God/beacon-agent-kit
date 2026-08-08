import Foundation
import BeaconAgentCore

public struct BeaconDeviceToolRequest: Equatable, Sendable {
    public let runID: String
    public let toolCallID: String
    public let capabilityID: String
    public let schemaVersion: Int
    public let registryRevision: String
    public let requestedScopes: Set<String>
    public let arguments: [String: BeaconJSONValue]
    public let idempotencyKey: String?
    public let expiresAt: Date

    public init(
        runID: String,
        toolCallID: String,
        capabilityID: String,
        schemaVersion: Int,
        registryRevision: String,
        requestedScopes: Set<String>,
        arguments: [String: BeaconJSONValue],
        idempotencyKey: String?,
        expiresAt: Date
    ) {
        self.runID = runID
        self.toolCallID = toolCallID
        self.capabilityID = capabilityID
        self.schemaVersion = schemaVersion
        self.registryRevision = registryRevision
        self.requestedScopes = requestedScopes
        self.arguments = arguments
        self.idempotencyKey = idempotencyKey
        self.expiresAt = expiresAt
    }
}

public struct BeaconAuthorizedToolRequest: Equatable, Sendable {
    public let runID: String
    public let toolCallID: String
    public let capabilityID: String
    public let registryRevision: String
    public let arguments: [String: BeaconJSONValue]
    public let idempotencyKey: String?
    public let trustedHostContext: BeaconTrustedHostContext

    init(request: BeaconDeviceToolRequest, trustedHostContext: BeaconTrustedHostContext) {
        runID = request.runID
        toolCallID = request.toolCallID
        capabilityID = request.capabilityID
        registryRevision = request.registryRevision
        arguments = request.arguments
        idempotencyKey = request.idempotencyKey
        self.trustedHostContext = trustedHostContext
    }
}

public struct BeaconToolObservation: Equatable, Sendable {
    public let toolCallID: String
    public let capabilityID: String
    public let payload: [String: BeaconJSONValue]
    public let idempotentReplay: Bool

    public init(
        toolCallID: String,
        capabilityID: String,
        payload: [String: BeaconJSONValue],
        idempotentReplay: Bool = false
    ) {
        self.toolCallID = toolCallID
        self.capabilityID = capabilityID
        self.payload = payload
        self.idempotentReplay = idempotentReplay
    }

    func replayed(for toolCallID: String) -> BeaconToolObservation {
        BeaconToolObservation(
            toolCallID: toolCallID,
            capabilityID: capabilityID,
            payload: payload,
            idempotentReplay: true
        )
    }
}

public protocol BeaconDeviceToolHandler: Sendable {
    var capabilityID: String { get }
    func execute(_ request: BeaconAuthorizedToolRequest) async throws -> BeaconToolObservation
}
