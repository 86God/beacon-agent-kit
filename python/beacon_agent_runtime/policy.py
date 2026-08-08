"""Kernel policy checks applied immediately before concrete execution."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

from .capabilities import CapabilityManifest, CapabilityRisk, IdempotencyPolicy
from .events import ToolRequestAction


@dataclass(frozen=True)
class PolicyDecision:
    allowed: bool
    safe_reason: str


class PolicyEngine(Protocol):
    def authorize(
        self,
        action: ToolRequestAction,
        manifest: CapabilityManifest,
        authorized_scopes: set[str],
        approved_tool_calls: set[str],
    ) -> PolicyDecision: ...


class DefaultPolicyEngine:
    def authorize(
        self,
        action: ToolRequestAction,
        manifest: CapabilityManifest,
        authorized_scopes: set[str],
        approved_tool_calls: set[str],
    ) -> PolicyDecision:
        required = set(manifest.required_scopes)
        if not required <= authorized_scopes:
            return PolicyDecision(False, "Required host scope is missing")
        if set(action.requested_scopes) != required:
            return PolicyDecision(False, "Requested scopes differ from manifest")
        if manifest.risk in {CapabilityRisk.CONSEQUENTIAL_WRITE, CapabilityRisk.DESTRUCTIVE}:
            if action.tool_call_id not in approved_tool_calls:
                return PolicyDecision(False, "Consequential action is not approved")
        if manifest.idempotency == IdempotencyPolicy.REQUIRED and not action.idempotency_key:
            return PolicyDecision(False, "Idempotency key is required")
        return PolicyDecision(True, "Host policy authorized execution")
