import Foundation
import BeaconAgentCore

public struct BeaconAppLifecycleEvent: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case launched
        case enteredForeground
        case enteredBackground
    }

    public let id: String
    public let kind: Kind
    public let appSessionId: String?

    public init(id: String = UUID().uuidString, kind: Kind, appSessionId: String? = nil) {
        self.id = id
        self.kind = kind
        self.appSessionId = appSessionId
    }
}
