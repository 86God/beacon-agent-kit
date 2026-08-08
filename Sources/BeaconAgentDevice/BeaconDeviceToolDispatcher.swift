import Foundation
import BeaconAgentCore

public enum BeaconDeviceDispatchError: Error, Equatable, Sendable {
    case unknownCapability
    case disabled
    case incompatibleSchema
    case missingScope
    case wrongAccount
    case confirmationRequired
    case expired
    case duplicateInFlight
    case idempotencyConflict
    case invalidArguments
    case invalidResult
    case missingHandler
}

public actor BeaconDeviceToolDispatcher {
    private struct IdempotencySignature: Equatable {
        let schemaVersion: Int
        let registryRevision: String
        let requestedScopes: Set<String>
        let arguments: [String: BeaconJSONValue]
    }

    private struct CompletedIdempotency {
        let signature: IdempotencySignature
        let observation: BeaconToolObservation
    }

    private let advertisements: [String: BeaconDeviceCapabilityAdvertisement]
    private let policies: [String: BeaconDevicePolicy]
    private let handlers: [String: any BeaconDeviceToolHandler]
    private let trustedHostContext: BeaconTrustedHostContext
    private let clock: @Sendable () -> Date
    private var inFlightToolCalls: Set<String> = []
    private var inFlightIdempotencyKeys: Set<String> = []
    private var completedIdempotency: [String: CompletedIdempotency] = [:]

    public init(
        advertisements: [BeaconDeviceCapabilityAdvertisement],
        policies: [BeaconDevicePolicy],
        handlers: [any BeaconDeviceToolHandler],
        trustedHostContext: BeaconTrustedHostContext,
        clock: @escaping @Sendable () -> Date = Date.init
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
        self.clock = clock
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
        guard request.expiresAt > clock() else {
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
        let scopedIdempotencyKey = request.idempotencyKey.map {
            [trustedHostContext.accountID, request.capabilityID, $0].joined(separator: "|")
        }
        let idempotencySignature = IdempotencySignature(
            schemaVersion: request.schemaVersion,
            registryRevision: request.registryRevision,
            requestedScopes: request.requestedScopes,
            arguments: request.arguments
        )
        if let key = scopedIdempotencyKey,
           let completed = completedIdempotency[key] {
            guard completed.signature == idempotencySignature else {
                throw BeaconDeviceDispatchError.idempotencyConflict
            }
            return completed.observation.replayed(for: request.toolCallID)
        }
        if inFlightToolCalls.contains(request.toolCallID)
            || scopedIdempotencyKey.map(inFlightIdempotencyKeys.contains) == true {
            throw BeaconDeviceDispatchError.duplicateInFlight
        }
        guard let handler = handlers[request.capabilityID] else {
            throw BeaconDeviceDispatchError.missingHandler
        }

        inFlightToolCalls.insert(request.toolCallID)
        if let key = scopedIdempotencyKey {
            inFlightIdempotencyKeys.insert(key)
        }
        defer {
            inFlightToolCalls.remove(request.toolCallID)
            if let key = scopedIdempotencyKey {
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
        if let key = scopedIdempotencyKey {
            completedIdempotency[key] = CompletedIdempotency(
                signature: idempotencySignature,
                observation: observation
            )
        }
        return observation
    }
}
