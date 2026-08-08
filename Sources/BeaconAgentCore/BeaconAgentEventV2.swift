import Foundation

/// The language-neutral v0.2 event envelope. Domain payloads remain opaque JSON.
public struct BeaconAgentEventV2: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let eventId: String
    public let runId: String
    public let sequence: Int
    public let type: String
    public let payload: [String: BeaconJSONValue]

    public init(
        schemaVersion: Int,
        eventId: String,
        runId: String,
        sequence: Int,
        type: String,
        payload: [String: BeaconJSONValue]
    ) {
        self.schemaVersion = schemaVersion
        self.eventId = eventId
        self.runId = runId
        self.sequence = sequence
        self.type = type
        self.payload = payload
    }
}
