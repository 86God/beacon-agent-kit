import Foundation
import BeaconAgentCore

public enum BeaconA2UIValidationError: Error, Equatable, Sendable {
    case missingRoot(String)
    case mismatchedComponentID(String)
    case unknownComponent(String)
    case cycle(String)
    case danglingReference(String)
    case identityInjection(String)
    case oversizedText(String)
    case invalidAction(String)
}

public struct BeaconA2UIValidator: Sendable {
    public static let supportedComponentTypes: Set<String> = [
        "Text", "Row", "Column", "Card", "Button", "Metric", "List", "Table",
        "Notice", "Error", "Retry", "Approval", "Receipt"
    ]
    public static let supportedActions: Set<String> = [
        "submit", "cancel", "retry", "approve", "reject", "replace",
        "increment", "decrement", "reorder", "select"
    ]

    public let maximumTextLength: Int
    public let allowedActions: Set<String>

    public init(
        maximumTextLength: Int = 32_768,
        allowedActions: Set<String> = Self.supportedActions
    ) {
        self.maximumTextLength = maximumTextLength
        self.allowedActions = allowedActions
    }

    public func validate(_ surface: BeaconA2UISurface) throws {
        guard surface.components[surface.rootComponentID] != nil else {
            throw BeaconA2UIValidationError.missingRoot(surface.rootComponentID)
        }
        for (key, component) in surface.components.sorted(by: { $0.key < $1.key }) {
            guard key == component.id else {
                throw BeaconA2UIValidationError.mismatchedComponentID(key)
            }
            guard Self.supportedComponentTypes.contains(component.type) else {
                throw BeaconA2UIValidationError.unknownComponent(component.type)
            }
            for child in component.children where surface.components[child] == nil {
                throw BeaconA2UIValidationError.danglingReference(child)
            }
            try validateJSON(.object(component.properties), componentID: component.id)
            for action in component.actions {
                guard !action.id.isEmpty, allowedActions.contains(action.name) else {
                    throw BeaconA2UIValidationError.invalidAction(action.name)
                }
                try validateJSON(.object(action.payload), componentID: component.id)
            }
        }
        var visiting: Set<String> = []
        var visited: Set<String> = []
        func visit(_ identifier: String) throws {
            if visiting.contains(identifier) {
                throw BeaconA2UIValidationError.cycle(identifier)
            }
            if visited.contains(identifier) { return }
            visiting.insert(identifier)
            for child in surface.components[identifier]?.children ?? [] {
                try visit(child)
            }
            visiting.remove(identifier)
            visited.insert(identifier)
        }
        try visit(surface.rootComponentID)
        for identifier in surface.components.keys.sorted() {
            try visit(identifier)
        }
    }

    private func validateJSON(_ value: BeaconJSONValue, componentID: String) throws {
        switch value {
        case let .string(text):
            if text.count > maximumTextLength {
                throw BeaconA2UIValidationError.oversizedText(componentID)
            }
        case let .array(values):
            for child in values {
                try validateJSON(child, componentID: componentID)
            }
        case let .object(object):
            for (key, child) in object {
                if Self.trustedIdentityKeys.contains(key.lowercased()) {
                    throw BeaconA2UIValidationError.identityInjection(key)
                }
                try validateJSON(child, componentID: componentID)
            }
        case .number, .bool, .null:
            break
        }
    }

    private static let trustedIdentityKeys: Set<String> = [
        "userid", "accountid", "deviceid", "accountscope", "authorizedscopes",
        "permissionstate", "databasepath"
    ]
}
