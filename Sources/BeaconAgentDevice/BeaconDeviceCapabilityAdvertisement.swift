import Foundation

public struct BeaconDeviceCapabilityAdvertisement: Codable, Equatable, Sendable {
    public let capabilityID: String
    public let version: String
    public let supportedSchemaVersions: Set<Int>
    /// The installed app version. The server may only use it to remove a
    /// capability below a release's minimum version; it never grants access.
    public let appVersion: String?
    public let enabled: Bool

    public init(
        capabilityID: String,
        version: String,
        supportedSchemaVersions: Set<Int>,
        appVersion: String? = nil,
        enabled: Bool
    ) {
        self.capabilityID = capabilityID
        self.version = version
        self.supportedSchemaVersions = supportedSchemaVersions
        self.appVersion = appVersion
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case capabilityID = "capabilityId"
        case version
        case supportedSchemaVersions
        case appVersion
        case enabled
    }
}

public struct BeaconTrustedHostContext: Equatable, Sendable {
    public let accountID: String
    public let deviceID: String
    public let authorizedScopes: Set<String>
    public let now: Date

    public init(
        accountID: String,
        deviceID: String,
        authorizedScopes: Set<String>,
        now: Date
    ) {
        self.accountID = accountID
        self.deviceID = deviceID
        self.authorizedScopes = authorizedScopes
        self.now = now
    }
}

public struct BeaconDeviceRunAuthorization: Equatable, Sendable {
    public let accountID: String
    public let confirmedToolCallIDs: Set<String>

    public init(accountID: String, confirmedToolCallIDs: Set<String>) {
        self.accountID = accountID
        self.confirmedToolCallIDs = confirmedToolCallIDs
    }
}
