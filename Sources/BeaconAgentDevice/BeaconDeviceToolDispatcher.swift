import Foundation

public enum BeaconDeviceDispatchError: Error, Equatable, Sendable {
    case unknownCapability
    case disabled
    case incompatibleSchema
    case missingScope
    case wrongAccount
    case confirmationRequired
    case expired
    case duplicateInFlight
    case invalidArguments
    case invalidResult
    case missingHandler
}

public actor BeaconDeviceToolDispatcher {
    private let advertisements: [String: BeaconDeviceCapabilityAdvertisement]
    private let policies: [String: BeaconDevicePolicy]
    private let handlers: [String: any BeaconDeviceToolHandler]
    private let trustedHostContext: BeaconTrustedHostContext
    private var inFlightToolCalls: Set<String> = []
    private var inFlightIdempotencyKeys: Set<String> = []
    private var completedIdempotency: [String: BeaconToolObservation] = [:]

    public init(
        advertisements: [BeaconDeviceCapabilityAdvertisement],
        policies: [BeaconDevicePolicy],
        handlers: [any BeaconDeviceToolHandler],
        trustedHostContext: BeaconTrustedHostContext
    ) {
        self.advertisements = Dictionary(
            advertisements.map { ($0.capabilityID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.policies = Dictionary(
            policies.map { ($0.capabilityID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.handlers = Dictionary(
            handlers.map { ($0.capabilityID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.trustedHostContext = trustedHostContext
    }

    public func dispatch(
        _ request: BeaconDeviceToolRequest,
        authorization: BeaconDeviceRunAuthorization
    ) async throws -> BeaconToolObservation {
        guard let advertisement = advertisements[request.capabilityID],
              let policy = policies[request.capabilityID]
        else {
            throw BeaconDeviceDispatchError.unknownCapability
        }
        guard advertisement.enabled else { throw BeaconDeviceDispatchError.disabled }
        guard advertisement.supportedSchemaVersions.contains(request.schemaVersion) else {
            throw BeaconDeviceDispatchError.incompatibleSchema
        }
        guard authorization.accountID == trustedHostContext.accountID else {
            throw BeaconDeviceDispatchError.wrongAccount
        }
        guard request.expiresAt > trustedHostContext.now else {
            throw BeaconDeviceDispatchError.expired
        }
        guard policy.requiredScopes.isSubset(of: trustedHostContext.authorizedScopes),
              request.requestedScopes == policy.requiredScopes
        else {
            throw BeaconDeviceDispatchError.missingScope
        }
        if policy.confirmation != .never,
           !authorization.confirmedToolCallIDs.contains(request.toolCallID) {
            throw BeaconDeviceDispatchError.confirmationRequired
        }
        guard policy.validates(arguments: request.arguments) else {
            throw BeaconDeviceDispatchError.invalidArguments
        }
        if let key = request.idempotencyKey,
           let completed = completedIdempotency[key] {
            return completed.replayed(for: request.toolCallID)
        }
        if inFlightToolCalls.contains(request.toolCallID)
            || request.idempotencyKey.map(inFlightIdempotencyKeys.contains) == true {
            throw BeaconDeviceDispatchError.duplicateInFlight
        }
        guard let handler = handlers[request.capabilityID] else {
            throw BeaconDeviceDispatchError.missingHandler
        }

        inFlightToolCalls.insert(request.toolCallID)
        if let key = request.idempotencyKey {
            inFlightIdempotencyKeys.insert(key)
        }
        defer {
            inFlightToolCalls.remove(request.toolCallID)
            if let key = request.idempotencyKey {
                inFlightIdempotencyKeys.remove(key)
            }
        }

        let authorized = BeaconAuthorizedToolRequest(
            request: request,
            trustedHostContext: trustedHostContext
        )
        let observation = try await handler.execute(authorized)
        guard policy.validates(output: observation.payload) else {
            throw BeaconDeviceDispatchError.invalidResult
        }
        if let key = request.idempotencyKey {
            completedIdempotency[key] = observation
        }
        return observation
    }
}
