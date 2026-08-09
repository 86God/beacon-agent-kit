"""Runtime actions, observations, and ordered event emission."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Iterable, Protocol

from .protocol import AgentEvent, AgentEventType


@dataclass(frozen=True)
class ToolRequestAction:
    tool_call_id: str
    capability_id: str
    arguments: dict[str, Any]
    requested_scopes: tuple[str, ...]
    idempotency_key: str | None


@dataclass(frozen=True)
class ApprovalInterruptAction:
    approval_id: str
    tool_call_id: str
    capability_id: str
    summary: str
    requested_scopes: tuple[str, ...]
    idempotency_key: str | None


@dataclass(frozen=True)
class FinishAction:
    text: str


@dataclass(frozen=True)
class StreamingFinishAction:
    """A provider-owned live text stream for the final assistant answer.

    The runtime deliberately owns event emission so each upstream chunk becomes a
    verifiable ``text.delta`` event instead of a UI-only typing simulation.
    """

    chunks: Iterable[str]


@dataclass(frozen=True)
class ToolObservation:
    tool_call_id: str
    capability_id: str
    data: dict[str, Any]


@dataclass(frozen=True)
class RunContext:
    run_id: str
    query: str
    registry_revision: str
    observations: tuple[ToolObservation, ...]
    step: int
    pending_approval: ApprovalInterruptAction | None = None


class EventSink(Protocol):
    def emit(self, event: AgentEvent) -> None: ...


@dataclass
class ListEventSink:
    events: list[AgentEvent] = field(default_factory=list)

    def emit(self, event: AgentEvent) -> None:
        self.events.append(event)


class AgentEventEmitter:
    def __init__(self, run_id: str, sink: EventSink, next_sequence: int = 0) -> None:
        self.run_id = run_id
        self.sink = sink
        self.next_sequence = next_sequence

    def emit(self, event_type: AgentEventType | str, payload: dict[str, Any]) -> AgentEvent:
        sequence = self.next_sequence
        event = AgentEvent(
            schemaVersion=2,
            eventId=f"{self.run_id}:{sequence}",
            runId=self.run_id,
            sequence=sequence,
            type=event_type,
            payload=payload,
        )
        self.sink.emit(event)
        self.next_sequence += 1
        return event
