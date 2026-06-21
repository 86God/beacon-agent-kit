import Foundation

public protocol BeaconTypedEvent: Codable, Equatable, Identifiable, Sendable {
    static var eventType: String { get }
    var id: String { get }
    var type: String { get }
    var schemaVersion: Int { get }
}

public struct BeaconRunStartedEvent: BeaconTypedEvent {
    public static let eventType = "run.started"
    public let id: String
    public let type: String
    public let schemaVersion: Int
    public let threadId: String
    public let runId: String
    public let createdAt: String?

    public init(id: String = UUID().uuidString, threadId: String, runId: String, createdAt: String? = nil, schemaVersion: Int = 1) {
        self.id = id
        self.type = Self.eventType
        self.schemaVersion = schemaVersion
        self.threadId = threadId
        self.runId = runId
        self.createdAt = createdAt
    }
}

public struct BeaconRunFinishedEvent: BeaconTypedEvent {
    public static let eventType = "run.finished"
    public let id: String
    public let type: String
    public let schemaVersion: Int
    public let threadId: String?
    public let runId: String
    public let finishedAt: String?

    public init(id: String = UUID().uuidString, threadId: String? = nil, runId: String, finishedAt: String? = nil, schemaVersion: Int = 1) {
        self.id = id
        self.type = Self.eventType
        self.schemaVersion = schemaVersion
        self.threadId = threadId
        self.runId = runId
        self.finishedAt = finishedAt
    }
}

public struct BeaconRunErrorEvent: BeaconTypedEvent {
    public static let eventType = "run.error"
    public let id: String
    public let type: String
    public let schemaVersion: Int
    public let threadId: String?
    public let runId: String?
    public let errorSummary: String

    public init(id: String = UUID().uuidString, threadId: String? = nil, runId: String? = nil, errorSummary: String, schemaVersion: Int = 1) {
        self.id = id
        self.type = Self.eventType
        self.schemaVersion = schemaVersion
        self.threadId = threadId
        self.runId = runId
        self.errorSummary = BeaconRedactor.displayText(errorSummary)
    }
}

public struct BeaconMessageStartedEvent: BeaconTypedEvent {
    public static let eventType = "message.started"
    public let id: String
    public let type: String
    public let schemaVersion: Int
    public let messageId: String
    public let role: BeaconMessageRole

    public init(id: String = UUID().uuidString, messageId: String, role: BeaconMessageRole, schemaVersion: Int = 1) {
        self.id = id
        self.type = Self.eventType
        self.schemaVersion = schemaVersion
        self.messageId = messageId
        self.role = role
    }
}

public struct BeaconMessageDeltaEvent: BeaconTypedEvent {
    public static let eventType = "message.delta"
    public let id: String
    public let type: String
    public let schemaVersion: Int
    public let messageId: String
    public let role: BeaconMessageRole
    public let delta: String

    public init(id: String = UUID().uuidString, messageId: String, role: BeaconMessageRole, delta: String, schemaVersion: Int = 1) {
        self.id = id
        self.type = Self.eventType
        self.schemaVersion = schemaVersion
        self.messageId = messageId
        self.role = role
        self.delta = BeaconRedactor.redactedText(delta)
    }
}

public struct BeaconMessageFinishedEvent: BeaconTypedEvent {
    public static let eventType = "message.finished"
    public let id: String
    public let type: String
    public let schemaVersion: Int
    public let messageId: String
    public let role: BeaconMessageRole
    public let finalText: String?

    public init(id: String = UUID().uuidString, messageId: String, role: BeaconMessageRole, finalText: String? = nil, schemaVersion: Int = 1) {
        self.id = id
        self.type = Self.eventType
        self.schemaVersion = schemaVersion
        self.messageId = messageId
        self.role = role
        self.finalText = BeaconRedactor.optionalDisplayText(finalText)
    }
}

public struct BeaconToolStartedEvent: BeaconTypedEvent {
    public static let eventType = "tool.started"
    public let id: String
    public let type: String
    public let schemaVersion: Int
    public let toolRunId: String
    public let toolName: String
    public let title: String
    public let inputSummary: String?
    public let startedAt: String?

    public init(id: String = UUID().uuidString, toolRunId: String, toolName: String, title: String, inputSummary: String? = nil, startedAt: String? = nil, schemaVersion: Int = 1) {
        self.id = id
        self.type = Self.eventType
        self.schemaVersion = schemaVersion
        self.toolRunId = toolRunId
        self.toolName = BeaconRedactor.displayText(toolName)
        self.title = BeaconRedactor.displayText(title)
        self.inputSummary = BeaconRedactor.optionalDisplayText(inputSummary)
        self.startedAt = startedAt
    }
}

public struct BeaconToolArgsDeltaEvent: BeaconTypedEvent {
    public static let eventType = "tool.args.delta"
    public let id: String
    public let type: String
    public let schemaVersion: Int
    public let toolRunId: String
    public let argsDeltaSummary: String

    public init(id: String = UUID().uuidString, toolRunId: String, argsDeltaSummary: String, schemaVersion: Int = 1) {
        self.id = id
        self.type = Self.eventType
        self.schemaVersion = schemaVersion
        self.toolRunId = toolRunId
        self.argsDeltaSummary = BeaconRedactor.displayText(argsDeltaSummary)
    }
}

public struct BeaconToolFinishedEvent: BeaconTypedEvent {
    public static let eventType = "tool.finished"
    public let id: String
    public let type: String
    public let schemaVersion: Int
    public let toolRunId: String
    public let status: BeaconToolRun.Status
    public let outputSummary: String?
    public let finishedAt: String?

    public init(id: String = UUID().uuidString, toolRunId: String, status: BeaconToolRun.Status = .succeeded, outputSummary: String? = nil, finishedAt: String? = nil, schemaVersion: Int = 1) {
        self.id = id
        self.type = Self.eventType
        self.schemaVersion = schemaVersion
        self.toolRunId = toolRunId
        self.status = status
        self.outputSummary = BeaconRedactor.optionalDisplayText(outputSummary)
        self.finishedAt = finishedAt
    }
}

public struct BeaconToolFailedEvent: BeaconTypedEvent {
    public static let eventType = "tool.failed"
    public let id: String
    public let type: String
    public let schemaVersion: Int
    public let toolRunId: String
    public let errorSummary: String
    public let finishedAt: String?

    public init(id: String = UUID().uuidString, toolRunId: String, errorSummary: String, finishedAt: String? = nil, schemaVersion: Int = 1) {
        self.id = id
        self.type = Self.eventType
        self.schemaVersion = schemaVersion
        self.toolRunId = toolRunId
        self.errorSummary = BeaconRedactor.displayText(errorSummary)
        self.finishedAt = finishedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case schemaVersion
        case toolRunId
        case errorSummary
        case finishedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            toolRunId: try container.decode(String.self, forKey: .toolRunId),
            errorSummary: try container.decode(String.self, forKey: .errorSummary),
            finishedAt: try container.decodeIfPresent(String.self, forKey: .finishedAt),
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion)
        )
    }
}

public struct BeaconCardCreatedEvent: BeaconTypedEvent {
    public static let eventType = "card.created"
    public let id: String
    public let type: String
    public let schemaVersion: Int
    public let card: BeaconCardEnvelope

    public init(id: String = UUID().uuidString, card: BeaconCardEnvelope, schemaVersion: Int = 1) {
        self.id = id
        self.type = Self.eventType
        self.schemaVersion = schemaVersion
        self.card = card
    }
}

public struct BeaconCardUpdatedEvent: BeaconTypedEvent {
    public static let eventType = "card.updated"
    public let id: String
    public let type: String
    public let schemaVersion: Int
    public let card: BeaconCardEnvelope

    public init(id: String = UUID().uuidString, card: BeaconCardEnvelope, schemaVersion: Int = 1) {
        self.id = id
        self.type = Self.eventType
        self.schemaVersion = schemaVersion
        self.card = card
    }
}

public struct BeaconCustomEvent: BeaconTypedEvent {
    public static let eventType = "custom"
    public let id: String
    public let type: String
    public let schemaVersion: Int
    public let name: String
    public let summary: String?

    public init(id: String = UUID().uuidString, type: String = Self.eventType, name: String, summary: String? = nil, schemaVersion: Int = 1) {
        self.id = id
        self.type = BeaconRedactor.displayText(type)
        self.schemaVersion = schemaVersion
        self.name = BeaconRedactor.displayText(name)
        self.summary = BeaconRedactor.optionalDisplayText(summary)
    }
}
