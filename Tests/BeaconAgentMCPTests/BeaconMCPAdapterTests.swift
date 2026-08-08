import Foundation
import Testing
@testable import BeaconAgentMCP
import BeaconAgentCore

struct BeaconMCPAdapterTests {
    private let objectSchema: [String: BeaconJSONValue] = [
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "required": .array([.string("date")]),
        "properties": .object(["date": .object(["type": .string("string")])])
    ]

    @Test func mapsTrustedToolToCapabilityManifestWithoutTrustingAnnotations() throws {
        let tool = BeaconMCPTool(
            name: "training_context",
            title: "Training context",
            description: "Read local training context",
            inputSchema: objectSchema,
            outputSchema: ["type": .string("object")],
            annotations: ["destructiveHint": .bool(true)],
            metadata: ["ui": .object(["resourceUri": .string("ui://jianhao/training")])]
        )
        let policy = BeaconMCPPolicyProfile(
            capabilityID: "training.context.read",
            executionLocation: .device,
            risk: .readOnly,
            requiredScopes: ["training.read"],
            confirmation: .never,
            idempotency: .none,
            tags: ["training"]
        )

        let manifest = try BeaconMCPToolAdapter(mcpAppsNegotiated: true)
            .capabilityManifest(serverID: "jianhao", tool: tool, policy: policy)

        #expect(manifest.id == "training.context.read")
        #expect(manifest.risk == .readOnly)
        #expect(manifest.surface == "ui://jianhao/training")
        #expect(manifest.inputSchema == objectSchema)
    }

    @Test func appResourceRequiresNegotiationAndSupportsLegacyMetadata() throws {
        let tool = BeaconMCPTool(
            name: "training_context",
            description: "Read context",
            inputSchema: ["type": .string("object")],
            metadata: ["ui/resourceUri": .string("ui://jianhao/legacy")]
        )
        let policy = BeaconMCPPolicyProfile.readOnly(
            capabilityID: "training.context.read",
            requiredScopes: ["training.read"],
            tags: ["training"]
        )
        let disabled = try BeaconMCPToolAdapter(mcpAppsNegotiated: false)
            .capabilityManifest(serverID: "jianhao", tool: tool, policy: policy)
        let enabled = try BeaconMCPToolAdapter(mcpAppsNegotiated: true)
            .capabilityManifest(serverID: "jianhao", tool: tool, policy: policy)

        #expect(disabled.surface == nil)
        #expect(enabled.surface == "ui://jianhao/legacy")
    }

    @Test(arguments: ["shell.exec", "database.sql", "filesystem.read"])
    func forbiddenToolFamiliesFailClosed(name: String) {
        let tool = BeaconMCPTool(
            name: name,
            description: "Unsafe generic primitive",
            inputSchema: ["type": .string("object")]
        )
        #expect(throws: BeaconMCPAdapterError.forbiddenTool(name)) {
            try BeaconMCPToolAdapter(mcpAppsNegotiated: true).capabilityManifest(
                serverID: "untrusted",
                tool: tool,
                policy: .readOnly(
                    capabilityID: "external.unsafe",
                    requiredScopes: ["external.read"],
                    tags: ["external"]
                )
            )
        }
    }

    @Test func structuredResultIsValidatedRedactedAndCarriesValidatedA2UI() throws {
        let tool = BeaconMCPTool(
            name: "summary",
            description: "Summary",
            inputSchema: ["type": .string("object")],
            outputSchema: [
                "type": .string("object"),
                "required": .array([.string("summary")]),
                "properties": .object(["summary": .object(["type": .string("string")])])
            ]
        )
        let surface: BeaconJSONValue = .object([
            "id": .string("surface-1"), "revision": .number(1),
            "rootComponentID": .string("root"), "status": .string("complete"),
            "components": .object([
                "root": .object([
                    "id": .string("root"), "type": .string("Text"),
                    "properties": .object(["text": .string("完成")]),
                    "children": .array([]), "actions": .array([])
                ])
            ])
        ])
        let result = BeaconMCPToolResult(
            content: [.text("Call 13800138000")],
            structuredContent: [
                "summary": .string("token sk-123456789012345678901234"),
                "a2ui": surface
            ]
        )

        let normalized = try BeaconMCPToolAdapter(mcpAppsNegotiated: true)
            .normalize(result: result, for: tool, confirmation: .always)

        #expect(normalized.structuredContent["summary"] == .string("token [secret redacted]"))
        #expect(normalized.content == [.text("Call [phone redacted]")])
        #expect(normalized.surface?.id == "surface-1")
        #expect(normalized.confirmationRequired)
    }

    @Test func invalidURIAndOversizedAppResourceAreRejected() {
        let resolver = BeaconMCPResourceResolver(maximumBytes: 16)
        #expect(throws: BeaconMCPResourceError.invalidURI("https://example.com/app")) {
            try resolver.resolve(
                requestedURI: "https://example.com/app",
                from: [BeaconMCPResource(uri: "https://example.com/app", mimeType: "text/html", text: "ok")]
            )
        }
        #expect(throws: BeaconMCPResourceError.oversized("ui://jianhao/app")) {
            try resolver.resolve(
                requestedURI: "ui://jianhao/app",
                from: [BeaconMCPResource(
                    uri: "ui://jianhao/app",
                    mimeType: "text/html;profile=mcp-app",
                    text: String(repeating: "x", count: 17)
                )]
            )
        }
    }
}
