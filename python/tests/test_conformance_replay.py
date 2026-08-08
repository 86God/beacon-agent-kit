"""Reference replay behavior shared with the Swift implementation."""

from __future__ import annotations

import json
from copy import deepcopy
from pathlib import Path

import pytest

from beacon_agent_runtime.protocol import AgentEvent
from beacon_agent_runtime.reducer import AgentStateReducer, EventCollisionError


ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "conformance" / "fixtures"


def load_events(name: str) -> list[AgentEvent]:
    return [
        AgentEvent.model_validate_json(line)
        for line in (FIXTURES / name).read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]


def replay(events: list[AgentEvent]) -> AgentStateReducer:
    reducer = AgentStateReducer()
    for event in events:
        reducer.ingest(event)
    return reducer


@pytest.mark.parametrize(
    "fixture_name",
    [
        "tomorrow-training-run.jsonl",
        "tool-interrupt-resume.jsonl",
        "surface-stream.jsonl",
    ],
)
def test_fixture_reaches_finished_terminal_state(fixture_name: str) -> None:
    reducer = replay(load_events(fixture_name))

    assert reducer.normalized()["status"] == "finished"
    assert reducer.normalized()["bufferedSequences"] == []


def test_tomorrow_training_fixture_projects_structured_state() -> None:
    state = replay(load_events("tomorrow-training-run.jsonl")).normalized()

    assert state["runId"] == "run-tomorrow"
    assert state["nextSequence"] == 14
    assert state["activities"]["activity-context"]["status"] == "completed"
    assert state["tools"]["tool-context"]["result"]["targetDate"] == "2026-08-09"
    assert state["surfaces"]["surface-plan"]["document"]["title"] == "Tomorrow shoulder training"
    assert state["surfaces"]["surface-plan"]["document"]["exercises"][0]["sets"] == 4
    assert state["approvals"]["approval-1"]["decision"] == "approved"
    assert state["receipts"][0]["targetDate"] == "2026-08-09"
    assert state["customEvents"][0]["type"] == "beacon.audit.note"


def test_sequence_gaps_buffer_and_drain_to_same_terminal_json() -> None:
    events = load_events("tomorrow-training-run.jsonl")
    ordered = replay(events).normalized_json()
    reordered = [events[0], events[2], events[4], events[1], events[3], *events[5:]]

    assert replay(reordered).normalized_json() == ordered


def test_identical_duplicate_is_idempotent() -> None:
    events = load_events("surface-stream.jsonl")
    reducer = replay([events[0], events[1], events[1], *events[2:]])

    assert reducer.normalized()["nextSequence"] == len(events)


def test_duplicate_event_id_with_different_payload_fails_closed() -> None:
    event = load_events("surface-stream.jsonl")[0]
    collision_document = deepcopy(event.model_dump(by_alias=True, mode="json"))
    collision_document["payload"] = {"unexpected": True}
    collision = AgentEvent.model_validate(collision_document)
    reducer = AgentStateReducer()
    reducer.ingest(event)

    with pytest.raises(EventCollisionError):
        reducer.ingest(collision)


def test_python_normalized_json_is_canonical() -> None:
    normalized = replay(load_events("tomorrow-training-run.jsonl")).normalized_json()

    assert normalized == json.dumps(json.loads(normalized), ensure_ascii=False, separators=(",", ":"), sort_keys=True)

