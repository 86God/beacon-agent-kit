import Foundation
import BeaconAgentCore

public enum BeaconAGUIResumeDecision: Equatable, Sendable {
    case accepted
    case duplicate
    case gap(expected: Int, received: Int)
}

public enum BeaconAGUIResumeError: Error, Equatable, Sendable {
    case eventCollision(String)
    case sequenceCollision(Int)
}

public struct BeaconAGUIResumeCursor: Sendable {
    public private(set) var lastEventID: String?
    public private(set) var nextSequence: Int
    private var seenEvents: [String: BeaconAgentEventV2]

    public init(lastEventID: String? = nil, nextSequence: Int = 0) {
        self.lastEventID = lastEventID
        self.nextSequence = nextSequence
        seenEvents = [:]
    }

    public mutating func accept(
        _ event: BeaconAgentEventV2,
        serverEventID: String?
    ) throws -> BeaconAGUIResumeDecision {
        if let previous = seenEvents[event.eventId] {
            guard previous == event else {
                throw BeaconAGUIResumeError.eventCollision(event.eventId)
            }
            return .duplicate
        }
        if event.sequence < nextSequence {
            throw BeaconAGUIResumeError.sequenceCollision(event.sequence)
        }
        if event.sequence > nextSequence {
            return .gap(expected: nextSequence, received: event.sequence)
        }
        seenEvents[event.eventId] = event
        nextSequence += 1
        lastEventID = serverEventID ?? event.eventId
        return .accepted
    }

    public func apply(to request: inout URLRequest) {
        if let lastEventID {
            request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID")
        }
    }
}
