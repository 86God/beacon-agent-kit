import Foundation

public struct BeaconCardSource: Codable, Equatable, Sendable {
    public enum SourceType: String, Codable, Sendable {
        case local
        case agent
        case tool
        case user
        case system
    }

    public let type: SourceType
    public let provider: String?
    public let description: String

    public init(type: SourceType, provider: String? = nil, description: String) {
        self.type = type
        self.provider = BeaconRedactor.optionalDisplayText(provider)
        self.description = BeaconRedactor.displayText(description)
    }
}

public struct BeaconCardPrivacy: Codable, Equatable, Sendable {
    public let requiresUserReview: Bool
    public let containsRawMedia: Bool
    public let containsHealthData: Bool
    public let localOnly: Bool

    public init(
        requiresUserReview: Bool,
        containsRawMedia: Bool,
        containsHealthData: Bool,
        localOnly: Bool
    ) {
        self.requiresUserReview = requiresUserReview
        self.containsRawMedia = containsRawMedia
        self.containsHealthData = containsHealthData
        self.localOnly = localOnly
    }

    public static let localOnlyReview = BeaconCardPrivacy(
        requiresUserReview: true,
        containsRawMedia: false,
        containsHealthData: false,
        localOnly: true
    )
}

public enum BeaconCardAccent: String, Codable, Sendable {
    case system
    case success
    case warning
    case destructive
}

public enum BeaconCardStatus: String, Codable, Sendable {
    case draft
    case needsReview
    case confirmed
    case failed
    case cancelled
}

public struct BeaconCardAction: Codable, Equatable, Identifiable, Sendable {
    public enum Role: String, Codable, Sendable {
        case primary
        case secondary
        case destructive
    }

    public let id: String
    public let title: String
    public let role: Role

    public init(id: String, title: String, role: Role) {
        self.id = id
        self.title = BeaconRedactor.displayText(title)
        self.role = role
    }
}

public enum BeaconCardPayload: Codable, Equatable, Sendable {
    case text(String)
    case toolStatus(BeaconToolRun)
    case json(type: String, value: BeaconJSONValue)

    private enum CodingKeys: String, CodingKey {
        case kind
        case text
        case toolStatus
        case jsonType
        case jsonValue
    }

    private enum Kind: String, Codable {
        case text
        case toolStatus
        case json
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .text:
            self = .text(BeaconRedactor.displayText(try container.decode(String.self, forKey: .text)))
        case .toolStatus:
            self = .toolStatus(try container.decode(BeaconToolRun.self, forKey: .toolStatus))
        case .json:
            self = .json(
                type: BeaconRedactor.displayText(try container.decode(String.self, forKey: .jsonType)),
                value: try container.decode(BeaconJSONValue.self, forKey: .jsonValue)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(value):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(BeaconRedactor.displayText(value), forKey: .text)
        case let .toolStatus(toolRun):
            try container.encode(Kind.toolStatus, forKey: .kind)
            try container.encode(toolRun, forKey: .toolStatus)
        case let .json(type, value):
            try container.encode(Kind.json, forKey: .kind)
            try container.encode(BeaconRedactor.displayText(type), forKey: .jsonType)
            try container.encode(value, forKey: .jsonValue)
        }
    }
}

public struct BeaconCardEnvelope: Codable, Equatable, Identifiable, Sendable {
    public let schemaVersion: Int
    public let id: String
    public let kind: String
    public let title: String
    public let subtitle: String
    public let status: BeaconCardStatus
    public let confidence: Int?
    public let source: BeaconCardSource
    public let privacy: BeaconCardPrivacy
    public let accent: BeaconCardAccent
    public let payload: BeaconCardPayload
    public let actions: [BeaconCardAction]

    public init(
        schemaVersion: Int = 1,
        id: String,
        kind: String,
        title: String,
        subtitle: String,
        status: BeaconCardStatus,
        confidence: Int? = nil,
        source: BeaconCardSource,
        privacy: BeaconCardPrivacy,
        accent: BeaconCardAccent,
        payload: BeaconCardPayload,
        actions: [BeaconCardAction] = []
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.kind = BeaconRedactor.displayText(kind)
        self.title = BeaconRedactor.displayText(title)
        self.subtitle = BeaconRedactor.displayText(subtitle)
        self.status = status
        self.confidence = confidence.map { min(max($0, 0), 100) }
        self.source = source
        self.privacy = privacy
        self.accent = accent
        self.payload = payload
        self.actions = actions
    }
}
