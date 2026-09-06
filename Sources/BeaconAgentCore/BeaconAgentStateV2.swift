import Foundation

public enum BeaconAgentReplayError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case eventCollision(String)
    case sequenceCollision(Int)
    case mixedRunIds
    case mixedTurnIds
    case unsupportedCriticalEvent(String)
    case eventAfterTerminal(Int)
    case blankField(String)
    case fieldCharacterLimit(field: String, actual: Int, maximum: Int)
    case fieldUTF8ByteLimit(field: String, actual: Int, maximum: Int)
    case payloadByteLimit(actual: Int, maximum: Int)
    case malformedPayload(String)
    case unsupportedPatch
}

/// Deterministic, transport-independent projection of an ordered v0.2 event stream.
public struct BeaconAgentStateV2: Sendable {
    public private(set) var runId: String?
    public private(set) var turnId: String?
    public private(set) var attemptId: String?
    public private(set) var segmentId: String?
    public private(set) var nextSequence = 0
    public private(set) var status = "idle"

    private var activities: [String: [String: BeaconJSONValue]] = [:]
    private var text: [String: String] = [:]
    private var tools: [String: [String: BeaconJSONValue]] = [:]
    private var agentState: [String: BeaconJSONValue] = [:]
    private var surfaces: [String: SurfaceRecord] = [:]
    private var approvals: [String: [String: BeaconJSONValue]] = [:]
    private var receipts: [[String: BeaconJSONValue]] = []
    private var customEvents: [BeaconAgentEventV2] = []
    private var errors: [[String: BeaconJSONValue]] = []
    private var resultKind: String?
    private var failure: [String: BeaconJSONValue]?
    private var diagnostic: [String: BeaconJSONValue]?
    private var buffer: [Int: BeaconAgentEventV2] = [:]
    private var seen: [String: Data] = [:]
    private var terminalSequence: Int?

    public init() {}

    public mutating func ingest(_ event: BeaconAgentEventV2) throws {
        guard event.schemaVersion == 2 else {
            throw BeaconAgentReplayError.unsupportedSchemaVersion(event.schemaVersion)
        }
        try event.validateWireBounds()
        let previousNextSequence = nextSequence
        var candidate = self
        do {
            try candidate.ingestValidated(event)
            self = candidate
        } catch {
            if candidate.nextSequence > previousNextSequence {
                self = candidate
            }
            throw error
        }
    }

    private mutating func ingestValidated(_ event: BeaconAgentEventV2) throws {
        let fingerprint = try canonicalData(event)
        if let previous = seen[event.eventId] {
            guard previous == fingerprint else {
                throw BeaconAgentReplayError.eventCollision(event.eventId)
            }
            return
        }
        if let runId, runId != event.runId {
            throw BeaconAgentReplayError.mixedRunIds
        }
        if let turnId, let eventTurnId = event.turnId, turnId != eventTurnId {
            throw BeaconAgentReplayError.mixedTurnIds
        }
        if terminalSequence != nil {
            throw BeaconAgentReplayError.eventAfterTerminal(event.sequence)
        }
        if let buffered = buffer[event.sequence], buffered.eventId != event.eventId {
            throw BeaconAgentReplayError.sequenceCollision(event.sequence)
        }
        guard event.sequence >= nextSequence else {
            throw BeaconAgentReplayError.sequenceCollision(event.sequence)
        }

        seen[event.eventId] = fingerprint
        buffer[event.sequence] = event
        try validateBufferedIdentity()
        while let current = buffer[nextSequence] {
            var reductionCandidate = self
            reductionCandidate.buffer.removeValue(forKey: nextSequence)
            do {
                try reductionCandidate.reduce(current)
            } catch {
                buffer.removeValue(forKey: nextSequence)
                seen.removeValue(forKey: current.eventId)
                throw error
            }
            reductionCandidate.nextSequence += 1
            self = reductionCandidate
            if terminalSequence != nil {
                for lateEvent in buffer.values {
                    seen.removeValue(forKey: lateEvent.eventId)
                }
                buffer.removeAll()
                break
            }
        }
    }

    private func validateBufferedIdentity() throws {
        var runIds = Set(buffer.values.map(\.runId))
        if let runId { runIds.insert(runId) }
        guard runIds.count <= 1 else {
            throw BeaconAgentReplayError.mixedRunIds
        }

        var turnIds = Set(buffer.values.compactMap(\.turnId))
        if let turnId { turnIds.insert(turnId) }
        guard turnIds.count <= 1 else {
            throw BeaconAgentReplayError.mixedTurnIds
        }
    }

    public func normalizedJSON() throws -> String {
        var projection: [String: BeaconJSONValue] = [
            "activities": .object(activities.mapValues(BeaconJSONValue.object)),
            "approvals": .object(approvals.mapValues(BeaconJSONValue.object)),
            "bufferedSequences": .array(buffer.keys.sorted().map { .number(Double($0)) }),
            "customEvents": .array(customEvents.map(eventValue)),
            "errors": .array(errors.map(BeaconJSONValue.object)),
            "nextSequence": .number(Double(nextSequence)),
            "receipts": .array(receipts.map(BeaconJSONValue.object)),
            "runId": runId.map(BeaconJSONValue.string) ?? .null,
            "state": .object(agentState),
            "status": .string(status),
            "surfaces": .object(surfaces.mapValues { $0.jsonValue }),
            "text": .object(text.mapValues(BeaconJSONValue.string)),
            "tools": .object(tools.mapValues(BeaconJSONValue.object))
        ]
        if let turnId { projection["turnId"] = .string(turnId) }
        if let attemptId { projection["attemptId"] = .string(attemptId) }
        if let segmentId { projection["segmentId"] = .string(segmentId) }
        if let resultKind { projection["resultKind"] = .string(resultKind) }
        if let failure { projection["failure"] = .object(failure) }
        if let diagnostic { projection["diagnostic"] = .object(diagnostic) }
        let value = BeaconJSONValue.object(projection)
        let data = try canonicalData(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw BeaconAgentReplayError.malformedPayload("normalized JSON encoding")
        }
        return string
    }

    private mutating func reduce(_ event: BeaconAgentEventV2) throws {
        if runId == nil {
            runId = event.runId
        }
        if turnId == nil {
            turnId = event.turnId
        }
        attemptId = event.attemptId ?? attemptId
        segmentId = event.segmentId ?? segmentId
        let payload = event.payload
        switch event.type {
        case "run.started":
            status = "running"
            diagnostic = nil
        case "run.finished":
            if payload["resultKind"] != nil {
                let kind = try requiredString("resultKind", in: payload)
                guard Self.resultKinds.contains(kind) else {
                    throw BeaconAgentReplayError.malformedPayload("invalid resultKind")
                }
                resultKind = kind
            }
            status = "finished"
            terminalSequence = event.sequence
        case "run.interrupted":
            status = "interrupted"
        case "run.error":
            status = "error"
            errors.append(payload)
            failure = try diagnosticFields(in: payload, required: false)
            terminalSequence = event.sequence
        case "device.waiting":
            status = "waiting_device"
            diagnostic = try diagnosticFields(in: payload, required: true)
        case "permission.denied":
            let fields = try diagnosticFields(in: payload, required: true) ?? [:]
            status = "permission_denied"
            failure = fields
            errors.append(fields)
            terminalSequence = event.sequence
        case "activity.snapshot", "activity.delta":
            let identifier = try requiredString("activityId", in: payload)
            activities[identifier, default: [:]].merge(payload) { _, new in new }
        case "text.start":
            text[try requiredString("messageId", in: payload)] = ""
        case "text.delta":
            let identifier = try requiredString("messageId", in: payload)
            text[identifier, default: ""] += payload.string("delta") ?? ""
        case "text.end":
            let identifier = try requiredString("messageId", in: payload)
            if let finalText = payload.string("finalText") {
                text[identifier] = finalText
            }
        case "tool.start":
            let identifier = try requiredString("toolCallId", in: payload)
            tools[identifier] = payload.merging(["status": .string("running")]) { current, _ in current }
        case "tool.result", "tool.end":
            let identifier = try requiredString("toolCallId", in: payload)
            tools[identifier, default: [:]].merge(payload) { _, new in new }
        case "state.snapshot":
            agentState = payload.object("state") ?? [:]
        case "state.delta":
            agentState = try applyPatch(try requiredPatch(in: payload), to: .object(agentState)).objectValue ?? [:]
        case "surface.create":
            let identifier = try requiredString("surfaceId", in: payload)
            surfaces[identifier] = SurfaceRecord(document: payload["document"] ?? .object([:]), status: "streaming")
        case "surface.patch":
            let identifier = try requiredString("surfaceId", in: payload)
            var surface = surfaces[identifier] ?? SurfaceRecord(document: .object([:]), status: "streaming")
            surface.document = try applyPatch(try requiredPatch(in: payload), to: surface.document)
            surfaces[identifier] = surface
        case "surface.complete":
            let identifier = try requiredString("surfaceId", in: payload)
            var surface = surfaces[identifier] ?? SurfaceRecord(document: .object([:]), status: "streaming")
            surface.status = "complete"
            surfaces[identifier] = surface
        case "surface.error":
            let identifier = try requiredString("surfaceId", in: payload)
            surfaces[identifier] = SurfaceRecord(document: surfaces[identifier]?.document ?? .object([:]), status: "error")
        case "approval.requested":
            let identifier = try requiredString("approvalId", in: payload)
            approvals[identifier] = payload.merging(["status": .string("pending")]) { current, _ in current }
            status = "waiting_approval"
            diagnostic = try diagnosticFields(in: payload, required: false)
        case "approval.resolved", "approval.expired":
            let identifier = try requiredString("approvalId", in: payload)
            approvals[identifier, default: [:]].merge(payload) { _, new in new }
            approvals[identifier]?["status"] = .string(event.type == "approval.resolved" ? "resolved" : "expired")
            if status == "waiting_approval" {
                status = event.type == "approval.resolved" ? "running" : "error"
                diagnostic = nil
            }
        case "receipt.committed", "receipt.rejected":
            receipts.append(payload)
        default:
            if !Self.standardEventTypes.contains(event.type) {
                if payload.bool("critical") == true {
                    throw BeaconAgentReplayError.unsupportedCriticalEvent(event.type)
                }
                customEvents.append(event)
            }
        }
    }

    private static let resultKinds: Set<String> = ["success", "empty", "text_fallback"]

    private static let standardEventTypes: Set<String> = [
        "run.started", "run.finished", "run.error", "run.interrupted",
        "step.started", "step.finished", "activity.snapshot", "activity.delta",
        "text.start", "text.delta", "text.end", "tool.start", "tool.arguments.delta",
        "tool.end", "tool.result", "state.snapshot", "state.delta", "surface.create",
        "surface.patch", "surface.complete", "surface.error", "approval.requested",
        "approval.resolved", "approval.expired", "receipt.committed", "receipt.rejected",
        "device.waiting", "permission.denied"
    ]
}

private struct SurfaceRecord: Sendable {
    var document: BeaconJSONValue
    var status: String

    var jsonValue: BeaconJSONValue {
        .object(["document": document, "status": .string(status)])
    }
}

private struct PatchOperation {
    let operation: String
    let path: [String]
    let value: BeaconJSONValue?
}

private extension Dictionary where Key == String, Value == BeaconJSONValue {
    func string(_ key: String) -> String? {
        guard case let .string(value)? = self[key] else { return nil }
        return value
    }

    func object(_ key: String) -> [String: BeaconJSONValue]? {
        self[key]?.objectValue
    }

    func bool(_ key: String) -> Bool? {
        guard case let .bool(value)? = self[key] else { return nil }
        return value
    }
}

private extension BeaconJSONValue {
    var objectValue: [String: BeaconJSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }
}

private func requiredString(_ key: String, in payload: [String: BeaconJSONValue]) throws -> String {
    guard let value = payload.string(key), !value.isEmpty else {
        throw BeaconAgentReplayError.malformedPayload("missing \(key)")
    }
    return value
}

private func diagnosticFields(
    in payload: [String: BeaconJSONValue],
    required: Bool
) throws -> [String: BeaconJSONValue]? {
    let hasAny = payload["retryable"] != nil || payload["diagnosticId"] != nil
    if !required, !hasAny { return nil }

    let code = try requiredString("code", in: payload)
    let diagnosticId = try requiredString("diagnosticId", in: payload)
    guard let retryable = payload.bool("retryable") else {
        throw BeaconAgentReplayError.malformedPayload("missing retryable")
    }
    try validateWireString(
        code,
        field: "code",
        maxCharacters: BeaconAgentEventV2WireLimits.identifierMaxCharacters,
        maxUTF8Bytes: BeaconAgentEventV2WireLimits.identifierMaxUTF8Bytes
    )
    try validateWireString(
        diagnosticId,
        field: "diagnosticId",
        maxCharacters: BeaconAgentEventV2WireLimits.identifierMaxCharacters,
        maxUTF8Bytes: BeaconAgentEventV2WireLimits.identifierMaxUTF8Bytes
    )
    return [
        "code": .string(code),
        "retryable": .bool(retryable),
        "diagnosticId": .string(diagnosticId)
    ]
}

private func requiredPatch(in payload: [String: BeaconJSONValue]) throws -> [PatchOperation] {
    guard case let .array(rawOperations)? = payload["patch"] else {
        throw BeaconAgentReplayError.malformedPayload("missing patch")
    }
    return try rawOperations.map { raw in
        guard case let .object(operation) = raw,
              let name = operation.string("op"),
              let pointer = operation.string("path"),
              pointer.hasPrefix("/")
        else {
            throw BeaconAgentReplayError.unsupportedPatch
        }
        let path = pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map {
            String($0).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
        }
        return PatchOperation(operation: name, path: path, value: operation["value"])
    }
}

private func applyPatch(_ operations: [PatchOperation], to original: BeaconJSONValue) throws -> BeaconJSONValue {
    try operations.reduce(original) { value, operation in
        try applying(operation, to: value, remainingPath: operation.path)
    }
}

private func applying(
    _ operation: PatchOperation,
    to current: BeaconJSONValue,
    remainingPath: [String]
) throws -> BeaconJSONValue {
    guard let head = remainingPath.first else {
        if operation.operation == "remove" { return .null }
        guard let value = operation.value, ["add", "replace"].contains(operation.operation) else {
            throw BeaconAgentReplayError.unsupportedPatch
        }
        return value
    }
    let tail = Array(remainingPath.dropFirst())
    switch current {
    case var .object(object):
        if tail.isEmpty {
            switch operation.operation {
            case "add", "replace":
                guard let value = operation.value else { throw BeaconAgentReplayError.unsupportedPatch }
                object[head] = value
            case "remove":
                object.removeValue(forKey: head)
            default:
                throw BeaconAgentReplayError.unsupportedPatch
            }
        } else {
            guard let child = object[head] else { throw BeaconAgentReplayError.unsupportedPatch }
            object[head] = try applying(operation, to: child, remainingPath: tail)
        }
        return .object(object)
    case var .array(array):
        if tail.isEmpty, operation.operation == "add", head == "-" {
            guard let value = operation.value else { throw BeaconAgentReplayError.unsupportedPatch }
            array.append(value)
            return .array(array)
        }
        guard let index = Int(head), array.indices.contains(index) else {
            throw BeaconAgentReplayError.unsupportedPatch
        }
        if tail.isEmpty {
            switch operation.operation {
            case "add":
                guard let value = operation.value else { throw BeaconAgentReplayError.unsupportedPatch }
                array.insert(value, at: index)
            case "replace":
                guard let value = operation.value else { throw BeaconAgentReplayError.unsupportedPatch }
                array[index] = value
            case "remove":
                array.remove(at: index)
            default:
                throw BeaconAgentReplayError.unsupportedPatch
            }
        } else {
            array[index] = try applying(operation, to: array[index], remainingPath: tail)
        }
        return .array(array)
    default:
        throw BeaconAgentReplayError.unsupportedPatch
    }
}

private func eventValue(_ event: BeaconAgentEventV2) -> BeaconJSONValue {
    var object: [String: BeaconJSONValue] = [
        "eventId": .string(event.eventId),
        "payload": .object(event.payload),
        "runId": .string(event.runId),
        "schemaVersion": .number(Double(event.schemaVersion)),
        "sequence": .number(Double(event.sequence)),
        "type": .string(event.type)
    ]
    if let turnId = event.turnId { object["turnId"] = .string(turnId) }
    if let attemptId = event.attemptId { object["attemptId"] = .string(attemptId) }
    if let segmentId = event.segmentId { object["segmentId"] = .string(segmentId) }
    return .object(object)
}

private func canonicalData<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
