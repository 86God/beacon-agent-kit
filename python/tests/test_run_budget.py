from beacon_agent_runtime.run_budget import (
    RunBudgetDecision,
    RunBudgetPolicy,
    RunBudgetState,
    RunKind,
    is_semantic_event,
)


def test_heartbeat_does_not_extend_semantic_deadline() -> None:
    state = RunBudgetState(started_at=0)
    state.record_connected(at=0)
    for second in range(1, 31):
        state.record_heartbeat(at=float(second))

    assert state.evaluate(at=15) is RunBudgetDecision.SHOW_WAITING
    assert state.evaluate(at=30) is RunBudgetDecision.SEMANTIC_TIMEOUT


def test_resume_resets_segment_but_not_absolute_deadline() -> None:
    state = RunBudgetState(started_at=0)
    state.record_connected(at=0)
    state.resume(at=25)
    state.record_connected(at=26)

    assert state.evaluate(at=50) is RunBudgetDecision.SHOW_WAITING
    assert state.evaluate(at=90) is RunBudgetDecision.TOTAL_TIMEOUT


def test_tool_and_connection_have_distinct_deadlines() -> None:
    policy = RunBudgetPolicy(connect_seconds=10, tool_seconds=5)
    connecting = RunBudgetState(started_at=0, policy=policy)
    assert connecting.evaluate(at=10) is RunBudgetDecision.CONNECTION_TIMEOUT

    tool = RunBudgetState(started_at=0, policy=policy)
    tool.record_connected(at=0)
    tool.start_tool(at=1)
    assert tool.evaluate(at=6) is RunBudgetDecision.TOOL_TIMEOUT


def test_retry_and_fallback_share_the_original_deadline_and_count() -> None:
    state = RunBudgetState(started_at=0)
    assert state.claim_transport_retry(at=1)
    assert not state.claim_transport_retry(at=2)
    assert state.claim_text_fallback(at=80)
    assert state.fallback_deadline(at=80) == 90
    assert not state.claim_text_fallback(at=81)
    assert not state.claim_transport_retry(at=90)


def test_cancel_and_approval_expiry_are_terminal_decisions() -> None:
    approval = RunBudgetState(started_at=0)
    approval.wait_for_approval(expires_at=20)
    assert approval.evaluate(at=19) is RunBudgetDecision.CONTINUE
    assert approval.evaluate(at=20) is RunBudgetDecision.APPROVAL_EXPIRED

    cancelled = RunBudgetState(started_at=0)
    cancelled.cancel()
    cancelled.record_semantic_progress(at=5)
    assert cancelled.evaluate(at=5) is RunBudgetDecision.CANCELLED


def test_kind_defaults_and_semantic_event_classification() -> None:
    assert RunBudgetPolicy.for_kind(RunKind.CHAT).total_seconds == 90
    assert RunBudgetPolicy.for_kind(RunKind.DRAFT).total_seconds == 120
    assert RunBudgetPolicy.for_kind(RunKind.IMAGE).tool_seconds == 45
    assert not is_semantic_event("heartbeat")
    assert not is_semantic_event("text.delta", {"delta": ""})
    assert is_semantic_event("tool.start")
    assert is_semantic_event("tool.result")
    assert is_semantic_event("tool.end")
    assert is_semantic_event("tool.started")
    assert is_semantic_event("text.delta", {"delta": "完成"})
