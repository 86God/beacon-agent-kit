"""Versioned wire primitives shared by BeaconAgentKit hosts."""

from enum import StrEnum
from typing import Any

from pydantic import BaseModel, ConfigDict, Field, field_validator


class AgentEventType(StrEnum):
    RUN_STARTED = "run.started"
    RUN_FINISHED = "run.finished"
    RUN_ERROR = "run.error"
    RUN_INTERRUPTED = "run.interrupted"
    STEP_STARTED = "step.started"
    STEP_FINISHED = "step.finished"
    ACTIVITY_SNAPSHOT = "activity.snapshot"
    ACTIVITY_DELTA = "activity.delta"
    TEXT_START = "text.start"
    TEXT_DELTA = "text.delta"
    TEXT_END = "text.end"
    TOOL_START = "tool.start"
    TOOL_ARGUMENTS_DELTA = "tool.arguments.delta"
    TOOL_END = "tool.end"
    TOOL_RESULT = "tool.result"
    STATE_SNAPSHOT = "state.snapshot"
    STATE_DELTA = "state.delta"
    SURFACE_CREATE = "surface.create"
    SURFACE_PATCH = "surface.patch"
    SURFACE_COMPLETE = "surface.complete"
    SURFACE_ERROR = "surface.error"
    APPROVAL_REQUESTED = "approval.requested"
    APPROVAL_RESOLVED = "approval.resolved"
    APPROVAL_EXPIRED = "approval.expired"
    RECEIPT_COMMITTED = "receipt.committed"
    RECEIPT_REJECTED = "receipt.rejected"


class AgentEvent(BaseModel):
    """One ordered event in an Agent run."""

    model_config = ConfigDict(populate_by_name=True, frozen=True, extra="forbid")

    schema_version: int = Field(alias="schemaVersion", ge=1)
    event_id: str = Field(alias="eventId")
    run_id: str = Field(alias="runId")
    sequence: int = Field(ge=0)
    type: AgentEventType | str
    payload: dict[str, Any]

    @field_validator("event_id", "run_id")
    @classmethod
    def validate_non_blank_identifier(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("identifier must not be blank")
        return value
