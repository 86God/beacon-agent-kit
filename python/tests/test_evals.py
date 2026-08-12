"""Deterministic regression metrics for routing, tools, policy, and surfaces."""

from beacon_agent_runtime.evals import (
    AgentConformanceObservation,
    AgentEvaluationCase,
    AgentEvaluationObservation,
    evaluate_agent_runs,
    evaluate_conformance_cases,
    load_conformance_cases,
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


def test_jianhao_migration_fixture_requires_real_local_tool_event_order() -> None:
    cases = load_conformance_cases("conformance/fixtures/jianhao-agent-migration.jsonl")

    assert {case.id for case in cases} == {
        "training-cross-date",
        "nutrition-summary",
        "nutrition-photo-review",
        "profile-query",
        "recovery-permission-unavailable",
        "cancelled-run",
        "tool-failure-reconnect",
    }
    training = next(case for case in cases if case.id == "training-cross-date")
    assert training.expected_tool_capability_ids == (
        "training.context.read",
        "exercise.candidates.search",
        "training.plan.draft",
        "training.plan.commit",
    )
    assert training.expected_surface_kind == "trainingPlanDraft"
    assert training.expects_receipt is True
    assert training.requires_device_private_data is True

    observations = tuple(
        AgentConformanceObservation(
            case_id=case.id,
            event_types=case.expected_event_types,
            tool_capability_ids=case.expected_tool_capability_ids,
            surface_kind=case.expected_surface_kind,
            receipt_created=case.expects_receipt,
            run_state=case.expected_run_state,
            remote_personal_data_sent=False,
        )
        for case in cases
    )

    report = evaluate_conformance_cases(cases, observations)

    assert report.case_count == len(cases)
    assert report.failed_case_ids == ()


def test_conformance_fixture_load_is_independent_of_the_current_working_directory() -> None:
    cases = load_conformance_cases("conformance/fixtures/jianhao-agent-migration.jsonl")

    assert cases
    assert cases[0].id == "training-cross-date"


def test_conformance_fails_closed_when_event_order_or_local_data_boundary_drifts() -> None:
    case = load_conformance_cases("conformance/fixtures/jianhao-agent-migration.jsonl")[0]
    observation = AgentConformanceObservation(
        case_id=case.id,
        event_types=tuple(reversed(case.expected_event_types)),
        tool_capability_ids=case.expected_tool_capability_ids,
        surface_kind=case.expected_surface_kind,
        receipt_created=case.expects_receipt,
        run_state=case.expected_run_state,
        remote_personal_data_sent=True,
    )

    report = evaluate_conformance_cases((case,), (observation,))

    assert report.failed_case_ids == (case.id,)
