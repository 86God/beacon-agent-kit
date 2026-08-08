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
        validates(value: .object(object), against: schema)
    }

    private func validates(
        value: BeaconJSONValue,
        against schema: [String: BeaconJSONValue]
    ) -> Bool {
        let expectedTypes = schema.schemaTypes
        guard !expectedTypes.isEmpty,
              expectedTypes.contains(where: value.matches(jsonType:)) else {
            return false
        }
        switch value {
        case let .object(object):
            let required = Set(schema.stringArray("required"))
            guard required.isSubset(of: object.keys) else { return false }
            let properties = schema.object("properties") ?? [:]
            if schema.bool("additionalProperties") == false,
               !Set(object.keys).isSubset(of: properties.keys) {
                return false
            }
            return object.allSatisfy { key, child in
                guard let childSchema = properties[key]?.objectValue else {
                    return schema.bool("additionalProperties") != false
                }
                return validates(value: child, against: childSchema)
            }
        case let .array(values):
            if let minimum = schema.int("minItems"), values.count < minimum { return false }
            if let maximum = schema.int("maxItems"), values.count > maximum { return false }
            guard let itemSchema = schema.object("items") else { return true }
            return values.allSatisfy { validates(value: $0, against: itemSchema) }
        case let .string(string):
            if let minimum = schema.int("minLength"), string.count < minimum { return false }
            let allowed = schema.stringArray("enum")
            return allowed.isEmpty || allowed.contains(string)
        case let .number(number):
            if let minimum = schema.number("minimum"), number < minimum { return false }
            if let maximum = schema.number("maximum"), number > maximum { return false }
            return true
        case .bool, .null:
            return true
        }
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

    func number(_ key: String) -> Double? {
        guard case let .number(value)? = self[key] else { return nil }
        return value
    }

    func int(_ key: String) -> Int? {
        guard let value = number(key), value.rounded() == value else { return nil }
        return Int(value)
    }

    func stringArray(_ key: String) -> [String] {
        guard case let .array(values)? = self[key] else { return [] }
        return values.compactMap {
            guard case let .string(value) = $0 else { return nil }
            return value
        }
    }

    var schemaTypes: [String] {
        if let value = string("type") { return [value] }
        return stringArray("type")
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
