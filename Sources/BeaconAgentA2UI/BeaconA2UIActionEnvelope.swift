import Foundation
import BeaconAgentCore

/// User actions contain only surface-local data. Trusted identity is injected by the host.
public struct BeaconA2UIActionEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let surfaceID: String
    public let componentID: String
    public let actionID: String
    public let name: String
    public let payload: [String: BeaconJSONValue]

    public init(
        schemaVersion: Int = 1,
        surfaceID: String,
        componentID: String,
        actionID: String,
        name: String,
        payload: [String: BeaconJSONValue]
    ) {
        self.schemaVersion = schemaVersion
        self.surfaceID = surfaceID
        self.componentID = componentID
        self.actionID = actionID
        self.name = name
        self.payload = payload
    }
}
