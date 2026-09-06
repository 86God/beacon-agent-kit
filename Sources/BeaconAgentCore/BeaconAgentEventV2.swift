import Foundation

public enum BeaconAgentEventV2WireLimits {
    public static let identifierMaxCharacters = 128
    public static let identifierMaxUTF8Bytes = 256
    public static let eventTypeMaxCharacters = 96
    public static let eventTypeMaxUTF8Bytes = 384
    public static let payloadMaxBytes = 262_144
}

/// The language-neutral v0.2 event envelope. Domain payloads remain opaque JSON.
public struct BeaconAgentEventV2: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let eventId: String
    public let runId: String
    public let sequence: Int
    public let type: String
    public let payload: [String: BeaconJSONValue]

    public init(
        schemaVersion: Int,
        eventId: String,
        runId: String,
        sequence: Int,
        type: String,
        payload: [String: BeaconJSONValue]
    ) {
        self.schemaVersion = schemaVersion
        self.eventId = eventId
        self.runId = runId
        self.sequence = sequence
        self.type = type
        self.payload = payload
    }

    func validateWireBounds() throws {
        try validateWireString(
            eventId,
            field: "eventId",
            maxCharacters: BeaconAgentEventV2WireLimits.identifierMaxCharacters,
            maxUTF8Bytes: BeaconAgentEventV2WireLimits.identifierMaxUTF8Bytes
        )
        try validateWireString(
            runId,
            field: "runId",
            maxCharacters: BeaconAgentEventV2WireLimits.identifierMaxCharacters,
            maxUTF8Bytes: BeaconAgentEventV2WireLimits.identifierMaxUTF8Bytes
        )
        try validateWireString(
            type,
            field: "type",
            maxCharacters: BeaconAgentEventV2WireLimits.eventTypeMaxCharacters,
            maxUTF8Bytes: BeaconAgentEventV2WireLimits.eventTypeMaxUTF8Bytes
        )

        let payloadSize = try payloadWireBudget(.object(payload))
        guard payloadSize <= BeaconAgentEventV2WireLimits.payloadMaxBytes else {
            throw BeaconAgentReplayError.payloadByteLimit(
                actual: payloadSize,
                maximum: BeaconAgentEventV2WireLimits.payloadMaxBytes
            )
        }
    }
}

private func validateWireString(
    _ value: String,
    field: String,
    maxCharacters: Int,
    maxUTF8Bytes: Int
) throws {
    guard value.unicodeScalars.contains(where: { !isWireBlank($0.value) }) else {
        throw BeaconAgentReplayError.blankField(field)
    }
    let characterCount = value.unicodeScalars.count
    guard characterCount <= maxCharacters else {
        throw BeaconAgentReplayError.fieldCharacterLimit(
            field: field,
            actual: characterCount,
            maximum: maxCharacters
        )
    }
    let utf8ByteCount = value.utf8.count
    guard utf8ByteCount <= maxUTF8Bytes else {
        throw BeaconAgentReplayError.fieldUTF8ByteLimit(
            field: field,
            actual: utf8ByteCount,
            maximum: maxUTF8Bytes
        )
    }
}

private func isWireBlank(_ scalar: UInt32) -> Bool {
    switch scalar {
    case 0x0009...0x000D, 0x001C...0x0020, 0x0085, 0x00A0, 0x1680,
         0x2000...0x200B, 0x2028...0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
        true
    default:
        false
    }
}

/// A decoded-JSON structural budget shared with Python. Numeric values use a
/// fixed cost so equivalent JSON numbers cannot diverge across encoders.
private func payloadWireBudget(_ value: BeaconJSONValue) throws -> Int {
    switch value {
    case let .string(text):
        2 + text.utf8.count
    case .number:
        32
    case let .bool(flag):
        flag ? 4 : 5
    case let .object(object):
        try object.reduce(2 + max(0, object.count - 1)) { total, entry in
            total + 3 + entry.key.utf8.count + (try payloadWireBudget(entry.value))
        }
    case let .array(array):
        try array.reduce(2 + max(0, array.count - 1)) { total, element in
            total + (try payloadWireBudget(element))
        }
    case .null:
        4
    }
}
