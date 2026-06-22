import Foundation

/// Generic conversation container owned by the host app's persistence layer.
public struct BeaconAgentThread: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let createdAt: String
    public let updatedAt: String?
    public let metadata: [String: BeaconJSONValue]

    public init(
        id: String = UUID().uuidString,
        title: String,
        createdAt: String,
        updatedAt: String? = nil,
        metadata: [String: BeaconJSONValue] = [:]
    ) {
        self.id = id
        self.title = BeaconRedactor.displayText(title)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadata = metadata
    }
}
