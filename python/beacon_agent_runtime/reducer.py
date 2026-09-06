"""Deterministic ordered replay for Beacon Agent v0.2 events."""

from __future__ import annotations

import json
from copy import deepcopy
from dataclasses import dataclass, field
from typing import Any

from .protocol import (
    AgentEvent,
    AgentEventType,
    validate_payload_wire_budget,
    validate_wire_identifier,
)


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
    turn_id: str | None = None
    attempt_id: str | None = None
    segment_id: str | None = None
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
    result_kind: str | None = None
    failure: dict[str, Any] | None = None
    diagnostic: dict[str, Any] | None = None
    _buffer: dict[int, AgentEvent] = field(default_factory=dict, repr=False)
    _seen: dict[str, str] = field(default_factory=dict, repr=False)
    _terminal_sequence: int | None = field(default=None, repr=False)

    def ingest(self, event: AgentEvent) -> None:
        event = AgentEvent.model_validate(event.model_dump(by_alias=True, mode="json"))
        validate_payload_wire_budget(event.payload)
        previous_next_sequence = self.next_sequence
        candidate = deepcopy(self)
        try:
            candidate._ingest_validated(event)
        except Exception:
            if candidate.next_sequence > previous_next_sequence:
                self._commit(candidate)
            raise
        self._commit(candidate)

    def _commit(self, candidate: AgentStateReducer) -> None:
        self.__dict__.clear()
        self.__dict__.update(candidate.__dict__)

    def _ingest_validated(self, event: AgentEvent) -> None:
        document = _event_document(event)
        fingerprint = _canonical(document)
        previous = self._seen.get(event.event_id)
        if previous is not None:
            if previous != fingerprint:
                raise EventCollisionError(f"event ID collision: {event.event_id}")
            return
        if self.run_id is not None and event.run_id != self.run_id:
            raise AgentReplayError("one reducer cannot mix run IDs")
        if (
            self.turn_id is not None
            and event.turn_id is not None
            and event.turn_id != self.turn_id
        ):
            raise AgentReplayError("one reducer cannot mix turn IDs")
        if self._terminal_sequence is not None:
            raise AgentReplayError(
                f"event after terminal sequence: {event.sequence}"
            )
        buffered = self._buffer.get(event.sequence)
        if buffered is not None and buffered.event_id != event.event_id:
            raise SequenceCollisionError(f"sequence collision: {event.sequence}")
        if event.sequence < self.next_sequence:
            raise SequenceCollisionError(f"sequence already consumed: {event.sequence}")

        self._seen[event.event_id] = fingerprint
        self._buffer[event.sequence] = event
        self._validate_buffered_identity()
        while self.next_sequence in self._buffer:
            current = self._buffer[self.next_sequence]
            reduction_candidate = deepcopy(self)
            reduction_candidate._buffer.pop(self.next_sequence)
            try:
                reduction_candidate._reduce(current)
            except Exception:
                self._buffer.pop(self.next_sequence)
                self._seen.pop(current.event_id, None)
                raise
            reduction_candidate.next_sequence += 1
            self._commit(reduction_candidate)
            if self._terminal_sequence is not None:
                for late_event in self._buffer.values():
                    self._seen.pop(late_event.event_id, None)
                self._buffer.clear()
                break

    def _validate_buffered_identity(self) -> None:
        run_ids = {event.run_id for event in self._buffer.values()}
        if self.run_id is not None:
            run_ids.add(self.run_id)
        if len(run_ids) > 1:
            raise AgentReplayError("one reducer cannot mix run IDs")

        turn_ids = {
            event.turn_id
            for event in self._buffer.values()
            if event.turn_id is not None
        }
        if self.turn_id is not None:
            turn_ids.add(self.turn_id)
        if len(turn_ids) > 1:
            raise AgentReplayError("one reducer cannot mix turn IDs")

    def normalized(self) -> dict[str, Any]:
        projection = {
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
        if self.turn_id is not None:
            projection["turnId"] = self.turn_id
        if self.attempt_id is not None:
            projection["attemptId"] = self.attempt_id
        if self.segment_id is not None:
            projection["segmentId"] = self.segment_id
        if self.result_kind is not None:
            projection["resultKind"] = self.result_kind
        if self.failure is not None:
            projection["failure"] = deepcopy(self.failure)
        if self.diagnostic is not None:
            projection["diagnostic"] = deepcopy(self.diagnostic)
        return projection

    def normalized_json(self) -> str:
        return _canonical(self.normalized())

    def _reduce(self, event: AgentEvent) -> None:
        if self.run_id is None:
            self.run_id = event.run_id
        if self.turn_id is None:
            self.turn_id = event.turn_id
        self.attempt_id = event.attempt_id or self.attempt_id
        self.segment_id = event.segment_id or self.segment_id
        event_type = str(event.type)
        payload = deepcopy(event.payload)

        if event_type == AgentEventType.RUN_STARTED:
            self.status = "running"
            self.diagnostic = None
        elif event_type == AgentEventType.RUN_FINISHED:
            if "resultKind" in payload:
                result_kind = _required_string(payload, "resultKind")
                if result_kind not in {"success", "empty", "text_fallback"}:
                    raise AgentReplayError("invalid resultKind")
                self.result_kind = result_kind
            self.status = "finished"
            self._terminal_sequence = event.sequence
        elif event_type == AgentEventType.RUN_INTERRUPTED:
            self.status = "interrupted"
        elif event_type == AgentEventType.RUN_ERROR:
            self.status = "error"
            self.errors.append(payload)
            self.failure = _diagnostic_fields(payload, required=False)
            self._terminal_sequence = event.sequence
        elif event_type == AgentEventType.DEVICE_WAITING:
            self.status = "waiting_device"
            self.diagnostic = _diagnostic_fields(payload, required=True)
        elif event_type == AgentEventType.PERMISSION_DENIED:
            fields = _diagnostic_fields(payload, required=True)
            self.status = "permission_denied"
            self.failure = fields
            self.errors.append(deepcopy(fields))
            self._terminal_sequence = event.sequence
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
            self.status = "waiting_approval"
            self.diagnostic = _diagnostic_fields(payload, required=False)
        elif event_type in {AgentEventType.APPROVAL_RESOLVED, AgentEventType.APPROVAL_EXPIRED}:
            identifier = _required_string(payload, "approvalId")
            status = "resolved" if event_type == AgentEventType.APPROVAL_RESOLVED else "expired"
            self.approvals.setdefault(identifier, {}).update(payload, status=status)
            if self.status == "waiting_approval":
                self.status = "running" if event_type == AgentEventType.APPROVAL_RESOLVED else "error"
                self.diagnostic = None
        elif event_type in {AgentEventType.RECEIPT_COMMITTED, AgentEventType.RECEIPT_REJECTED}:
            self.receipts.append(payload)
        elif event_type not in {str(item) for item in AgentEventType}:
            if payload.get("critical") is True:
                raise AgentReplayError(f"unsupported critical event: {event_type}")
            self.custom_events.append(_event_document(event))


def _required_string(payload: dict[str, Any], key: str) -> str:
    value = payload.get(key)
    if not isinstance(value, str) or not value:
        raise AgentReplayError(f"missing {key}")
    return value


def _diagnostic_fields(payload: dict[str, Any], required: bool) -> dict[str, Any] | None:
    has_any = "retryable" in payload or "diagnosticId" in payload
    if not required and not has_any:
        return None

    code = _required_string(payload, "code")
    diagnostic_id = _required_string(payload, "diagnosticId")
    retryable = payload.get("retryable")
    if not isinstance(retryable, bool):
        raise AgentReplayError("missing retryable")
    try:
        validate_wire_identifier(code)
        validate_wire_identifier(diagnostic_id)
    except ValueError as error:
        raise AgentReplayError(str(error)) from error
    return {"code": code, "retryable": retryable, "diagnosticId": diagnostic_id}


def _required_patch(payload: dict[str, Any]) -> list[dict[str, Any]]:
    value = payload.get("patch")
    if not isinstance(value, list) or not all(isinstance(item, dict) for item in value):
        raise AgentReplayError("missing patch operations")
    return value
