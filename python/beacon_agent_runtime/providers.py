"""Replaceable provider contracts used by routing and runtime layers."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol, TYPE_CHECKING

from .capabilities import CapabilityManifest

if TYPE_CHECKING:
    from .routing import RouteContext


class CapabilityRetriever(Protocol):
    def retrieve(
        self,
        query: str,
        capabilities: tuple[CapabilityManifest, ...],
        limit: int,
    ) -> tuple[str, ...]: ...


@dataclass(frozen=True)
class RerankResult:
    selected_ids: tuple[str, ...]
    confidence: float
    safe_reasons: tuple[str, ...]


class CapabilityReranker(Protocol):
    def rerank(
        self,
        query: str,
        candidate_ids: tuple[str, ...],
        context: RouteContext,
    ) -> RerankResult: ...


class LexicalCapabilityRetriever:
    """Offline-only fallback driven entirely by manifest declarations."""

    def retrieve(
        self,
        query: str,
        capabilities: tuple[CapabilityManifest, ...],
        limit: int,
    ) -> tuple[str, ...]:
        normalized = query.casefold()
        scored: list[tuple[int, str]] = []
        for capability in capabilities:
            terms = (*capability.tags, *capability.intent_examples)
            score = sum(1 for term in terms if term.casefold() in normalized)
            if score:
                scored.append((score, capability.id))
        scored.sort(key=lambda item: (-item[0], item[1]))
        return tuple(identifier for _, identifier in scored[:limit])
