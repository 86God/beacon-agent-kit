import Foundation

public enum BeaconPrivacyLevel: String, Codable, Equatable, Sendable {
    case publicInfo
    case appState
    case personalPreference
    case locationApproximate
    case locationPrecise
    case healthSummary
    case healthSample
    case rawMedia
    case notificationContent
    case contactOrCalendar
    case secret
}

public struct BeaconPolicy: Codable, Equatable, Sendable {
    public var privacyLevel: BeaconPrivacyLevel
    public var requiresUserConsent: Bool
    public var canSendToCloudAgent: Bool
    public var canTriggerNotification: Bool
    public var canStartLiveActivity: Bool
    public var canWriteHealthData: Bool
    public var canReadPreciseLocation: Bool
    public var canIncludeRawMedia: Bool

    public init(
        privacyLevel: BeaconPrivacyLevel,
        requiresUserConsent: Bool = false,
        canSendToCloudAgent: Bool = false,
        canTriggerNotification: Bool = false,
        canStartLiveActivity: Bool = false,
        canWriteHealthData: Bool = false,
        canReadPreciseLocation: Bool = false,
        canIncludeRawMedia: Bool = false
    ) {
        self.privacyLevel = privacyLevel
        self.requiresUserConsent = requiresUserConsent
        self.canSendToCloudAgent = canSendToCloudAgent
        self.canTriggerNotification = canTriggerNotification
        self.canStartLiveActivity = canStartLiveActivity
        self.canWriteHealthData = canWriteHealthData
        self.canReadPreciseLocation = canReadPreciseLocation
        self.canIncludeRawMedia = canIncludeRawMedia
    }

    public static let localOnly = BeaconPolicy(privacyLevel: .appState)
}
