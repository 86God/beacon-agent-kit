import Foundation
import BeaconAgentCore
import BeaconAgentA2UI

public struct BeaconMCPToolAdapter: Sendable {
    public let mcpAppsNegotiated: Bool

    public init(mcpAppsNegotiated: Bool) {
        self.mcpAppsNegotiated = mcpAppsNegotiated
    }

    public func capabilityManifest(
        serverID: String,
        tool: BeaconMCPTool,
        policy: BeaconMCPPolicyProfile
    ) throws -> BeaconCapabilityManifest {
        guard !serverID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !tool.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !tool.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw BeaconMCPAdapterError.invalidTool }
        if Self.isForbidden(tool.name) {
            throw BeaconMCPAdapterError.forbiddenTool(tool.name)
        }
        let resourceURI = try appResourceURI(tool.metadata)
        return BeaconCapabilityManifest(
            id: policy.capabilityID,
            version: "1.0.0",
            kind: .tool,
            title: tool.title ?? tool.name,
            description: tool.description,
            intentExamples: [tool.description],
            inputSchema: tool.inputSchema,
            outputSchema: tool.outputSchema ?? ["type": .string("object")],
            executionLocation: policy.executionLocation,
            risk: policy.risk,
            requiredScopes: policy.requiredScopes,
            confirmation: policy.confirmation,
            idempotency: policy.idempotency,
            surface: mcpAppsNegotiated ? resourceURI : nil,
            tags: policy.tags + ["mcp", "mcp.server.\(serverID)"],
            fallback: "text_summary"
        )
    }

    public func normalize(
        result: BeaconMCPToolResult,
        for tool: BeaconMCPTool,
        confirmation: BeaconConfirmationPolicy
    ) throws -> BeaconNormalizedMCPResult {
        let redactedStructured = result.structuredContent.mapValues(Self.redact)
        guard Self.validates(redactedStructured, schema: tool.outputSchema) else {
            throw BeaconMCPAdapterError.invalidStructuredResult
        }
        let redactedContent = result.content.map { content -> BeaconMCPContent in
            switch content {
            case let .text(text):
                return .text(BeaconRedactor.redactedText(text))
            case let .resource(resource):
                return .resource(resource)
            }
        }
        var surface: BeaconA2UISurface?
        if let value = redactedStructured["a2ui"] {
            do {
                let data = try JSONEncoder().encode(value)
                let decoded = try JSONDecoder().decode(BeaconA2UISurface.self, from: data)
                try BeaconA2UIValidator().validate(decoded)
                surface = decoded
            } catch {
                throw BeaconMCPAdapterError.invalidSurface
            }
        }
        return BeaconNormalizedMCPResult(
            content: redactedContent,
            structuredContent: redactedStructured,
            surface: surface,
            confirmationRequired: confirmation != .never,
            isError: result.isError
        )
    }

    private func appResourceURI(_ metadata: [String: BeaconJSONValue]) throws -> String? {
        var value: String?
        if case let .object(ui)? = metadata["ui"], case let .string(uri)? = ui["resourceUri"] {
            value = uri
        } else if case let .string(uri)? = metadata["ui/resourceUri"] {
            value = uri
        }
        guard let value else { return nil }
        guard value.hasPrefix("ui://"), URL(string: value) != nil else {
            throw BeaconMCPAdapterError.invalidAppURI(value)
        }
        return value
    }

    private static func isForbidden(_ name: String) -> Bool {
        let tokens = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return !Set(tokens.map(String.init)).isDisjoint(with: [
            "shell", "terminal", "exec", "command", "sql", "filesystem", "file", "fs"
        ])
    }

    private static func redact(_ value: BeaconJSONValue) -> BeaconJSONValue {
        switch value {
        case let .string(text): .string(BeaconRedactor.redactedText(text))
        case let .array(values): .array(values.map(redact))
        case let .object(values): .object(values.mapValues(redact))
        case .number, .bool, .null: value
        }
    }

    private static func validates(
        _ object: [String: BeaconJSONValue],
        schema: [String: BeaconJSONValue]?
    ) -> Bool {
        guard let schema else { return true }
        guard case .string("object")? = schema["type"] else { return false }
        let required: Set<String>
        if case let .array(values)? = schema["required"] {
            required = Set(values.compactMap { if case let .string(value) = $0 { value } else { nil } })
        } else { required = [] }
        guard required.isSubset(of: object.keys) else { return false }
        guard case let .object(properties)? = schema["properties"] else { return true }
        for (key, value) in object where properties[key] != nil {
            guard case let .object(rule)? = properties[key], case let .string(type)? = rule["type"] else {
                return false
            }
            switch (type, value) {
            case ("string", .string), ("number", .number), ("integer", .number),
                 ("boolean", .bool), ("object", .object), ("array", .array), ("null", .null):
                continue
            default: return false
            }
        }
        return true
    }
}
