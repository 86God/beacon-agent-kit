"""Bounded iterative Agent loop behavior."""

from __future__ import annotations

from dataclasses import dataclass, field

from beacon_agent_runtime.capabilities import CapabilityManifest
from beacon_agent_runtime.checkpoints import InMemoryCheckpointStore
from beacon_agent_runtime.events import ListEventSink
from beacon_agent_runtime.policy import DefaultPolicyEngine, PolicyDecision
from beacon_agent_runtime.registry import EffectiveRegistry
from beacon_agent_runtime.runtime import (
    AgentRuntime,
    AgentRuntimeLimits,
    ApprovalInterruptAction,
    FinishAction,
    RunContext,
    StreamingFinishAction,
    StaticRegistryProvider,
    ToolObservation,
    ToolRequestAction,
)


def capability(
    identifier: str,
    *,
    risk: str = "read_only",
    input_schema: dict[str, object] | None = None,
    output_schema: dict[str, object] | None = None,
) -> CapabilityManifest:
    return CapabilityManifest(
        schemaVersion=2,
        id=identifier,
        version="1.0.0",
        kind="tool",
        title=identifier,
        description=f"Capability {identifier}",
        intentExamples=(identifier,),
        inputSchema=input_schema or {"type": "object"},
        outputSchema=output_schema or {"type": "object"},
        executionLocation="device",
        risk=risk,
        requiredScopes=("training.read",),
        confirmation="before_commit" if risk == "consequential_write" else "never",
        idempotency="required" if risk == "consequential_write" else "none",
        dependencies=(),
        tags=("training",),
        fallback="text_summary",
    )


@dataclass
class ScriptedModel:
    actions: list[object]
    observation_counts: list[int] = field(default_factory=list)

    def next_action(self, context: RunContext) -> object:
        self.observation_counts.append(len(context.observations))
        return self.actions.pop(0)


@dataclass
class RecordingDispatcher:
    results: dict[str, dict[str, object]]
    calls: list[str] = field(default_factory=list)

    def execute(
        self,
        action: ToolRequestAction,
        manifest: CapabilityManifest,
    ) -> ToolObservation:
        self.calls.append(action.capability_id)
        return ToolObservation(
            tool_call_id=action.tool_call_id,
            capability_id=action.capability_id,
            data=self.results[action.capability_id],
        )


def tool(index: int, identifier: str) -> ToolRequestAction:
    return ToolRequestAction(
        tool_call_id=f"tool-{index}",
        capability_id=identifier,
        arguments={},
        requested_scopes=("training.read",),
        idempotency_key=None,
    )


def runtime(
    *,
    model: ScriptedModel,
    dispatcher: RecordingDispatcher,
    manifests: tuple[CapabilityManifest, ...],
    sink: ListEventSink | None = None,
    limits: AgentRuntimeLimits | None = None,
    policy: object | None = None,
) -> tuple[AgentRuntime, ListEventSink]:
    event_sink = sink or ListEventSink()
    return (
        AgentRuntime(
            model=model,
            dispatcher=dispatcher,
            checkpoints=InMemoryCheckpointStore(),
            policy=policy or DefaultPolicyEngine(),
            event_sink=event_sink,
            registry=StaticRegistryProvider(
                EffectiveRegistry(revision="registry-1", capabilities=manifests)
            ),
            limits=limits or AgentRuntimeLimits(),
        ),
        event_sink,
    )


def test_agent_alternates_model_and_tools_before_approval_interrupt() -> None:
    identifiers = (
        "training.context.read",
        "exercise.candidates.search",
        "training.plan.draft",
        "training.plan.commit",
    )
    manifests = tuple(
        capability(identifier, risk="consequential_write" if identifier.endswith("commit") else "read_only")
        for identifier in identifiers
    )
    model = ScriptedModel(
        [
            tool(1, identifiers[0]),
            tool(2, identifiers[1]),
            tool(3, identifiers[2]),
            ApprovalInterruptAction(
                approval_id="approval-1",
                tool_call_id="tool-commit",
                capability_id=identifiers[3],
                summary="Add draft to tomorrow",
                requested_scopes=("training.read",),
                idempotency_key="run-1:commit",
            ),
        ]
    )
    dispatcher = RecordingDispatcher(
        {
            identifiers[0]: {"targetDate": "2026-08-09"},
            identifiers[1]: {"exerciseIds": ["press", "raise"]},
            identifiers[2]: {"draftId": "draft-1", "targetDate": "2026-08-09"},
        }
    )
    agent, sink = runtime(model=model, dispatcher=dispatcher, manifests=manifests)

    result = agent.start(
        run_id="run-1",
        query="安排一下明天练肩",
        authorized_scopes={"training.read"},
    )

    assert result.status == "interrupted"
    assert model.observation_counts == [0, 1, 2, 3]
    assert dispatcher.calls == list(identifiers[:3])
    event_types = [str(event.type) for event in sink.events]
    assert event_types.index("tool.result") < event_types.index("approval.requested")
    assert event_types[-1] == "run.interrupted"
    assert "run.finished" not in event_types


def test_invalid_input_unknown_tool_policy_denial_and_large_observation_fail_closed() -> None:
    strict = capability(
        "training.context.read",
        input_schema={
            "type": "object",
            "additionalProperties": False,
            "required": ["date"],
            "properties": {"date": {"type": "string"}},
        },
    )

    cases = [
        (
            ScriptedModel([tool(1, strict.id)]),
            RecordingDispatcher({strict.id: {}}),
            DefaultPolicyEngine(),
            "invalid_tool_arguments",
        ),
        (
            ScriptedModel([tool(1, "unknown.tool")]),
            RecordingDispatcher({}),
            DefaultPolicyEngine(),
            "unknown_capability",
        ),
        (
            ScriptedModel([
                ToolRequestAction(
                    tool_call_id="tool-1",
                    capability_id=strict.id,
                    arguments={"date": "2026-08-09"},
                    requested_scopes=("training.read",),
                    idempotency_key=None,
                )
            ]),
            RecordingDispatcher({strict.id: {}}),
            DenyAllPolicy(),
            "policy_denied",
        ),
        (
            ScriptedModel([
                ToolRequestAction(
                    tool_call_id="tool-1",
                    capability_id=strict.id,
                    arguments={"date": "2026-08-09"},
                    requested_scopes=("training.read",),
                    idempotency_key=None,
                )
            ]),
            RecordingDispatcher({strict.id: {"text": "x" * 256}}),
            DefaultPolicyEngine(),
            "observation_too_large",
        ),
    ]

    for model, dispatcher, policy, expected in cases:
        agent, _ = runtime(
            model=model,
            dispatcher=dispatcher,
            manifests=(strict,),
            limits=AgentRuntimeLimits(max_observation_bytes=64),
            policy=policy,
        )
        result = agent.start(run_id=f"run-{expected}", query="test", authorized_scopes={"training.read"})
        assert result.error_code == expected


def test_step_and_tool_limits_are_enforced() -> None:
    lookup = capability("training.context.read")
    for limits, actions, expected in [
        (AgentRuntimeLimits(max_steps=1), [tool(1, lookup.id), FinishAction("done")], "step_limit"),
        (AgentRuntimeLimits(max_tools=0), [tool(1, lookup.id)], "tool_limit"),
    ]:
        agent, _ = runtime(
            model=ScriptedModel(actions),
            dispatcher=RecordingDispatcher({lookup.id: {}}),
            manifests=(lookup,),
            limits=limits,
        )
        result = agent.start(run_id=f"run-{expected}", query="test", authorized_scopes={"training.read"})
        assert result.error_code == expected


def test_agent_emits_streamed_markdown_deltas_without_collapsing_whitespace() -> None:
    streamed = iter(["## 明天肩部训练\n\n", "- 杠铃推举\n", "- 侧平举\n"])
    agent, sink = runtime(
        model=ScriptedModel([StreamingFinishAction(streamed)]),
        dispatcher=RecordingDispatcher({}),
        manifests=(),
    )

    result = agent.start(
        run_id="run-streamed-markdown",
        query="安排明天练肩",
        authorized_scopes=set(),
    )

    deltas = [
        event.payload["delta"]
        for event in sink.events
        if str(event.type) == "text.delta"
    ]
    assert deltas == ["## 明天肩部训练\n\n", "- 杠铃推举\n", "- 侧平举\n"]
    assert result.final_text == "".join(deltas)
    assert next(
        event.payload["finalText"]
        for event in sink.events
        if str(event.type) == "text.end"
    ) == result.final_text


def test_invalid_output_schema_fails_closed() -> None:
    lookup = capability(
        "training.context.read",
        output_schema={
            "type": "object",
            "additionalProperties": False,
            "required": ["targetDate"],
            "properties": {"targetDate": {"type": "string"}},
        },
    )
    agent, _ = runtime(
        model=ScriptedModel([tool(1, lookup.id)]),
        dispatcher=RecordingDispatcher({lookup.id: {"unexpected": True}}),
        manifests=(lookup,),
    )

    result = agent.start(run_id="run-invalid-result", query="test", authorized_scopes={"training.read"})

    assert result.error_code == "invalid_tool_result"


class DenyAllPolicy:
    def authorize(self, *args: object, **kwargs: object) -> PolicyDecision:
        return PolicyDecision(False, "Denied by test policy")
