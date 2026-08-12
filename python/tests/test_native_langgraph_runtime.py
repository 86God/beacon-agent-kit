"""Native LangGraph HITL must keep device observations out of checkpoints."""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

import pytest
from beacon_agent_runtime.capabilities import CapabilityManifest
from beacon_agent_runtime.events import (
    ApprovalInterruptAction,
    FinishAction,
    ListEventSink,
    RunContext,
    ToolRequestAction,
)
import beacon_agent_runtime.native_langgraph_runtime as native_runtime_module
from beacon_agent_runtime.native_langgraph_runtime import NativeLangGraphAgentRuntime
from beacon_agent_runtime.policy import DefaultPolicyEngine
from beacon_agent_runtime.registry import EffectiveRegistry
from beacon_agent_runtime.runtime import AgentRuntimeLimits, StaticRegistryProvider


@dataclass
class _ScriptedModel:
    actions: list[object]

    def next_action(self, _context: RunContext) -> object:
        return self.actions.pop(0)


class _NoopDispatcher:
    def execute(self, *_arguments: object) -> object:
        raise AssertionError("native device tools must interrupt instead of using the dispatcher")


def _device_manifest() -> CapabilityManifest:
    return CapabilityManifest(
        schemaVersion=2,
        id="training.context.read",
        version="1.0.0",
        kind="tool",
        title="Training context",
        description="Read a local training summary.",
        intentExamples=("总结本周训练",),
        inputSchema={
            "type": "object",
            "additionalProperties": False,
            "properties": {"dayIdentifier": {"type": "string"}},
        },
        outputSchema={
            "type": "object",
            "additionalProperties": False,
            "required": ["displayName", "weightKg", "meal"],
            "properties": {
                "displayName": {"type": "string"},
                "weightKg": {"type": "number"},
                "meal": {"type": "string"},
            },
        },
        executionLocation="device",
        risk="read_only",
        requiredScopes=("training.read",),
        confirmation="never",
        idempotency="none",
        tags=("training",),
        offlineSafe=True,
    )


def _database_text(path: Path) -> str:
    with sqlite3.connect(path) as connection:
        return "\n".join(
            str(value)
            for table in connection.execute(
                "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
            )
            for row in connection.execute(f"SELECT * FROM {table[0]}")
            for value in row
        )


def test_native_langgraph_device_interrupt_resumes_without_persisting_private_observation(
    tmp_path: Path,
) -> None:
    database = tmp_path / "native-runtime.sqlite3"
    sink = ListEventSink()
    runtime = NativeLangGraphAgentRuntime.sqlite(
        path=database,
        model=_ScriptedModel(
            [
                ToolRequestAction(
                    tool_call_id="local-context-1",
                    capability_id="training.context.read",
                    arguments={"dayIdentifier": "2026-08-12"},
                    requested_scopes=("training.read",),
                    idempotency_key=None,
                ),
                FinishAction("已生成明日训练草稿。"),
            ]
        ),
        dispatcher=_NoopDispatcher(),
        policy=DefaultPolicyEngine(),
        event_sink=sink,
        registry=StaticRegistryProvider(EffectiveRegistry("registry-v1", (_device_manifest(),))),
        limits=AgentRuntimeLimits(),
    )

    interrupted = runtime.start(
        run_id="native-private-run",
        query="我叫Alice，体重68kg，晚餐吃了牛肉粥。图片在 /private/photo.jpg。请安排明天练肩。",
        authorized_scopes={"training.read"},
    )

    assert interrupted.status == "interrupted"
    assert sink.events[-1].payload["deviceToolRequest"]["arguments"] == {
        "dayIdentifier": "2026-08-12"
    }
    expiry = sink.events[-1].payload["deviceToolRequest"]["expiresAt"]
    assert datetime.fromisoformat(expiry.replace("Z", "+00:00")).tzinfo is not None
    assert "Alice" not in _database_text(database)
    assert "牛肉粥" not in _database_text(database)
    assert "/private/photo.jpg" not in _database_text(database)

    completed = runtime.resume_device_tool(
        run_id="native-private-run",
        tool_call_id="local-context-1",
        observation={"displayName": "Alice", "weightKg": 68, "meal": "牛肉粥"},
    )

    assert completed.status == "finished"
    text_events = [event for event in sink.events if str(event.type).startswith("text.")]
    assert text_events[0].payload == {"messageId": "native-private-run:final"}
    assert text_events[-1].payload == {
        "messageId": "native-private-run:final",
        "finalText": "已生成明日训练草稿。",
    }
    assert next(
        event.payload["result"]
        for event in sink.events
        if str(event.type) == "tool.result"
    ) == {"displayName": "Alice", "weightKg": 68, "meal": "牛肉粥"}
    persisted = _database_text(database)
    assert "Alice" not in persisted
    assert "weightKg" not in persisted
    assert "牛肉粥" not in persisted
    assert "/private/photo.jpg" not in persisted


def test_native_rehydrate_rejects_replayed_arguments_that_do_not_match_checkpoint(
    tmp_path: Path,
) -> None:
    database = tmp_path / "argument-binding.sqlite3"
    runtime = NativeLangGraphAgentRuntime.sqlite(
        path=database,
        model=_ScriptedModel(
            [
                ToolRequestAction(
                    tool_call_id="bound-action",
                    capability_id="training.context.read",
                    arguments={"dayIdentifier": "2026-08-12"},
                    requested_scopes=("training.read",),
                    idempotency_key=None,
                )
            ]
        ),
        dispatcher=_NoopDispatcher(),
        policy=DefaultPolicyEngine(),
        event_sink=ListEventSink(),
        registry=StaticRegistryProvider(EffectiveRegistry("registry-v1", (_device_manifest(),))),
        limits=AgentRuntimeLimits(),
    )
    assert runtime.start(
        run_id="argument-binding",
        query="安排明天练肩",
        authorized_scopes={"training.read"},
    ).status == "interrupted"

    try:
        runtime.rehydrate_device_context(
            run_id="argument-binding",
            query="安排明天练肩",
            pending_action=ToolRequestAction(
                tool_call_id="bound-action",
                capability_id="training.context.read",
                arguments={"dayIdentifier": "2099-01-01"},
                requested_scopes=("training.read",),
                idempotency_key=None,
            ),
        )
    except Exception as error:
        assert getattr(error, "code", None) == "device_tool_mismatch"
    else:
        raise AssertionError("mismatched replay arguments must be rejected")


def test_native_langgraph_counts_device_tools_before_issuing_a_second_interrupt(
    tmp_path: Path,
) -> None:
    runtime = NativeLangGraphAgentRuntime.sqlite(
        path=tmp_path / "tool-limit.sqlite3",
        model=_ScriptedModel(
            [
                ToolRequestAction(
                    tool_call_id="first-read",
                    capability_id="training.context.read",
                    arguments={},
                    requested_scopes=("training.read",),
                    idempotency_key=None,
                ),
                ToolRequestAction(
                    tool_call_id="second-read",
                    capability_id="training.context.read",
                    arguments={},
                    requested_scopes=("training.read",),
                    idempotency_key=None,
                ),
            ]
        ),
        dispatcher=_NoopDispatcher(),
        policy=DefaultPolicyEngine(),
        event_sink=ListEventSink(),
        registry=StaticRegistryProvider(EffectiveRegistry("registry-v1", (_device_manifest(),))),
        limits=AgentRuntimeLimits(max_tools=1),
    )

    assert runtime.start(
        run_id="native-tool-limit",
        query="总结训练",
        authorized_scopes={"training.read"},
    ).status == "interrupted"

    result = runtime.resume_device_tool(
        run_id="native-tool-limit",
        tool_call_id="first-read",
        observation={"displayName": "A", "weightKg": 68, "meal": "粥"},
    )

    assert result.status == "error"
    assert result.error_code == "tool_limit"


def test_native_langgraph_preserves_a_safe_provider_failure_code(
    tmp_path: Path,
) -> None:
    class _KnownFailureModel:
        def next_action(self, _context: RunContext) -> object:
            from beacon_agent_runtime.runtime import RuntimeFailure

            raise RuntimeFailure(
                "model_selected_unavailable_capability",
                "Model selected an unavailable capability",
            )

    runtime = NativeLangGraphAgentRuntime.sqlite(
        path=tmp_path / "safe-provider-failure.sqlite3",
        model=_KnownFailureModel(),
        dispatcher=_NoopDispatcher(),
        policy=DefaultPolicyEngine(),
        event_sink=ListEventSink(),
        registry=StaticRegistryProvider(EffectiveRegistry("registry-v1", (_device_manifest(),))),
        limits=AgentRuntimeLimits(),
    )

    result = runtime.start(
        run_id="safe-provider-failure",
        query="安排明天训练",
        authorized_scopes={"training.read"},
    )

    assert result.status == "error"
    assert result.error_code == "model_selected_unavailable_capability"


def test_native_langgraph_preserves_a_safe_server_tool_failure_code(
    tmp_path: Path,
) -> None:
    from beacon_agent_runtime.runtime import RuntimeFailure

    class _FailingServerDispatcher:
        def execute(self, *_arguments: object) -> object:
            raise RuntimeFailure("vision_analysis_failed", "Image analysis is unavailable")

    server_manifest = _device_manifest().model_copy(update={"execution_location": "server"})
    runtime = NativeLangGraphAgentRuntime.sqlite(
        path=tmp_path / "safe-server-tool-failure.sqlite3",
        model=_ScriptedModel(
            [
                ToolRequestAction(
                    tool_call_id="vision-1",
                    capability_id="training.context.read",
                    arguments={},
                    requested_scopes=("training.read",),
                    idempotency_key=None,
                )
            ]
        ),
        dispatcher=_FailingServerDispatcher(),
        policy=DefaultPolicyEngine(),
        event_sink=ListEventSink(),
        registry=StaticRegistryProvider(EffectiveRegistry("registry-v1", (server_manifest,))),
        limits=AgentRuntimeLimits(),
    )

    result = runtime.start(
        run_id="safe-server-tool-failure",
        query="识别这张图片",
        authorized_scopes={"training.read"},
    )

    assert result.status == "error"
    assert result.error_code == "vision_analysis_failed"


def test_native_langgraph_requires_and_accepts_device_context_replay_after_restart(
    tmp_path: Path,
) -> None:
    database = tmp_path / "restart.sqlite3"
    action = ToolRequestAction(
        tool_call_id="restart-read",
        capability_id="training.context.read",
        arguments={"dayIdentifier": "2026-08-12"},
        requested_scopes=("training.read",),
        idempotency_key=None,
    )
    first = NativeLangGraphAgentRuntime.sqlite(
        path=database,
        model=_ScriptedModel([action]),
        dispatcher=_NoopDispatcher(),
        policy=DefaultPolicyEngine(),
        event_sink=ListEventSink(),
        registry=StaticRegistryProvider(EffectiveRegistry("registry-v1", (_device_manifest(),))),
        limits=AgentRuntimeLimits(),
    )
    assert first.start(
        run_id="native-restart",
        query="Alice 想安排明天训练。",
        authorized_scopes={"training.read"},
    ).status == "interrupted"
    first.close()

    restarted = NativeLangGraphAgentRuntime.sqlite(
        path=database,
        model=_ScriptedModel([FinishAction("已恢复并生成草稿。")]),
        dispatcher=_NoopDispatcher(),
        policy=DefaultPolicyEngine(),
        event_sink=ListEventSink(),
        registry=StaticRegistryProvider(EffectiveRegistry("registry-v1", (_device_manifest(),))),
        limits=AgentRuntimeLimits(),
    )

    assert restarted.resume_device_tool(
        run_id="native-restart",
        tool_call_id="restart-read",
        observation={"displayName": "Alice", "weightKg": 68, "meal": "粥"},
    ).error_code == "private_context_replay_required"

    restarted.rehydrate_device_context(
        run_id="native-restart",
        query="Alice 想安排明天训练。",
        pending_action=action,
    )
    completed = restarted.resume_device_tool(
        run_id="native-restart",
        tool_call_id="restart-read",
        observation={"displayName": "Alice", "weightKg": 68, "meal": "粥"},
    )

    assert completed.status == "finished"
    assert "Alice" not in _database_text(database)


def test_native_langgraph_rejects_duplicate_device_resume_after_the_same_interrupt(
    tmp_path: Path,
) -> None:
    runtime = NativeLangGraphAgentRuntime.sqlite(
        path=tmp_path / "duplicate-device-resume.sqlite3",
        model=_ScriptedModel(
            [
                ToolRequestAction(
                    tool_call_id="one-read",
                    capability_id="training.context.read",
                    arguments={},
                    requested_scopes=("training.read",),
                    idempotency_key=None,
                ),
                FinishAction("已完成。"),
            ]
        ),
        dispatcher=_NoopDispatcher(),
        policy=DefaultPolicyEngine(),
        event_sink=ListEventSink(),
        registry=StaticRegistryProvider(EffectiveRegistry("registry-v1", (_device_manifest(),))),
        limits=AgentRuntimeLimits(),
    )
    assert runtime.start(
        run_id="duplicate-device-resume", query="查询训练", authorized_scopes={"training.read"}
    ).status == "interrupted"

    first = runtime.resume_device_tool(
        run_id="duplicate-device-resume",
        tool_call_id="one-read",
        observation={"displayName": "A", "weightKg": 66, "meal": "粥"},
    )
    second = runtime.resume_device_tool(
        run_id="duplicate-device-resume",
        tool_call_id="one-read",
        observation={"displayName": "A", "weightKg": 66, "meal": "粥"},
    )

    assert first.status == "finished"
    assert second.error_code == "device_tool_not_pending"


def test_native_langgraph_resumes_approval_once_with_command_resume(tmp_path: Path) -> None:
    approval = ApprovalInterruptAction(
        approval_id="approval-1",
        tool_call_id="commit-1",
        capability_id="training.context.read",
        summary="确认继续",
        requested_scopes=("training.read",),
        idempotency_key="commit-1",
    )
    runtime = NativeLangGraphAgentRuntime.sqlite(
        path=tmp_path / "approval-resume.sqlite3",
        model=_ScriptedModel([approval, FinishAction("确认后完成。")]),
        dispatcher=_NoopDispatcher(),
        policy=DefaultPolicyEngine(),
        event_sink=ListEventSink(),
        registry=StaticRegistryProvider(EffectiveRegistry("registry-v1", (_device_manifest(),))),
        limits=AgentRuntimeLimits(),
    )
    assert runtime.start(
        run_id="approval-resume", query="确认操作", authorized_scopes={"training.read"}
    ).status == "interrupted"

    first = runtime.resume(run_id="approval-resume", approval_id="approval-1", approved=True)
    second = runtime.resume(run_id="approval-resume", approval_id="approval-1", approved=True)

    assert first.status == "finished"
    assert second.error_code == "approval_not_pending"


def test_native_langgraph_postgres_factory_uses_official_saver_and_closes_context(
    monkeypatch,
) -> None:
    calls: list[object] = []

    class _Saver(native_runtime_module.SqliteSaver):
        def __init__(self) -> None:
            super().__init__(sqlite3.connect(":memory:"))

        def setup(self) -> None:
            calls.append("setup")

    class _ConnectionContext:
        def __enter__(self) -> _Saver:
            calls.append("enter")
            return _Saver()

        def __exit__(self, *_arguments: object) -> None:
            calls.append("exit")

    class _PostgresSaver:
        @staticmethod
        def from_conn_string(connection_string: str) -> _ConnectionContext:
            calls.append(connection_string)
            return _ConnectionContext()

    monkeypatch.setattr(native_runtime_module, "PostgresSaver", _PostgresSaver)
    runtime = NativeLangGraphAgentRuntime.postgresql(
        connection_string="postgresql://agent:secret@db/jianhao_agent",
        model=_ScriptedModel([FinishAction("done")]),
        dispatcher=_NoopDispatcher(),
        policy=DefaultPolicyEngine(),
        event_sink=ListEventSink(),
        registry=StaticRegistryProvider(EffectiveRegistry("registry-v1", ())),
        limits=AgentRuntimeLimits(),
    )

    assert calls == ["postgresql://agent:secret@db/jianhao_agent", "enter", "setup"]
    runtime.close()
    assert calls[-1] == "exit"
