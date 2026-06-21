import Foundation

public enum BeaconTimelineReducer {
    public static func reduce(state: BeaconTimelineState, event: BeaconAgentEvent) -> BeaconTimelineState {
        var next = state
        switch event {
        case .runStarted, .runFinished, .custom:
            break
        case let .runError(event):
            next.messages.append(BeaconTimelineMessage(role: .assistant, text: event.errorSummary))
        case let .messageStarted(event):
            next.activeMessageDeltas[event.messageId] = ""
        case let .messageDelta(event):
            next.activeMessageDeltas[event.messageId, default: ""] += event.delta
        case let .messageFinished(event):
            let text = event.finalText ?? next.activeMessageDeltas[event.messageId] ?? ""
            next.messages.append(BeaconTimelineMessage(id: event.messageId, role: event.role, text: text))
            next.activeMessageDeltas[event.messageId] = nil
        case .toolArgsDelta:
            break
        case let .toolStarted(event):
            upsert(
                BeaconToolRun(
                    id: event.toolRunId,
                    toolName: event.toolName,
                    title: event.title,
                    status: .running,
                    summary: event.inputSummary ?? "Running \(event.title)",
                    inputSummary: event.inputSummary,
                    startedAt: event.startedAt
                ),
                in: &next.toolRuns
            )
        case let .toolFinished(event):
            let existing = next.toolRuns.first { $0.id == event.toolRunId }
            upsert(
                BeaconToolRun(
                    id: event.toolRunId,
                    toolName: existing?.toolName ?? "tool",
                    title: existing?.title ?? "Tool",
                    status: event.status,
                    summary: event.outputSummary ?? "\(existing?.title ?? "Tool") finished.",
                    inputSummary: existing?.inputSummary,
                    outputSummary: event.outputSummary ?? existing?.outputSummary,
                    startedAt: existing?.startedAt,
                    finishedAt: event.finishedAt
                ),
                in: &next.toolRuns
            )
        case let .toolFailed(event):
            let existing = next.toolRuns.first { $0.id == event.toolRunId }
            upsert(
                BeaconToolRun(
                    id: event.toolRunId,
                    toolName: existing?.toolName ?? "tool",
                    title: existing?.title ?? "Tool",
                    status: .failed,
                    summary: event.errorSummary,
                    inputSummary: existing?.inputSummary,
                    outputSummary: existing?.outputSummary,
                    errorSummary: event.errorSummary,
                    startedAt: existing?.startedAt,
                    finishedAt: event.finishedAt
                ),
                in: &next.toolRuns
            )
        case let .cardCreated(event):
            upsert(event.card, in: &next.cards)
        case let .cardUpdated(event):
            upsert(event.card, in: &next.cards)
        }
        return next
    }

    private static func upsert(_ toolRun: BeaconToolRun, in toolRuns: inout [BeaconToolRun]) {
        if let index = toolRuns.firstIndex(where: { $0.id == toolRun.id }) {
            toolRuns[index] = toolRun
        } else {
            toolRuns.append(toolRun)
        }
    }

    private static func upsert(_ card: BeaconCardEnvelope, in cards: inout [BeaconCardEnvelope]) {
        if let index = cards.firstIndex(where: { $0.id == card.id }) {
            cards[index] = card
        } else {
            cards.append(card)
        }
    }
}
