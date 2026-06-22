import Foundation

/// Display-safe state for a tool invocation shown in a timeline or review surface.
public struct BeaconToolRun: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable {
        case queued
        case running
        case succeeded
        case failed
        case needsReview
        case cancelled
    }

    public let id: String
    public let toolName: String
    public let title: String
    public let status: Status
    public let summary: String
    public let inputSummary: String?
    public let outputSummary: String?
    public let errorSummary: String?
    public let startedAt: String?
    public let finishedAt: String?

    public init(
        id: String = UUID().uuidString,
        toolName: String,
        title: String,
        status: Status,
        summary: String,
        inputSummary: String? = nil,
        outputSummary: String? = nil,
        errorSummary: String? = nil,
        startedAt: String? = nil,
        finishedAt: String? = nil
    ) {
        self.id = id
        self.toolName = BeaconRedactor.displayText(toolName)
        self.title = BeaconRedactor.displayText(title)
        self.status = status
        self.summary = BeaconRedactor.displayText(summary)
        self.inputSummary = BeaconRedactor.optionalDisplayText(inputSummary)
        self.outputSummary = BeaconRedactor.optionalDisplayText(outputSummary)
        self.errorSummary = BeaconRedactor.optionalDisplayText(errorSummary)
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}
