import Foundation
import BeaconAgentCore

public struct BeaconNotificationEvent: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case received
        case actionTapped
        case dismissed
    }

    public let id: String
    public let kind: Kind
    public let notificationId: String
    public let actionId: String?

    public init(id: String = UUID().uuidString, kind: Kind, notificationId: String, actionId: String? = nil) {
        self.id = id
        self.kind = kind
        self.notificationId = notificationId
        self.actionId = actionId
    }
}
