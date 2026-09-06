import Foundation
import BeaconAgentCore

public enum BeaconOutboxError: Error, Equatable, Sendable {
    case invalidCommand
    case idempotencyConflict(String)
}

public enum BeaconOutboxCommandKind: String, Codable, Equatable, Sendable {
    case deviceToolResume = "device_tool.resume"
    case approvalResume = "approval.resume"
    case actionSubmit = "action.submit"
}

/// Durable commands keep only identifiers and explicit user choices. Tool
/// observations and A2UI arguments are reconstructed from the local journal
/// immediately before dispatch, so drafts and media can never enter the outbox.
public enum BeaconOutboxCommandPayload: Equatable, Sendable {
    case deviceToolResume(toolCallId: String)
    case approvalResume(approvalId: String, approved: Bool)
    case actionSubmit(surfaceId: String, actionId: String)

    fileprivate var kind: BeaconOutboxCommandKind {
        switch self {
        case .deviceToolResume: .deviceToolResume
        case .approvalResume: .approvalResume
        case .actionSubmit: .actionSubmit
        }
    }

    fileprivate func validate() throws {
        do {
            switch self {
            case let .deviceToolResume(toolCallId):
                try BeaconAgentWireValidation.validateIdentifier(toolCallId, field: "toolCallId")
            case let .approvalResume(approvalId, _):
                try BeaconAgentWireValidation.validateIdentifier(approvalId, field: "approvalId")
            case let .actionSubmit(surfaceId, actionId):
                try BeaconAgentWireValidation.validateIdentifier(surfaceId, field: "surfaceId")
                try BeaconAgentWireValidation.validateIdentifier(actionId, field: "actionId")
            }
        } catch {
            throw BeaconOutboxError.invalidCommand
        }
    }
}

extension BeaconOutboxCommandPayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case toolCallId
        case approvalId
        case approved
        case surfaceId
        case actionId
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: BeaconOutboxCodingKey.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(BeaconOutboxCommandKind.self, forKey: .type)
        let allowed: Set<String> = switch kind {
        case .deviceToolResume:
            [CodingKeys.type.rawValue, CodingKeys.toolCallId.rawValue]
        case .approvalResume:
            [CodingKeys.type.rawValue, CodingKeys.approvalId.rawValue, CodingKeys.approved.rawValue]
        case .actionSubmit:
            [CodingKeys.type.rawValue, CodingKeys.surfaceId.rawValue, CodingKeys.actionId.rawValue]
        }
        if let unknown = raw.allKeys.first(where: { !allowed.contains($0.stringValue) }) {
            throw DecodingError.dataCorruptedError(
                forKey: unknown,
                in: raw,
                debugDescription: "unknown durable command field: \(unknown.stringValue)"
            )
        }

        switch kind {
        case .deviceToolResume:
            self = .deviceToolResume(
                toolCallId: try container.decode(String.self, forKey: .toolCallId)
            )
        case .approvalResume:
            self = .approvalResume(
                approvalId: try container.decode(String.self, forKey: .approvalId),
                approved: try container.decode(Bool.self, forKey: .approved)
            )
        case .actionSubmit:
            self = .actionSubmit(
                surfaceId: try container.decode(String.self, forKey: .surfaceId),
                actionId: try container.decode(String.self, forKey: .actionId)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .type)
        switch self {
        case let .deviceToolResume(toolCallId):
            try container.encode(toolCallId, forKey: .toolCallId)
        case let .approvalResume(approvalId, approved):
            try container.encode(approvalId, forKey: .approvalId)
            try container.encode(approved, forKey: .approved)
        case let .actionSubmit(surfaceId, actionId):
            try container.encode(surfaceId, forKey: .surfaceId)
            try container.encode(actionId, forKey: .actionId)
        }
    }
}

public struct BeaconOutboxCommand: Codable, Equatable, Sendable {
    public let idempotencyKey: String
    public let commandId: String
    public let threadId: String
    public let runId: String
    public let payload: BeaconOutboxCommandPayload

    public var kind: BeaconOutboxCommandKind { payload.kind }

    public init(
        idempotencyKey: String,
        commandId: String,
        threadId: String,
        runId: String,
        payload: BeaconOutboxCommandPayload
    ) {
        self.idempotencyKey = idempotencyKey
        self.commandId = commandId
        self.threadId = threadId
        self.runId = runId
        self.payload = payload
    }

    fileprivate func validate() throws {
        do {
            for (field, value) in [
                ("idempotencyKey", idempotencyKey),
                ("commandId", commandId),
                ("threadId", threadId),
                ("runId", runId),
            ] {
                try BeaconAgentWireValidation.validateIdentifier(value, field: field)
            }
            try payload.validate()
        } catch {
            throw BeaconOutboxError.invalidCommand
        }
    }
}

struct BeaconOutbox: Codable, Equatable, Sendable {
    private(set) var commands: [BeaconOutboxCommand] = []

    mutating func enqueue(_ command: BeaconOutboxCommand) throws -> Bool {
        try command.validate()
        if let existing = commands.first(where: {
            $0.idempotencyKey == command.idempotencyKey
        }) {
            guard existing == command else {
                throw BeaconOutboxError.idempotencyConflict(command.idempotencyKey)
            }
            return false
        }
        commands.append(command)
        return true
    }

    mutating func acknowledge(idempotencyKey: String) -> Bool {
        guard let index = commands.firstIndex(where: {
            $0.idempotencyKey == idempotencyKey
        }) else {
            return false
        }
        commands.remove(at: index)
        return true
    }

    func pending(threadId: String?) -> [BeaconOutboxCommand] {
        commands.filter { command in
            threadId == nil || command.threadId == threadId
        }
    }
}

private struct BeaconOutboxCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
