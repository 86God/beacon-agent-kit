import Foundation
import BeaconAgentCore

public enum BeaconAGUIStreamError: Error, Equatable, Sendable {
    case invalidResponse
    case httpStatus(Int)
    case sequenceGap(expected: Int, received: Int)
}

public final class BeaconAGUIStreamClient: @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func events(
        for originalRequest: URLRequest,
        resumeCursor: BeaconAGUIResumeCursor = BeaconAGUIResumeCursor()
    ) -> AsyncThrowingStream<BeaconAgentEventV2, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = originalRequest
                    var cursor = resumeCursor
                    cursor.apply(to: &request)
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw BeaconAGUIStreamError.invalidResponse
                    }
                    guard (200..<300).contains(httpResponse.statusCode) else {
                        throw BeaconAGUIStreamError.httpStatus(httpResponse.statusCode)
                    }
                    var parser = BeaconAGUISSEParser()
                    for try await byte in bytes {
                        let messages = try parser.append(Data([byte]))
                        try yield(messages, cursor: &cursor, continuation: continuation)
                    }
                    try yield(
                        parser.finish(),
                        cursor: &cursor,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func yield(
        _ messages: [BeaconSSEMessage],
        cursor: inout BeaconAGUIResumeCursor,
        continuation: AsyncThrowingStream<BeaconAgentEventV2, Error>.Continuation
    ) throws {
        for message in messages {
            let event = try BeaconAGUIEventDecoder.decodeV2Event(message.data)
            switch try cursor.accept(event, serverEventID: message.id) {
            case .accepted:
                continuation.yield(event)
            case .duplicate:
                continue
            case let .gap(expected, received):
                throw BeaconAGUIStreamError.sequenceGap(expected: expected, received: received)
            }
        }
    }
}
