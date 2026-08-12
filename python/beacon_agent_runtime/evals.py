"""Provider-neutral offline evaluation contracts for Agent regressions."""

from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path


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


@dataclass(frozen=True)
class AgentConformanceCase:
    """A deterministic cross-client protocol contract.

    This deliberately describes observable Agent Run behavior, rather than a
    provider prompt or hidden reasoning trace.  It can be replayed by any
    domain adapter without carrying a user's private records into the fixture.
    """

    id: str
    expected_event_types: tuple[str, ...]
    expected_tool_capability_ids: tuple[str, ...]
    expected_surface_kind: str | None
    expects_receipt: bool
    expected_run_state: str
    requires_device_private_data: bool

    def __post_init__(self) -> None:
        if not self.id:
            raise ValueError("conformance case id must be nonblank")
        if not self.expected_event_types or any(not value for value in self.expected_event_types):
            raise ValueError("expected event types must be nonblank")
        _require_unique(self.expected_tool_capability_ids, "expected tool capability ID")
        if not self.expected_run_state:
            raise ValueError("expected run state must be nonblank")


@dataclass(frozen=True)
class AgentConformanceObservation:
    case_id: str
    event_types: tuple[str, ...]
    tool_capability_ids: tuple[str, ...]
    surface_kind: str | None
    receipt_created: bool
    run_state: str
    remote_personal_data_sent: bool

    def __post_init__(self) -> None:
        if not self.case_id:
            raise ValueError("conformance observation case_id must be nonblank")
        if not self.event_types or any(not value for value in self.event_types):
            raise ValueError("observed event types must be nonblank")
        _require_unique(self.tool_capability_ids, "observed tool capability ID")
        if not self.run_state:
            raise ValueError("observed run state must be nonblank")


@dataclass(frozen=True)
class AgentConformanceReport:
    case_count: int
    failed_case_ids: tuple[str, ...]


def load_conformance_cases(path: str | Path) -> tuple[AgentConformanceCase, ...]:
    """Load versioned JSONL contracts and reject malformed fixture drift."""

    fixture_path = Path(path)
    # Conformance fixtures are published with this package, while callers may
    # execute tests from either the repository root or the Python package root.
    # Resolve a missing relative path against the repository so evaluation does
    # not depend on the current working directory.
    if not fixture_path.is_absolute() and not fixture_path.exists():
        fixture_path = Path(__file__).resolve().parents[2] / fixture_path
    cases: list[AgentConformanceCase] = []
    for line_number, line in enumerate(fixture_path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            payload = json.loads(line)
            cases.append(
                AgentConformanceCase(
                    id=payload["id"],
                    expected_event_types=tuple(payload["expected_event_types"]),
                    expected_tool_capability_ids=tuple(payload["expected_tool_capability_ids"]),
                    expected_surface_kind=payload.get("expected_surface_kind"),
                    expects_receipt=payload["expects_receipt"],
                    expected_run_state=payload["expected_run_state"],
                    requires_device_private_data=payload["requires_device_private_data"],
                )
            )
        except (KeyError, TypeError, json.JSONDecodeError, ValueError) as error:
            raise ValueError(f"invalid conformance fixture at line {line_number}") from error
    _require_unique(tuple(case.id for case in cases), "conformance case ID")
    return tuple(cases)


def evaluate_conformance_cases(
    cases: tuple[AgentConformanceCase, ...],
    observations: tuple[AgentConformanceObservation, ...],
) -> AgentConformanceReport:
    """Fail closed on protocol order, capability, surface, receipt and privacy drift."""

    observation_by_id = {observation.case_id: observation for observation in observations}
    if len(observation_by_id) != len(observations):
        raise ValueError("duplicate conformance observation")
    unknown = set(observation_by_id) - {case.id for case in cases}
    if unknown:
        raise ValueError(f"observation references unknown case: {', '.join(sorted(unknown))}")
    missing = {case.id for case in cases} - set(observation_by_id)
    if missing:
        raise ValueError(f"missing conformance observations: {', '.join(sorted(missing))}")

    failed_case_ids: list[str] = []
    for case in cases:
        observation = observation_by_id[case.id]
        is_valid = all(
            (
                observation.event_types == case.expected_event_types,
                observation.tool_capability_ids == case.expected_tool_capability_ids,
                observation.surface_kind == case.expected_surface_kind,
                observation.receipt_created == case.expects_receipt,
                observation.run_state == case.expected_run_state,
                not observation.remote_personal_data_sent,
            )
        )
        if not is_valid:
            failed_case_ids.append(case.id)
    return AgentConformanceReport(
        case_count=len(cases),
        failed_case_ids=tuple(failed_case_ids),
    )


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
