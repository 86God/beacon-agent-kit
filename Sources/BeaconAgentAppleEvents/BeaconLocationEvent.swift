import Foundation
import BeaconAgentCore

public struct BeaconLocationEvent: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case enteredRegion
        case exitedRegion
        case significantChange
        case visitDetected
    }

    public let id: String
    public let kind: Kind
    public let regionId: String?
    public let approximateLabel: String?

    public init(id: String = UUID().uuidString, kind: Kind, regionId: String? = nil, approximateLabel: String? = nil) {
        self.id = id
        self.kind = kind
        self.regionId = regionId
        self.approximateLabel = BeaconRedactor.optionalDisplayText(approximateLabel)
    }
}
