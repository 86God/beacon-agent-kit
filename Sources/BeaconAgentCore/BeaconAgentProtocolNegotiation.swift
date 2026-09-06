import Foundation

public struct BeaconAgentProtocolFailureV2: Codable, Equatable, Sendable, Error {
    public let code: String
    public let retryable: Bool
    public let diagnosticId: String
    public let requiredSchemaVersion: Int?

    public init(
        code: String,
        retryable: Bool,
        diagnosticId: String,
        requiredSchemaVersion: Int? = nil
    ) {
        self.code = code
        self.retryable = retryable
        self.diagnosticId = diagnosticId
        self.requiredSchemaVersion = requiredSchemaVersion
    }
}

public struct BeaconAgentProtocolNegotiationResult: Codable, Equatable, Sendable {
    public let kind: String
    public let selectedVersion: Int?
    public let failure: BeaconAgentProtocolFailureV2?

    public init(
        kind: String,
        selectedVersion: Int? = nil,
        failure: BeaconAgentProtocolFailureV2? = nil
    ) {
        self.kind = kind
        self.selectedVersion = selectedVersion
        self.failure = failure
    }
}

public enum BeaconAgentProtocolNegotiator {
    public static let minimumVersion = 1
    public static let maximumVersion = Int(Int32.max)

    public static func negotiate(
        localSupported: [Int],
        peerSupported: [Int],
        diagnosticId: String
    ) -> BeaconAgentProtocolNegotiationResult {
        guard !localSupported.isEmpty,
              !peerSupported.isEmpty,
              localSupported.allSatisfy({ minimumVersion...maximumVersion ~= $0 }),
              peerSupported.allSatisfy({ minimumVersion...maximumVersion ~= $0 })
        else {
            return failure(
                kind: "incompatible",
                code: "protocol.invalid_version_offer",
                diagnosticId: diagnosticId
            )
        }

        let local = Set(localSupported)
        let peer = Set(peerSupported)
        if let selected = local.intersection(peer).max() {
            return BeaconAgentProtocolNegotiationResult(
                kind: "compatible",
                selectedVersion: selected
            )
        }

        if let localMaximum = local.max(),
           let peerMinimum = peer.min(),
           peerMinimum > localMaximum {
            return failure(
                kind: "upgrade_required",
                code: "protocol.upgrade_required",
                diagnosticId: diagnosticId,
                requiredSchemaVersion: peerMinimum
            )
        }

        return failure(
            kind: "incompatible",
            code: "protocol.no_common_version",
            diagnosticId: diagnosticId
        )
    }

    private static func failure(
        kind: String,
        code: String,
        diagnosticId: String,
        requiredSchemaVersion: Int? = nil
    ) -> BeaconAgentProtocolNegotiationResult {
        BeaconAgentProtocolNegotiationResult(
            kind: kind,
            failure: BeaconAgentProtocolFailureV2(
                code: code,
                retryable: false,
                diagnosticId: diagnosticId,
                requiredSchemaVersion: requiredSchemaVersion
            )
        )
    }
}

public extension BeaconAgentReplayError {
    func publicFailure(diagnosticId: String) -> BeaconAgentProtocolFailureV2 {
        let code: String
        let requiredSchemaVersion: Int?
        switch self {
        case let .unsupportedSchemaVersion(version):
            code = "protocol.unsupported_schema_version"
            requiredSchemaVersion = version
        case .eventCollision:
            code = "protocol.event_collision"
            requiredSchemaVersion = nil
        case .sequenceCollision:
            code = "protocol.sequence_collision"
            requiredSchemaVersion = nil
        case .mixedRunIds:
            code = "protocol.mixed_run"
            requiredSchemaVersion = nil
        case .mixedTurnIds:
            code = "protocol.mixed_turn"
            requiredSchemaVersion = nil
        case .eventAfterTerminal:
            code = "protocol.event_after_terminal"
            requiredSchemaVersion = nil
        case .unsupportedCriticalEvent:
            code = "protocol.unsupported_critical_event"
            requiredSchemaVersion = nil
        case .unsupportedPatch:
            code = "protocol.unsupported_patch"
            requiredSchemaVersion = nil
        case .blankField, .fieldCharacterLimit, .fieldUTF8ByteLimit,
             .payloadByteLimit, .malformedPayload:
            code = "protocol.invalid_event"
            requiredSchemaVersion = nil
        }
        return BeaconAgentProtocolFailureV2(
            code: code,
            retryable: false,
            diagnosticId: diagnosticId,
            requiredSchemaVersion: requiredSchemaVersion
        )
    }
}
