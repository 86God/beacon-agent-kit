import Foundation
import BeaconAgentCore

public struct BeaconMotionEvent: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case activityChanged
        case stationary
        case walking
        case running
        case cycling
    }

    public let id: String
    public let kind: Kind

    public init(id: String = UUID().uuidString, kind: Kind) {
        self.id = id
        self.kind = kind
    }
}
