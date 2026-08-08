import Foundation
import Testing
@testable import BeaconAgentCore

struct BeaconKnowledgeManifestTests {
    @Test
    func decodesStrictProviderNeutralKnowledgeManifest() throws {
        let manifest = try JSONDecoder().decode(
            BeaconKnowledgeManifest.self,
            from: validManifestData
        )

        #expect(manifest.id == "example.knowledge")
        #expect(manifest.locale == "zh-CN")
        #expect(manifest.sources.map(\.id) == ["source.guideline"])
        #expect(manifest.citationPolicy == .requiredForEvidence)
    }

    @Test(arguments: ["id", "url", "reuseStatus"])
    func rejectsSourceMissingRequiredProvenanceField(_ field: String) throws {
        var document = try #require(
            JSONSerialization.jsonObject(with: validManifestData) as? [String: Any]
        )
        var sources = try #require(document["sources"] as? [[String: Any]])
        sources[0].removeValue(forKey: field)
        document["sources"] = sources
        let data = try JSONSerialization.data(withJSONObject: document)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(BeaconKnowledgeManifest.self, from: data)
        }
    }

    @Test
    func evidenceAnswerRejectsCitationOutsideRetrievedPassages() throws {
        let query = BeaconKnowledgeQuery(
            corpusID: "example.knowledge",
            text: "What is supported?",
            locale: "zh-CN",
            topK: 3
        )
        let result = BeaconKnowledgeRetrievalResult(
            query: query,
            passages: [BeaconKnowledgePassage(
                id: "passage-1",
                sourceID: "source.guideline",
                content: "An original summary.",
                citationLabel: "Example Authority"
            )]
        )
        let invalid = BeaconKnowledgeAnswer(
            text: "Evidence claim.",
            evidenceClaims: [BeaconEvidenceClaim(
                text: "Evidence claim",
                passageIDs: ["missing"]
            )],
            citations: []
        )

        #expect(throws: BeaconKnowledgeValidationError.self) {
            try invalid.validate(against: result)
        }
    }

    private var validManifestData: Data {
        Data(
            """
            {
              "schemaVersion": 1,
              "id": "example.knowledge",
              "version": "1.0.0",
              "locale": "zh-CN",
              "domain": "example",
              "sources": [{
                "id": "source.guideline",
                "title": "Public guideline",
                "publisher": "Example Authority",
                "url": "https://example.org/guideline",
                "reuseStatus": "original_summary_only",
                "reviewedAt": "2026-08-08T00:00:00Z"
              }],
              "retrievalAdapter": "example.local.v1",
              "chunkSchema": {"type": "object"},
              "citationPolicy": "required_for_evidence",
              "safetyDisclaimers": ["Not professional advice."],
              "excludedAdviceCategories": ["diagnosis"],
              "evaluationDatasetVersion": "1.0.0",
              "reviewExpiresAt": "2027-08-08T00:00:00Z"
            }
            """.utf8
        )
    }
}
