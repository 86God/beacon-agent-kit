"""Provider-neutral offline evaluation contracts for Agent regressions."""

from __future__ import annotations

from dataclasses import dataclass


def _require_unique(values: tuple[str, ...], label: str) -> None:
    if len(values) != len(set(values)):
        raise ValueError(f"duplicate {label}")
    if any(not value for value in values):
        raise ValueError(f"{label} must be nonblank")


@dataclass(frozen=True)
class AgentEvaluationCase:
    id: str
    expected_capability_ids: tuple[str, ...]
    expected_clarification: bool
    allowed_tool_capability_ids: tuple[str, ...]
    expects_completion: bool
    expects_surface: bool
    expects_task_success: bool

    def __post_init__(self) -> None:
        if not self.id:
            raise ValueError("evaluation case id must be nonblank")
        _require_unique(self.expected_capability_ids, "expected capability ID")
        _require_unique(self.allowed_tool_capability_ids, "allowed tool capability ID")


@dataclass(frozen=True)
class AgentEvaluationObservation:
    case_id: str
    routed_capability_ids: tuple[str, ...]
    clarification_requested: bool
    tool_capability_ids: tuple[str, ...]
    policy_violation_count: int
    completed: bool
    surface_fallback_count: int
    task_succeeded: bool

    def __post_init__(self) -> None:
        if not self.case_id:
            raise ValueError("evaluation observation case_id must be nonblank")
        if self.policy_violation_count < 0 or self.surface_fallback_count < 0:
            raise ValueError("evaluation counts must be non-negative")
        _require_unique(self.routed_capability_ids, "routed capability ID")


@dataclass(frozen=True)
class AgentEvaluationReport:
    case_count: int
    route_recall: float
    capability_precision: float
    unnecessary_tool_call_rate: float
    clarification_correctness: float
    policy_violation_rate: float
    completion_correctness: float
    surface_fallback_rate: float
    task_success_rate: float
    failed_case_ids: tuple[str, ...]


def _ratio(numerator: int, denominator: int, *, empty: float = 1.0) -> float:
    if denominator == 0:
        return empty
    return round(numerator / denominator, 6)


def evaluate_agent_runs(
    cases: tuple[AgentEvaluationCase, ...],
    observations: tuple[AgentEvaluationObservation, ...],
) -> AgentEvaluationReport:
    """Evaluate observed runs against immutable cases, failing closed on fixture drift."""

    case_by_id: dict[str, AgentEvaluationCase] = {}
    for case in cases:
        if case.id in case_by_id:
            raise ValueError(f"duplicate evaluation case {case.id}")
        # Re-run validation so mutated or foreign dataclass-like inputs fail closed.
        _require_unique(case.expected_capability_ids, "expected capability ID")
        _require_unique(case.allowed_tool_capability_ids, "allowed tool capability ID")
        case_by_id[case.id] = case

    observation_by_id: dict[str, AgentEvaluationObservation] = {}
    for observation in observations:
        if observation.case_id not in case_by_id:
            raise ValueError(f"observation references unknown case {observation.case_id}")
        if observation.case_id in observation_by_id:
            raise ValueError(f"duplicate observation for {observation.case_id}")
        observation_by_id[observation.case_id] = observation

    missing = tuple(sorted(set(case_by_id) - set(observation_by_id)))
    if missing:
        raise ValueError(f"missing observations: {', '.join(missing)}")

    expected_route_count = 0
    matched_route_count = 0
    routed_count = 0
    correct_routed_count = 0
    tool_count = 0
    unnecessary_tool_count = 0
    correct_clarification_count = 0
    policy_violation_case_count = 0
    correct_completion_count = 0
    expected_surface_count = 0
    surface_fallback_case_count = 0
    correct_task_success_count = 0
    failed_case_ids: list[str] = []

    for case in cases:
        observation = observation_by_id[case.id]
        expected_routes = set(case.expected_capability_ids)
        actual_routes = set(observation.routed_capability_ids)
        expected_route_count += len(expected_routes)
        matched_route_count += len(expected_routes & actual_routes)
        routed_count += len(actual_routes)
        correct_routed_count += len(expected_routes & actual_routes)

        allowed_tools = set(case.allowed_tool_capability_ids)
        tool_count += len(observation.tool_capability_ids)
        unnecessary_tools = [
            capability_id
            for capability_id in observation.tool_capability_ids
            if capability_id not in allowed_tools
        ]
        unnecessary_tool_count += len(unnecessary_tools)

        clarification_correct = (
            observation.clarification_requested == case.expected_clarification
        )
        correct_clarification_count += int(clarification_correct)
        policy_ok = observation.policy_violation_count == 0
        policy_violation_case_count += int(not policy_ok)
        completion_correct = observation.completed == case.expects_completion
        correct_completion_count += int(completion_correct)
        if case.expects_surface:
            expected_surface_count += 1
            surface_fallback_case_count += int(observation.surface_fallback_count > 0)
        task_success_correct = observation.task_succeeded == case.expects_task_success
        correct_task_success_count += int(task_success_correct)

        route_correct = expected_routes == actual_routes
        surface_ok = not case.expects_surface or observation.surface_fallback_count == 0
        if not all(
            (
                route_correct,
                not unnecessary_tools,
                clarification_correct,
                policy_ok,
                completion_correct,
                surface_ok,
                task_success_correct,
            )
        ):
            failed_case_ids.append(case.id)

    case_count = len(cases)
    return AgentEvaluationReport(
        case_count=case_count,
        route_recall=_ratio(matched_route_count, expected_route_count),
        capability_precision=_ratio(correct_routed_count, routed_count),
        unnecessary_tool_call_rate=_ratio(
            unnecessary_tool_count, tool_count, empty=0.0
        ),
        clarification_correctness=_ratio(correct_clarification_count, case_count),
        policy_violation_rate=_ratio(
            policy_violation_case_count, case_count, empty=0.0
        ),
        completion_correctness=_ratio(correct_completion_count, case_count),
        surface_fallback_rate=_ratio(
            surface_fallback_case_count, expected_surface_count, empty=0.0
        ),
        task_success_rate=_ratio(correct_task_success_count, case_count),
        failed_case_ids=tuple(failed_case_ids),
    )
