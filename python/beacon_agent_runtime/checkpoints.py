"""Checkpoint contracts for interrupted and recoverable Agent runs."""

from __future__ import annotations

from copy import deepcopy
from dataclasses import dataclass, field
import json
from pathlib import Path
import sqlite3
from threading import Lock
from typing import Any, Protocol

from .events import ApprovalInterruptAction, ToolObservation, ToolRequestAction


@dataclass
class RuntimeCheckpoint:
    run_id: str
    query: str
    authorized_scopes: set[str]
    observations: list[ToolObservation] = field(default_factory=list)
    steps: int = 0
    tools: int = 0
    retries: int = 0
    next_sequence: int = 0
    pending_approval: ApprovalInterruptAction | None = None
    pending_device_tool: ToolRequestAction | None = None
    cancelled: bool = False
    approved_tool_calls: set[str] = field(default_factory=set)
    completed_idempotency: dict[str, ToolObservation] = field(default_factory=dict)


class CheckpointStore(Protocol):
    def save(self, checkpoint: RuntimeCheckpoint) -> None: ...

    def load(self, run_id: str) -> RuntimeCheckpoint | None: ...


class InMemoryCheckpointStore:
    def __init__(self) -> None:
        self._checkpoints: dict[str, RuntimeCheckpoint] = {}

    def save(self, checkpoint: RuntimeCheckpoint) -> None:
        self._checkpoints[checkpoint.run_id] = deepcopy(checkpoint)

    def load(self, run_id: str) -> RuntimeCheckpoint | None:
        checkpoint = self._checkpoints.get(run_id)
        return deepcopy(checkpoint) if checkpoint is not None else None


class SQLiteCheckpointStore:
    """Small durable checkpoint store for host-owned resumable agent state.

    It persists only the runtime contract (tool requests, validated observations
    and approval state). Hosts remain responsible for authenticating a run before
    loading it and for keeping device records on the device.
    """

    def __init__(self, path: str | Path) -> None:
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = Lock()
        with self._connect() as connection:
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS beacon_runtime_checkpoints (
                    run_id TEXT PRIMARY KEY,
                    payload TEXT NOT NULL
                )
                """
            )

    def save(self, checkpoint: RuntimeCheckpoint) -> None:
        payload = json.dumps(_checkpoint_payload(checkpoint), ensure_ascii=False, separators=(",", ":"))
        with self._lock, self._connect() as connection:
            connection.execute(
                "INSERT INTO beacon_runtime_checkpoints(run_id, payload) VALUES (?, ?) "
                "ON CONFLICT(run_id) DO UPDATE SET payload=excluded.payload",
                (checkpoint.run_id, payload),
            )

    def load(self, run_id: str) -> RuntimeCheckpoint | None:
        with self._lock, self._connect() as connection:
            row = connection.execute(
                "SELECT payload FROM beacon_runtime_checkpoints WHERE run_id = ?",
                (run_id,),
            ).fetchone()
        return _checkpoint_from_payload(json.loads(row[0])) if row is not None else None

    def purge(self) -> None:
        """Remove legacy payloads which may contain private device context.

        Native LangGraph uses its own allowlisted checkpointer.  Hosts call this
        during migration so the previous custom checkpoint table cannot retain
        raw queries, observations, or tool arguments indefinitely.
        """

        with self._lock, self._connect() as connection:
            connection.execute("DELETE FROM beacon_runtime_checkpoints")

    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(self.path)


def _tool_request_payload(action: ToolRequestAction | None) -> dict[str, Any] | None:
    if action is None:
        return None
    return {
        "toolCallId": action.tool_call_id,
        "capabilityId": action.capability_id,
        "arguments": action.arguments,
        "requestedScopes": list(action.requested_scopes),
        "idempotencyKey": action.idempotency_key,
    }


def _tool_request_from_payload(payload: dict[str, Any] | None) -> ToolRequestAction | None:
    if payload is None:
        return None
    return ToolRequestAction(
        tool_call_id=payload["toolCallId"],
        capability_id=payload["capabilityId"],
        arguments=payload["arguments"],
        requested_scopes=tuple(payload["requestedScopes"]),
        idempotency_key=payload["idempotencyKey"],
    )


def _approval_payload(action: ApprovalInterruptAction | None) -> dict[str, Any] | None:
    if action is None:
        return None
    return {
        "approvalId": action.approval_id,
        "toolCallId": action.tool_call_id,
        "capabilityId": action.capability_id,
        "summary": action.summary,
        "requestedScopes": list(action.requested_scopes),
        "idempotencyKey": action.idempotency_key,
    }


def _approval_from_payload(payload: dict[str, Any] | None) -> ApprovalInterruptAction | None:
    if payload is None:
        return None
    return ApprovalInterruptAction(
        approval_id=payload["approvalId"],
        tool_call_id=payload["toolCallId"],
        capability_id=payload["capabilityId"],
        summary=payload["summary"],
        requested_scopes=tuple(payload["requestedScopes"]),
        idempotency_key=payload["idempotencyKey"],
    )


def _observation_payload(observation: ToolObservation) -> dict[str, Any]:
    return {
        "toolCallId": observation.tool_call_id,
        "capabilityId": observation.capability_id,
        "data": observation.data,
    }


def _observation_from_payload(payload: dict[str, Any]) -> ToolObservation:
    return ToolObservation(
        tool_call_id=payload["toolCallId"],
        capability_id=payload["capabilityId"],
        data=payload["data"],
    )


def _checkpoint_payload(checkpoint: RuntimeCheckpoint) -> dict[str, Any]:
    return {
        "runId": checkpoint.run_id,
        "query": checkpoint.query,
        "authorizedScopes": sorted(checkpoint.authorized_scopes),
        "observations": [_observation_payload(item) for item in checkpoint.observations],
        "steps": checkpoint.steps,
        "tools": checkpoint.tools,
        "retries": checkpoint.retries,
        "nextSequence": checkpoint.next_sequence,
        "pendingApproval": _approval_payload(checkpoint.pending_approval),
        "pendingDeviceTool": _tool_request_payload(checkpoint.pending_device_tool),
        "cancelled": checkpoint.cancelled,
        "approvedToolCalls": sorted(checkpoint.approved_tool_calls),
        "completedIdempotency": {
            key: _observation_payload(value)
            for key, value in checkpoint.completed_idempotency.items()
        },
    }


def _checkpoint_from_payload(payload: dict[str, Any]) -> RuntimeCheckpoint:
    return RuntimeCheckpoint(
        run_id=payload["runId"],
        query=payload["query"],
        authorized_scopes=set(payload["authorizedScopes"]),
        observations=[_observation_from_payload(item) for item in payload["observations"]],
        steps=payload["steps"],
        tools=payload["tools"],
        retries=payload["retries"],
        next_sequence=payload["nextSequence"],
        pending_approval=_approval_from_payload(payload["pendingApproval"]),
        pending_device_tool=_tool_request_from_payload(payload["pendingDeviceTool"]),
        cancelled=payload["cancelled"],
        approved_tool_calls=set(payload["approvedToolCalls"]),
        completed_idempotency={
            key: _observation_from_payload(value)
            for key, value in payload["completedIdempotency"].items()
        },
    )
