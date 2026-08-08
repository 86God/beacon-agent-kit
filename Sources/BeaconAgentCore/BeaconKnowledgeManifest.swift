import Foundation

public enum BeaconKnowledgeReuseStatus: String, Codable, Equatable, Sendable {
    case permitted
    case originalSummaryOnly = "original_summary_only"
    case reviewRequired = "review_required"
    case prohibited
}

public enum BeaconKnowledgeCitationPolicy: String, Codable, Equatable, Sendable {
    case requiredForEvidence = "required_for_evidence"
    case always
    case optional
}

public enum BeaconKnowledgeValidationError: Error, Equatable, Sendable {
    case invalidManifest(String)
    case citationOutsideRetrieval
    case citationSourceMismatch
    case uncitedEvidenceClaim
}

public struct BeaconKnowledgeSource: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let publisher: String
    public let url: URL
    public let reuseStatus: BeaconKnowledgeReuseStatus
    public let reviewedAt: String

    public init(
        id: String,
        title: String,
        publisher: String,
        url: URL,
        reuseStatus: BeaconKnowledgeReuseStatus,
        reviewedAt: String
    ) {
        self.id = id
        self.title = title
        self.publisher = publisher
        self.url = url
        self.reuseStatus = reuseStatus
        self.reviewedAt = reviewedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        publisher = try container.decode(String.self, forKey: .publisher)
        url = try container.decode(URL.self, forKey: .url)
        reuseStatus = try container.decode(BeaconKnowledgeReuseStatus.self, forKey: .reuseStatus)
        reviewedAt = try container.decode(String.self, forKey: .reviewedAt)
        guard Self.isNonblank(id), Self.isNonblank(title), Self.isNonblank(publisher),
              url.scheme == "https", Self.isISO8601(reviewedAt) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Invalid knowledge source provenance"
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, publisher, url, reuseStatus, reviewedAt
    }

    fileprivate static func isNonblank(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    fileprivate static func isISO8601(_ value: String) -> Bool {
        ISO8601DateFormatter().date(from: value) != nil
    }
}

public struct BeaconKnowledgeManifest: Codable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let id: String
    public let version: String
    public let locale: String
    public let domain: String
    public let sources: [BeaconKnowledgeSource]
    public let retrievalAdapter: String
    public let chunkSchema: [String: BeaconJSONValue]
    public let citationPolicy: BeaconKnowledgeCitationPolicy
    public let safetyDisclaimers: [String]
    public let excludedAdviceCategories: [String]
    public let evaluationDatasetVersion: String
    public let reviewExpiresAt: String

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(String.self, forKey: .id)
        version = try container.decode(String.self, forKey: .version)
        locale = try container.decode(String.self, forKey: .locale)
        domain = try container.decode(String.self, forKey: .domain)
        sources = try container.decode([BeaconKnowledgeSource].self, forKey: .sources)
        retrievalAdapter = try container.decode(String.self, forKey: .retrievalAdapter)
        chunkSchema = try container.decode([String: BeaconJSONValue].self, forKey: .chunkSchema)
        citationPolicy = try container.decode(BeaconKnowledgeCitationPolicy.self, forKey: .citationPolicy)
        safetyDisclaimers = try container.decode([String].self, forKey: .safetyDisclaimers)
        excludedAdviceCategories = try container.decode([String].self, forKey: .excludedAdviceCategories)
        evaluationDatasetVersion = try container.decode(String.self, forKey: .evaluationDatasetVersion)
        reviewExpiresAt = try container.decode(String.self, forKey: .reviewExpiresAt)

        let sourceIDs = sources.map(\.id)
        guard schemaVersion == Self.supportedSchemaVersion,
              Self.isNonblank(id), Self.isSemver(version), Self.isLocale(locale),
              Self.isNonblank(domain), !sources.isEmpty,
              sourceIDs.count == Set(sourceIDs).count,
              Self.isNonblank(retrievalAdapter), !chunkSchema.isEmpty,
              !safetyDisclaimers.isEmpty,
              safetyDisclaimers.allSatisfy(Self.isNonblank),
              excludedAdviceCategories.allSatisfy(Self.isNonblank),
              Self.isSemver(evaluationDatasetVersion),
              BeaconKnowledgeSource.isISO8601(reviewExpiresAt) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Invalid knowledge manifest"
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, version, locale, domain, sources, retrievalAdapter
        case chunkSchema, citationPolicy, safetyDisclaimers, excludedAdviceCategories
        case evaluationDatasetVersion, reviewExpiresAt
    }

    private static func isNonblank(_ value: String) -> Bool {
        BeaconKnowledgeSource.isNonblank(value)
    }

    private static func isSemver(_ value: String) -> Bool {
        value.range(
            of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isLocale(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$"#,
            options: .regularExpression
        ) != nil
    }
}

public struct BeaconKnowledgeQuery: Codable, Equatable, Sendable {
    public let corpusID: String
    public let text: String
    public let locale: String
    public let topK: Int

    public init(corpusID: String, text: String, locale: String, topK: Int) {
        self.corpusID = corpusID
        self.text = text
        self.locale = locale
        self.topK = topK
    }
}

public struct BeaconKnowledgePassage: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let sourceID: String
    public let content: String
    public let citationLabel: String
    public let metadata: [String: String]

    public init(
        id: String,
        sourceID: String,
        content: String,
        citationLabel: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.sourceID = sourceID
        self.content = content
        self.citationLabel = citationLabel
        self.metadata = metadata
    }
}

public struct BeaconKnowledgeRetrievalResult: Codable, Equatable, Sendable {
    public let query: BeaconKnowledgeQuery
    public let passages: [BeaconKnowledgePassage]

    public init(query: BeaconKnowledgeQuery, passages: [BeaconKnowledgePassage]) {
        self.query = query
        self.passages = passages
    }
}

public struct BeaconKnowledgeCorpus: Codable, Equatable, Sendable {
    public let manifest: BeaconKnowledgeManifest
    public let passages: [BeaconKnowledgePassage]
}

public struct BeaconKnowledgeCitation: Codable, Equatable, Sendable {
    public let passageID: String
    public let sourceID: String
    public let title: String
    public let url: URL

    public init(passageID: String, sourceID: String, title: String, url: URL) {
        self.passageID = passageID
        self.sourceID = sourceID
        self.title = title
        self.url = url
    }
}

public struct BeaconEvidenceClaim: Codable, Equatable, Sendable {
    public let text: String
    public let passageIDs: [String]

    public init(text: String, passageIDs: [String]) {
        self.text = text
        self.passageIDs = passageIDs
    }
}

public struct BeaconKnowledgeAnswer: Codable, Equatable, Sendable {
    public let text: String
    public let evidenceClaims: [BeaconEvidenceClaim]
    public let citations: [BeaconKnowledgeCitation]

    public init(
        text: String,
        evidenceClaims: [BeaconEvidenceClaim],
        citations: [BeaconKnowledgeCitation]
    ) {
        self.text = text
        self.evidenceClaims = evidenceClaims
        self.citations = citations
    }

    public func validate(against retrieval: BeaconKnowledgeRetrievalResult) throws {
        var retrieved: [String: BeaconKnowledgePassage] = [:]
        for passage in retrieval.passages {
            guard retrieved.updateValue(passage, forKey: passage.id) == nil else {
                throw BeaconKnowledgeValidationError.invalidManifest("duplicate passage ID")
            }
        }
        var cited: [String: BeaconKnowledgeCitation] = [:]
        for citation in citations {
            guard cited.updateValue(citation, forKey: citation.passageID) == nil else {
                throw BeaconKnowledgeValidationError.invalidManifest("duplicate citation")
            }
        }
        for citation in citations {
            guard let passage = retrieved[citation.passageID] else {
                throw BeaconKnowledgeValidationError.citationOutsideRetrieval
            }
            guard passage.sourceID == citation.sourceID else {
                throw BeaconKnowledgeValidationError.citationSourceMismatch
            }
        }
        for claim in evidenceClaims {
            guard !claim.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !claim.passageIDs.isEmpty,
                  claim.passageIDs.allSatisfy({ retrieved[$0] != nil && cited[$0] != nil }) else {
                throw BeaconKnowledgeValidationError.uncitedEvidenceClaim
            }
        }
    }
}

public protocol BeaconKnowledgeRetrieving: Sendable {
    func retrieve(_ query: BeaconKnowledgeQuery) async throws -> BeaconKnowledgeRetrievalResult
}
