import Foundation
import Testing
@testable import BeaconAgentCore

struct BeaconCapabilityManifestTests {
    @Test
    func decodesPythonCapabilityFixture() throws {
        let data = try Data(contentsOf: fixtureURL)
        let manifests = try JSONDecoder().decode([BeaconCapabilityManifest].self, from: data)

        #expect(manifests.map(\.id) == ["training.context.read", "training.plan.draft"])
        #expect(manifests[0].executionLocation == .device)
        #expect(manifests[1].requiredScopes == ["training.read", "training.draft.write"])
        #expect(manifests[1].dependencies == ["training.context.read@^1"])
    }

    @Test
    func rejectsUnsupportedRequiredSchemaVersion() {
        let data = Data(
            """
            {
              "schemaVersion": 3,
              "id": "training.context.read",
              "version": "1.0.0",
              "kind": "tool",
              "title": "Read context",
              "description": "Reads context.",
              "intentExamples": ["Read context"],
              "inputSchema": {},
              "outputSchema": {},
              "executionLocation": "device",
              "risk": "read_only",
              "requiredScopes": ["training.read"],
              "confirmation": "never",
              "idempotency": "none",
              "dependencies": [],
              "surface": null,
              "tags": ["training"],
              "fallback": "text_summary",
              "offlineSafe": true
            }
            """.utf8
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(BeaconCapabilityManifest.self, from: data)
        }
    }

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("conformance/fixtures/capability-manifests.json")
    }
}
