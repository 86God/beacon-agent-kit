from __future__ import annotations

import json
from pathlib import Path

from beacon_agent_runtime import ProtocolFailure, ProtocolNegotiationResult, negotiate_protocol_version
from beacon_agent_runtime.reducer import EventCollisionError


ROOT = Path(__file__).resolve().parents[2]


def test_shared_negotiation_cases_match_expected_results() -> None:
    cases = json.loads(
        (ROOT / "contracts" / "fixtures" / "protocol-negotiation-cases.json").read_text(
            encoding="utf-8"
        )
    )

    for item in cases:
        result = negotiate_protocol_version(
            local_supported=item["localSupported"],
            peer_supported=item["peerSupported"],
            diagnostic_id=item["diagnosticId"],
        )
        assert isinstance(result, ProtocolNegotiationResult)
        assert result.model_dump(by_alias=True) == item["expected"], item["name"]
        assert json.loads(result.model_dump_json(by_alias=True)) == item["expected"]


def test_replay_errors_map_to_stable_public_failures() -> None:
    failure = EventCollisionError("private-event-id").public_failure("diag-collision")

    assert isinstance(failure, ProtocolFailure)
    assert failure.model_dump(by_alias=True) == {
        "code": "protocol.event_collision",
        "retryable": False,
        "diagnosticId": "diag-collision",
    }
    assert "private-event-id" not in failure.model_dump_json()


def test_malformed_python_offers_return_public_incompatible_failure() -> None:
    malformed_offers = [[True], ["2"], [2.5], [2**31]]

    for offer in malformed_offers:
        result = negotiate_protocol_version(
            local_supported=offer,  # type: ignore[arg-type]
            peer_supported=[2],
            diagnostic_id="diag-malformed-offer",
        )
        assert result.kind == "incompatible"
        assert result.failure is not None
        assert result.failure.code == "protocol.invalid_version_offer"
