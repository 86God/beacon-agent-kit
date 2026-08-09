"""Bounded, resumable model-tool Agent loop."""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any, Callable, Protocol

from jsonschema import Draft202012Validator, ValidationError

from .capabilities import CapabilityManifest
from .checkpoints import CheckpointStore, RuntimeCheckpoint
from .events import (
    AgentEventEmitter,
    ApprovalInterruptAction,
    EventSink,
    FinishAction,
    RunContext,
    ToolObservation,
    ToolRequestAction,
)
from .policy import PolicyEngine
from .protocol import AgentEventType
from .registry import EffectiveRegistry


class ModelProvider(Protocol):
    def next_action(
        self,
        context: RunContext,
    ) -> ToolRequestAction | ApprovalInterruptAction | FinishAction: ...


class ToolDispatcher(Protocol):
    def execute(
        self,
        action: ToolRequestAction,
        manifest: CapabilityManifest,
    ) -> ToolObservation: ...


class RegistryProvider(Protocol):
    def current(self) -> EffectiveRegistry: ...


@dataclass(frozen=True)
class StaticRegistryProvider:
    registry: EffectiveRegistry

    def current(self) -> EffectiveRegistry:
        return self.registry


class RecoverableToolError(RuntimeError):
    pass


@dataclass(frozen=True)
class AgentRuntimeLimits:
    max_steps: int = 12
    max_tools: int = 8
    max_retries: int = 3
    max_observation_bytes: int = 65_536
    device_tool_ttl_seconds: int = 300


@dataclass(frozen=True)
class AgentRunResult:
    run_id: str
    status: str
    final_text: str | None = None
    error_code: str | None = None


class RuntimeFailure(RuntimeError):
    def __init__(self, code: str, summary: str) -> None:
        super().__init__(summary)
        self.code = code
        self.summary = summary


class AgentRuntime:
    def __init__(
        self,
        *,
        model: ModelProvider,
        dispatcher: ToolDispatcher,
        checkpoints: CheckpointStore,
        policy: PolicyEngine,
        event_sink: EventSink,
        registry: RegistryProvider,
        limits: AgentRuntimeLimits,
        interrupt_device_tools: bool = False,
        clock: Callable[[], datetime] | None = None,
    ) -> None:
        self.model = model
        self.dispatcher = dispatcher
        self.checkpoints = checkpoints
        self.policy = policy
        self.event_sink = event_sink
        self.registry = registry
        self.limits = limits
        self.interrupt_device_tools = interrupt_device_tools
        self.clock = clock or (lambda: datetime.now(UTC))

    def start(
        self,
        *,
        run_id: str,
        query: str,
        authorized_scopes: set[str],
        preapproved_tool_calls: set[str] | None = None,
    ) -> AgentRunResult:
        checkpoint = RuntimeCheckpoint(
            run_id=run_id,
            query=query,
            authorized_scopes=set(authorized_scopes),
            approved_tool_calls=set(preapproved_tool_calls or ()),
        )
        emitter = AgentEventEmitter(run_id, self.event_sink)
        emitter.emit(AgentEventType.RUN_STARTED, {"registryRevision": self.registry.current().revision})
        checkpoint.next_sequence = emitter.next_sequence
        return self._drive(checkpoint, emitter)

    def resume(
        self,
        *,
        run_id: str,
        approval_id: str,
        approved: bool,
    ) -> AgentRunResult:
        checkpoint = self.checkpoints.load(run_id)
        if checkpoint is None or checkpoint.pending_approval is None:
            return AgentRunResult(run_id, "error", error_code="checkpoint_missing")
        pending = checkpoint.pending_approval
        if pending.approval_id != approval_id:
            return AgentRunResult(run_id, "error", error_code="approval_mismatch")
        emitter = AgentEventEmitter(run_id, self.event_sink, checkpoint.next_sequence)
        emitter.emit(
            AgentEventType.APPROVAL_RESOLVED,
            {"approvalId": approval_id, "decision": "approved" if approved else "rejected"},
        )
        checkpoint.pending_approval = None
        if not approved:
            emitter.emit(AgentEventType.RUN_FINISHED, {"status": "cancelled"})
            checkpoint.next_sequence = emitter.next_sequence
            self.checkpoints.save(checkpoint)
            return AgentRunResult(run_id, "finished", final_text="Cancelled")
        checkpoint.approved_tool_calls.add(pending.tool_call_id)
        checkpoint.observations.append(
            ToolObservation(
                tool_call_id=pending.tool_call_id,
                capability_id=pending.capability_id,
                data={"approvalId": approval_id, "decision": "approved"},
            )
        )
        checkpoint.next_sequence = emitter.next_sequence
        return self._drive(checkpoint, emitter)

    def resume_device_tool(
        self,
        *,
        run_id: str,
        tool_call_id: str,
        observation: dict[str, Any],
    ) -> AgentRunResult:
        """Resume a device-bound tool call with an observation supplied by the host app."""

        checkpoint = self.checkpoints.load(run_id)
        if checkpoint is None or checkpoint.pending_device_tool is None:
            return AgentRunResult(run_id, "error", error_code="checkpoint_missing")
        pending = checkpoint.pending_device_tool
        if pending.tool_call_id != tool_call_id:
            return AgentRunResult(run_id, "error", error_code="device_tool_mismatch")
        manifest = self._manifest(pending.capability_id, self.registry.current())
        try:
            validated = self._validated_observation(pending, manifest, observation)
        except RuntimeFailure as failure:
            return AgentRunResult(run_id, "error", error_code=failure.code)

        emitter = AgentEventEmitter(run_id, self.event_sink, checkpoint.next_sequence)
        checkpoint.pending_device_tool = None
        self._record_observation(pending, validated, checkpoint, emitter, replayed=False)
        checkpoint.next_sequence = emitter.next_sequence
        return self._drive(checkpoint, emitter)

    def _drive(
        self,
        checkpoint: RuntimeCheckpoint,
        emitter: AgentEventEmitter,
    ) -> AgentRunResult:
        try:
            while True:
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
                try:
                    action = self.model.next_action(context)
                except Exception as error:
                    raise RuntimeFailure("model_failure", "Model provider failed") from error
                checkpoint.steps += 1
                emitter.emit(AgentEventType.STEP_STARTED, {"step": checkpoint.steps})

                if isinstance(action, ToolRequestAction):
                    if self.interrupt_device_tools and self._is_device_tool(action, effective):
                        replayed = self._interrupt_device_tool(action, effective, checkpoint, emitter)
                        emitter.emit(AgentEventType.STEP_FINISHED, {"step": checkpoint.steps})
                        if not replayed:
                            manifest = self._manifest(action.capability_id, effective)
                            emitter.emit(
                                AgentEventType.RUN_INTERRUPTED,
                                {
                                    "reason": "device_tool_required",
                                    "toolCallId": action.tool_call_id,
                                    "capabilityId": action.capability_id,
                                    "arguments": action.arguments,
                                    "deviceToolRequest": self._device_tool_request_payload(
                                        action,
                                        manifest,
                                        effective.revision,
                                    ),
                                },
                            )
                            self._save(checkpoint, emitter)
                            return AgentRunResult(checkpoint.run_id, "interrupted")
                        self._save(checkpoint, emitter)
                        continue
                    self._execute_tool(action, effective, checkpoint, emitter)
                    emitter.emit(AgentEventType.STEP_FINISHED, {"step": checkpoint.steps})
                    self._save(checkpoint, emitter)
                    continue
                if isinstance(action, ApprovalInterruptAction):
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
                    return AgentRunResult(checkpoint.run_id, "interrupted")
                if isinstance(action, FinishAction):
                    message_id = f"{checkpoint.run_id}:final"
                    emitter.emit(AgentEventType.TEXT_START, {"messageId": message_id})
                    emitter.emit(
                        AgentEventType.TEXT_DELTA,
                        {"messageId": message_id, "delta": action.text},
                    )
                    emitter.emit(
                        AgentEventType.TEXT_END,
                        {"messageId": message_id, "finalText": action.text},
                    )
                    emitter.emit(AgentEventType.STEP_FINISHED, {"step": checkpoint.steps})
                    emitter.emit(AgentEventType.RUN_FINISHED, {"status": "completed"})
                    self._save(checkpoint, emitter)
                    return AgentRunResult(checkpoint.run_id, "finished", final_text=action.text)
                raise RuntimeFailure("invalid_model_action", "Model returned an unsupported action")
        except RuntimeFailure as failure:
            emitter.emit(
                AgentEventType.RUN_ERROR,
                {"code": failure.code, "summary": failure.summary},
            )
            self._save(checkpoint, emitter)
            return AgentRunResult(checkpoint.run_id, "error", error_code=failure.code)

    def _execute_tool(
        self,
        action: ToolRequestAction,
        registry: EffectiveRegistry,
        checkpoint: RuntimeCheckpoint,
        emitter: AgentEventEmitter,
    ) -> None:
        manifest = self._authorize_tool(action, registry, checkpoint)

        checkpoint.tools += 1
        emitter.emit(
            AgentEventType.TOOL_START,
            {
                "toolCallId": action.tool_call_id,
                "capabilityId": action.capability_id,
                "executionLocation": str(manifest.execution_location),
            },
        )
        observation = (
            checkpoint.completed_idempotency.get(action.idempotency_key)
            if action.idempotency_key
            else None
        )
        if observation is None:
            while True:
                try:
                    observation = self.dispatcher.execute(action, manifest)
                    break
                except RecoverableToolError as error:
                    checkpoint.retries += 1
                    if checkpoint.retries > self.limits.max_retries:
                        raise RuntimeFailure("retry_limit", "Recoverable retry limit reached") from error
                    emitter.emit(
                        AgentEventType.ACTIVITY_DELTA,
                        {
                            "activityId": action.tool_call_id,
                            "status": "retrying",
                            "detail": "Temporary tool failure; retrying safely",
                        },
                    )
                except Exception as error:
                    raise RuntimeFailure("tool_failure", "Tool execution failed") from error
        replayed = observation.tool_call_id != action.tool_call_id
        observation = self._validated_observation(action, manifest, observation.data)
        self._record_observation(action, observation, checkpoint, emitter, replayed=replayed)

    def _is_device_tool(self, action: ToolRequestAction, registry: EffectiveRegistry) -> bool:
        return str(self._manifest(action.capability_id, registry).execution_location) == "device"

    def _interrupt_device_tool(
        self,
        action: ToolRequestAction,
        registry: EffectiveRegistry,
        checkpoint: RuntimeCheckpoint,
        emitter: AgentEventEmitter,
    ) -> bool:
        manifest = self._authorize_tool(action, registry, checkpoint)
        checkpoint.tools += 1
        emitter.emit(
            AgentEventType.TOOL_START,
            {
                "toolCallId": action.tool_call_id,
                "capabilityId": action.capability_id,
                "executionLocation": "device",
                "requestedScopes": list(action.requested_scopes),
            },
        )
        replay = (
            checkpoint.completed_idempotency.get(action.idempotency_key)
            if action.idempotency_key
            else None
        )
        if replay is not None:
            observation = self._validated_observation(action, manifest, replay.data)
            self._record_observation(action, observation, checkpoint, emitter, replayed=True)
            return True
        checkpoint.pending_device_tool = action
        return False

    def _device_tool_request_payload(
        self,
        action: ToolRequestAction,
        manifest: CapabilityManifest,
        registry_revision: str,
    ) -> dict[str, Any]:
        """Emit the full request the device must independently validate."""

        expires_at = self.clock() + timedelta(seconds=self.limits.device_tool_ttl_seconds)
        return {
            "toolCallId": action.tool_call_id,
            "capabilityId": action.capability_id,
            "schemaVersion": manifest.schema_version,
            "registryRevision": registry_revision,
            "requestedScopes": list(action.requested_scopes),
            "arguments": action.arguments,
            "idempotencyKey": action.idempotency_key,
            "expiresAt": expires_at.astimezone(UTC).isoformat().replace("+00:00", "Z"),
        }

    def _authorize_tool(
        self,
        action: ToolRequestAction,
        registry: EffectiveRegistry,
        checkpoint: RuntimeCheckpoint,
    ) -> CapabilityManifest:
        if checkpoint.tools >= self.limits.max_tools:
            raise RuntimeFailure("tool_limit", "Agent tool limit reached")
        manifest = self._manifest(action.capability_id, registry)
        try:
            Draft202012Validator(manifest.input_schema).validate(action.arguments)
        except ValidationError as error:
            raise RuntimeFailure("invalid_tool_arguments", "Tool arguments failed schema validation") from error
        decision = self.policy.authorize(
            action,
            manifest,
            checkpoint.authorized_scopes,
            checkpoint.approved_tool_calls,
        )
        if not decision.allowed:
            raise RuntimeFailure("policy_denied", decision.safe_reason)
        return manifest

    @staticmethod
    def _manifest(capability_id: str, registry: EffectiveRegistry) -> CapabilityManifest:
        manifest = next((item for item in registry.capabilities if item.id == capability_id), None)
        if manifest is None:
            raise RuntimeFailure("unknown_capability", "Capability is not in the effective registry")
        return manifest

    def _validated_observation(
        self,
        action: ToolRequestAction,
        manifest: CapabilityManifest,
        data: dict[str, Any],
    ) -> ToolObservation:
        try:
            Draft202012Validator(manifest.output_schema).validate(data)
        except ValidationError as error:
            raise RuntimeFailure("invalid_tool_result", "Tool result failed schema validation") from error
        try:
            encoded = json.dumps(
                data,
                ensure_ascii=False,
                separators=(",", ":"),
                sort_keys=True,
            ).encode("utf-8")
        except (TypeError, ValueError) as error:
            raise RuntimeFailure("invalid_tool_result", "Tool result is not JSON serializable") from error
        if len(encoded) > self.limits.max_observation_bytes:
            raise RuntimeFailure("observation_too_large", "Tool observation exceeds safe limit")
        return ToolObservation(action.tool_call_id, action.capability_id, data)

    @staticmethod
    def _record_observation(
        action: ToolRequestAction,
        observation: ToolObservation,
        checkpoint: RuntimeCheckpoint,
        emitter: AgentEventEmitter,
        *,
        replayed: bool,
    ) -> None:
        if action.idempotency_key and not replayed:
            checkpoint.completed_idempotency[action.idempotency_key] = observation
        checkpoint.observations.append(observation)
        emitter.emit(
            AgentEventType.TOOL_RESULT,
            {
                "toolCallId": action.tool_call_id,
                "result": observation.data,
                "idempotentReplay": replayed,
            },
        )
        emitter.emit(
            AgentEventType.TOOL_END,
            {"toolCallId": action.tool_call_id, "status": "completed"},
        )

    def _save(self, checkpoint: RuntimeCheckpoint, emitter: AgentEventEmitter) -> None:
        checkpoint.next_sequence = emitter.next_sequence
        self.checkpoints.save(checkpoint)


__all__ = [
    "AgentRuntime",
    "AgentRuntimeLimits",
    "AgentRunResult",
    "ApprovalInterruptAction",
    "FinishAction",
    "RecoverableToolError",
    "RunContext",
    "StaticRegistryProvider",
    "ToolObservation",
    "ToolRequestAction",
]
