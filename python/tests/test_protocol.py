import json
from pathlib import Path

import pytest
from pydantic import ValidationError

from beacon_agent_runtime.protocol import AgentEvent, AgentEventType


ROOT = Path(__file__).resolve().parents[2]


def test_agent_event_round_trips() -> None:
    event = AgentEvent(
        schemaVersion=2,
        eventId="event-1",
        runId="run-1",
        sequence=1,
        type=AgentEventType.RUN_STARTED,
        payload={"threadId": "thread-1"},
    )

    assert AgentEvent.model_validate_json(event.model_dump_json()) == event


def test_legacy_event_serialization_omits_missing_identity_fields() -> None:
    event = AgentEvent(
        schemaVersion=2,
        eventId="event-legacy",
        runId="run-legacy",
        sequence=0,
        type=AgentEventType.RUN_STARTED,
        payload={},
    )

    document = json.loads(event.model_dump_json(by_alias=True))

    assert "turnId" not in document
    assert "attemptId" not in document
    assert "segmentId" not in document


def test_agent_event_rejects_unknown_top_level_envelope_fields() -> None:
    with pytest.raises(ValidationError, match="extra_forbidden"):
        AgentEvent.model_validate(
            {
                "schemaVersion": 2,
                "eventId": "strict-0",
                "runId": "run-strict",
                "sequence": 0,
                "type": "tool.start",
                "toolCallId": "wrong-layer",
                "payload": {"toolCallId": "tool-1"},
            }
        )


def test_agent_event_rejects_blank_identity_fields() -> None:
    try:
        AgentEvent(
            schemaVersion=2,
            eventId=" ",
            runId="run-1",
            sequence=0,
            type=AgentEventType.RUN_STARTED,
            payload={},
        )
    except ValueError:
        return

    raise AssertionError("blank eventId must be rejected")


def test_agent_event_rejects_negative_sequence() -> None:
    try:
        AgentEvent(
            schemaVersion=2,
            eventId="event-1",
            runId="run-1",
            sequence=-1,
            type=AgentEventType.RUN_STARTED,
            payload={},
        )
    except ValueError:
        return

    raise AssertionError("negative sequence must be rejected")


@pytest.mark.parametrize(
    ("field", "value", "error_code"),
    [
        ("eventId", " ", "blank_field"),
        ("eventId", "🧭" * 65, "utf8_byte_limit_exceeded"),
        ("eventId", "x" * 129, "character_limit_exceeded"),
        ("runId", "\n", "blank_field"),
        ("runId", "\u200b", "blank_field"),
        ("runId", "\u001c", "blank_field"),
        ("runId", "🧭" * 65, "utf8_byte_limit_exceeded"),
        ("type", " ", "blank_field"),
        ("type", "x" * 97, "character_limit_exceeded"),
        ("turnId", "\u200b", "blank_field"),
        ("attemptId", "x" * 129, "character_limit_exceeded"),
        ("segmentId", "🧭" * 65, "utf8_byte_limit_exceeded"),
    ],
)
def test_agent_event_rejects_invalid_wire_string_fields(
    field: str,
    value: str,
    error_code: str,
) -> None:
    document = {
        "schemaVersion": 2,
        "eventId": "event-0",
        "runId": "run-0",
        "sequence": 0,
        "type": "run.started",
        "payload": {},
    }
    document[field] = value

    with pytest.raises(ValidationError, match=error_code):
        AgentEvent.model_validate(document)


def test_agent_event_accepts_multibyte_identifier_at_utf8_boundary() -> None:
    boundary_identifier = "🧭" * 64
    event = AgentEvent(
        schemaVersion=2,
        eventId=boundary_identifier,
        runId=boundary_identifier,
        sequence=0,
        type=AgentEventType.RUN_STARTED,
        payload={},
    )

    assert event.event_id == boundary_identifier


def test_agent_event_rejects_oversized_payload() -> None:
    with pytest.raises(ValidationError, match="payload_byte_limit_exceeded"):
        AgentEvent(
            schemaVersion=2,
            eventId="event-large",
            runId="run-large",
            sequence=0,
            type=AgentEventType.TEXT_DELTA,
            payload={"messageId": "message-large", "delta": "x" * 262_144},
        )


def test_agent_event_accepts_payload_at_exact_utf8_boundary() -> None:
    event = AgentEvent(
        schemaVersion=2,
        eventId="event-boundary",
        runId="run-boundary",
        sequence=0,
        type=AgentEventType.RUN_STARTED,
        payload={"delta": "x" * 262_132},
    )

    assert event.payload["delta"] == "x" * 262_132


def test_agent_event_rejects_numeric_heavy_structural_payload() -> None:
    with pytest.raises(ValidationError, match="payload_byte_limit_exceeded"):
        AgentEvent(
            schemaVersion=2,
            eventId="event-numeric-heavy",
            runId="run-numeric-heavy",
            sequence=0,
            type=AgentEventType.RUN_STARTED,
            payload={"values": [1.0] * 70_000},
        )


def test_agent_event_budgets_tuple_as_wire_json_array() -> None:
    event = AgentEvent(
        schemaVersion=2,
        eventId="event-tuple",
        runId="run-tuple",
        sequence=0,
        type=AgentEventType.RUN_STARTED,
        payload={"requestedScopes": ("training.read",)},
    )

    assert event.model_dump(mode="json")["payload"]["requestedScopes"] == ["training.read"]


def test_shared_mobile_contract_publishes_wire_bounds() -> None:
    contract_path = ROOT / "contracts" / "mobile-agent-contract.json"
    assert contract_path.exists(), "shared mobile Agent contract is required"
    contract = json.loads(contract_path.read_text(encoding="utf-8"))

    assert contract["wireLimits"] == {
        "identifierMaxCharacters": 128,
        "identifierMaxUTF8Bytes": 256,
        "eventTypeMaxCharacters": 96,
        "eventTypeMaxUTF8Bytes": 384,
        "payloadMaxBytes": 262_144,
    }
    assert "001C-0020" in contract["characterCounting"]["blankCodePoints"]
    assert "2000-200B" in contract["characterCounting"]["blankCodePoints"]
    assert contract["payloadSizing"]["algorithm"] == "decoded-json-structural-budget-v1"
    assert contract["payloadSizing"]["numberBytes"] == 32
    assert contract["optionalEnvelopeFields"] == ["turnId", "attemptId", "segmentId"]
    assert contract["identifierSemantics"]["toolCallId"].startswith("payload_identifier")
    assert contract["identifierSemantics"]["commandId"].startswith("payload_identifier")
