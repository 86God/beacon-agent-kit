"""Deterministic run budgets shared by gateway and mobile clients.

All timestamps are caller-supplied monotonic seconds.  The state therefore has
no hidden wall-clock dependency and can be verified with a virtual clock.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum


class RunKind(StrEnum):
    CHAT = "chat"
    DRAFT = "draft"
    IMAGE = "image"


class RunBudgetDecision(StrEnum):
    CONTINUE = "continue"
    SHOW_WAITING = "show_waiting"
    CONNECTION_TIMEOUT = "connection_timeout"
    TOOL_TIMEOUT = "tool_timeout"
    SEMANTIC_TIMEOUT = "semantic_timeout"
    TOTAL_TIMEOUT = "total_timeout"
    APPROVAL_EXPIRED = "approval_expired"
    CANCELLED = "cancelled"


@dataclass(frozen=True)
class RunBudgetPolicy:
    connect_seconds: float = 10
    tool_seconds: float = 5
    semantic_notice_seconds: float = 15
    semantic_timeout_seconds: float = 30
    total_seconds: float = 90
    fallback_seconds: float = 15
    max_transport_retries: int = 1
    max_text_fallbacks: int = 1

    @classmethod
    def for_kind(cls, kind: RunKind) -> "RunBudgetPolicy":
        if kind is RunKind.DRAFT:
            return cls(total_seconds=120)
        if kind is RunKind.IMAGE:
            return cls(tool_seconds=45, total_seconds=120)
        return cls()

    def __post_init__(self) -> None:
        values = (
            self.connect_seconds,
            self.tool_seconds,
            self.semantic_notice_seconds,
            self.semantic_timeout_seconds,
            self.total_seconds,
            self.fallback_seconds,
        )
        if any(value <= 0 for value in values):
            raise ValueError("run_budget_duration_must_be_positive")
        if self.semantic_notice_seconds >= self.semantic_timeout_seconds:
            raise ValueError("run_budget_notice_must_precede_timeout")
        if self.semantic_timeout_seconds > self.total_seconds:
            raise ValueError("run_budget_semantic_timeout_exceeds_total")
        if self.max_transport_retries < 0 or self.max_text_fallbacks < 0:
            raise ValueError("run_budget_attempt_limit_must_not_be_negative")


class RunBudgetState:
    """One run's absolute and semantic deadlines.

    Resume starts a fresh connection/semantic segment but never grants a new
    total budget.  Transport heartbeats intentionally do nothing.
    """

    def __init__(
        self,
        *,
        started_at: float,
        policy: RunBudgetPolicy | None = None,
    ) -> None:
        self.policy = policy or RunBudgetPolicy()
        self.started_at = started_at
        self.absolute_deadline = started_at + self.policy.total_seconds
        self.segment_started_at = started_at
        self.last_semantic_progress_at = started_at
        self.connected = False
        self.tool_started_at: float | None = None
        self.approval_expires_at: float | None = None
        self.cancelled = False
        self.terminal = False
        self.transport_retry_count = 0
        self.text_fallback_count = 0

    def record_heartbeat(self, *, at: float) -> None:
        del at

    def record_connected(self, *, at: float) -> None:
        if self.terminal:
            return
        self.connected = True
        self.record_semantic_progress(at=at)

    def record_semantic_progress(self, *, at: float) -> None:
        if self.terminal:
            return
        self.last_semantic_progress_at = max(self.last_semantic_progress_at, at)

    def start_tool(self, *, at: float) -> None:
        if self.terminal:
            return
        self.tool_started_at = at
        self.record_semantic_progress(at=at)

    def finish_tool(self, *, at: float) -> None:
        if self.terminal:
            return
        self.tool_started_at = None
        self.record_semantic_progress(at=at)

    def resume(self, *, at: float) -> None:
        if self.terminal:
            return
        self.segment_started_at = at
        self.last_semantic_progress_at = at
        self.connected = False
        self.tool_started_at = None
        self.approval_expires_at = None

    def wait_for_approval(self, *, expires_at: float) -> None:
        if self.terminal:
            return
        self.approval_expires_at = expires_at
        self.tool_started_at = None

    def cancel(self) -> None:
        self.cancelled = True
        self.terminal = True

    def finish(self) -> None:
        self.terminal = True

    def claim_transport_retry(self, *, at: float) -> bool:
        if (
            self.terminal
            or at >= self.absolute_deadline
            or self.transport_retry_count >= self.policy.max_transport_retries
        ):
            return False
        self.transport_retry_count += 1
        return True

    def claim_text_fallback(self, *, at: float) -> bool:
        if (
            self.terminal
            or at >= self.absolute_deadline
            or self.text_fallback_count >= self.policy.max_text_fallbacks
            or self.remaining_seconds(at=at) <= 0
        ):
            return False
        self.text_fallback_count += 1
        return True

    def remaining_seconds(self, *, at: float) -> float:
        return max(0, self.absolute_deadline - at)

    def fallback_deadline(self, *, at: float) -> float:
        return min(self.absolute_deadline, at + self.policy.fallback_seconds)

    def evaluate(self, *, at: float) -> RunBudgetDecision:
        if self.cancelled:
            return RunBudgetDecision.CANCELLED
        if self.terminal:
            return RunBudgetDecision.CONTINUE
        if at >= self.absolute_deadline:
            return RunBudgetDecision.TOTAL_TIMEOUT
        if self.approval_expires_at is not None:
            if at >= self.approval_expires_at:
                return RunBudgetDecision.APPROVAL_EXPIRED
            return RunBudgetDecision.CONTINUE
        if self.tool_started_at is not None:
            if at - self.tool_started_at >= self.policy.tool_seconds:
                return RunBudgetDecision.TOOL_TIMEOUT
        elif not self.connected and at - self.segment_started_at >= self.policy.connect_seconds:
            return RunBudgetDecision.CONNECTION_TIMEOUT
        semantic_elapsed = at - self.last_semantic_progress_at
        if semantic_elapsed >= self.policy.semantic_timeout_seconds:
            return RunBudgetDecision.SEMANTIC_TIMEOUT
        if semantic_elapsed >= self.policy.semantic_notice_seconds:
            return RunBudgetDecision.SHOW_WAITING
        return RunBudgetDecision.CONTINUE


def is_semantic_event(event_type: str, payload: dict | None = None) -> bool:
    """Classify public events without treating keep-alives as progress."""

    if event_type in {"heartbeat", "ping", "transport.heartbeat"}:
        return False
    if event_type == "text.delta":
        return bool((payload or {}).get("delta"))
    return event_type in {
        "run.started",
        "step.started",
        "step.finished",
        "tool.start",
        "tool.result",
        "tool.end",
        "tool.started",
        "tool.finished",
        "run.interrupted",
        "run.finished",
        "run.error",
        "permission.denied",
        "a2ui.patch",
        "a2ui.snapshot",
        "state.delta",
    }
