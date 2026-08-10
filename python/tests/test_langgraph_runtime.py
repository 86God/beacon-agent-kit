"""LangGraph-backed execution must preserve the Beacon wire protocol."""

from __future__ import annotations

from dataclasses import dataclass

from beacon_agent_runtime.capabilities import CapabilityManifest
from beacon_agent_runtime.checkpoints import InMemoryCheckpointStore
from beacon_agent_runtime.events import (
    FinishAction,
    ListEventSink,
    RunContext,
    StreamingFinishAction,
    ToolObservation,
    ToolRequestAction,
)
from beacon_agent_runtime.langgraph_runtime import LangGraphAgentRuntime
from beacon_agent_runtime.policy import DefaultPolicyEngine
from beacon_agent_runtime.registry import EffectiveRegistry
from beacon_agent_runtime.runtime import AgentRuntime, AgentRuntimeLimits, StaticRegistryProvider


@dataclass
class _FinishModel:
    text: str

    def next_action(self, _context: RunContext) -> FinishAction:
        return FinishAction(self.text)


class _NoopDispatcher:
    def execute(self, *_arguments) -> ToolObservation:
        raise AssertionError("finish-only graph must not dispatch a tool")


@dataclass
class _RecordingDispatcher:
    def execute(self, action: ToolRequestAction, _manifest: CapabilityManifest) -> ToolObservation:
        return ToolObservation(action.tool_call_id, action.capability_id, {"sessions": 3})


@dataclass
class _ScriptedModel:
    actions: list[object]

    def next_action(self, _context: RunContext) -> object:
        return self.actions.pop(0)


def _device_manifest() -> CapabilityManifest:
    return CapabilityManifest(
        schemaVersion=2,
        id="training.context.read",
        version="1.0.0",
        kind="tool",
        title="Training context",
        description="Read a minimal local training summary.",
        intentExamples=("总结本周训练",),
        inputSchema={"type": "object", "additionalProperties": False},
        outputSchema={
            "type": "object",
            "additionalProperties": False,
            "required": ["sessions"],
            "properties": {"sessions": {"type": "integer"}},
        },
        executionLocation="device",
        risk="read_only",
        requiredScopes=("training.read",),
        confirmation="never",
        idempotency="none",
        tags=("training",),
        offlineSafe=True,
    )


def _server_manifest() -> CapabilityManifest:
    return _device_manifest().model_copy(update={"execution_location": "server"})


def _event_transcript(sink: ListEventSink) -> list[tuple[str, dict[object, object]]]:
    return [(str(event.type), event.payload) for event in sink.events]


def test_langgraph_runtime_emits_the_existing_finish_event_sequence() -> None:
    sink = ListEventSink()
    runtime = LangGraphAgentRuntime(
        model=_FinishModel("已完成本机安全汇总。"),
        dispatcher=_NoopDispatcher(),
        checkpoints=InMemoryCheckpointStore(),
        policy=DefaultPolicyEngine(),
        event_sink=sink,
        registry=StaticRegistryProvider(EffectiveRegistry("registry-v1", ())),
        limits=AgentRuntimeLimits(),
    )

    result = runtime.start(
        run_id="langgraph-finish",
        query="总结本周训练",
        authorized_scopes=set(),
    )

    assert result.status == "finished"
    assert result.final_text == "已完成本机安全汇总。"
    assert [str(event.type) for event in sink.events] == [
        "run.started",
        "step.started",
        "text.start",
        "text.delta",
        "text.end",
        "step.finished",
        "run.finished",
    ]


def test_langgraph_runtime_interrupts_for_a_device_tool_then_resumes() -> None:
    sink = ListEventSink()
    checkpoints = InMemoryCheckpointStore()
    runtime = LangGraphAgentRuntime(
        model=_ScriptedModel(
            [
                ToolRequestAction(
                    tool_call_id="local-summary-1",
                    capability_id="training.context.read",
                    arguments={},
                    requested_scopes=("training.read",),
                    idempotency_key=None,
                ),
                FinishAction("已汇总近 7 天训练。"),
            ]
        ),
        dispatcher=_NoopDispatcher(),
        checkpoints=checkpoints,
        policy=DefaultPolicyEngine(),
        event_sink=sink,
        registry=StaticRegistryProvider(EffectiveRegistry("registry-v1", (_device_manifest(),))),
        limits=AgentRuntimeLimits(),
        interrupt_device_tools=True,
    )

    interrupted = runtime.start(
        run_id="langgraph-device",
        query="总结本周训练",
        authorized_scopes={"training.read"},
    )
    assert interrupted.status == "interrupted"
    assert [str(event.type) for event in sink.events] == [
        "run.started",
        "step.started",
        "tool.start",
        "step.finished",
        "run.interrupted",
    ]

    completed = runtime.resume_device_tool(
        run_id="langgraph-device",
        tool_call_id="local-summary-1",
        observation={"sessions": 3},
    )
    assert completed.status == "finished"
    assert completed.final_text == "已汇总近 7 天训练。"
    assert [str(event.type) for event in sink.events][-6:] == [
        "step.started",
        "text.start",
        "text.delta",
        "text.end",
        "step.finished",
        "run.finished",
    ]


def test_langgraph_runtime_matches_legacy_golden_transcript_for_server_tool() -> None:
    def make_actions() -> list[object]:
        return [
            ToolRequestAction(
                tool_call_id="server-summary-1",
                capability_id="training.context.read",
                arguments={},
                requested_scopes=("training.read",),
                idempotency_key=None,
            ),
            StreamingFinishAction(("## 本周训练\\n\\n", "已完成 3 次。")),
        ]

    def make_runtime(runtime_type: type[AgentRuntime]) -> tuple[AgentRuntime, ListEventSink]:
        sink = ListEventSink()
        return (
            runtime_type(
                model=_ScriptedModel(make_actions()),
                dispatcher=_RecordingDispatcher(),
                checkpoints=InMemoryCheckpointStore(),
                policy=DefaultPolicyEngine(),
                event_sink=sink,
                registry=StaticRegistryProvider(
                    EffectiveRegistry("registry-v1", (_server_manifest(),))
                ),
                limits=AgentRuntimeLimits(),
                interrupt_device_tools=True,
            ),
            sink,
        )

    legacy, legacy_sink = make_runtime(AgentRuntime)
    graph, graph_sink = make_runtime(LangGraphAgentRuntime)
    legacy_result = legacy.start(
        run_id="golden-run", query="总结本周训练", authorized_scopes={"training.read"}
    )
    graph_result = graph.start(
        run_id="golden-run", query="总结本周训练", authorized_scopes={"training.read"}
    )

    assert graph_result == legacy_result
    assert _event_transcript(graph_sink) == _event_transcript(legacy_sink)


def test_langgraph_runtime_replays_an_idempotent_device_observation_then_continues() -> None:
    sink = ListEventSink()
    runtime = LangGraphAgentRuntime(
        model=_ScriptedModel(
            [
                ToolRequestAction(
                    tool_call_id="local-summary-1",
                    capability_id="training.context.read",
                    arguments={},
                    requested_scopes=("training.read",),
                    idempotency_key="same-summary",
                ),
                ToolRequestAction(
                    tool_call_id="local-summary-replay",
                    capability_id="training.context.read",
                    arguments={},
                    requested_scopes=("training.read",),
                    idempotency_key="same-summary",
                ),
                FinishAction("已使用同一份本机摘要。"),
            ]
        ),
        dispatcher=_NoopDispatcher(),
        checkpoints=InMemoryCheckpointStore(),
        policy=DefaultPolicyEngine(),
        event_sink=sink,
        registry=StaticRegistryProvider(EffectiveRegistry("registry-v1", (_device_manifest(),))),
        limits=AgentRuntimeLimits(),
        interrupt_device_tools=True,
    )

    assert runtime.start(
        run_id="langgraph-replay",
        query="总结本周训练",
        authorized_scopes={"training.read"},
    ).status == "interrupted"

    completed = runtime.resume_device_tool(
        run_id="langgraph-replay",
        tool_call_id="local-summary-1",
        observation={"sessions": 3},
    )

    assert completed.status == "finished"
    replay = next(
        event for event in sink.events
        if str(event.type) == "tool.result" and event.payload["toolCallId"] == "local-summary-replay"
    )
    assert replay.payload["idempotentReplay"] is True
