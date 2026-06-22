import Foundation

/// A transport-agnostic event envelope for agent runs, messages, tools, cards, and vendor extensions.
public enum BeaconAgentEvent: Codable, Equatable, Identifiable, Sendable {
    case runStarted(BeaconRunStartedEvent)
    case runFinished(BeaconRunFinishedEvent)
    case runError(BeaconRunErrorEvent)
    case messageStarted(BeaconMessageStartedEvent)
    case messageDelta(BeaconMessageDeltaEvent)
    case messageFinished(BeaconMessageFinishedEvent)
    case toolStarted(BeaconToolStartedEvent)
    case toolArgsDelta(BeaconToolArgsDeltaEvent)
    case toolFinished(BeaconToolFinishedEvent)
    case toolFailed(BeaconToolFailedEvent)
    case cardCreated(BeaconCardCreatedEvent)
    case cardUpdated(BeaconCardUpdatedEvent)
    case custom(BeaconCustomEvent)

    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case schemaVersion
        case name
        case summary
    }

    public var id: String {
        switch self {
        case let .runStarted(event): event.id
        case let .runFinished(event): event.id
        case let .runError(event): event.id
        case let .messageStarted(event): event.id
        case let .messageDelta(event): event.id
        case let .messageFinished(event): event.id
        case let .toolStarted(event): event.id
        case let .toolArgsDelta(event): event.id
        case let .toolFinished(event): event.id
        case let .toolFailed(event): event.id
        case let .cardCreated(event): event.id
        case let .cardUpdated(event): event.id
        case let .custom(event): event.id
        }
    }

    public var type: String {
        switch self {
        case .runStarted: BeaconRunStartedEvent.eventType
        case .runFinished: BeaconRunFinishedEvent.eventType
        case .runError: BeaconRunErrorEvent.eventType
        case .messageStarted: BeaconMessageStartedEvent.eventType
        case .messageDelta: BeaconMessageDeltaEvent.eventType
        case .messageFinished: BeaconMessageFinishedEvent.eventType
        case .toolStarted: BeaconToolStartedEvent.eventType
        case .toolArgsDelta: BeaconToolArgsDeltaEvent.eventType
        case .toolFinished: BeaconToolFinishedEvent.eventType
        case .toolFailed: BeaconToolFailedEvent.eventType
        case .cardCreated: BeaconCardCreatedEvent.eventType
        case .cardUpdated: BeaconCardUpdatedEvent.eventType
        case let .custom(event): event.type
        }
    }

    public var schemaVersion: Int {
        switch self {
        case let .runStarted(event): event.schemaVersion
        case let .runFinished(event): event.schemaVersion
        case let .runError(event): event.schemaVersion
        case let .messageStarted(event): event.schemaVersion
        case let .messageDelta(event): event.schemaVersion
        case let .messageFinished(event): event.schemaVersion
        case let .toolStarted(event): event.schemaVersion
        case let .toolArgsDelta(event): event.schemaVersion
        case let .toolFinished(event): event.schemaVersion
        case let .toolFailed(event): event.schemaVersion
        case let .cardCreated(event): event.schemaVersion
        case let .cardUpdated(event): event.schemaVersion
        case let .custom(event): event.schemaVersion
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case BeaconRunStartedEvent.eventType:
            self = .runStarted(try BeaconRunStartedEvent(from: decoder))
        case BeaconRunFinishedEvent.eventType:
            self = .runFinished(try BeaconRunFinishedEvent(from: decoder))
        case BeaconRunErrorEvent.eventType:
            self = .runError(try BeaconRunErrorEvent(from: decoder))
        case BeaconMessageStartedEvent.eventType:
            self = .messageStarted(try BeaconMessageStartedEvent(from: decoder))
        case BeaconMessageDeltaEvent.eventType:
            self = .messageDelta(try BeaconMessageDeltaEvent(from: decoder))
        case BeaconMessageFinishedEvent.eventType:
            self = .messageFinished(try BeaconMessageFinishedEvent(from: decoder))
        case BeaconToolStartedEvent.eventType:
            self = .toolStarted(try BeaconToolStartedEvent(from: decoder))
        case BeaconToolArgsDeltaEvent.eventType:
            self = .toolArgsDelta(try BeaconToolArgsDeltaEvent(from: decoder))
        case BeaconToolFinishedEvent.eventType:
            self = .toolFinished(try BeaconToolFinishedEvent(from: decoder))
        case BeaconToolFailedEvent.eventType:
            self = .toolFailed(try BeaconToolFailedEvent(from: decoder))
        case BeaconCardCreatedEvent.eventType:
            self = .cardCreated(try BeaconCardCreatedEvent(from: decoder))
        case BeaconCardUpdatedEvent.eventType:
            self = .cardUpdated(try BeaconCardUpdatedEvent(from: decoder))
        case BeaconCustomEvent.eventType:
            self = .custom(try BeaconCustomEvent(from: decoder))
        default:
            self = .custom(
                BeaconCustomEvent(
                    id: (try? container.decode(String.self, forKey: .id)) ?? UUID().uuidString,
                    type: type,
                    name: (try? container.decode(String.self, forKey: .name)) ?? type,
                    summary: try? container.decode(String.self, forKey: .summary),
                    schemaVersion: (try? container.decode(Int.self, forKey: .schemaVersion)) ?? 1
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .runStarted(event): try event.encode(to: encoder)
        case let .runFinished(event): try event.encode(to: encoder)
        case let .runError(event): try event.encode(to: encoder)
        case let .messageStarted(event): try event.encode(to: encoder)
        case let .messageDelta(event): try event.encode(to: encoder)
        case let .messageFinished(event): try event.encode(to: encoder)
        case let .toolStarted(event): try event.encode(to: encoder)
        case let .toolArgsDelta(event): try event.encode(to: encoder)
        case let .toolFinished(event): try event.encode(to: encoder)
        case let .toolFailed(event): try event.encode(to: encoder)
        case let .cardCreated(event): try event.encode(to: encoder)
        case let .cardUpdated(event): try event.encode(to: encoder)
        case let .custom(event): try event.encode(to: encoder)
        }
    }
}
