import Foundation
import BeaconAgentCore

public struct BeaconDevicePolicy: Equatable, Sendable {
    public let capabilityID: String
    public let requiredScopes: Set<String>
    public let confirmation: BeaconConfirmationPolicy
    public let inputSchema: [String: BeaconJSONValue]
    public let outputSchema: [String: BeaconJSONValue]

    public init(
        capabilityID: String,
        requiredScopes: Set<String>,
        confirmation: BeaconConfirmationPolicy,
        inputSchema: [String: BeaconJSONValue],
        outputSchema: [String: BeaconJSONValue] = ["type": .string("object")]
    ) {
        self.capabilityID = capabilityID
        self.requiredScopes = requiredScopes
        self.confirmation = confirmation
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
    }

    func validates(arguments: [String: BeaconJSONValue]) -> Bool {
        validates(object: arguments, against: inputSchema)
    }

    func validates(output: [String: BeaconJSONValue]) -> Bool {
        validates(object: output, against: outputSchema)
    }

    private func validates(
        object: [String: BeaconJSONValue],
        against schema: [String: BeaconJSONValue]
    ) -> Bool {
        guard schema.string("type") == "object" else { return false }
        let required = Set(schema.stringArray("required"))
        guard required.isSubset(of: object.keys) else { return false }
        let properties = schema.object("properties") ?? [:]
        if schema.bool("additionalProperties") == false,
           !Set(object.keys).isSubset(of: properties.keys) {
            return false
        }
        for (key, value) in object {
            if properties.isEmpty { continue }
            guard let rule = properties[key]?.objectValue,
                  let expected = rule.string("type"),
                  value.matches(jsonType: expected)
            else {
                return false
            }
        }
        return true
    }
}

private extension Dictionary where Key == String, Value == BeaconJSONValue {
    func string(_ key: String) -> String? {
        guard case let .string(value)? = self[key] else { return nil }
        return value
    }

    func bool(_ key: String) -> Bool? {
        guard case let .bool(value)? = self[key] else { return nil }
        return value
    }

    func object(_ key: String) -> [String: BeaconJSONValue]? {
        self[key]?.objectValue
    }

    func stringArray(_ key: String) -> [String] {
        guard case let .array(values)? = self[key] else { return [] }
        return values.compactMap {
            guard case let .string(value) = $0 else { return nil }
            return value
        }
    }
}

private extension BeaconJSONValue {
    var objectValue: [String: BeaconJSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    func matches(jsonType: String) -> Bool {
        switch (jsonType, self) {
        case ("string", .string), ("number", .number), ("boolean", .bool),
             ("object", .object), ("array", .array), ("null", .null):
            true
        case ("integer", let .number(value)):
            value.rounded() == value
        default:
            false
        }
    }
}
