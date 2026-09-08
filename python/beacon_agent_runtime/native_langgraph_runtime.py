"""Privacy-minimized LangGraph runtime for device-first agent hosts.

The graph persists only resumable control state.  The user's query, device
observations, generated text, tool arguments, and editable draft payloads live
in a process-local vault and are never included in graph state or resume
payloads.  If a process restart loses that transient context, the host must ask
the device to replay the already-authorized local read instead of recovering it
from a server checkpoint.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from hashlib import sha256
import json
from pathlib import Path
import sqlite3
from typing import Any, Callable, Literal, TypedDict
from uuid import uuid4

from jsonschema import Draft202012Validator
from jsonschema.exceptions import ValidationError
try:  # Optional until a host explicitly configures a PostgreSQL checkpointer.
    from langgraph.checkpoint.postgres import PostgresSaver
except ImportError:  # pragma: no cover - exercised by the factory's error path.
    PostgresSaver = None  # type: ignore[assignment,misc]
from langgraph.checkpoint.sqlite import SqliteSaver
from langgraph.graph import END, START, StateGraph
from langgraph.types import Command, interrupt

from .capabilities import CapabilityManifest, CapabilityRisk
from .events import (
    AgentEventEmitter,
    ApprovalInterruptAction,
    EventSink,
    FinishAction,
    RunContext,
    StreamingFinishAction,
    ToolObservation,
    ToolRequestAction,
)
from .policy import PolicyEngine
from .protocol import AgentEventType
from .registry import EffectiveRegistry
from .runtime import (
    AgentRunResult,
    AgentRuntimeLimits,
    ModelProvider,
    RegistryProvider,
    RuntimeFailure,
    ToolDispatcher,
)


class _PersistentGraphState(TypedDict, total=False):
    """The complete state allowlist written by LangGraph's checkpointer."""

    run_id: str
    thread_id: str
    query_digest: str
    authorized_scopes: tuple[str, ...]
    registry_revision: str
    phase: str
    steps: int
    tools: int
    retries: int
    next_sequence: int
    action_kind: str
    pending_tool: dict[str, Any]
    pending_approval: dict[str, Any]
    approved_tool_call_ids: tuple[str, ...]
    completed_idempotency_keys: tuple[str, ...]
    completed_device_results: dict[str, str]
    error_code: str | None


@dataclass
class _PrivateRunContext:
    """Ephemeral data required by the current process only."""

    query: str
    observations: list[ToolObservation] = field(default_factory=list)
    actions: dict[str, ToolRequestAction] = field(default_factory=dict)
    approvals: dict[str, ApprovalInterruptAction] = field(default_factory=dict)
    observations_by_receipt: dict[str, ToolObservation] = field(default_factory=dict)
    final_actions: dict[str, FinishAction | StreamingFinishAction] = field(default_factory=dict)
    results: dict[str, AgentRunResult] = field(default_factory=dict)


@dataclass
class _PreparedPostgresCheckpointer:
    """One host-owned Postgres saver shared by its per-run graphs."""

    checkpointer: Any
    context: Any
    closed: bool = False

    def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        self.context.__exit__(None, None, None)

    def __exit__(self, *_arguments: object) -> None:
        self.close()


class NativeLangGraphAgentRuntime:
    """LangGraph-native planner with privacy-safe device interrupts.

    ``PostgresSaver`` is the production checkpointer; ``SqliteSaver`` remains
    available only for local development and isolated tests.  The public
    methods mirror the legacy runtime while translating device replies into opaque
    ``Command(resume=...)`` values.  Raw observations stay only in
    ``_PrivateRunContext`` for the duration of the gateway process.
    """

    def __init__(
        self,
        *,
        checkpointer: SqliteSaver,
        model: ModelProvider,
        dispatcher: ToolDispatcher,
        policy: PolicyEngine,
        event_sink: EventSink,
        registry: RegistryProvider,
        limits: AgentRuntimeLimits,
        now: Callable[[], datetime] | None = None,
        sqlite_connection: sqlite3.Connection | None = None,
        postgres_context: Any | None = None,
    ) -> None:
        self._checkpointer = checkpointer
        self._sqlite_connection = sqlite_connection
        self._postgres_context = postgres_context
        self.model = model
        self.dispatcher = dispatcher
        self.policy = policy
        self.event_sink = event_sink
        self.registry = registry
        self.limits = limits
        self._now = now or (lambda: datetime.now(UTC))
        self._private: dict[str, _PrivateRunContext] = {}
        # A graph node can emit an observable event and then raise before its
        # returned state reaches the checkpointer.  Retain only the next event
        # cursor in memory so terminal failures never reuse that just-emitted
        # sequence number.  This contains no user or tool data.
        self._emitted_next_sequence: dict[str, int] = {}

        graph = StateGraph(_PersistentGraphState)
        graph.add_node("planner", self._planner_node)
        graph.add_node("server_tool", self._server_tool_node)
        graph.add_node("device_request", self._device_request_node)
        graph.add_node("device_interrupt", self._device_interrupt_node)
        graph.add_node("approval_request", self._approval_request_node)
        graph.add_node("approval_interrupt", self._approval_interrupt_node)
        graph.add_node("finalizer", self._finalizer_node)
        graph.add_node("invalid", self._invalid_node)
        graph.add_edge(START, "planner")
        graph.add_conditional_edges(
            "planner",
            self._route_action,
            {
                "server_tool": "server_tool",
                "device_tool": "device_request",
                "approval": "approval_request",
                "finalizer": "finalizer",
                "invalid": "invalid",
            },
        )
        graph.add_edge("server_tool", "planner")
        graph.add_edge("device_request", "device_interrupt")
        graph.add_edge("device_interrupt", "planner")
        graph.add_edge("approval_request", "approval_interrupt")
        graph.add_edge("approval_interrupt", "planner")
        graph.add_edge("finalizer", END)
        graph.add_edge("invalid", END)
        self._graph = graph.compile(checkpointer=checkpointer)

    @classmethod
    def sqlite(
        cls,
        *,
        path: str | Path,
        model: ModelProvider,
        dispatcher: ToolDispatcher,
        policy: PolicyEngine,
        event_sink: EventSink,
        registry: RegistryProvider,
        limits: AgentRuntimeLimits,
        now: Callable[[], datetime] | None = None,
    ) -> "NativeLangGraphAgentRuntime":
        database = Path(path)
        database.parent.mkdir(parents=True, exist_ok=True)
        connection = sqlite3.connect(database, check_same_thread=False)
        checkpointer = SqliteSaver(connection)
        # SqliteSaver otherwise initializes its schema lazily on the first
        # graph invocation.  When several fresh runs arrive together, separate
        # connections can race on PRAGMA journal_mode/CREATE TABLE and surface
        # an avoidable ``database is locked`` graph failure.  The host
        # serializes construction of SQLite runtimes, so complete that one-time
        # setup while still inside the serialized section.
        try:
            checkpointer.setup()
        except Exception:
            connection.close()
            raise
        return cls(
            checkpointer=checkpointer,
            sqlite_connection=connection,
            model=model,
            dispatcher=dispatcher,
            policy=policy,
            event_sink=event_sink,
            registry=registry,
            limits=limits,
            now=now,
        )

    @classmethod
    def postgresql(
        cls,
        *,
        connection_string: str,
        prepared: _PreparedPostgresCheckpointer | None = None,
        model: ModelProvider,
        dispatcher: ToolDispatcher,
        policy: PolicyEngine,
        event_sink: EventSink,
        registry: RegistryProvider,
        limits: AgentRuntimeLimits,
        now: Callable[[], datetime] | None = None,
    ) -> "NativeLangGraphAgentRuntime":
        """Create a production graph with LangGraph's official Postgres saver.

        The caller owns the connection string through deployment secrets; this
        class never persists it.  ``setup`` is idempotent and creates the
        official LangGraph tables on the first deployment.
        """

        owned = prepared is None
        prepared = prepared or cls.prepare_postgresql(connection_string)
        return cls(
            checkpointer=prepared.checkpointer,
            postgres_context=prepared if owned else None,
            model=model,
            dispatcher=dispatcher,
            policy=policy,
            event_sink=event_sink,
            registry=registry,
            limits=limits,
            now=now,
        )

    @classmethod
    def prepare_postgresql(
        cls,
        connection_string: str,
    ) -> _PreparedPostgresCheckpointer:
        """Open and migrate one saver before the host accepts mobile runs."""

        if PostgresSaver is None:
            raise RuntimeError("langgraph_checkpoint_postgres_unavailable")
        context = PostgresSaver.from_conn_string(connection_string)
        checkpointer = context.__enter__()
        try:
            checkpointer.setup()
        except Exception:
            context.__exit__(None, None, None)
            raise
        return _PreparedPostgresCheckpointer(
            checkpointer=checkpointer,
            context=context,
        )

    def close(self) -> None:
        if self._sqlite_connection is not None:
            self._sqlite_connection.close()
            self._sqlite_connection = None
        if self._postgres_context is not None:
            self._postgres_context.__exit__(None, None, None)
            self._postgres_context = None

    def start(
        self,
        *,
        run_id: str,
        query: str,
        authorized_scopes: set[str],
        preapproved_tool_calls: set[str] | None = None,
        initial_observations: tuple[ToolObservation, ...] = (),
    ) -> AgentRunResult:
        if run_id in self._private:
            return AgentRunResult(run_id, "error", error_code="run_already_started")
        self._private[run_id] = _PrivateRunContext(
            query=query,
            observations=list(initial_observations),
        )
        effective = self.registry.current()
        initial_state: _PersistentGraphState = {
            "run_id": run_id,
            "thread_id": run_id,
            "query_digest": _digest(query),
            "authorized_scopes": tuple(sorted(authorized_scopes)),
            "registry_revision": effective.revision,
            "phase": "running",
            "steps": 0,
            "tools": 0,
            "retries": 0,
            "next_sequence": 0,
            "action_kind": "",
            "pending_tool": {},
            "pending_approval": {},
            "approved_tool_call_ids": tuple(sorted(preapproved_tool_calls or ())),
            "completed_idempotency_keys": (),
            "completed_device_results": {},
            "error_code": None,
        }
        next_sequence = self._emit(initial_state, AgentEventType.RUN_STARTED, {"registryRevision": effective.revision})
        initial_state["next_sequence"] = next_sequence
        return self._invoke(run_id, initial_state)

    def resume_device_tool(
        self,
        *,
        run_id: str,
        tool_call_id: str,
        observation: dict[str, Any],
    ) -> AgentRunResult:
        state = self._state(run_id)
        if state is None:
            return AgentRunResult(run_id, "error", error_code="checkpoint_missing")
        observation_digest = _observation_digest(observation)
        completed = state.get("completed_device_results", {})
        if tool_call_id in completed:
            if completed[tool_call_id] != observation_digest:
                return AgentRunResult(
                    run_id,
                    "error",
                    error_code="device_tool_result_conflict",
                    replayed=True,
                )
            return self._replayed_result(run_id, state)
        if state.get("phase") == "cancelled":
            return AgentRunResult(run_id, "error", error_code="run_cancelled")
        if state.get("phase") != "waiting_device":
            return AgentRunResult(run_id, "error", error_code="device_tool_not_pending")
        private = self._private.get(run_id)
        if private is None:
            return AgentRunResult(run_id, "error", error_code="private_context_replay_required")
        action = private.actions.get(tool_call_id)
        if action is None:
            return AgentRunResult(run_id, "error", error_code="private_context_replay_required")
        if state.get("pending_tool", {}).get("toolCallId") != tool_call_id:
            return AgentRunResult(run_id, "error", error_code="device_tool_mismatch")
        if _is_expired(state.get("pending_tool", {}).get("expiresAt"), now=self._now()):
            return AgentRunResult(run_id, "error", error_code="device_tool_expired")
        try:
            manifest = self._manifest(action.capability_id, self.registry.current())
            validated = self._validated_observation(action, manifest, observation)
        except RuntimeFailure as failure:
            return AgentRunResult(run_id, "error", error_code=failure.code)
        receipt = uuid4().hex
        private.observations_by_receipt[receipt] = validated
        return self._invoke(
            run_id,
            Command(resume={"toolCallId": tool_call_id, "receipt": receipt}),
        )

    @staticmethod
    def _replayed_result(run_id: str, state: _PersistentGraphState) -> AgentRunResult:
        phase = str(state.get("phase", ""))
        if phase == "finished":
            return AgentRunResult(run_id, "finished", replayed=True)
        if phase == "cancelled":
            return AgentRunResult(run_id, "cancelled", replayed=True)
        if phase == "failed":
            return AgentRunResult(
                run_id,
                "error",
                error_code=state.get("error_code") or "runtime_failure",
                replayed=True,
            )
        return AgentRunResult(run_id, "interrupted", replayed=True)

    def rehydrate_device_context(
        self,
        *,
        run_id: str,
        query: str,
        pending_action: ToolRequestAction,
    ) -> None:
        """Restore only client-supplied transient context after a host restart.

        The safe checkpoint proves which capability and tool call are pending;
        the device re-supplies the query and request arguments from its local
        conversation rather than the gateway retrieving them from persistence.
        """

        state = self._state(run_id)
        if state is None or state.get("phase") != "waiting_device":
            raise RuntimeFailure("device_tool_not_pending", "No device tool is waiting")
        pending = state.get("pending_tool", {})
        if (
            pending.get("toolCallId") != pending_action.tool_call_id
            or pending.get("capabilityId") != pending_action.capability_id
            or tuple(pending.get("requestedScopes", ())) != pending_action.requested_scopes
            or pending.get("argumentsDigest") != _arguments_digest(pending_action.arguments)
        ):
            raise RuntimeFailure("device_tool_mismatch", "Replayed action does not match checkpoint")
        manifest = self._manifest(pending_action.capability_id, self.registry.current())
        try:
            Draft202012Validator(manifest.input_schema).validate(pending_action.arguments)
        except ValidationError as error:
            raise RuntimeFailure("invalid_tool_arguments", "Tool arguments failed schema validation") from error
        self._private[run_id] = _PrivateRunContext(
            query=query,
            actions={pending_action.tool_call_id: pending_action},
        )

    def resume(self, *, run_id: str, approval_id: str, approved: bool) -> AgentRunResult:
        state = self._state(run_id)
        if state is None:
            return AgentRunResult(run_id, "error", error_code="checkpoint_missing")
        if state.get("phase") == "cancelled":
            return AgentRunResult(run_id, "error", error_code="run_cancelled")
        if state.get("phase") != "waiting_approval":
            return AgentRunResult(run_id, "error", error_code="approval_not_pending")
        pending = state.get("pending_approval", {})
        if pending.get("approvalId") != approval_id:
            return AgentRunResult(run_id, "error", error_code="approval_mismatch")
        if _is_expired(pending.get("expiresAt"), now=self._now()):
            return AgentRunResult(run_id, "error", error_code="approval_expired")
        return self._invoke(
            run_id,
            Command(resume={"approvalId": approval_id, "approved": approved}),
        )

    def cancel(self, *, run_id: str) -> AgentRunResult:
        state = self._state(run_id)
        if state is None:
            return AgentRunResult(run_id, "error", error_code="checkpoint_missing")
        next_sequence = self._emit(state, AgentEventType.RUN_FINISHED, {"status": "cancelled"})
        self._graph.update_state(
            self._config(run_id),
            {"phase": "cancelled", "next_sequence": next_sequence, "pending_tool": {}, "pending_approval": {}},
        )
        return AgentRunResult(run_id, "cancelled", final_text="Cancelled")

    def _invoke(self, run_id: str, input_value: _PersistentGraphState | Command) -> AgentRunResult:
        try:
            result = self._graph.invoke(input_value, self._config(run_id))
        except RuntimeFailure as failure:
            return self._fail(run_id, failure)
        except Exception:
            return self._fail(run_id, RuntimeFailure("graph_failure", "LangGraph execution failed"))
        interrupted = result.get("__interrupt__") if isinstance(result, dict) else None
        if interrupted:
            state = self._state(run_id) or {}
            reason = (
                "device_tool_required"
                if state.get("phase") == "waiting_device"
                else "approval_required"
            )
            payload: dict[str, Any] = {"reason": reason}
            private = self._private.get(run_id)
            if reason == "device_tool_required" and private is not None:
                pending = state.get("pending_tool", {})
                action = private.actions.get(str(pending.get("toolCallId", "")))
                if action is not None:
                    payload["deviceToolRequest"] = _transient_device_tool_request(action, pending)
            next_sequence = self._emit(state, AgentEventType.RUN_INTERRUPTED, payload)
            self._graph.update_state(self._config(run_id), {"next_sequence": next_sequence})
            return AgentRunResult(run_id, "interrupted")
        private = self._private.get(run_id)
        if private is None:
            return AgentRunResult(run_id, "error", error_code="private_context_replay_required")
        completed = private.results.pop(run_id, None)
        if completed is not None:
            return completed
        return AgentRunResult(run_id, "error", error_code="graph_missing_result")

    def checkpoint_view(self, run_id: str) -> dict[str, Any] | None:
        """Expose a transient diagnostic view without reintroducing persistence.

        Hosts use this only for compatibility diagnostics.  It deliberately
        returns no query or observation values, and its pending action disappears
        after a process restart together with the private vault.
        """

        state = self._state(run_id)
        if state is None:
            return None
        pending_tool = state.get("pending_tool", {})
        pending_approval = state.get("pending_approval", {})
        return {
            "phase": state.get("phase"),
            "pendingDeviceTool": bool(pending_tool),
            "pendingApproval": bool(pending_approval),
            "toolCallId": pending_tool.get("toolCallId"),
            "capabilityId": pending_tool.get("capabilityId"),
            "nextSequence": state.get("next_sequence"),
        }

    def _planner_node(self, state: _PersistentGraphState) -> dict[str, Any]:
        if state["steps"] >= self.limits.max_steps:
            raise RuntimeFailure("step_limit", "Agent step limit reached")
        private = self._private.get(state["run_id"])
        if private is None:
            raise RuntimeFailure("private_context_replay_required", "Device context must be replayed")
        effective = self.registry.current()
        next_sequence = self._emit(state, AgentEventType.STEP_STARTED, {"step": state["steps"] + 1})
        context = RunContext(
            run_id=state["run_id"],
            query=private.query,
            registry_revision=effective.revision,
            observations=tuple(private.observations),
            step=state["steps"],
            pending_approval=None,
        )
        try:
            action = self.model.next_action(context)
        except RuntimeFailure:
            # Providers may deliberately return a bounded, protocol-safe error
            # code (for example an unavailable tool selection).  Preserve that
            # classification so the host can observe and recover it without
            # retaining any prompt or device observation.
            raise
        except Exception as error:
            raise RuntimeFailure("model_failure", "Model provider failed") from error
        updates: dict[str, Any] = {
            "steps": state["steps"] + 1,
            "next_sequence": next_sequence,
            "registry_revision": effective.revision,
            "phase": "running",
            "error_code": None,
        }
        if isinstance(action, ToolRequestAction):
            manifest = self._authorize_tool(action, state, effective)
            private.actions[action.tool_call_id] = action
            updates.update(
                {
                    "tools": state["tools"] + 1,
                    "action_kind": "device_tool"
                    if manifest.execution_location == "device"
                    else "server_tool",
                    "pending_tool": _safe_tool_reference(
                        action,
                        manifest,
                        effective.revision,
                        expires_at=self._now()
                        + timedelta(seconds=self.limits.device_tool_ttl_seconds),
                    ),
                }
            )
        elif isinstance(action, ApprovalInterruptAction):
            if action.capability_id not in {item.id for item in effective.capabilities}:
                raise RuntimeFailure("unknown_capability", "Approval references unavailable capability")
            private.approvals[action.approval_id] = action
            updates.update(
                {
                    "action_kind": "approval",
                    "pending_approval": _safe_approval_reference(
                        action,
                        expires_at=self._now()
                        + timedelta(seconds=self.limits.approval_ttl_seconds),
                    ),
                }
            )
        elif isinstance(action, (FinishAction, StreamingFinishAction)):
            private.final_actions[state["run_id"]] = action
            updates["action_kind"] = "finalizer"
        else:
            updates["action_kind"] = "invalid"
        return updates

    @staticmethod
    def _route_action(
        state: _PersistentGraphState,
    ) -> Literal["server_tool", "device_tool", "approval", "finalizer", "invalid"]:
        action_kind = state.get("action_kind")
        if action_kind == "server_tool":
            return "server_tool"
        if action_kind == "device_tool":
            return "device_tool"
        if action_kind == "approval":
            return "approval"
        if action_kind == "finalizer":
            return "finalizer"
        return "invalid"

    def _server_tool_node(self, state: _PersistentGraphState) -> dict[str, Any]:
        private = self._private.get(state["run_id"])
        if private is None:
            raise RuntimeFailure("private_context_replay_required", "Device context must be replayed")
        pending = state.get("pending_tool", {})
        action = private.actions.get(str(pending.get("toolCallId", "")))
        if action is None:
            raise RuntimeFailure("private_context_replay_required", "Tool arguments must be replayed")
        manifest = self._manifest(action.capability_id, self.registry.current())
        next_sequence = self._emit(
            state,
            AgentEventType.TOOL_START,
            _safe_tool_event(action, manifest.execution_location),
        )
        try:
            observation = self.dispatcher.execute(action, manifest)
        except RuntimeFailure as failure:
            # Dispatchers may already have translated provider/network errors
            # into a safe, actionable code. Preserve it for the client instead
            # of flattening every operational failure into ``tool_failure``.
            if manifest.risk is not CapabilityRisk.READ_ONLY or not manifest.fallback:
                raise
            return self._degrade_read_only_tool(
                state=state,
                private=private,
                action=action,
                manifest=manifest,
                next_sequence=next_sequence,
                failure_code=manifest.fallback,
            )
        except Exception as error:
            if manifest.risk is not CapabilityRisk.READ_ONLY or not manifest.fallback:
                raise RuntimeFailure("tool_failure", "Tool execution failed") from error
            return self._degrade_read_only_tool(
                state=state,
                private=private,
                action=action,
                manifest=manifest,
                next_sequence=next_sequence,
                failure_code=manifest.fallback,
            )
        validated = self._validated_observation(action, manifest, observation.data)
        private.observations.append(validated)
        next_sequence = self._emit(
            {**state, "next_sequence": next_sequence},
            AgentEventType.TOOL_RESULT,
            {
                "toolCallId": action.tool_call_id,
                "capabilityId": action.capability_id,
                "status": "completed",
                "result": validated.data,
            },
        )
        next_sequence = self._emit(
            {**state, "next_sequence": next_sequence},
            AgentEventType.TOOL_END,
            {"toolCallId": action.tool_call_id, "capabilityId": action.capability_id, "status": "completed"},
        )
        next_sequence = self._emit(
            {**state, "next_sequence": next_sequence},
            AgentEventType.STEP_FINISHED,
            {"step": state["steps"]},
        )
        return {"next_sequence": next_sequence, "pending_tool": {}, "action_kind": ""}

    def _degrade_read_only_tool(
        self,
        *,
        state: _PersistentGraphState,
        private: _PrivateRunContext,
        action: ToolRequestAction,
        manifest: CapabilityManifest,
        next_sequence: int,
        failure_code: str,
    ) -> dict[str, Any]:
        """Turn an optional read failure into a bounded, trusted observation.

        The marker is runtime-owned and deliberately contains no dispatcher
        message or fabricated domain fields.  It lets the planner continue
        with an explicit evidence gap while the completed capability is
        removed from subsequent selection.
        """

        failure_observation = ToolObservation(
            action.tool_call_id,
            action.capability_id,
            {"unavailable": True, "code": failure_code},
        )
        private.observations.append(failure_observation)
        next_sequence = self._emit(
            {**state, "next_sequence": next_sequence},
            AgentEventType.TOOL_RESULT,
            {
                "toolCallId": action.tool_call_id,
                "capabilityId": action.capability_id,
                "status": "failed",
                "failureCode": failure_code,
            },
        )
        next_sequence = self._emit(
            {**state, "next_sequence": next_sequence},
            AgentEventType.TOOL_END,
            {
                "toolCallId": action.tool_call_id,
                "capabilityId": action.capability_id,
                "status": "failed",
            },
        )
        next_sequence = self._emit(
            {**state, "next_sequence": next_sequence},
            AgentEventType.STEP_FINISHED,
            {"step": state["steps"]},
        )
        return {"next_sequence": next_sequence, "pending_tool": {}, "action_kind": ""}

    def _device_request_node(self, state: _PersistentGraphState) -> dict[str, Any]:
        pending = state.get("pending_tool", {})
        next_sequence = self._emit(
            state,
            AgentEventType.TOOL_START,
            {
                "toolCallId": pending["toolCallId"],
                "capabilityId": pending["capabilityId"],
                "executionLocation": "device",
                "requestedScopes": pending["requestedScopes"],
                "requestRef": pending["requestRef"],
            },
        )
        next_sequence = self._emit(
            {**state, "next_sequence": next_sequence},
            AgentEventType.STEP_FINISHED,
            {"step": state["steps"]},
        )
        return {"next_sequence": next_sequence, "phase": "waiting_device", "action_kind": ""}

    def _device_interrupt_node(self, state: _PersistentGraphState) -> dict[str, Any]:
        pending = state.get("pending_tool", {})
        reply = interrupt(
            {
                "kind": "device_tool",
                "toolCallId": pending["toolCallId"],
                "capabilityId": pending["capabilityId"],
                "requestedScopes": pending["requestedScopes"],
                "requestRef": pending["requestRef"],
            }
        )
        if not isinstance(reply, dict) or reply.get("toolCallId") != pending["toolCallId"]:
            raise RuntimeFailure("device_tool_mismatch", "Device resume does not match pending tool")
        private = self._private.get(state["run_id"])
        receipt = str(reply.get("receipt", ""))
        observation = private.observations_by_receipt.get(receipt) if private is not None else None
        if observation is None:
            raise RuntimeFailure("private_context_replay_required", "Device observation must be replayed")
        private.observations.append(observation)
        next_sequence = self._emit(
            state,
            AgentEventType.TOOL_RESULT,
            {
                "toolCallId": pending["toolCallId"],
                "capabilityId": pending["capabilityId"],
                "status": "completed",
                "result": observation.data,
            },
        )
        next_sequence = self._emit(
            {**state, "next_sequence": next_sequence},
            AgentEventType.TOOL_END,
            {
                "toolCallId": pending["toolCallId"],
                "capabilityId": pending["capabilityId"],
                "status": "completed",
            },
        )
        completed_keys = set(state.get("completed_idempotency_keys", ()))
        idempotency_key = pending.get("idempotencyKey")
        if idempotency_key:
            completed_keys.add(str(idempotency_key))
        completed_results = dict(state.get("completed_device_results", {}))
        completed_results[str(pending["toolCallId"])] = _observation_digest(observation.data)
        return {
            "next_sequence": next_sequence,
            "phase": "running",
            "pending_tool": {},
            "completed_idempotency_keys": tuple(sorted(completed_keys)),
            "completed_device_results": completed_results,
        }

    def _approval_request_node(self, state: _PersistentGraphState) -> dict[str, Any]:
        pending = state.get("pending_approval", {})
        private = self._private.get(state["run_id"])
        action = private.approvals.get(str(pending.get("approvalId", ""))) if private else None
        next_sequence = self._emit(
            state,
            AgentEventType.APPROVAL_REQUESTED,
            {
                "approvalId": pending["approvalId"],
                "toolCallId": pending["toolCallId"],
                "capabilityId": pending["capabilityId"],
                "requestedScopes": pending["requestedScopes"],
                "idempotencyKey": pending["idempotencyKey"],
                "approvalRef": pending["approvalRef"],
                "expiresAt": pending["expiresAt"],
                "summary": action.summary if action is not None else "请在本机确认此操作。",
            },
        )
        next_sequence = self._emit(
            {**state, "next_sequence": next_sequence},
            AgentEventType.STEP_FINISHED,
            {"step": state["steps"]},
        )
        return {"next_sequence": next_sequence, "phase": "waiting_approval", "action_kind": ""}

    def _approval_interrupt_node(self, state: _PersistentGraphState) -> dict[str, Any]:
        pending = state.get("pending_approval", {})
        reply = interrupt(
            {
                "kind": "approval",
                "approvalId": pending["approvalId"],
                "toolCallId": pending["toolCallId"],
                "capabilityId": pending["capabilityId"],
                "approvalRef": pending["approvalRef"],
            }
        )
        if not isinstance(reply, dict) or reply.get("approvalId") != pending["approvalId"]:
            raise RuntimeFailure("approval_mismatch", "Approval resume does not match pending approval")
        approved = bool(reply.get("approved"))
        next_sequence = self._emit(
            state,
            AgentEventType.APPROVAL_RESOLVED,
            {"approvalId": pending["approvalId"], "decision": "approved" if approved else "rejected"},
        )
        if not approved:
            next_sequence = self._emit(
                {**state, "next_sequence": next_sequence},
                AgentEventType.RUN_FINISHED,
                {"status": "cancelled"},
            )
            private = self._private.get(state["run_id"])
            if private is not None:
                private.results[state["run_id"]] = AgentRunResult(
                    state["run_id"], "finished", final_text="Cancelled"
                )
            return {
                "next_sequence": next_sequence,
                "phase": "cancelled",
                "pending_approval": {},
            }
        approved_ids = set(state.get("approved_tool_call_ids", ()))
        approved_ids.add(str(pending["toolCallId"]))
        private = self._private.get(state["run_id"])
        if private is None:
            raise RuntimeFailure("private_context_replay_required", "Approval context must be replayed")
        private.observations.append(
            ToolObservation(
                tool_call_id=str(pending["toolCallId"]),
                capability_id=str(pending["capabilityId"]),
                data={"approvalId": pending["approvalId"], "decision": "approved"},
            )
        )
        return {
            "next_sequence": next_sequence,
            "phase": "running",
            "pending_approval": {},
            "approved_tool_call_ids": tuple(sorted(approved_ids)),
        }

    def _finalizer_node(self, state: _PersistentGraphState) -> dict[str, Any]:
        private = self._private.get(state["run_id"])
        action = private.final_actions.pop(state["run_id"], None) if private is not None else None
        if action is None:
            raise RuntimeFailure("private_context_replay_required", "Generated response must be replayed")
        structured_output = (
            isinstance(action, FinishAction) and action.output_kind == "structured"
        )
        if structured_output and (private is None or not private.observations):
            raise RuntimeFailure(
                "missing_structured_output",
                "Structured completion requires a validated observation",
            )
        chunks = (
            ()
            if structured_output
            else (action.text,)
            if isinstance(action, FinishAction)
            else iter(action.chunks)
        )
        # The iOS consumer keys incremental Markdown rendering by messageId and
        # finalizes it from finalText.  Keep that public stream contract stable
        # while the checkpoint remains limited to the safe graph state.
        message_id = f"{state['run_id']}:final"
        next_sequence = state["next_sequence"]
        text = ""
        pending_chunks: list[str] = []
        text_started = False
        for chunk in chunks:
            if not isinstance(chunk, str):
                raise RuntimeFailure("invalid_final_output", "Generated response was not text")
            text += chunk
            if not text_started:
                pending_chunks.append(chunk)
                if not text.strip():
                    continue
                next_sequence = self._emit(
                    {**state, "next_sequence": next_sequence},
                    AgentEventType.TEXT_START,
                    {"messageId": message_id},
                )
                text_started = True
                chunks_to_emit = pending_chunks
                pending_chunks = []
            else:
                chunks_to_emit = [chunk]
            for emitted_chunk in chunks_to_emit:
                next_sequence = self._emit(
                    {**state, "next_sequence": next_sequence},
                    AgentEventType.TEXT_DELTA,
                    {"messageId": message_id, "delta": emitted_chunk},
                )
        if not text_started and not structured_output:
            raise RuntimeFailure("empty_final_output", "Generated response was empty")
        if text_started:
            next_sequence = self._emit(
                {**state, "next_sequence": next_sequence},
                AgentEventType.TEXT_END,
                {"messageId": message_id, "finalText": text},
            )
        next_sequence = self._emit(
            {**state, "next_sequence": next_sequence},
            AgentEventType.STEP_FINISHED,
            {"step": state["steps"]},
        )
        result_kind = action.outcome.result_kind if isinstance(action, StreamingFinishAction) else "success"
        next_sequence = self._emit(
            {**state, "next_sequence": next_sequence},
            AgentEventType.RUN_FINISHED,
            {"status": "completed", "resultKind": result_kind},
        )
        if private is not None:
            private.results[state["run_id"]] = AgentRunResult(
                state["run_id"],
                "finished",
                final_text=text,
            )
        return {"next_sequence": next_sequence, "phase": "finished", "action_kind": ""}

    @staticmethod
    def _invalid_node(_state: _PersistentGraphState) -> dict[str, Any]:
        raise RuntimeFailure("invalid_model_action", "Model returned an unsupported action")

    def _fail(self, run_id: str, failure: RuntimeFailure) -> AgentRunResult:
        state = self._state(run_id)
        if state is not None:
            state = {
                **state,
                "next_sequence": max(
                    state.get("next_sequence", 0),
                    self._emitted_next_sequence.get(run_id, 0),
                ),
            }
            next_sequence = self._emit(
                state,
                AgentEventType.RUN_ERROR,
                {"code": failure.code, "summary": failure.summary},
            )
            self._graph.update_state(
                self._config(run_id),
                {"phase": "failed", "error_code": failure.code, "next_sequence": next_sequence},
            )
        return AgentRunResult(run_id, "error", error_code=failure.code)

    def _state(self, run_id: str) -> _PersistentGraphState | None:
        snapshot = self._graph.get_state(self._config(run_id))
        values = dict(snapshot.values)
        return values if values else None

    @staticmethod
    def _config(run_id: str) -> dict[str, dict[str, str]]:
        return {"configurable": {"thread_id": run_id}}

    def _emit(
        self,
        state: _PersistentGraphState,
        event_type: AgentEventType | str,
        payload: dict[str, Any],
    ) -> int:
        emitter = AgentEventEmitter(state["run_id"], self.event_sink, state.get("next_sequence", 0))
        emitter.emit(event_type, payload)
        self._emitted_next_sequence[state["run_id"]] = emitter.next_sequence
        return emitter.next_sequence

    def _authorize_tool(
        self,
        action: ToolRequestAction,
        state: _PersistentGraphState,
        registry: EffectiveRegistry,
    ) -> CapabilityManifest:
        if state["tools"] >= self.limits.max_tools:
            raise RuntimeFailure("tool_limit", "Agent tool limit reached")
        manifest = self._manifest(action.capability_id, registry)
        try:
            Draft202012Validator(manifest.input_schema).validate(action.arguments)
        except ValidationError as error:
            raise RuntimeFailure("invalid_tool_arguments", "Tool arguments failed schema validation") from error
        decision = self.policy.authorize(
            action,
            manifest,
            set(state["authorized_scopes"]),
            set(state.get("approved_tool_call_ids", ())),
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
        encoded = repr(data).encode("utf-8")
        if len(encoded) > self.limits.max_observation_bytes:
            raise RuntimeFailure("observation_too_large", "Tool observation exceeds safe limit")
        return ToolObservation(action.tool_call_id, action.capability_id, data)


def _digest(value: str) -> str:
    return sha256(value.encode("utf-8")).hexdigest()


def _safe_tool_reference(
    action: ToolRequestAction,
    manifest: CapabilityManifest,
    registry_revision: str,
    *,
    expires_at: datetime,
) -> dict[str, Any]:
    return {
        "toolCallId": action.tool_call_id,
        "capabilityId": action.capability_id,
        "schemaVersion": manifest.schema_version,
        "registryRevision": registry_revision,
        "requestedScopes": tuple(action.requested_scopes),
        "idempotencyKey": action.idempotency_key,
        "argumentsDigest": _arguments_digest(action.arguments),
        "requestRef": _digest(f"{action.tool_call_id}:{action.capability_id}:{uuid4().hex}"),
        "expiresAt": expires_at.astimezone(UTC).isoformat().replace("+00:00", "Z"),
    }


def _safe_tool_event(action: ToolRequestAction, location: str) -> dict[str, Any]:
    return {
        "toolCallId": action.tool_call_id,
        "capabilityId": action.capability_id,
        "executionLocation": location,
        "requestedScopes": list(action.requested_scopes),
    }


def _arguments_digest(arguments: dict[str, Any]) -> str:
    return _digest(json.dumps(arguments, ensure_ascii=False, separators=(",", ":"), sort_keys=True))


def _transient_device_tool_request(
    action: ToolRequestAction,
    reference: dict[str, Any],
) -> dict[str, Any]:
    """Build the device request for the live SSE stream only.

    The function is called outside graph nodes after an interrupt is observed.
    Its return value is never placed in graph state or an interrupt payload, so
    it remains available to the connected device without entering LangGraph's
    persistent SQLite checkpoint.
    """

    return {
        "toolCallId": action.tool_call_id,
        "capabilityId": action.capability_id,
        "schemaVersion": reference["schemaVersion"],
        "registryRevision": reference["registryRevision"],
        "requestedScopes": list(action.requested_scopes),
        "arguments": action.arguments,
        "idempotencyKey": action.idempotency_key,
        "requestRef": reference["requestRef"],
        # This request is deliberately live-stream-only, but the device still
        # needs an explicit short expiry before it may execute a local action.
        # Omitting it makes otherwise-valid requests fail closed on the client.
        "expiresAt": reference["expiresAt"],
    }


def _safe_approval_reference(
    action: ApprovalInterruptAction,
    *,
    expires_at: datetime,
) -> dict[str, Any]:
    return {
        "approvalId": action.approval_id,
        "toolCallId": action.tool_call_id,
        "capabilityId": action.capability_id,
        "requestedScopes": tuple(action.requested_scopes),
        "idempotencyKey": action.idempotency_key,
        "approvalRef": _digest(f"{action.approval_id}:{action.tool_call_id}:{uuid4().hex}"),
        "expiresAt": expires_at.astimezone(UTC).isoformat().replace("+00:00", "Z"),
    }


def _is_expired(value: Any, *, now: datetime) -> bool:
    if not isinstance(value, str) or not value.endswith("Z"):
        return True
    try:
        expires_at = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError:
        return True
    return now.astimezone(UTC) >= expires_at.astimezone(UTC)


def _observation_digest(observation: dict[str, Any]) -> str:
    return _digest(
        json.dumps(
            observation,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        )
    )


__all__ = ["NativeLangGraphAgentRuntime"]
