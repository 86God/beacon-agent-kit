import Foundation

/// Role used by generic timeline messages.
public enum BeaconMessageRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
    case system
}

/// A redacted message ready to render in a timeline.
public struct BeaconTimelineMessage: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let role: BeaconMessageRole
    public let text: String

    public init(id: String = UUID().uuidString, role: BeaconMessageRole, text: String) {
        self.id = id
        self.role = role
        self.text = BeaconRedactor.displayText(text)
    }
}

/// Reducer-owned timeline projection of messages, tool runs, cards, and active deltas.
public struct BeaconTimelineState: Codable, Equatable, Sendable {
    public var messages: [BeaconTimelineMessage]
    public var toolRuns: [BeaconToolRun]
    public var cards: [BeaconCardEnvelope]
    public var activeMessageDeltas: [String: String]

    public init(
        messages: [BeaconTimelineMessage] = [],
        toolRuns: [BeaconToolRun] = [],
        cards: [BeaconCardEnvelope] = [],
        activeMessageDeltas: [String: String] = [:]
    ) {
        self.messages = messages
        self.toolRuns = toolRuns
        self.cards = cards
        self.activeMessageDeltas = activeMessageDeltas
    }
}
