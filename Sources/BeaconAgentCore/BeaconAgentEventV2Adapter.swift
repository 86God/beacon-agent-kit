import Foundation

/// Projects the v0.2 ordered transport envelope onto the established generic
/// timeline types.  Domain renderers may additionally consume the original V2
/// payload for registered A2UI surfaces; this adapter never exposes tool data
/// as a text summary.
public enum BeaconAgentEventV2Adapter {
    public static func timelineEvent(
        from event: BeaconAgentEventV2,
        toolTitle: (String) -> String = { $0 }
    ) -> BeaconAgentEvent? {
        switch event.type {
        case "run.started":
            return .runStarted(
                BeaconRunStartedEvent(
                    id: event.eventId,
                    threadId: "agent",
                    runId: event.runId,
                    schemaVersion: event.schemaVersion
                )
            )
        case "run.finished":
            return .runFinished(
                BeaconRunFinishedEvent(
                    id: event.eventId,
                    runId: event.runId,
                    schemaVersion: event.schemaVersion
                )
            )
        case "run.error":
            return .runError(
                BeaconRunErrorEvent(
                    id: event.eventId,
                    runId: event.runId,
                    errorSummary: event.payload["summary"]?.stringValue ?? "Agent run failed",
                    schemaVersion: event.schemaVersion
                )
            )
        case "text.start":
            guard let messageID = event.payload["messageId"]?.stringValue else { return nil }
            return .messageStarted(
                BeaconMessageStartedEvent(
                    id: event.eventId,
                    messageId: messageID,
                    role: .assistant,
                    schemaVersion: event.schemaVersion
                )
            )
        case "text.delta":
            guard let messageID = event.payload["messageId"]?.stringValue,
                  let delta = event.payload["delta"]?.stringValue else { return nil }
            return .messageDelta(
                BeaconMessageDeltaEvent(
                    id: event.eventId,
                    messageId: messageID,
                    role: .assistant,
                    delta: delta,
                    schemaVersion: event.schemaVersion
                )
            )
        case "text.end":
            guard let messageID = event.payload["messageId"]?.stringValue else { return nil }
            return .messageFinished(
                BeaconMessageFinishedEvent(
                    id: event.eventId,
                    messageId: messageID,
                    role: .assistant,
                    finalText: event.payload["finalText"]?.stringValue,
                    schemaVersion: event.schemaVersion
                )
            )
        case "tool.start":
            guard let toolCallID = event.payload["toolCallId"]?.stringValue,
                  let capabilityID = event.payload["capabilityId"]?.stringValue else { return nil }
            return .toolStarted(
                BeaconToolStartedEvent(
                    id: event.eventId,
                    toolRunId: toolCallID,
                    toolName: capabilityID,
                    title: toolTitle(capabilityID),
                    inputSummary: "正在使用本机已授权能力",
                    schemaVersion: event.schemaVersion
                )
            )
        case "tool.result":
            guard let toolCallID = event.payload["toolCallId"]?.stringValue else { return nil }
            return .toolFinished(
                BeaconToolFinishedEvent(
                    id: event.eventId,
                    toolRunId: toolCallID,
                    outputSummary: "本机数据已返回",
                    schemaVersion: event.schemaVersion
                )
            )
        default:
            return nil
        }
    }
}

private extension BeaconJSONValue {
    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }
}
