"""Runtime selection for a reversible LangGraph rollout."""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum
from typing import Any, TypeAlias

from .native_langgraph_runtime import NativeLangGraphAgentRuntime
from .runtime import AgentRuntime


class RuntimeMode(StrEnum):
    """Server-selected execution mode; clients never choose a runtime."""

    LEGACY = "legacy"
    LANGGRAPH = "langgraph"
    SHADOW_COMPARE = "shadow_compare"


RuntimeClass: TypeAlias = type[Any]


@dataclass(frozen=True)
class RuntimeSelection:
    """The primary runtime and an optional no-side-effect comparison runtime."""

    primary: RuntimeClass
    shadow: RuntimeClass | None = None


def select_runtime(mode: RuntimeMode | str) -> RuntimeSelection:
    """Resolve a strictly server-owned, reversible runtime choice.

    LangGraph remains user-visible in every non-emergency mode.  Shadow mode
    runs the legacy runtime only as an isolated, no-side-effect comparator, so
    rollout telemetry cannot silently route a user back through old state.
    Hosts must instantiate the shadow with device interruption and a rejecting
    server dispatcher so it can never cause an additional write.
    """

    normalized = RuntimeMode(mode)
    if normalized is RuntimeMode.LEGACY:
        return RuntimeSelection(primary=AgentRuntime)
    if normalized is RuntimeMode.LANGGRAPH:
        return RuntimeSelection(primary=NativeLangGraphAgentRuntime)
    return RuntimeSelection(primary=NativeLangGraphAgentRuntime, shadow=AgentRuntime)


__all__ = ["RuntimeMode", "RuntimeSelection", "select_runtime"]
