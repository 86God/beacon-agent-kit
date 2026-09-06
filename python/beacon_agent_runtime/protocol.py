"""Versioned wire primitives shared by BeaconAgentKit hosts."""

from enum import StrEnum
from math import isfinite
from typing import Any

from pydantic import BaseModel, ConfigDict, Field, field_validator


IDENTIFIER_MAX_CHARACTERS = 128
IDENTIFIER_MAX_UTF8_BYTES = 256
EVENT_TYPE_MAX_CHARACTERS = 96
EVENT_TYPE_MAX_UTF8_BYTES = 384
PAYLOAD_MAX_BYTES = 262_144


def _is_wire_blank(value: str) -> bool:
    def is_blank(code_point: int) -> bool:
        return (
            0x0009 <= code_point <= 0x000D
            or 0x001C <= code_point <= 0x0020
            or code_point in {0x0085, 0x00A0, 0x1680, 0x202F, 0x205F, 0x3000, 0xFEFF}
            or 0x2000 <= code_point <= 0x200B
            or 0x2028 <= code_point <= 0x2029
        )

    return not value or all(is_blank(ord(character)) for character in value)


def payload_wire_budget(value: Any) -> int:
    """Return the cross-runtime decoded-JSON structural budget."""
    if value is None:
        return 4
    if isinstance(value, bool):
        return 4 if value else 5
    if isinstance(value, (int, float)):
        if isinstance(value, float) and not isfinite(value):
            raise ValueError("payload_not_json")
        return 32
    if isinstance(value, str):
        return 2 + len(value.encode("utf-8"))
    if isinstance(value, (list, tuple)):
        return (
            2
            + max(0, len(value) - 1)
            + sum(payload_wire_budget(item) for item in value)
        )
    if isinstance(value, dict):
        if not all(isinstance(key, str) for key in value):
            raise ValueError("payload_not_json")
        return 2 + max(0, len(value) - 1) + sum(
            3 + len(key.encode("utf-8")) + payload_wire_budget(item)
            for key, item in value.items()
        )
    raise ValueError("payload_not_json")


def validate_payload_wire_budget(value: dict[str, Any]) -> dict[str, Any]:
    if payload_wire_budget(value) > PAYLOAD_MAX_BYTES:
        raise ValueError("payload_byte_limit_exceeded")
    return value


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

    schema_version: int = Field(alias="schemaVersion", ge=2, le=2)
    event_id: str = Field(alias="eventId")
    run_id: str = Field(alias="runId")
    sequence: int = Field(ge=0)
    type: AgentEventType | str
    payload: dict[str, Any]

    @field_validator("event_id", "run_id")
    @classmethod
    def validate_non_blank_identifier(cls, value: str) -> str:
        if _is_wire_blank(value):
            raise ValueError("blank_field")
        if len(value) > IDENTIFIER_MAX_CHARACTERS:
            raise ValueError("character_limit_exceeded")
        if len(value.encode("utf-8")) > IDENTIFIER_MAX_UTF8_BYTES:
            raise ValueError("utf8_byte_limit_exceeded")
        return value

    @field_validator("type")
    @classmethod
    def validate_event_type(cls, value: AgentEventType | str) -> AgentEventType | str:
        text = str(value)
        if _is_wire_blank(text):
            raise ValueError("blank_field")
        if len(text) > EVENT_TYPE_MAX_CHARACTERS:
            raise ValueError("character_limit_exceeded")
        if len(text.encode("utf-8")) > EVENT_TYPE_MAX_UTF8_BYTES:
            raise ValueError("utf8_byte_limit_exceeded")
        return value

    @field_validator("payload")
    @classmethod
    def validate_payload_size(cls, value: dict[str, Any]) -> dict[str, Any]:
        return validate_payload_wire_budget(value)
