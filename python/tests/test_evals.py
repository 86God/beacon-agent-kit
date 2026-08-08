"""Deterministic regression metrics for routing, tools, policy, and surfaces."""

from beacon_agent_runtime.evals import (
    AgentEvaluationCase,
    AgentEvaluationObservation,
    evaluate_agent_runs,
)


def test_evaluation_measures_complete_agent_quality_vector() -> None:
    cases = (
        AgentEvaluationCase(
            id="training-tomorrow",
            expected_capability_ids=("training.context.read", "training.plan.draft"),
            expected_clarification=False,
            allowed_tool_capability_ids=(
                "training.context.read",
                "exercise.candidates.search",
                "training.plan.draft",
            ),
            expects_completion=True,
            expects_surface=True,
            expects_task_success=True,
        ),
        AgentEvaluationCase(
            id="ambiguous-delete",
            expected_capability_ids=("record.delete",),
            expected_clarification=True,
            allowed_tool_capability_ids=(),
            expects_completion=False,
            expects_surface=False,
            expects_task_success=False,
        ),
    )
    observations = (
        AgentEvaluationObservation(
            case_id="training-tomorrow",
            routed_capability_ids=("training.context.read", "training.plan.draft"),
            clarification_requested=False,
            tool_capability_ids=(
                "training.context.read",
                "exercise.candidates.search",
                "training.plan.draft",
            ),
            policy_violation_count=0,
            completed=True,
            surface_fallback_count=0,
            task_succeeded=True,
        ),
        AgentEvaluationObservation(
            case_id="ambiguous-delete",
            routed_capability_ids=("record.delete",),
            clarification_requested=True,
            tool_capability_ids=(),
            policy_violation_count=0,
            completed=False,
            surface_fallback_count=0,
            task_succeeded=False,
        ),
    )

    report = evaluate_agent_runs(cases, observations)

    assert report.route_recall == 1.0
    assert report.capability_precision == 1.0
    assert report.unnecessary_tool_call_rate == 0.0
    assert report.clarification_correctness == 1.0
    assert report.policy_violation_rate == 0.0
    assert report.completion_correctness == 1.0
    assert report.surface_fallback_rate == 0.0
    assert report.task_success_rate == 1.0
    assert report.case_count == 2


def test_evaluation_exposes_route_tool_policy_and_surface_failures() -> None:
    case = AgentEvaluationCase(
        id="meal-summary",
        expected_capability_ids=("nutrition.records.read",),
        expected_clarification=False,
        allowed_tool_capability_ids=("nutrition.records.read",),
        expects_completion=True,
        expects_surface=True,
        expects_task_success=True,
    )
    observation = AgentEvaluationObservation(
        case_id="meal-summary",
        routed_capability_ids=("training.records.read",),
        clarification_requested=True,
        tool_capability_ids=("training.records.read", "nutrition.records.read"),
        policy_violation_count=1,
        completed=False,
        surface_fallback_count=1,
        task_succeeded=False,
    )

    report = evaluate_agent_runs((case,), (observation,))

    assert report.route_recall == 0.0
    assert report.capability_precision == 0.0
    assert report.unnecessary_tool_call_rate == 0.5
    assert report.clarification_correctness == 0.0
    assert report.policy_violation_rate == 1.0
    assert report.completion_correctness == 0.0
    assert report.surface_fallback_rate == 1.0
    assert report.task_success_rate == 0.0
    assert report.failed_case_ids == ("meal-summary",)


def test_evaluation_rejects_missing_duplicate_and_unknown_observations() -> None:
    case = AgentEvaluationCase(
        id="one",
        expected_capability_ids=(),
        expected_clarification=False,
        allowed_tool_capability_ids=(),
        expects_completion=True,
        expects_surface=False,
        expects_task_success=True,
    )
    observation = AgentEvaluationObservation(
        case_id="one",
        routed_capability_ids=(),
        clarification_requested=False,
        tool_capability_ids=(),
        policy_violation_count=0,
        completed=True,
        surface_fallback_count=0,
        task_succeeded=True,
    )

    try:
        evaluate_agent_runs((case,), ())
        raise AssertionError("missing observation should fail")
    except ValueError as error:
        assert "missing observations" in str(error)

    try:
        evaluate_agent_runs((case,), (observation, observation))
        raise AssertionError("duplicate observation should fail")
    except ValueError as error:
        assert "duplicate observation" in str(error)

    unknown = AgentEvaluationObservation(
        case_id="other",
        routed_capability_ids=(),
        clarification_requested=False,
        tool_capability_ids=(),
        policy_violation_count=0,
        completed=True,
        surface_fallback_count=0,
        task_succeeded=True,
    )
    try:
        evaluate_agent_runs((case,), (unknown,))
        raise AssertionError("unknown observation should fail")
    except ValueError as error:
        assert "unknown case" in str(error)


def test_evaluation_rejects_invalid_negative_counts_and_duplicate_ids() -> None:
    try:
        AgentEvaluationObservation(
            case_id="bad",
            routed_capability_ids=(),
            clarification_requested=False,
            tool_capability_ids=(),
            policy_violation_count=-1,
            completed=False,
            surface_fallback_count=0,
            task_succeeded=False,
        )
        raise AssertionError("negative counts should fail")
    except ValueError as error:
        assert "non-negative" in str(error)

    try:
        AgentEvaluationCase(
            id="duplicate",
            expected_capability_ids=("a", "a"),
            expected_clarification=False,
            allowed_tool_capability_ids=(),
            expects_completion=True,
            expects_surface=False,
            expects_task_success=True,
        )
        raise AssertionError("duplicate capability IDs should fail")
    except ValueError as error:
        assert "duplicate expected capability" in str(error)
