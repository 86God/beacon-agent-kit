"""LangGraph orchestration that preserves the Beacon runtime wire contract.

The graph deliberately does not let LangGraph call device tools.  Device work
is represented by a durable Beacon checkpoint and resumed by the host, so the
device remains the authorization and data boundary.  LangGraph owns the
planner/tool/finalizer routing; :class:`AgentRuntime` remains the compatibility
adapter for checkpoint and event semantics during the incremental migration.
"""

from __future__ import annotations

from typing import Any, Literal, TypedDict

from langgraph.graph import END, START, StateGraph

from .checkpoints import RuntimeCheckpoint
from .events import (
    AgentEventEmitter,
    ApprovalInterruptAction,
    FinishAction,
    RunContext,
    StreamingFinishAction,
    ToolRequestAction,
)
from .protocol import AgentEventType
from .runtime import AgentRunResult, AgentRuntime, RuntimeFailure


class _GraphState(TypedDict, total=False):
    checkpoint: RuntimeCheckpoint
    emitter: AgentEventEmitter
    action: Any
    result: AgentRunResult


class LangGraphAgentRuntime(AgentRuntime):
    """A real ``StateGraph`` runtime with existing Beacon event compatibility.

    The graph state only contains per-run data.  Durable resumption remains in
    ``CheckpointStore`` for now because it already defines the public
    ``resume_device_tool`` and confirmation contracts consumed by the gateway.
    This makes the migration reversible while LangGraph becomes the actual
    planner/router for every selected run.
    """

    def __init__(self, **kwargs: Any) -> None:
        super().__init__(**kwargs)
        graph = StateGraph(_GraphState)
        graph.add_node("planner", self._planner_node)
        graph.add_node("server_tool", self._server_tool_node)
        graph.add_node("device_tool", self._device_tool_node)
        graph.add_node("approval", self._approval_node)
        graph.add_node("finalizer", self._finalizer_node)
        graph.add_node("invalid", self._invalid_node)
        graph.add_edge(START, "planner")
        graph.add_conditional_edges(
            "planner",
            self._route_action,
            {
                "server_tool": "server_tool",
                "device_tool": "device_tool",
                "approval": "approval",
                "finalizer": "finalizer",
                "invalid": "invalid",
            },
        )
        graph.add_conditional_edges(
            "server_tool",
            self._route_after_tool,
            {"planner": "planner", "end": END},
        )
        graph.add_conditional_edges(
            "device_tool",
            self._route_after_device_tool,
            {"planner": "planner", "end": END},
        )
        graph.add_edge("approval", END)
        graph.add_edge("finalizer", END)
        graph.add_edge("invalid", END)
        self._graph = graph.compile()

    def _drive(
        self,
        checkpoint: RuntimeCheckpoint,
        emitter: AgentEventEmitter,
    ) -> AgentRunResult:
        """Execute one bounded LangGraph invocation and preserve safe failures."""

        try:
            result = self._graph.invoke({"checkpoint": checkpoint, "emitter": emitter})
            run_result = result.get("result")
            if isinstance(run_result, AgentRunResult):
                return run_result
            raise RuntimeFailure("graph_missing_result", "LangGraph completed without a run result")
        except RuntimeFailure as failure:
            emitter.emit(
                AgentEventType.RUN_ERROR,
                {"code": failure.code, "summary": failure.summary},
            )
            self._save(checkpoint, emitter)
            return AgentRunResult(checkpoint.run_id, "error", error_code=failure.code)

    def _planner_node(self, state: _GraphState) -> dict[str, Any]:
        checkpoint = state["checkpoint"]
        emitter = state["emitter"]
        if checkpoint.steps >= self.limits.max_steps:
            raise RuntimeFailure("step_limit", "Agent step limit reached")
        effective = self.registry.current()
        context = RunContext(
            run_id=checkpoint.run_id,
            query=checkpoint.query,
            registry_revision=effective.revision,
            observations=tuple(checkpoint.observations),
            step=checkpoint.steps,
            pending_approval=checkpoint.pending_approval,
        )
        checkpoint.steps += 1
        emitter.emit(AgentEventType.STEP_STARTED, {"step": checkpoint.steps})
        try:
            action = self.model.next_action(context)
        except Exception as error:
            raise RuntimeFailure("model_failure", "Model provider failed") from error
        return {"action": action, "checkpoint": checkpoint}

    def _route_action(
        self,
        state: _GraphState,
    ) -> Literal["server_tool", "device_tool", "approval", "finalizer", "invalid"]:
        action = state.get("action")
        if isinstance(action, ToolRequestAction):
            return "device_tool" if self.interrupt_device_tools and self._is_device_tool(
                action, self.registry.current()
            ) else "server_tool"
        if isinstance(action, ApprovalInterruptAction):
            return "approval"
        if isinstance(action, (FinishAction, StreamingFinishAction)):
            return "finalizer"
        return "invalid"

    def _server_tool_node(self, state: _GraphState) -> dict[str, Any]:
        checkpoint = state["checkpoint"]
        emitter = state["emitter"]
        action = state["action"]
        if not isinstance(action, ToolRequestAction):
            raise RuntimeFailure("invalid_model_action", "Model returned an unsupported action")
        self._execute_tool(action, self.registry.current(), checkpoint, emitter)
        emitter.emit(AgentEventType.STEP_FINISHED, {"step": checkpoint.steps})
        self._save(checkpoint, emitter)
        return {"checkpoint": checkpoint}

    def _route_after_tool(self, state: _GraphState) -> Literal["planner", "end"]:
        return "end" if state.get("result") is not None else "planner"

    def _device_tool_node(self, state: _GraphState) -> dict[str, Any]:
        checkpoint = state["checkpoint"]
        emitter = state["emitter"]
        action = state["action"]
        if not isinstance(action, ToolRequestAction):
            raise RuntimeFailure("invalid_model_action", "Model returned an unsupported action")
        effective = self.registry.current()
        replayed = self._interrupt_device_tool(action, effective, checkpoint, emitter)
        emitter.emit(AgentEventType.STEP_FINISHED, {"step": checkpoint.steps})
        if replayed:
            self._save(checkpoint, emitter)
            return {"checkpoint": checkpoint}
        manifest = self._manifest(action.capability_id, effective)
        emitter.emit(
            AgentEventType.RUN_INTERRUPTED,
            {
                "reason": "device_tool_required",
                "toolCallId": action.tool_call_id,
                "capabilityId": action.capability_id,
                "arguments": action.arguments,
                "deviceToolRequest": self._device_tool_request_payload(
                    action, manifest, effective.revision
                ),
            },
        )
        self._save(checkpoint, emitter)
        return {"checkpoint": checkpoint, "result": AgentRunResult(checkpoint.run_id, "interrupted")}

    @staticmethod
    def _route_after_device_tool(state: _GraphState) -> Literal["planner", "end"]:
        return "end" if state.get("result") is not None else "planner"

    def _approval_node(self, state: _GraphState) -> dict[str, Any]:
        checkpoint = state["checkpoint"]
        emitter = state["emitter"]
        action = state["action"]
        if not isinstance(action, ApprovalInterruptAction):
            raise RuntimeFailure("invalid_model_action", "Model returned an unsupported action")
        effective = self.registry.current()
        if action.capability_id not in {item.id for item in effective.capabilities}:
            raise RuntimeFailure("unknown_capability", "Approval references unavailable capability")
        checkpoint.pending_approval = action
        emitter.emit(
            AgentEventType.APPROVAL_REQUESTED,
            {
                "approvalId": action.approval_id,
                "toolCallId": action.tool_call_id,
                "capabilityId": action.capability_id,
                "summary": action.summary,
                "requestedScopes": list(action.requested_scopes),
                "idempotencyKey": action.idempotency_key,
            },
        )
        emitter.emit(AgentEventType.STEP_FINISHED, {"step": checkpoint.steps})
        emitter.emit(AgentEventType.RUN_INTERRUPTED, {"reason": "approval_required"})
        self._save(checkpoint, emitter)
        return {"checkpoint": checkpoint, "result": AgentRunResult(checkpoint.run_id, "interrupted")}

    def _finalizer_node(self, state: _GraphState) -> dict[str, Any]:
        checkpoint = state["checkpoint"]
        emitter = state["emitter"]
        action = state["action"]
        if isinstance(action, FinishAction):
            result = self._finish_text((action.text,), checkpoint, emitter)
        elif isinstance(action, StreamingFinishAction):
            result = self._finish_text(action.chunks, checkpoint, emitter)
        else:
            raise RuntimeFailure("invalid_model_action", "Model returned an unsupported action")
        return {"checkpoint": checkpoint, "result": result}

    def _invalid_node(self, state: _GraphState) -> dict[str, Any]:
        raise RuntimeFailure("invalid_model_action", "Model returned an unsupported action")


__all__ = ["LangGraphAgentRuntime"]
