import Foundation
import BeaconAgentCore

/// Decoder for newline-delimited AG-UI-like JSON event streams.
public enum BeaconAGUIEventDecoder {
    public static func decodeLines(_ data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> [BeaconAgentEvent] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return try text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { line in
                try decoder.decode(BeaconAgentEvent.self, from: Data(line.utf8))
            }
    }

    public static func decodeV2Event(
        _ text: String,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> BeaconAgentEventV2 {
        try decoder.decode(BeaconAgentEventV2.self, from: Data(text.utf8))
    }
}
