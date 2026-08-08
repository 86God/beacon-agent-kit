"""Deterministic ordered replay for Beacon Agent v0.2 events."""

from __future__ import annotations

import json
from copy import deepcopy
from dataclasses import dataclass, field
from typing import Any

from .protocol import AgentEvent, AgentEventType


class AgentReplayError(ValueError):
    """Base class for replay failures that must fail closed."""


class EventCollisionError(AgentReplayError):
    """An event ID was reused with different content."""


class SequenceCollisionError(AgentReplayError):
    """A sequence number was reused by a different event."""


def _event_document(event: AgentEvent) -> dict[str, Any]:
    return event.model_dump(by_alias=True, mode="json")


def _canonical(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def _pointer_parts(path: str) -> list[str]:
    if not path.startswith("/"):
        raise AgentReplayError(f"invalid JSON pointer: {path}")
    return [part.replace("~1", "/").replace("~0", "~") for part in path[1:].split("/")]


def _apply_patch(document: Any, operations: list[dict[str, Any]]) -> Any:
    result = deepcopy(document)
    for operation in operations:
        op = operation.get("op")
        path = operation.get("path")
        if op not in {"add", "replace", "remove"} or not isinstance(path, str):
            raise AgentReplayError("unsupported JSON patch operation")
        parts = _pointer_parts(path)
        if not parts:
            if op == "remove":
                result = None
            else:
                result = deepcopy(operation.get("value"))
            continue
        parent = result
        for part in parts[:-1]:
            if isinstance(parent, list):
                parent = parent[int(part)]
            elif isinstance(parent, dict):
                parent = parent[part]
            else:
                raise AgentReplayError("JSON patch traversed a scalar")
        leaf = parts[-1]
        if isinstance(parent, list):
            if op == "add" and leaf == "-":
                parent.append(deepcopy(operation.get("value")))
            else:
                index = int(leaf)
                if op == "remove":
                    parent.pop(index)
                elif op == "add":
                    parent.insert(index, deepcopy(operation.get("value")))
                else:
                    parent[index] = deepcopy(operation.get("value"))
        elif isinstance(parent, dict):
            if op == "remove":
                parent.pop(leaf, None)
            else:
                parent[leaf] = deepcopy(operation.get("value"))
        else:
            raise AgentReplayError("JSON patch targeted a scalar")
    return result


@dataclass
class AgentStateReducer:
    """Buffers gaps and reduces each accepted event exactly once."""

    run_id: str | None = None
    next_sequence: int = 0
    status: str = "idle"
    activities: dict[str, dict[str, Any]] = field(default_factory=dict)
    text: dict[str, str] = field(default_factory=dict)
    tools: dict[str, dict[str, Any]] = field(default_factory=dict)
    state: dict[str, Any] = field(default_factory=dict)
    surfaces: dict[str, dict[str, Any]] = field(default_factory=dict)
    approvals: dict[str, dict[str, Any]] = field(default_factory=dict)
    receipts: list[dict[str, Any]] = field(default_factory=list)
    custom_events: list[dict[str, Any]] = field(default_factory=list)
    errors: list[dict[str, Any]] = field(default_factory=list)
    _buffer: dict[int, AgentEvent] = field(default_factory=dict, repr=False)
    _seen: dict[str, str] = field(default_factory=dict, repr=False)

    def ingest(self, event: AgentEvent) -> None:
        document = _event_document(event)
        fingerprint = _canonical(document)
        previous = self._seen.get(event.event_id)
        if previous is not None:
            if previous != fingerprint:
                raise EventCollisionError(f"event ID collision: {event.event_id}")
            return
        if self.run_id is not None and event.run_id != self.run_id:
            raise AgentReplayError("one reducer cannot mix run IDs")
        buffered = self._buffer.get(event.sequence)
        if buffered is not None and buffered.event_id != event.event_id:
            raise SequenceCollisionError(f"sequence collision: {event.sequence}")
        if event.sequence < self.next_sequence:
            raise SequenceCollisionError(f"sequence already consumed: {event.sequence}")

        self._seen[event.event_id] = fingerprint
        self._buffer[event.sequence] = event
        while self.next_sequence in self._buffer:
            current = self._buffer.pop(self.next_sequence)
            self._reduce(current)
            self.next_sequence += 1

    def normalized(self) -> dict[str, Any]:
        return {
            "activities": deepcopy(self.activities),
            "approvals": deepcopy(self.approvals),
            "bufferedSequences": sorted(self._buffer),
            "customEvents": deepcopy(self.custom_events),
            "errors": deepcopy(self.errors),
            "nextSequence": self.next_sequence,
            "receipts": deepcopy(self.receipts),
            "runId": self.run_id,
            "state": deepcopy(self.state),
            "status": self.status,
            "surfaces": deepcopy(self.surfaces),
            "text": deepcopy(self.text),
            "tools": deepcopy(self.tools),
        }

    def normalized_json(self) -> str:
        return _canonical(self.normalized())

    def _reduce(self, event: AgentEvent) -> None:
        if self.run_id is None:
            self.run_id = event.run_id
        event_type = str(event.type)
        payload = deepcopy(event.payload)

        if event_type == AgentEventType.RUN_STARTED:
            self.status = "running"
        elif event_type == AgentEventType.RUN_FINISHED:
            self.status = "finished"
        elif event_type == AgentEventType.RUN_INTERRUPTED:
            self.status = "interrupted"
        elif event_type == AgentEventType.RUN_ERROR:
            self.status = "error"
            self.errors.append(payload)
        elif event_type in {AgentEventType.ACTIVITY_SNAPSHOT, AgentEventType.ACTIVITY_DELTA}:
            identifier = _required_string(payload, "activityId")
            self.activities.setdefault(identifier, {}).update(payload)
        elif event_type == AgentEventType.TEXT_START:
            self.text[_required_string(payload, "messageId")] = ""
        elif event_type == AgentEventType.TEXT_DELTA:
            identifier = _required_string(payload, "messageId")
            self.text[identifier] = self.text.get(identifier, "") + str(payload.get("delta", ""))
        elif event_type == AgentEventType.TEXT_END:
            identifier = _required_string(payload, "messageId")
            if "finalText" in payload:
                self.text[identifier] = str(payload["finalText"])
        elif event_type == AgentEventType.TOOL_START:
            identifier = _required_string(payload, "toolCallId")
            self.tools[identifier] = {**payload, "status": "running"}
        elif event_type == AgentEventType.TOOL_RESULT:
            identifier = _required_string(payload, "toolCallId")
            self.tools.setdefault(identifier, {}).update(payload)
        elif event_type == AgentEventType.TOOL_END:
            identifier = _required_string(payload, "toolCallId")
            self.tools.setdefault(identifier, {}).update(payload)
        elif event_type == AgentEventType.STATE_SNAPSHOT:
            self.state = deepcopy(payload.get("state", {}))
        elif event_type == AgentEventType.STATE_DELTA:
            self.state = _apply_patch(self.state, _required_patch(payload))
        elif event_type == AgentEventType.SURFACE_CREATE:
            identifier = _required_string(payload, "surfaceId")
            self.surfaces[identifier] = {
                "document": deepcopy(payload.get("document", {})),
                "status": "streaming",
            }
        elif event_type == AgentEventType.SURFACE_PATCH:
            identifier = _required_string(payload, "surfaceId")
            surface = self.surfaces.setdefault(identifier, {"document": {}, "status": "streaming"})
            surface["document"] = _apply_patch(surface["document"], _required_patch(payload))
        elif event_type == AgentEventType.SURFACE_COMPLETE:
            identifier = _required_string(payload, "surfaceId")
            self.surfaces.setdefault(identifier, {"document": {}})["status"] = "complete"
        elif event_type == AgentEventType.SURFACE_ERROR:
            identifier = _required_string(payload, "surfaceId")
            self.surfaces.setdefault(identifier, {"document": {}}).update(status="error", error=payload)
        elif event_type == AgentEventType.APPROVAL_REQUESTED:
            identifier = _required_string(payload, "approvalId")
            self.approvals[identifier] = {**payload, "status": "pending"}
        elif event_type in {AgentEventType.APPROVAL_RESOLVED, AgentEventType.APPROVAL_EXPIRED}:
            identifier = _required_string(payload, "approvalId")
            status = "resolved" if event_type == AgentEventType.APPROVAL_RESOLVED else "expired"
            self.approvals.setdefault(identifier, {}).update(payload, status=status)
        elif event_type in {AgentEventType.RECEIPT_COMMITTED, AgentEventType.RECEIPT_REJECTED}:
            self.receipts.append(payload)
        elif event_type not in {str(item) for item in AgentEventType}:
            self.custom_events.append(_event_document(event))


def _required_string(payload: dict[str, Any], key: str) -> str:
    value = payload.get(key)
    if not isinstance(value, str) or not value:
        raise AgentReplayError(f"missing {key}")
    return value


def _required_patch(payload: dict[str, Any]) -> list[dict[str, Any]]:
    value = payload.get("patch")
    if not isinstance(value, list) or not all(isinstance(item, dict) for item in value):
        raise AgentReplayError("missing patch operations")
    return value
