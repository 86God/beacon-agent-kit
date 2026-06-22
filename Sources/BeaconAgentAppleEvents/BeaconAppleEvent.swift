import Foundation
import BeaconAgentCore

/// Model-only Apple platform event envelope for future adapters and policy evaluation.
public enum BeaconAppleEvent: Codable, Equatable, Identifiable, Sendable {
    case appLifecycle(BeaconAppLifecycleEvent)
    case notification(BeaconNotificationEvent)
    case location(BeaconLocationEvent)
    case motion(BeaconMotionEvent)

    private enum CodingKeys: String, CodingKey {
        case type
        case appLifecycle
        case notification
        case location
        case motion
    }

    public var id: String {
        switch self {
        case let .appLifecycle(event): event.id
        case let .notification(event): event.id
        case let .location(event): event.id
        case let .motion(event): event.id
        }
    }

    public var type: String {
        switch self {
        case let .appLifecycle(event): "app.\(event.kind.rawValue)"
        case let .notification(event): "notification.\(event.kind.rawValue)"
        case let .location(event): "location.\(event.kind.rawValue)"
        case let .motion(event): "motion.\(event.kind.rawValue)"
        }
    }

    public var privacyLevel: BeaconPrivacyLevel {
        switch self {
        case .appLifecycle, .motion:
            return .appState
        case .notification:
            return .notificationContent
        case .location:
            return .locationApproximate
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        if type.hasPrefix("app.") {
            self = .appLifecycle(try container.decode(BeaconAppLifecycleEvent.self, forKey: .appLifecycle))
        } else if type.hasPrefix("notification.") {
            self = .notification(try container.decode(BeaconNotificationEvent.self, forKey: .notification))
        } else if type.hasPrefix("location.") {
            self = .location(try container.decode(BeaconLocationEvent.self, forKey: .location))
        } else {
            self = .motion(try container.decode(BeaconMotionEvent.self, forKey: .motion))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        switch self {
        case let .appLifecycle(event):
            try container.encode(event, forKey: .appLifecycle)
        case let .notification(event):
            try container.encode(event, forKey: .notification)
        case let .location(event):
            try container.encode(event, forKey: .location)
        case let .motion(event):
            try container.encode(event, forKey: .motion)
        }
    }
}
