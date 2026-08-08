"""Staged, constrained intent routing over one effective registry snapshot."""

from __future__ import annotations

from dataclasses import dataclass

from .capabilities import CapabilityKind, CapabilityRisk
from .providers import (
    CapabilityReranker,
    CapabilityRetriever,
    LexicalCapabilityRetriever,
    RerankResult,
)
from .registry import EffectiveRegistry


class RoutingError(ValueError):
    pass


class InvalidRerankerSelection(RoutingError):
    pass


@dataclass(frozen=True)
class RouteContext:
    pending_workflow_id: str | None = None
    active_approval_capability_id: str | None = None
    explicit_capability_id: str | None = None
    resolved_date: str | None = None
    attachment_class: str | None = None


@dataclass(frozen=True)
class RouteDecision:
    registry_revision: str
    candidate_ids: tuple[str, ...]
    selected_ids: tuple[str, ...]
    confidence: float
    safe_reasons: tuple[str, ...]
    required_clarification: str | None
    planner_action: str
    resolved_date: str | None


class StagedIntentRouter:
    def __init__(
        self,
        *,
        retriever: CapabilityRetriever,
        reranker: CapabilityReranker | None,
        candidate_limit: int = 8,
        consequential_confidence: float = 0.8,
    ) -> None:
        self.retriever = retriever
        self.reranker = reranker
        self.candidate_limit = candidate_limit
        self.consequential_confidence = consequential_confidence
        self._fallback = LexicalCapabilityRetriever()

    def route(
        self,
        query: str,
        registry: EffectiveRegistry,
        context: RouteContext,
    ) -> RouteDecision:
        available = {item.id: item for item in registry.capabilities}

        precedence = (
            (context.pending_workflow_id, "Pending workflow continuation"),
            (context.active_approval_capability_id, "Active approval continuation"),
            (context.explicit_capability_id, "Explicit structured capability"),
        )
        for identifier, reason in precedence:
            if identifier and identifier in available:
                item = available[identifier]
                return RouteDecision(
                    registry_revision=registry.revision,
                    candidate_ids=(identifier,),
                    selected_ids=(identifier,),
                    confidence=1.0,
                    safe_reasons=(reason,),
                    required_clarification=None,
                    planner_action=_planner_action(item.kind),
                    resolved_date=context.resolved_date,
                )

        candidates = self._retrieve(query, registry, context)
        if not candidates:
            return RouteDecision(
                registry_revision=registry.revision,
                candidate_ids=(),
                selected_ids=(),
                confidence=0.0,
                safe_reasons=("No eligible capability candidate",),
                required_clarification=None,
                planner_action="direct_answer",
                resolved_date=context.resolved_date,
            )

        reranked = (
            self.reranker.rerank(query, candidates, context)
            if self.reranker is not None
            else RerankResult((candidates[0],), 0.6, ("Manifest tag fallback",))
        )
        if not set(reranked.selected_ids) <= set(candidates):
            raise InvalidRerankerSelection("reranker selected outside supplied candidates")
        selected = tuple(identifier for identifier in reranked.selected_ids if identifier in available)
        if not selected:
            return RouteDecision(
                registry_revision=registry.revision,
                candidate_ids=candidates,
                selected_ids=(),
                confidence=reranked.confidence,
                safe_reasons=reranked.safe_reasons,
                required_clarification=None,
                planner_action="direct_answer",
                resolved_date=context.resolved_date,
            )

        if any(
            available[identifier].risk in {CapabilityRisk.CONSEQUENTIAL_WRITE, CapabilityRisk.DESTRUCTIVE}
            for identifier in selected
        ) and reranked.confidence < self.consequential_confidence:
            return RouteDecision(
                registry_revision=registry.revision,
                candidate_ids=candidates,
                selected_ids=(),
                confidence=reranked.confidence,
                safe_reasons=reranked.safe_reasons,
                required_clarification="请确认要修改的记录、日期和写入范围。",
                planner_action="clarify",
                resolved_date=context.resolved_date,
            )

        return RouteDecision(
            registry_revision=registry.revision,
            candidate_ids=candidates,
            selected_ids=selected,
            confidence=reranked.confidence,
            safe_reasons=reranked.safe_reasons,
            required_clarification=None,
            planner_action=_planner_action(available[selected[0]].kind),
            resolved_date=context.resolved_date,
        )

    def _retrieve(
        self,
        query: str,
        registry: EffectiveRegistry,
        context: RouteContext,
    ) -> tuple[str, ...]:
        capabilities = registry.capabilities
        available = {item.id for item in capabilities}
        retrieval_query = " ".join(
            part for part in (query, context.attachment_class) if part
        )
        try:
            raw = self.retriever.retrieve(retrieval_query, capabilities, self.candidate_limit)
        except (ConnectionError, TimeoutError):
            raw = self._fallback.retrieve(retrieval_query, capabilities, self.candidate_limit)
        return tuple(dict.fromkeys(identifier for identifier in raw if identifier in available))


def _planner_action(kind: CapabilityKind) -> str:
    return "workflow" if kind == CapabilityKind.WORKFLOW else "tool"
