import Foundation

/// Minimal state for one agent execution attempt inside a thread.
public struct BeaconAgentRun: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable {
        case queued
        case running
        case succeeded
        case failed
        case cancelled
    }

    public let id: String
    public let threadId: String
    public let status: Status
    public let startedAt: String?
    public let finishedAt: String?

    public init(
        id: String = UUID().uuidString,
        threadId: String,
        status: Status,
        startedAt: String? = nil,
        finishedAt: String? = nil
    ) {
        self.id = id
        self.threadId = threadId
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}
