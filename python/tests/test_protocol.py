from beacon_agent_runtime.protocol import AgentEvent, AgentEventType


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
