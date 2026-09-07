"""Protocol-level equivalence checks for the isolated PydanticAI runtime PoC."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

import pytest

pytest.importorskip("pydantic_ai", reason="install the runtime-comparison extra")

from beacon_agent_runtime.capabilities import CapabilityManifest
from beacon_agent_runtime.events import (
    FinishAction,
    ListEventSink,
    RunContext,
    StreamingFinishAction,
    ToolObservation,
    ToolRequestAction,
)
from beacon_agent_runtime.experimental.pydantic_runner import PydanticAgentRuntime
from beacon_agent_runtime.native_langgraph_runtime import NativeLangGraphAgentRuntime
from beacon_agent_runtime.policy import DefaultPolicyEngine
from beacon_agent_runtime.registry import EffectiveRegistry
from beacon_agent_runtime.runtime import (
    AgentRuntimeLimits,
    RuntimeFailure,
    StaticRegistryProvider,
)
from beacon_agent_runtime.runtime_selector import RuntimeMode, select_runtime


def capability(identifier: str, *, execution_location: str = "device") -> CapabilityManifest:
    return CapabilityManifest(
        schemaVersion=2,
        id=identifier,
        version="1.0.0",
        kind="tool",
        title=identifier,
        description=f"Capability {identifier}",
        intentExamples=(identifier,),
        inputSchema={"type": "object", "additionalProperties": False},
        outputSchema={
            "type": "object",
            "additionalProperties": False,
            "required": ["sessions"],
            "properties": {"sessions": {"type": "integer", "minimum": 0}},
        },
        executionLocation=execution_location,
        risk="read_only",
        requiredScopes=("training.read",),
        confirmation="never",
        idempotency="none",
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
        action = self.actions.pop(0)
        if isinstance(action, Exception):
            raise action
        return action


@dataclass
class NoServerDispatch:
    calls: list[str] = field(default_factory=list)

    def execute(
        self,
        action: ToolRequestAction,
        manifest: CapabilityManifest,
    ) -> ToolObservation:
        self.calls.append(action.capability_id)
        raise AssertionError("device tools must not execute in the gateway")


@dataclass
class RecordingDispatcher:
    result: dict[str, object]
    calls: list[str] = field(default_factory=list)

    def execute(
        self,
        action: ToolRequestAction,
        manifest: CapabilityManifest,
    ) -> ToolObservation:
        self.calls.append(action.capability_id)
        return ToolObservation(action.tool_call_id, action.capability_id, self.result)


RuntimeFactory = Callable[[Path, ScriptedModel, ListEventSink], object]


def native_factory(path: Path, model: ScriptedModel, sink: ListEventSink) -> object:
    return NativeLangGraphAgentRuntime.sqlite(
        path=path,
        model=model,
        dispatcher=NoServerDispatch(),
        policy=DefaultPolicyEngine(),
        event_sink=sink,
        registry=StaticRegistryProvider(
            EffectiveRegistry(revision="registry-1", capabilities=(capability("training.context.read"),))
        ),
        limits=AgentRuntimeLimits(),
    )


def pydantic_factory(path: Path, model: ScriptedModel, sink: ListEventSink) -> object:
    del path
    return PydanticAgentRuntime(
        model=model,
        dispatcher=NoServerDispatch(),
        policy=DefaultPolicyEngine(),
        event_sink=sink,
        registry=StaticRegistryProvider(
            EffectiveRegistry(revision="registry-1", capabilities=(capability("training.context.read"),))
        ),
        limits=AgentRuntimeLimits(),
    )


def _tool() -> ToolRequestAction:
    return ToolRequestAction(
        tool_call_id="tool-training-context",
        capability_id="training.context.read",
        arguments={},
        requested_scopes=("training.read",),
        idempotency_key=None,
    )


def _semantic_trace(sink: ListEventSink) -> list[str]:
    return [str(event.type) for event in sink.events]


@pytest.mark.parametrize("factory", [native_factory, pydantic_factory])
def test_device_resume_reaches_the_same_terminal_turn_semantics(
    factory: RuntimeFactory,
    tmp_path: Path,
) -> None:
    model = ScriptedModel(
        [
            _tool(),
            StreamingFinishAction(iter(["建议先做体态评估。\n", "再安排训练。"])),
        ]
    )
    sink = ListEventSink()
    runtime = factory(tmp_path / f"{factory.__name__}.sqlite", model, sink)

    initial = runtime.start(
        run_id=f"run-{factory.__name__}",
        query="合成训练咨询",
        authorized_scopes={"training.read"},
    )
    resumed = runtime.resume_device_tool(
        run_id=f"run-{factory.__name__}",
        tool_call_id="tool-training-context",
        observation={"sessions": 3},
    )

    assert initial.status == "interrupted"
    assert resumed.status == "finished"
    assert resumed.final_text == "建议先做体态评估。\n再安排训练。"
    assert model.observation_counts == [0, 1]
    assert _semantic_trace(sink) == [
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
        "text.delta",
        "text.end",
        "step.finished",
        "run.finished",
    ]


@pytest.mark.parametrize("factory", [native_factory, pydantic_factory])
def test_model_failure_is_explicit_and_terminal(
    factory: RuntimeFactory,
    tmp_path: Path,
) -> None:
    model = ScriptedModel([RuntimeFailure("synthetic_model_failure", "synthetic")])
    sink = ListEventSink()
    runtime = factory(tmp_path / f"{factory.__name__}-failure.sqlite", model, sink)

    result = runtime.start(
        run_id=f"run-{factory.__name__}-failure",
        query="合成故障",
        authorized_scopes={"training.read"},
    )

    assert result.status == "error"
    assert result.error_code == "synthetic_model_failure"
    assert _semantic_trace(sink) == ["run.started", "step.started", "run.error"]
    assert sink.events[-1].payload == {
        "code": "synthetic_model_failure",
        "summary": "synthetic",
    }


def test_pydantic_checkpoint_view_contains_no_query_or_observation_plaintext(
    tmp_path: Path,
) -> None:
    model = ScriptedModel([_tool(), FinishAction("不应在恢复前执行")])
    sink = ListEventSink()
    runtime = pydantic_factory(tmp_path / "unused.sqlite", model, sink)

    runtime.start(
        run_id="run-private-boundary",
        query="PRIVATE_QUERY_SENTINEL",
        authorized_scopes={"training.read"},
    )

    checkpoint = runtime.checkpoint_view("run-private-boundary")
    assert checkpoint is not None
    serialized = repr(checkpoint)
    assert "PRIVATE_QUERY_SENTINEL" not in serialized
    assert "query" not in serialized.lower()
    assert "observations" not in serialized.lower()


@pytest.mark.parametrize("runtime_kind", ["native", "pydantic"])
def test_server_tool_loop_calls_once_and_waits_for_complete_final_output(
    runtime_kind: str,
    tmp_path: Path,
) -> None:
    manifest = capability("training.context.read", execution_location="server")
    dispatcher = RecordingDispatcher({"sessions": 2})
    model = ScriptedModel([_tool(), StreamingFinishAction(iter(["完整", "回答"]))])
    sink = ListEventSink()
    common = dict(
        model=model,
        dispatcher=dispatcher,
        policy=DefaultPolicyEngine(),
        event_sink=sink,
        registry=StaticRegistryProvider(
            EffectiveRegistry(revision="registry-1", capabilities=(manifest,))
        ),
        limits=AgentRuntimeLimits(),
    )
    runtime = (
        NativeLangGraphAgentRuntime.sqlite(path=tmp_path / "server.sqlite", **common)
        if runtime_kind == "native"
        else PydanticAgentRuntime(**common)
    )

    result = runtime.start(
        run_id=f"run-server-{runtime_kind}",
        query="合成服务端读取",
        authorized_scopes={"training.read"},
    )

    assert result.status == "finished"
    assert result.final_text == "完整回答"
    assert dispatcher.calls == ["training.context.read"]
    assert model.observation_counts == [0, 1]
    trace = _semantic_trace(sink)
    assert trace.index("tool.result") < trace.index("text.start")
    assert trace[-1] == "run.finished"
    assert "".join(
        event.payload["delta"] for event in sink.events if str(event.type) == "text.delta"
    ) == "完整回答"


@pytest.mark.parametrize("factory", [native_factory, pydantic_factory])
def test_unknown_capability_keeps_the_same_safe_failure_code(
    factory: RuntimeFactory,
    tmp_path: Path,
) -> None:
    model = ScriptedModel(
        [
            ToolRequestAction(
                tool_call_id="unknown-tool",
                capability_id="unknown.capability",
                arguments={},
                requested_scopes=("training.read",),
                idempotency_key=None,
            )
        ]
    )
    sink = ListEventSink()
    runtime = factory(tmp_path / f"{factory.__name__}-unknown.sqlite", model, sink)

    result = runtime.start(
        run_id=f"run-{factory.__name__}-unknown",
        query="合成未知能力",
        authorized_scopes={"training.read"},
    )

    assert result.status == "error"
    assert result.error_code == "unknown_capability"
    assert _semantic_trace(sink)[-1] == "run.error"


@pytest.mark.parametrize("factory", [native_factory, pydantic_factory])
def test_structured_completion_has_no_fake_text_message(
    factory: RuntimeFactory,
    tmp_path: Path,
) -> None:
    model = ScriptedModel([FinishAction("", output_kind="structured")])
    sink = ListEventSink()
    runtime = factory(tmp_path / f"{factory.__name__}-structured.sqlite", model, sink)

    result = runtime.start(
        run_id=f"run-{factory.__name__}-structured",
        query="合成结构化结果",
        authorized_scopes={"training.read"},
        initial_observations=(
            ToolObservation("initial-card", "training.context.read", {"sessions": 1}),
        ),
    )

    assert result.status == "finished"
    assert result.final_text == ""
    assert _semantic_trace(sink) == [
        "run.started",
        "step.started",
        "step.finished",
        "run.finished",
    ]


@pytest.mark.parametrize("factory", [native_factory, pydantic_factory])
def test_blank_final_output_fails_instead_of_claiming_success(
    factory: RuntimeFactory,
    tmp_path: Path,
) -> None:
    model = ScriptedModel([FinishAction("  \n")])
    sink = ListEventSink()
    runtime = factory(tmp_path / f"{factory.__name__}-blank.sqlite", model, sink)

    result = runtime.start(
        run_id=f"run-{factory.__name__}-blank",
        query="合成空答复",
        authorized_scopes={"training.read"},
    )

    assert result.status == "error"
    assert result.error_code == "empty_final_output"
    assert _semantic_trace(sink)[-1] == "run.error"


def test_experiment_is_not_selectable_as_a_production_runtime() -> None:
    for mode in RuntimeMode:
        selection = select_runtime(mode)
        assert selection.primary is not PydanticAgentRuntime
        assert selection.shadow is not PydanticAgentRuntime
