"""Checkpoint resume, retry limits, and idempotency tests."""

from __future__ import annotations

from dataclasses import dataclass, field

from beacon_agent_runtime.capabilities import CapabilityManifest
from beacon_agent_runtime.checkpoints import InMemoryCheckpointStore
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

