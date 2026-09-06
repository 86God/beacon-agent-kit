"""Reference replay behavior shared with the Swift implementation."""

from __future__ import annotations

import json
from copy import deepcopy
from pathlib import Path

import pytest
from pydantic import ValidationError

from beacon_agent_runtime.negotiation import ProtocolPublicError
from beacon_agent_runtime.protocol import AgentEvent, parse_agent_event
from beacon_agent_runtime.reducer import AgentReplayError, AgentStateReducer, EventCollisionError


ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "conformance" / "fixtures"
CONTRACT_FIXTURES = ROOT / "contracts" / "fixtures"


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


def test_execution_identity_fixture_matches_shared_golden_json() -> None:
    events = [
        AgentEvent.model_validate_json(line)
        for line in (CONTRACT_FIXTURES / "execution-identity-run.jsonl")
        .read_text(encoding="utf-8")
        .splitlines()
        if line.strip()
    ]
    expected = (CONTRACT_FIXTURES / "execution-identity-run.normalized.json").read_text(
        encoding="utf-8"
    ).strip()

    assert replay(events).normalized_json() == expected


@pytest.mark.parametrize(
    "fixture_name",
    ["success-run", "empty-query-run", "text-fallback-run", "permission-denied-run"],
)
def test_public_outcome_fixture_matches_shared_golden_json(fixture_name: str) -> None:
    events = [
        AgentEvent.model_validate_json(line)
        for line in (CONTRACT_FIXTURES / f"{fixture_name}.jsonl")
        .read_text(encoding="utf-8")
        .splitlines()
        if line.strip()
    ]
    expected = (CONTRACT_FIXTURES / f"{fixture_name}.normalized.json").read_text(
        encoding="utf-8"
    ).strip()

    assert replay(events).normalized_json() == expected


def test_waiting_states_are_explicit_and_resume_without_becoming_terminal() -> None:
    reducer = AgentStateReducer()
    reducer.ingest(
        AgentEvent(schemaVersion=2, eventId="waiting-0", runId="run-waiting", sequence=0, type="run.started", payload={})
    )
    reducer.ingest(
        AgentEvent(
            schemaVersion=2,
            eventId="waiting-1",
            runId="run-waiting",
            sequence=1,
            type="device.waiting",
            payload={"code": "device.unavailable", "retryable": True, "diagnosticId": "diag-waiting-1"},
        )
    )
    assert reducer.status == "waiting_device"

    reducer.ingest(
        AgentEvent(schemaVersion=2, eventId="waiting-2", runId="run-waiting", sequence=2, type="run.started", payload={})
    )
    assert reducer.status == "running"
    reducer.ingest(
        AgentEvent(
            schemaVersion=2,
            eventId="waiting-3",
            runId="run-waiting",
            sequence=3,
            type="approval.requested",
            payload={"approvalId": "approval-waiting"},
        )
    )
    assert reducer.status == "waiting_approval"


def test_malformed_diagnostic_group_fails_atomically() -> None:
    reducer = AgentStateReducer()
    before = reducer.normalized_json()

    with pytest.raises(AgentReplayError):
        reducer.ingest(
            AgentEvent(
                schemaVersion=2,
                eventId="diagnostic-invalid",
                runId="run-diagnostic",
                sequence=0,
                type="permission.denied",
                payload={"code": "device.permission_denied", "retryable": False},
            )
        )

    assert reducer.normalized_json() == before


def test_legacy_run_error_with_code_and_summary_remains_compatible() -> None:
    reducer = AgentStateReducer()
    reducer.ingest(
        AgentEvent(
            schemaVersion=2,
            eventId="legacy-error-0",
            runId="run-legacy-error",
            sequence=0,
            type="run.error",
            payload={"code": "provider_error", "summary": "retry later"},
        )
    )

    assert reducer.status == "error"
    assert reducer.next_sequence == 1
    assert "failure" not in reducer.normalized()


@pytest.mark.parametrize("result_kind", [None, 1, True, {}])
def test_wrong_typed_result_kind_fails_atomically(result_kind: object) -> None:
    reducer = AgentStateReducer()
    before = reducer.normalized_json()

    with pytest.raises(AgentReplayError):
        reducer.ingest(
            AgentEvent(
                schemaVersion=2,
                eventId="result-kind-invalid",
                runId="run-result-kind-invalid",
                sequence=0,
                type="run.finished",
                payload={"resultKind": result_kind},
            )
        )

    assert reducer.normalized_json() == before


def test_unknown_critical_event_fails_without_changing_projection() -> None:
    reducer = AgentStateReducer()
    before = reducer.normalized_json()

    with pytest.raises(AgentReplayError):
        reducer.ingest(
            AgentEvent(
                schemaVersion=2,
                eventId="critical-0",
                runId="run-critical",
                sequence=0,
                type="future.command.required",
                payload={"critical": True, "requiredSchemaVersion": 3},
            )
        )

    assert reducer.normalized_json() == before


def test_replay_error_codes_match_public_contract() -> None:
    cases = [
        (
            AgentStateReducer(),
            [
                AgentEvent(schemaVersion=2, eventId="run-a", runId="run-a", sequence=0, type="run.started", payload={}),
                AgentEvent(schemaVersion=2, eventId="run-b", runId="run-b", sequence=1, type="step.started", payload={}),
            ],
            "protocol.mixed_run",
        ),
        (
            AgentStateReducer(),
            [
                AgentEvent(schemaVersion=2, eventId="critical", runId="run-critical-code", sequence=0, type="future.required", payload={"critical": True}),
            ],
            "protocol.unsupported_critical_event",
        ),
        (
            AgentStateReducer(),
            [
                AgentEvent(schemaVersion=2, eventId="bad-patch", runId="run-patch-code", sequence=0, type="state.delta", payload={"patch": [{"op": "move", "path": "/x"}]}),
            ],
            "protocol.unsupported_patch",
        ),
        (
            AgentStateReducer(),
            [
                AgentEvent(schemaVersion=2, eventId="bad-payload", runId="run-invalid-code", sequence=0, type="text.delta", payload={"delta": "private"}),
            ],
            "protocol.invalid_event",
        ),
    ]

    for reducer, events, expected_code in cases:
        with pytest.raises(AgentReplayError) as caught:
            for event in events:
                reducer.ingest(event)
        failure = caught.value.public_failure("diag-shared-error")
        assert failure.code == expected_code
        assert "private" not in failure.model_dump_json()


def test_shared_wire_failures_match_stable_public_failures() -> None:
    cases = json.loads(
        (ROOT / "contracts" / "fixtures" / "public-failure-cases.json").read_text(
            encoding="utf-8"
        )
    )

    for item in cases:
        reducer = AgentStateReducer()
        captured = None
        try:
            for document in item["events"]:
                reducer.ingest(parse_agent_event(document))
        except ProtocolPublicError as error:
            captured = error.public_failure(item["expectedFailure"]["diagnosticId"])

        assert captured is not None, item["name"]
        assert captured.model_dump(by_alias=True) == item["expectedFailure"], item["name"]


def test_mixed_turn_identity_fails_without_changing_projection() -> None:
    reducer = AgentStateReducer()
    reducer.ingest(
        AgentEvent(
            schemaVersion=2,
            eventId="identity-turn-a",
            runId="run-identity",
            turnId="turn-a",
            attemptId="attempt-1",
            segmentId="segment-1",
            sequence=0,
            type="run.started",
            payload={},
        )
    )
    valid_projection = reducer.normalized_json()

    with pytest.raises(AgentReplayError, match="mix turn IDs"):
        reducer.ingest(
            AgentEvent(
                schemaVersion=2,
                eventId="identity-turn-b",
                runId="run-identity",
                turnId="turn-b",
                attemptId="attempt-1",
                segmentId="segment-1",
                sequence=1,
                type="step.started",
                payload={},
            )
        )

    assert reducer.normalized_json() == valid_projection


def test_out_of_order_identity_conflict_fails_without_changing_buffered_projection() -> None:
    reducer = AgentStateReducer()
    reducer.ingest(
        AgentEvent(
            schemaVersion=2,
            eventId="identity-late",
            runId="run-a",
            turnId="turn-a",
            sequence=1,
            type="step.started",
            payload={},
        )
    )
    buffered_projection = reducer.normalized_json()

    with pytest.raises(AgentReplayError):
        reducer.ingest(
            AgentEvent(
                schemaVersion=2,
                eventId="identity-first",
                runId="run-b",
                turnId="turn-b",
                sequence=0,
                type="run.started",
                payload={},
            )
        )

    assert reducer.normalized_json() == buffered_projection


def test_malformed_event_rolls_back_identity_and_duplicate_bookkeeping() -> None:
    reducer = AgentStateReducer()
    reducer.ingest(
        AgentEvent(
            schemaVersion=2,
            eventId="identity-start",
            runId="run-atomic",
            turnId="turn-atomic",
            attemptId="attempt-1",
            segmentId="segment-1",
            sequence=0,
            type="run.started",
            payload={},
        )
    )
    valid_projection = reducer.normalized_json()

    with pytest.raises(AgentReplayError):
        reducer.ingest(
            AgentEvent(
                schemaVersion=2,
                eventId="identity-delta",
                runId="run-atomic",
                turnId="turn-atomic",
                attemptId="attempt-2",
                segmentId="segment-2",
                sequence=1,
                type="text.delta",
                payload={"delta": "hello"},
            )
        )

    assert reducer.normalized_json() == valid_projection
    reducer.ingest(
        AgentEvent(
            schemaVersion=2,
            eventId="identity-delta",
            runId="run-atomic",
            turnId="turn-atomic",
            attemptId="attempt-2",
            segmentId="segment-2",
            sequence=1,
            type="text.delta",
            payload={"messageId": "message-atomic", "delta": "hello"},
        )
    )
    assert reducer.attempt_id == "attempt-2"
    assert reducer.segment_id == "segment-2"
    assert reducer.text["message-atomic"] == "hello"


def test_buffered_malformed_event_is_evicted_when_gap_closes() -> None:
    reducer = AgentStateReducer()
    reducer.ingest(
        AgentEvent(
            schemaVersion=2,
            eventId="buffered-delta",
            runId="run-buffered-invalid",
            turnId="turn-buffered-invalid",
            attemptId="attempt-2",
            segmentId="segment-2",
            sequence=1,
            type="text.delta",
            payload={"delta": "hello"},
        )
    )

    with pytest.raises(AgentReplayError):
        reducer.ingest(
            AgentEvent(
                schemaVersion=2,
                eventId="buffered-start",
                runId="run-buffered-invalid",
                turnId="turn-buffered-invalid",
                attemptId="attempt-1",
                segmentId="segment-1",
                sequence=0,
                type="run.started",
                payload={},
            )
        )

    assert reducer.next_sequence == 1
    assert reducer.attempt_id == "attempt-1"
    assert reducer.segment_id == "segment-1"
    assert reducer.normalized()["bufferedSequences"] == []

    reducer.ingest(
        AgentEvent(
            schemaVersion=2,
            eventId="buffered-delta",
            runId="run-buffered-invalid",
            turnId="turn-buffered-invalid",
            attemptId="attempt-2",
            segmentId="segment-2",
            sequence=1,
            type="text.delta",
            payload={"messageId": "message-buffered-invalid", "delta": "hello"},
        )
    )
    assert reducer.next_sequence == 2
    assert reducer.text["message-buffered-invalid"] == "hello"


def test_mutated_payload_is_revalidated_before_projection() -> None:
    event = AgentEvent(
        schemaVersion=2,
        eventId="event-mutated",
        runId="run-mutated",
        sequence=0,
        type="text.delta",
        payload={"messageId": "message-mutated", "delta": "ok"},
    )
    event.payload["delta"] = "x" * 262_144
    reducer = AgentStateReducer()

    with pytest.raises(ValueError, match="payload_byte_limit_exceeded"):
        reducer.ingest(event)

    assert reducer.normalized()["nextSequence"] == 0
    assert reducer.normalized()["text"] == {}


def test_buffered_event_uses_validated_snapshot_not_mutable_caller_payload() -> None:
    delayed = AgentEvent(
        schemaVersion=2,
        eventId="event-delayed",
        runId="run-buffered-copy",
        sequence=1,
        type="text.delta",
        payload={"messageId": "message-buffered", "delta": "ok"},
    )
    reducer = AgentStateReducer()
    reducer.ingest(delayed)
    delayed.payload["delta"] = "changed-after-buffering"

    reducer.ingest(
        AgentEvent(
            schemaVersion=2,
            eventId="event-start",
            runId="run-buffered-copy",
            sequence=0,
            type="run.started",
            payload={},
        )
    )

    assert reducer.normalized()["nextSequence"] == 2
    assert reducer.normalized()["text"]["message-buffered"] == "ok"


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


def test_terminal_state_rejects_late_events_without_changing_projection() -> None:
    terminal = AgentEvent.model_validate(
        {
            "schemaVersion": 2,
            "eventId": "terminal-0",
            "runId": "run-terminal",
            "sequence": 0,
            "type": "run.error",
            "payload": {"message": "请重试"},
        }
    )
    reducer = AgentStateReducer()
    reducer.ingest(terminal)
    terminal_projection = reducer.normalized_json()

    reducer.ingest(terminal)
    assert reducer.normalized_json() == terminal_projection

    late_text = AgentEvent.model_validate(
        {
            "schemaVersion": 2,
            "eventId": "late-1",
            "runId": "run-terminal",
            "sequence": 1,
            "type": "text.start",
            "payload": {"messageId": "late-message"},
        }
    )
    with pytest.raises(AgentReplayError):
        reducer.ingest(late_text)
    assert reducer.normalized_json() == terminal_projection


def test_unsupported_schema_version_is_rejected_before_replay() -> None:
    with pytest.raises(ValidationError):
        AgentEvent.model_validate(
            {
                "schemaVersion": 3,
                "eventId": "future-0",
                "runId": "run-future",
                "sequence": 0,
                "type": "run.started",
                "payload": {},
            }
        )


def test_python_normalized_json_is_canonical() -> None:
    normalized = replay(load_events("tomorrow-training-run.jsonl")).normalized_json()

    assert normalized == json.dumps(json.loads(normalized), ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def test_legacy_fixture_still_matches_shared_golden_without_null_identity_fields() -> None:
    normalized = replay(load_events("tomorrow-training-run.jsonl")).normalized_json()
    expected = (
        ROOT / "conformance" / "expected" / "tomorrow-training-run.normalized.json"
    ).read_text(encoding="utf-8").strip()

    assert normalized == expected
