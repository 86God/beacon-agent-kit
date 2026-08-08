import Foundation
import Testing
import BeaconAgentCore
@testable import BeaconAgentDevice

struct BeaconDeviceToolDispatcherTests {
    @Test(arguments: [
        FailureCase.disabled,
        .incompatible,
        .missingScope,
        .wrongAccount,
        .unconfirmed,
        .expired,
        .invalidSchema
    ])
    func rejectsUnauthorizedOrInvalidRequests(failure: FailureCase) async {
        let handler = CountingHandler()
        let fixture = makeFixture(handler: handler, failure: failure)

        do {
            _ = try await fixture.dispatcher.dispatch(
                fixture.request,
                authorization: fixture.authorization
            )
            Issue.record("Expected dispatch to fail")
        } catch let error as BeaconDeviceDispatchError {
            #expect(error == failure.expectedError)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await handler.callCount == 0)
    }

    @Test
    func duplicateInFlightFailsClosed() async throws {
        let handler = SuspendingHandler()
        let fixture = makeFixture(handler: handler)
        let first = Task {
            try await fixture.dispatcher.dispatch(
                fixture.request,
                authorization: fixture.authorization
            )
        }
        while await handler.callCount == 0 {
            await Task.yield()
        }

        do {
            _ = try await fixture.dispatcher.dispatch(
                fixture.request,
                authorization: fixture.authorization
            )
            Issue.record("Expected duplicate-in-flight rejection")
        } catch let error as BeaconDeviceDispatchError {
            #expect(error == .duplicateInFlight)
        }
        await handler.release()
        _ = try await first.value
    }

    @Test
    func completedIdempotencyReturnsReceiptWithoutSecondExecution() async throws {
        let handler = CountingHandler()
        let fixture = makeFixture(handler: handler)

        let first = try await fixture.dispatcher.dispatch(
            fixture.request,
            authorization: fixture.authorization
        )
        let duplicateRequest = BeaconDeviceToolRequest(
            runID: fixture.request.runID,
            toolCallID: "tool-2",
            capabilityID: fixture.request.capabilityID,
            schemaVersion: fixture.request.schemaVersion,
            registryRevision: fixture.request.registryRevision,
            requestedScopes: fixture.request.requestedScopes,
            arguments: fixture.request.arguments,
            idempotencyKey: fixture.request.idempotencyKey,
            expiresAt: fixture.request.expiresAt
        )
        let replay = try await fixture.dispatcher.dispatch(
            duplicateRequest,
            authorization: fixture.authorization
        )

        #expect(await handler.callCount == 1)
        #expect(first.payload == replay.payload)
        #expect(replay.idempotentReplay)
    }

    @Test
    func invalidHandlerResultFailsClosed() async {
        let fixture = makeFixture(
            handler: InvalidOutputHandler(),
            outputSchema: [
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "required": .array([.string("targetDate")]),
                "properties": .object([
                    "targetDate": .object(["type": .string("string")])
                ])
            ]
        )

        do {
            _ = try await fixture.dispatcher.dispatch(
                fixture.request,
                authorization: fixture.authorization
            )
            Issue.record("Expected invalid result rejection")
        } catch let error as BeaconDeviceDispatchError {
            #expect(error == .invalidResult)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func makeFixture(
        handler: some BeaconDeviceToolHandler,
        failure: FailureCase? = nil,
        outputSchema: [String: BeaconJSONValue] = ["type": .string("object")]
    ) -> Fixture {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let advertisement = BeaconDeviceCapabilityAdvertisement(
            capabilityID: "training.context.read",
            version: "1.0.0",
            supportedSchemaVersions: failure == .incompatible ? [1] : [2],
            enabled: failure != .disabled
        )
        let policy = BeaconDevicePolicy(
            capabilityID: advertisement.capabilityID,
            requiredScopes: ["training.read"],
            confirmation: failure == .unconfirmed ? .always : .never,
            inputSchema: [
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "required": .array([.string("targetDate")]),
                "properties": .object([
                    "targetDate": .object(["type": .string("string")])
                ])
            ],
            outputSchema: outputSchema
        )
        let host = BeaconTrustedHostContext(
            accountID: "account-1",
            deviceID: "device-1",
            authorizedScopes: failure == .missingScope ? [] : ["training.read"],
            now: now
        )
        let request = BeaconDeviceToolRequest(
            runID: "run-1",
            toolCallID: "tool-1",
            capabilityID: advertisement.capabilityID,
            schemaVersion: 2,
            registryRevision: "registry-1",
            requestedScopes: ["training.read"],
            arguments: failure == .invalidSchema ? [:] : ["targetDate": .string("2027-01-15")],
            idempotencyKey: "run-1:tool-1",
            expiresAt: failure == .expired ? now.addingTimeInterval(-1) : now.addingTimeInterval(60)
        )
        let authorization = BeaconDeviceRunAuthorization(
            accountID: failure == .wrongAccount ? "account-2" : "account-1",
            confirmedToolCallIDs: failure == .unconfirmed ? [] : ["tool-1", "tool-2"]
        )
        return Fixture(
            dispatcher: BeaconDeviceToolDispatcher(
                advertisements: [advertisement],
                policies: [policy],
                handlers: [handler],
                trustedHostContext: host
            ),
            request: request,
            authorization: authorization
        )
    }
}

enum FailureCase: CaseIterable, Sendable {
    case disabled, incompatible, missingScope, wrongAccount, unconfirmed, expired, invalidSchema

    var expectedError: BeaconDeviceDispatchError {
        switch self {
        case .disabled: .disabled
        case .incompatible: .incompatibleSchema
        case .missingScope: .missingScope
        case .wrongAccount: .wrongAccount
        case .unconfirmed: .confirmationRequired
        case .expired: .expired
        case .invalidSchema: .invalidArguments
        }
    }
}

private struct Fixture {
    let dispatcher: BeaconDeviceToolDispatcher
    let request: BeaconDeviceToolRequest
    let authorization: BeaconDeviceRunAuthorization
}

private actor CountingHandler: BeaconDeviceToolHandler {
    nonisolated let capabilityID = "training.context.read"
    private(set) var callCount = 0

    func execute(_ request: BeaconAuthorizedToolRequest) async throws -> BeaconToolObservation {
        callCount += 1
        return BeaconToolObservation(
            toolCallID: request.toolCallID,
            capabilityID: request.capabilityID,
            payload: ["targetDate": request.arguments["targetDate"] ?? .null]
        )
    }
}

private actor SuspendingHandler: BeaconDeviceToolHandler {
    nonisolated let capabilityID = "training.context.read"
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func execute(_ request: BeaconAuthorizedToolRequest) async throws -> BeaconToolObservation {
        callCount += 1
        await withCheckedContinuation { continuation = $0 }
        return BeaconToolObservation(
            toolCallID: request.toolCallID,
            capabilityID: request.capabilityID,
            payload: ["targetDate": request.arguments["targetDate"] ?? .null]
        )
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor InvalidOutputHandler: BeaconDeviceToolHandler {
    nonisolated let capabilityID = "training.context.read"

    func execute(_ request: BeaconAuthorizedToolRequest) async throws -> BeaconToolObservation {
        BeaconToolObservation(
            toolCallID: request.toolCallID,
            capabilityID: request.capabilityID,
            payload: ["unexpected": .bool(true)]
        )
    }
}
