"""Staged intent routing and constrained model-selection tests."""

from __future__ import annotations

from dataclasses import dataclass

import pytest

from beacon_agent_runtime.capabilities import CapabilityManifest
from beacon_agent_runtime.registry import EffectiveRegistry
from beacon_agent_runtime.routing import (
    InvalidRerankerSelection,
    RouteContext,
    StagedIntentRouter,
)
from beacon_agent_runtime.providers import RerankResult


def capability(
    identifier: str,
    *,
    kind: str = "tool",
    risk: str = "read_only",
    tags: tuple[str, ...] = ("training",),
) -> CapabilityManifest:
    return CapabilityManifest(
        schemaVersion=2,
        id=identifier,
        version="1.0.0",
        kind=kind,
        title=identifier,
        description=f"Capability {identifier}",
        intentExamples=(identifier.replace(".", " "),),
        inputSchema={"type": "object"},
        outputSchema={"type": "object"},
        executionLocation="device",
        risk=risk,
        requiredScopes=("training.read",),
        confirmation="always" if risk in {"consequential_write", "destructive"} else "never",
        idempotency="required" if risk in {"consequential_write", "destructive"} else "none",
        dependencies=(),
        tags=tags,
        fallback="text_summary",
    )


@dataclass
class FixedRetriever:
    identifiers: tuple[str, ...]

    def retrieve(
        self,
        query: str,
        capabilities: tuple[CapabilityManifest, ...],
        limit: int,
    ) -> tuple[str, ...]:
        return self.identifiers[:limit]


@dataclass
class FixedReranker:
    result: RerankResult

    def rerank(
        self,
        query: str,
        candidate_ids: tuple[str, ...],
        context: RouteContext,
    ) -> RerankResult:
        return self.result


def registry(*items: CapabilityManifest) -> EffectiveRegistry:
    return EffectiveRegistry(revision="registry-7", capabilities=items)


def test_host_resolved_explicit_date_is_preserved_for_workflow() -> None:
    draft = capability("training.plan.draft", kind="workflow", risk="reversible_draft")
    router = StagedIntentRouter(
        retriever=FixedRetriever((draft.id,)),
        reranker=FixedReranker(RerankResult((draft.id,), 0.96, ("Explicit training request",))),
    )

    decision = router.route(
        "安排一下明天练肩",
        registry(draft),
        RouteContext(resolved_date="2026-08-09"),
    )

    assert decision.selected_ids == (draft.id,)
    assert decision.planner_action == "workflow"
    assert decision.resolved_date == "2026-08-09"
    assert decision.required_clarification is None


def test_active_approval_and_pending_workflow_take_precedence() -> None:
    draft = capability("training.plan.draft", kind="workflow", risk="reversible_draft")
    commit = capability("training.plan.commit", risk="consequential_write")
    router = StagedIntentRouter(
        retriever=FixedRetriever((draft.id,)),
        reranker=FixedReranker(RerankResult((draft.id,), 0.99, ("Would pick draft",))),
    )

    approval = router.route(
        "确认",
        registry(draft, commit),
        RouteContext(active_approval_capability_id=commit.id, resolved_date="2026-08-09"),
    )
    workflow = router.route(
        "替换第二个动作",
        registry(draft, commit),
        RouteContext(pending_workflow_id=draft.id, resolved_date="2026-08-09"),
    )

    assert approval.selected_ids == (commit.id,)
    assert approval.safe_reasons == ("Active approval continuation",)
    assert workflow.selected_ids == (draft.id,)
    assert workflow.safe_reasons == ("Pending workflow continuation",)


def test_reranker_cannot_select_disabled_capability() -> None:
    enabled = capability("training.context.read")
    router = StagedIntentRouter(
        retriever=FixedRetriever((enabled.id,)),
        reranker=FixedReranker(
            RerankResult(("training.plan.commit",), 0.99, ("Model attempted bypass",))
        ),
    )

    with pytest.raises(InvalidRerankerSelection):
        router.route("确认计划", registry(enabled), RouteContext())


def test_low_confidence_consequential_ambiguity_requires_clarification() -> None:
    commit = capability("training.plan.commit", risk="consequential_write")
    router = StagedIntentRouter(
        retriever=FixedRetriever((commit.id,)),
        reranker=FixedReranker(RerankResult((commit.id,), 0.55, ("Possible write",))),
    )

    decision = router.route("帮我改一下", registry(commit), RouteContext())

    assert decision.selected_ids == ()
    assert decision.planner_action == "clarify"
    assert decision.required_clarification == "请确认要修改的记录、日期和写入范围。"


def test_read_only_lookup_can_proceed_without_consequential_clarification() -> None:
    lookup = capability("training.history.read", risk="read_only")
    router = StagedIntentRouter(
        retriever=FixedRetriever((lookup.id,)),
        reranker=FixedReranker(RerankResult((lookup.id,), 0.52, ("History lookup",))),
    )

    decision = router.route("看看最近训练", registry(lookup), RouteContext())

    assert decision.selected_ids == (lookup.id,)
    assert decision.planner_action == "tool"
    assert decision.required_clarification is None


def test_manifest_tag_fallback_never_leaves_effective_registry() -> None:
    shoulder = capability("training.shoulder.read", tags=("肩", "shoulder"))
    sleep = capability("sleep.summary", tags=("睡眠", "sleep"))

    class OfflineRetriever:
        def retrieve(self, *args: object, **kwargs: object) -> tuple[str, ...]:
            raise ConnectionError("retrieval unavailable")

    router = StagedIntentRouter(retriever=OfflineRetriever(), reranker=None)
    decision = router.route("今天练肩", registry(shoulder, sleep), RouteContext())

    assert decision.candidate_ids == (shoulder.id,)
    assert decision.selected_ids == (shoulder.id,)

