"""Checkpoint contracts for interrupted and recoverable Agent runs."""

from __future__ import annotations

from copy import deepcopy
from dataclasses import dataclass, field
from typing import Protocol

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
