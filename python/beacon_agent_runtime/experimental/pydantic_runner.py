"""Isolated PydanticAI runner preserving the Beacon runtime port.

This module is deliberately excluded from ``runtime_selector``.  It is a
comparison harness, not a production fallback.  PydanticAI owns the bounded
single-agent tool loop while Beacon continues to own policy, event ordering,
device authorization, and terminal semantics.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import json
from typing import Any, Protocol

from jsonschema import Draft202012Validator
from jsonschema.exceptions import ValidationError
from pydantic_ai import Agent, CallDeferred, DeferredToolRequests, DeferredToolResults
from pydantic_ai import RunContext as PydanticRunContext
from pydantic_ai.messages import ModelResponse, TextPart, ToolCallPart
from pydantic_ai.models.function import AgentInfo, FunctionModel

from ..capabilities import CapabilityManifest, ExecutionLocation
from ..events import (
    AgentEventEmitter,
    ApprovalInterruptAction,
    EventSink,
    FinishAction,
    RunContext,
    StreamingFinishAction,
    ToolObservation,
    ToolRequestAction,
)
from ..policy import PolicyEngine
from ..protocol import AgentEventType
from ..registry import EffectiveRegistry
from ..runtime import (
    AgentRunResult,
    AgentRuntimeLimits,
    ModelProvider,
    RegistryProvider,
    RuntimeFailure,
    ToolDispatcher,
)


class RuntimePort(Protocol):
    """Structural port shared with the production runtime."""

    def start(
        self,
        *,
        run_id: str,
        query: str,
        authorized_scopes: set[str],
        preapproved_tool_calls: set[str] | None = None,
        initial_observations: tuple[ToolObservation, ...] = (),
    ) -> AgentRunResult: ...

    def resume_device_tool(
        self,
        *,
        run_id: str,
        tool_call_id: str,
        observation: dict[str, Any],
    ) -> AgentRunResult: ...

    def cancel(self, *, run_id: str) -> AgentRunResult: ...


@dataclass
class _RunState:
    run_id: str
    query: str
    authorized_scopes: set[str]
    approved_tool_calls: set[str]
    emitter: AgentEventEmitter
    observations: list[ToolObservation] = field(default_factory=list)
    steps: int = 0
    tools: int = 0
    messages: list[Any] = field(default_factory=list)
    pending: DeferredToolRequests | None = None
    pending_action: ToolRequestAction | None = None
    final_chunks: tuple[str, ...] = ()
    structured_output: bool = False
    result_kind: str = "success"
    failure: RuntimeFailure | None = None
    segments: int = 0
    phase: str = "running"


class PydanticAgentRuntime:
    """PydanticAI PoC with the same synchronous host-facing runtime methods.

    All prompt, model message, argument, and observation content is process
    local.  The safe ``checkpoint_view`` is metadata-only; process restart is
    therefore an explicit recovery gap instead of silently persisting health
    plaintext.
    """

    def __init__(
        self,
        *,
        model: ModelProvider,
        dispatcher: ToolDispatcher,
        policy: PolicyEngine,
        event_sink: EventSink,
        registry: RegistryProvider,
        limits: AgentRuntimeLimits,
    ) -> None:
        self.model = model
        self.dispatcher = dispatcher
        self.policy = policy
        self.event_sink = event_sink
        self.registry = registry
        self.limits = limits
        self._runs: dict[str, _RunState] = {}

    def start(
        self,
        *,
        run_id: str,
        query: str,
        authorized_scopes: set[str],
        preapproved_tool_calls: set[str] | None = None,
        initial_observations: tuple[ToolObservation, ...] = (),
    ) -> AgentRunResult:
        if run_id in self._runs:
            return AgentRunResult(run_id, "error", error_code="run_already_started")
        emitter = AgentEventEmitter(run_id, self.event_sink)
        effective = self.registry.current()
        emitter.emit(AgentEventType.RUN_STARTED, {"registryRevision": effective.revision})
        state = _RunState(
            run_id=run_id,
            query=query,
            authorized_scopes=set(authorized_scopes),
            approved_tool_calls=set(preapproved_tool_calls or ()),
            emitter=emitter,
            observations=list(initial_observations),
        )
        self._runs[run_id] = state
        return self._drive(state, user_prompt=query)

    def resume_device_tool(
        self,
        *,
        run_id: str,
        tool_call_id: str,
        observation: dict[str, Any],
    ) -> AgentRunResult:
        state = self._runs.get(run_id)
        if state is None:
            return AgentRunResult(run_id, "error", error_code="private_context_replay_required")
        if state.phase == "cancelled":
            return AgentRunResult(run_id, "error", error_code="run_cancelled")
        action = state.pending_action
        pending = state.pending
        if state.phase != "waiting_device" or action is None or pending is None:
            return AgentRunResult(run_id, "error", error_code="device_tool_not_pending")
        if action.tool_call_id != tool_call_id:
            return AgentRunResult(run_id, "error", error_code="device_tool_mismatch")
        try:
            manifest = self._manifest(action.capability_id, self.registry.current())
            validated = self._validated_observation(action, manifest, observation)
            deferred_results = pending.build_results(calls={tool_call_id: validated.data})
        except RuntimeFailure as failure:
            return AgentRunResult(run_id, "error", error_code=failure.code)
        except ValueError:
            return AgentRunResult(run_id, "error", error_code="device_tool_mismatch")

        state.observations.append(validated)
        state.emitter.emit(
            AgentEventType.TOOL_RESULT,
            {
                "toolCallId": tool_call_id,
                "capabilityId": action.capability_id,
                "status": "completed",
                "result": validated.data,
            },
        )
        state.emitter.emit(
            AgentEventType.TOOL_END,
            {
                "toolCallId": tool_call_id,
                "capabilityId": action.capability_id,
                "status": "completed",
            },
        )
        state.pending = None
        state.pending_action = None
        state.phase = "running"
        return self._drive(state, deferred_tool_results=deferred_results)

    def cancel(self, *, run_id: str) -> AgentRunResult:
        state = self._runs.get(run_id)
        if state is None:
            return AgentRunResult(run_id, "error", error_code="checkpoint_missing")
        if state.phase == "cancelled":
            return AgentRunResult(run_id, "cancelled", final_text="Cancelled")
        state.phase = "cancelled"
        state.pending = None
        state.pending_action = None
        state.emitter.emit(AgentEventType.RUN_FINISHED, {"status": "cancelled"})
        return AgentRunResult(run_id, "cancelled", final_text="Cancelled")

    def checkpoint_view(self, run_id: str) -> dict[str, Any] | None:
        state = self._runs.get(run_id)
        if state is None:
            return None
        pending = state.pending_action
        return {
            "phase": state.phase,
            "pendingDeviceTool": pending is not None,
            "toolCallId": pending.tool_call_id if pending else None,
            "capabilityId": pending.capability_id if pending else None,
            "nextSequence": state.emitter.next_sequence,
        }

    def _drive(
        self,
        state: _RunState,
        *,
        user_prompt: str | None = None,
        deferred_tool_results: DeferredToolResults | None = None,
    ) -> AgentRunResult:
        agent = self._agent(state)
        try:
            state.segments += 1
            result = agent.run_sync(
                user_prompt,
                message_history=state.messages or None,
                deferred_tool_results=deferred_tool_results,
                conversation_id=state.run_id,
                run_id=f"{state.run_id}:segment:{state.segments}",
            )
            state.messages = result.all_messages()
            output = result.output
            if isinstance(output, DeferredToolRequests):
                if len(output.calls) != 1 or output.approvals:
                    raise RuntimeFailure(
                        "unsupported_deferred_batch",
                        "PydanticAI emitted an unsupported deferred tool batch",
                    )
                call = output.calls[0]
                action = state.pending_action
                if action is None or call.tool_call_id != action.tool_call_id:
                    raise RuntimeFailure("device_tool_mismatch", "Deferred tool identity changed")
                state.pending = output
                state.phase = "waiting_device"
                state.emitter.emit(AgentEventType.STEP_FINISHED, {"step": state.steps})
                state.emitter.emit(
                    AgentEventType.RUN_INTERRUPTED,
                    {
                        "reason": "device_tool_required",
                        "deviceToolRequest": {
                            "toolCallId": action.tool_call_id,
                            "capabilityId": action.capability_id,
                            "arguments": action.arguments,
                            "requestedScopes": list(action.requested_scopes),
                        },
                    },
                )
                return AgentRunResult(state.run_id, "interrupted")
            if not isinstance(output, str):
                raise RuntimeFailure("invalid_model_output", "PydanticAI returned unsupported output")
            return self._finish(state, output)
        except RuntimeFailure as failure:
            return self._fail(state, failure)
        except Exception:
            return self._fail(
                state,
                state.failure
                or RuntimeFailure("pydantic_runtime_failure", "PydanticAI execution failed"),
            )

    def _agent(self, state: _RunState) -> Agent[_RunState, str | DeferredToolRequests]:
        def model_function(_messages: list[Any], _info: AgentInfo) -> ModelResponse:
            if state.steps >= self.limits.max_steps:
                failure = RuntimeFailure("step_limit", "Agent step limit reached")
                state.failure = failure
                raise failure
            state.steps += 1
            state.emitter.emit(AgentEventType.STEP_STARTED, {"step": state.steps})
            context = RunContext(
                run_id=state.run_id,
                query=state.query,
                registry_revision=self.registry.current().revision,
                observations=tuple(state.observations),
                step=state.steps - 1,
                pending_approval=None,
            )
            try:
                action = self.model.next_action(context)
            except RuntimeFailure as failure:
                state.failure = failure
                raise
            except Exception as error:
                failure = RuntimeFailure("model_failure", "Model provider failed")
                state.failure = failure
                raise failure from error
            if isinstance(action, ToolRequestAction):
                return ModelResponse(
                    [
                        ToolCallPart(
                            "beacon_capability",
                            {
                                "capability_id": action.capability_id,
                                "arguments": action.arguments,
                                "requested_scopes": list(action.requested_scopes),
                                "idempotency_key": action.idempotency_key,
                            },
                            action.tool_call_id,
                        )
                    ]
                )
            if isinstance(action, ApprovalInterruptAction):
                failure = RuntimeFailure(
                    "approval_not_implemented",
                    "The comparison runtime does not implement approval continuation",
                )
                state.failure = failure
                raise failure
            if isinstance(action, FinishAction):
                state.structured_output = action.output_kind == "structured"
                state.result_kind = "success"
                if state.structured_output:
                    if not state.observations:
                        failure = RuntimeFailure(
                            "missing_structured_output",
                            "Structured completion requires a validated observation",
                        )
                        state.failure = failure
                        raise failure
                    state.final_chunks = ()
                    return ModelResponse([TextPart("__BEACON_STRUCTURED_COMPLETION__")])
                state.final_chunks = (action.text,)
                return ModelResponse([TextPart(action.text)])
            if isinstance(action, StreamingFinishAction):
                try:
                    chunks = tuple(action.chunks)
                except Exception as error:
                    failure = RuntimeFailure("model_stream_failure", "Model stream failed")
                    state.failure = failure
                    raise failure from error
                if any(not isinstance(chunk, str) for chunk in chunks):
                    failure = RuntimeFailure("invalid_model_stream", "Model stream returned a non-text delta")
                    state.failure = failure
                    raise failure
                state.final_chunks = tuple(chunk for chunk in chunks if chunk)
                state.structured_output = False
                state.result_kind = action.outcome.result_kind
                return ModelResponse([TextPart("".join(state.final_chunks))])
            failure = RuntimeFailure("invalid_model_action", "Model returned an unsupported action")
            state.failure = failure
            raise failure

        agent: Agent[_RunState, str | DeferredToolRequests] = Agent(
            FunctionModel(model_function, model_name="beacon-port-adapter"),
            output_type=[str, DeferredToolRequests],
            deps_type=_RunState,
            retries=0,
        )

        @agent.tool(name="beacon_capability")
        def beacon_capability(
            context: PydanticRunContext[_RunState],
            capability_id: str,
            arguments: dict[str, Any],
            requested_scopes: list[str],
            idempotency_key: str | None = None,
        ) -> dict[str, Any]:
            tool_call_id = context.tool_call_id or ""
            action = ToolRequestAction(
                tool_call_id=tool_call_id,
                capability_id=capability_id,
                arguments=arguments,
                requested_scopes=tuple(requested_scopes),
                idempotency_key=idempotency_key,
            )
            effective = self.registry.current()
            manifest = self._authorize(action, effective, state)
            if state.tools >= self.limits.max_tools:
                failure = RuntimeFailure("tool_limit", "Agent tool limit reached")
                state.failure = failure
                raise failure
            state.tools += 1
            state.emitter.emit(
                AgentEventType.TOOL_START,
                {
                    "toolCallId": action.tool_call_id,
                    "capabilityId": action.capability_id,
                    "executionLocation": str(manifest.execution_location),
                    "arguments": action.arguments,
                },
            )
            if manifest.execution_location is ExecutionLocation.DEVICE:
                state.pending_action = action
                raise CallDeferred(
                    {
                        "capabilityId": action.capability_id,
                        "requestedScopes": list(action.requested_scopes),
                    }
                )
            try:
                observation = self.dispatcher.execute(action, manifest)
                validated = self._validated_observation(action, manifest, observation.data)
            except RuntimeFailure as failure:
                state.failure = failure
                raise
            except Exception as error:
                failure = RuntimeFailure("tool_failure", "Tool execution failed")
                state.failure = failure
                raise failure from error
            state.observations.append(validated)
            state.emitter.emit(
                AgentEventType.TOOL_RESULT,
                {
                    "toolCallId": action.tool_call_id,
                    "capabilityId": action.capability_id,
                    "status": "completed",
                    "result": validated.data,
                },
            )
            state.emitter.emit(
                AgentEventType.TOOL_END,
                {
                    "toolCallId": action.tool_call_id,
                    "capabilityId": action.capability_id,
                    "status": "completed",
                },
            )
            state.emitter.emit(AgentEventType.STEP_FINISHED, {"step": state.steps})
            return validated.data

        return agent

    def _finish(self, state: _RunState, final_text: str) -> AgentRunResult:
        if state.structured_output:
            final_text = ""
        elif not final_text.strip():
            raise RuntimeFailure("empty_final_output", "Generated response was empty")
        message_id = f"{state.run_id}:final"
        if not state.structured_output:
            state.emitter.emit(AgentEventType.TEXT_START, {"messageId": message_id})
            chunks = state.final_chunks or (final_text,)
            for delta in chunks:
                state.emitter.emit(
                    AgentEventType.TEXT_DELTA,
                    {"messageId": message_id, "delta": delta},
                )
            state.emitter.emit(
                AgentEventType.TEXT_END,
                {"messageId": message_id, "finalText": final_text},
            )
        state.emitter.emit(AgentEventType.STEP_FINISHED, {"step": state.steps})
        state.emitter.emit(
            AgentEventType.RUN_FINISHED,
            {"status": "completed", "resultKind": state.result_kind},
        )
        state.phase = "finished"
        return AgentRunResult(state.run_id, "finished", final_text=final_text)

    def _fail(self, state: _RunState, failure: RuntimeFailure) -> AgentRunResult:
        if state.phase != "failed":
            state.emitter.emit(
                AgentEventType.RUN_ERROR,
                {"code": failure.code, "summary": failure.summary},
            )
        state.phase = "failed"
        state.failure = failure
        return AgentRunResult(state.run_id, "error", error_code=failure.code)

    def _authorize(
        self,
        action: ToolRequestAction,
        registry: EffectiveRegistry,
        state: _RunState,
    ) -> CapabilityManifest:
        manifest = self._manifest(action.capability_id, registry)
        try:
            Draft202012Validator(manifest.input_schema).validate(action.arguments)
        except ValidationError as error:
            raise RuntimeFailure("invalid_tool_arguments", "Tool arguments failed schema validation") from error
        decision = self.policy.authorize(
            action,
            manifest,
            state.authorized_scopes,
            state.approved_tool_calls,
        )
        if not decision.allowed:
            raise RuntimeFailure("policy_denied", decision.safe_reason)
        return manifest

    @staticmethod
    def _manifest(capability_id: str, registry: EffectiveRegistry) -> CapabilityManifest:
        for manifest in registry.capabilities:
            if manifest.id == capability_id:
                return manifest
        raise RuntimeFailure("unknown_capability", "Capability is not available")

    def _validated_observation(
        self,
        action: ToolRequestAction,
        manifest: CapabilityManifest,
        observation: dict[str, Any],
    ) -> ToolObservation:
        try:
            Draft202012Validator(manifest.output_schema).validate(observation)
        except ValidationError as error:
            raise RuntimeFailure("invalid_tool_result", "Tool result failed schema validation") from error
        try:
            encoded = json.dumps(observation, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        except (TypeError, ValueError) as error:
            raise RuntimeFailure("invalid_tool_result", "Tool result is not JSON serializable") from error
        if len(encoded) > self.limits.max_observation_bytes:
            raise RuntimeFailure("observation_too_large", "Tool result exceeds the observation limit")
        return ToolObservation(action.tool_call_id, action.capability_id, observation)


__all__ = ["PydanticAgentRuntime", "RuntimePort"]
