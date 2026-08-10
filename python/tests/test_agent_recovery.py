"""Checkpoint resume, retry limits, and idempotency tests."""

from __future__ import annotations

from dataclasses import dataclass, field

from beacon_agent_runtime.capabilities import CapabilityManifest
from beacon_agent_runtime.checkpoints import (
    InMemoryCheckpointStore,
    RuntimeCheckpoint,
    SQLiteCheckpointStore,
)
from beacon_agent_runtime.events import ListEventSink
from beacon_agent_runtime.policy import DefaultPolicyEngine
from beacon_agent_runtime.registry import EffectiveRegistry
from beacon_agent_runtime.runtime import (
    AgentRuntime,
    AgentRuntimeLimits,
    ApprovalInterruptAction,
    FinishAction,
    RecoverableToolError,
    RunContext,
    StaticRegistryProvider,
    ToolObservation,
    ToolRequestAction,
)


def manifest(identifier: str, *, risk: str = "read_only") -> CapabilityManifest:
    return CapabilityManifest(
        schemaVersion=2,
        id=identifier,
        version="1.0.0",
        kind="tool",
        title=identifier,
        description=identifier,
        intentExamples=(identifier,),
        inputSchema={"type": "object"},
        outputSchema={"type": "object"},
        executionLocation="device",
        risk=risk,
        requiredScopes=("training.write" if risk == "consequential_write" else "training.read",),
        confirmation="before_commit" if risk == "consequential_write" else "never",
        idempotency="required" if risk == "consequential_write" else "none",
        dependencies=(),
        tags=("training",),
    )


@dataclass
class QueueModel:
    actions: list[object]

    def next_action(self, context: RunContext) -> object:
        return self.actions.pop(0)


@dataclass
class FlakyDispatcher:
    failures_before_success: int
    calls: int = 0

    def execute(self, action: ToolRequestAction, manifest: CapabilityManifest) -> ToolObservation:
        self.calls += 1
        if self.calls <= self.failures_before_success:
            raise RecoverableToolError("temporary device disconnect")
        return ToolObservation(action.tool_call_id, action.capability_id, {"recordId": "local-1"})


def make_runtime(
    model: QueueModel,
    dispatcher: FlakyDispatcher,
    manifests: tuple[CapabilityManifest, ...],
    checkpoints: InMemoryCheckpointStore,
    sink: ListEventSink,
    limits: AgentRuntimeLimits | None = None,
    interrupt_device_tools: bool = False,
) -> AgentRuntime:
    return AgentRuntime(
        model=model,
        dispatcher=dispatcher,
        checkpoints=checkpoints,
        policy=DefaultPolicyEngine(),
        event_sink=sink,
        registry=StaticRegistryProvider(
            EffectiveRegistry(revision="registry-1", capabilities=manifests)
        ),
        limits=limits or AgentRuntimeLimits(),
        interrupt_device_tools=interrupt_device_tools,
    )


def test_approval_interrupt_resumes_from_checkpoint() -> None:
    commit = manifest("training.plan.commit", risk="consequential_write")
    model = QueueModel(
        [
            ApprovalInterruptAction(
                approval_id="approval-1",
                tool_call_id="tool-commit",
                capability_id=commit.id,
                summary="Commit tomorrow plan",
                requested_scopes=("training.write",),
                idempotency_key="run-1:commit",
            ),
            ToolRequestAction(
                tool_call_id="tool-commit",
                capability_id=commit.id,
                arguments={},
                requested_scopes=("training.write",),
                idempotency_key="run-1:commit",
            ),
            FinishAction("Added to tomorrow"),
        ]
    )
    checkpoints = InMemoryCheckpointStore()
    sink = ListEventSink()
    dispatcher = FlakyDispatcher(0)
    agent = make_runtime(model, dispatcher, (commit,), checkpoints, sink)

    interrupted = agent.start(
        run_id="run-1",
        query="安排明天训练",
        authorized_scopes={"training.write"},
    )
    finished = agent.resume(run_id="run-1", approval_id="approval-1", approved=True)

    assert interrupted.status == "interrupted"
    assert finished.status == "finished"
    assert dispatcher.calls == 1
    assert [event.sequence for event in sink.events] == list(range(len(sink.events)))
    assert str(sink.events[-1].type) == "run.finished"


def test_recoverable_failures_respect_retry_limit() -> None:
    lookup = manifest("training.context.read")
    action = ToolRequestAction("tool-1", lookup.id, {}, ("training.read",), None)
    dispatcher = FlakyDispatcher(3)
    agent = make_runtime(
        QueueModel([action]),
        dispatcher,
        (lookup,),
        InMemoryCheckpointStore(),
        ListEventSink(),
        AgentRuntimeLimits(max_retries=2),
    )

    result = agent.start(run_id="run-retry", query="test", authorized_scopes={"training.read"})

    assert result.error_code == "retry_limit"
    assert dispatcher.calls == 3


def test_completed_idempotency_key_is_replayed_without_second_write() -> None:
    commit = manifest("training.plan.commit", risk="consequential_write")
    first = ToolRequestAction("tool-commit-1", commit.id, {}, ("training.write",), "same-key")
    duplicate = ToolRequestAction("tool-commit-2", commit.id, {}, ("training.write",), "same-key")
    dispatcher = FlakyDispatcher(0)
    checkpoints = InMemoryCheckpointStore()
    sink = ListEventSink()
    agent = make_runtime(
        QueueModel([first, duplicate, FinishAction("done")]),
        dispatcher,
        (commit,),
        checkpoints,
        sink,
    )

    result = agent.start(
        run_id="run-idempotent",
        query="commit",
        authorized_scopes={"training.write"},
        preapproved_tool_calls={"tool-commit-1", "tool-commit-2"},
    )

    assert result.status == "finished"
    assert dispatcher.calls == 1


def test_device_tool_interrupt_resumes_with_schema_valid_local_observation() -> None:
    lookup = manifest("training.context.read")
    action = ToolRequestAction("tool-device", lookup.id, {}, ("training.read",), None)
    checkpoints = InMemoryCheckpointStore()
    sink = ListEventSink()
    dispatcher = FlakyDispatcher(0)
    agent = make_runtime(
        QueueModel([action, FinishAction("已读取本机训练上下文")]),
        dispatcher,
        (lookup,),
        checkpoints,
        sink,
        interrupt_device_tools=True,
    )

    interrupted = agent.start(
        run_id="run-device",
        query="读取我的训练记录",
        authorized_scopes={"training.read"},
    )
    pending = checkpoints.load("run-device")
    finished = agent.resume_device_tool(
        run_id="run-device",
        tool_call_id="tool-device",
        observation={"recordId": "iphone-local-1"},
    )

    assert interrupted.status == "interrupted"
    assert pending is not None
    assert pending.pending_device_tool == action
    assert dispatcher.calls == 0
    assert finished.status == "finished"
    assert [str(event.type) for event in sink.events] == [
        "run.started",
        "step.started",
        "tool.start",
        "step.finished",
        "run.interrupted",
        "tool.result",
        "tool.end",
        "step.started",
        "text.start",
        "text.delta",
        "text.end",
        "step.finished",
        "run.finished",
    ]
    assert sink.events[4].payload | {"deviceToolRequest": None} == {
        "reason": "device_tool_required",
        "toolCallId": "tool-device",
        "capabilityId": lookup.id,
        "arguments": {},
        "deviceToolRequest": None,
    }
    request = sink.events[4].payload["deviceToolRequest"]
    assert request == {
        "toolCallId": "tool-device",
        "capabilityId": lookup.id,
        "schemaVersion": lookup.schema_version,
        "registryRevision": "registry-1",
        "requestedScopes": ["training.read"],
        "arguments": {},
        "idempotencyKey": None,
        "expiresAt": request["expiresAt"],
    }
    assert request["expiresAt"].endswith("Z")
    assert sink.events[2].payload["arguments"] == {}
    assert sink.events[5].payload["result"] == {"recordId": "iphone-local-1"}


def test_cancelled_interrupted_run_cannot_resume_or_write() -> None:
    lookup = manifest("training.context.read")
    action = ToolRequestAction("tool-device", lookup.id, {}, ("training.read",), None)
    checkpoints = InMemoryCheckpointStore()
    sink = ListEventSink()
    agent = make_runtime(
        QueueModel([action, FinishAction("must not run")]),
        FlakyDispatcher(0),
        (lookup,),
        checkpoints,
        sink,
        interrupt_device_tools=True,
    )

    interrupted = agent.start(
        run_id="run-cancelled",
        query="读取本机记录",
        authorized_scopes={"training.read"},
    )
    cancelled = agent.cancel(run_id="run-cancelled")
    resumed = agent.resume_device_tool(
        run_id="run-cancelled",
        tool_call_id="tool-device",
        observation={"recordId": "must-not-be-recorded"},
    )

    assert interrupted.status == "interrupted"
    assert cancelled.status == "cancelled"
    assert resumed.error_code == "run_cancelled"
    checkpoint = checkpoints.load("run-cancelled")
    assert checkpoint is not None and checkpoint.cancelled is True
    assert checkpoint.pending_device_tool is None
    assert sink.events[-1].payload == {"status": "cancelled"}


def test_device_tool_resume_rejects_mismatched_or_invalid_observation_without_advancing() -> None:
    lookup = CapabilityManifest(
        **{
            **manifest("training.context.read").model_dump(by_alias=True),
            "outputSchema": {
                "type": "object",
                "properties": {"recordId": {"type": "string"}},
                "required": ["recordId"],
                "additionalProperties": False,
            },
        }
    )
    action = ToolRequestAction("tool-device", lookup.id, {}, ("training.read",), None)
    checkpoints = InMemoryCheckpointStore()
    sink = ListEventSink()
    agent = make_runtime(
        QueueModel([action, FinishAction("done")]),
        FlakyDispatcher(0),
        (lookup,),
        checkpoints,
        sink,
        interrupt_device_tools=True,
    )
    agent.start(
        run_id="run-invalid-device-result",
        query="read",
        authorized_scopes={"training.read"},
    )
    sequence_before = checkpoints.load("run-invalid-device-result").next_sequence

    mismatch = agent.resume_device_tool(
        run_id="run-invalid-device-result",
        tool_call_id="another-tool",
        observation={"recordId": "local-1"},
    )
    invalid = agent.resume_device_tool(
        run_id="run-invalid-device-result",
        tool_call_id="tool-device",
        observation={"unexpected": True},
    )
    still_pending = checkpoints.load("run-invalid-device-result")

    assert mismatch.error_code == "device_tool_mismatch"
    assert invalid.error_code == "invalid_tool_result"
    assert still_pending is not None
    assert still_pending.pending_device_tool == action
    assert still_pending.next_sequence == sequence_before


def test_sqlite_checkpoint_store_survives_a_new_runtime_instance(tmp_path) -> None:
    path = tmp_path / "agent-checkpoints.sqlite3"
    action = ToolRequestAction(
        "tool-local", "training.context.read", {"dayIdentifier": "2026-08-11"},
        ("training.read",), None,
    )
    checkpoint = RuntimeCheckpoint(
        run_id="durable-run",
        query="安排明天训练",
        authorized_scopes={"training.read"},
        observations=[ToolObservation("edge", "edge.training.summary", {"sessions": 2})],
        steps=2,
        next_sequence=7,
        pending_device_tool=action,
        approved_tool_calls={"approved-1"},
        completed_idempotency={
            "idempotency-1": ToolObservation("tool-1", "training.plan.draft", {"draftID": "d1"})
        },
    )
    SQLiteCheckpointStore(path).save(checkpoint)

    restored = SQLiteCheckpointStore(path).load("durable-run")

    assert restored == checkpoint
