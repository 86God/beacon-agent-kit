"""Language-neutral wire-schema conformance tests."""

from __future__ import annotations

import json
from copy import deepcopy
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator, ValidationError


ROOT = Path(__file__).resolve().parents[2]
SCHEMA_DIR = ROOT / "specs"


VALID_DOCUMENTS: dict[str, dict[str, object]] = {
    "agent-event.schema.json": {
        "schemaVersion": 2,
        "eventId": "event-1",
        "runId": "run-1",
        "sequence": 0,
        "type": "run.started",
        "payload": {"threadId": "thread-1"},
    },
    "capability-manifest.schema.json": {
        "schemaVersion": 2,
        "id": "training.plan.draft",
        "version": "1.0.0",
        "kind": "workflow",
        "title": "Draft a training plan",
        "description": "Builds a reversible draft for a requested date.",
        "intentExamples": ["Arrange shoulder training tomorrow"],
        "inputSchema": {"type": "object"},
        "outputSchema": {"type": "object"},
        "executionLocation": "device",
        "risk": "reversible_draft",
        "requiredScopes": ["training.read", "training.draft.write"],
        "confirmation": "before_commit",
        "idempotency": "required",
        "dependencies": ["training.context.read@^1"],
        "surface": "training.plan.draft@^1",
        "tags": ["training", "shoulder"],
        "fallback": "text_summary",
    },
    "run-input.schema.json": {
        "schemaVersion": 2,
        "runId": "run-1",
        "threadId": "thread-1",
        "message": {
            "id": "message-1",
            "role": "user",
            "content": "Arrange shoulder training tomorrow",
        },
        "registryRevision": "registry-7",
        "clientContext": {
            "locale": "en-US",
            "timeZone": "Asia/Shanghai",
            "currentDate": "2026-08-08",
        },
    },
    "route-decision.schema.json": {
        "schemaVersion": 2,
        "runId": "run-1",
        "registryRevision": "registry-7",
        "candidateIds": ["training.plan.draft"],
        "selectedIds": ["training.plan.draft"],
        "confidence": 0.96,
        "safeReasons": ["Explicit training request and date"],
        "requiredClarification": None,
        "plannerAction": "workflow",
    },
    "approval-request.schema.json": {
        "schemaVersion": 2,
        "approvalId": "approval-1",
        "runId": "run-1",
        "toolCallId": "tool-1",
        "capabilityId": "training.plan.commit",
        "summary": "Add this draft to tomorrow's training plan",
        "risk": "consequential_write",
        "requestedScopes": ["training.plan.write"],
        "expiresAt": "2026-08-08T12:00:00Z",
        "idempotencyKey": "run-1:tool-1",
    },
    "execution-receipt.schema.json": {
        "schemaVersion": 2,
        "receiptId": "receipt-1",
        "runId": "run-1",
        "toolCallId": "tool-1",
        "capabilityId": "training.plan.commit",
        "outcome": "committed",
        "committedAt": "2026-08-08T11:55:00Z",
        "idempotencyKey": "run-1:tool-1",
        "redactedResult": {"targetDate": "2026-08-09", "recordId": "local-7"},
    },
}


def load_schema(name: str) -> dict[str, object]:
    return json.loads((SCHEMA_DIR / name).read_text(encoding="utf-8"))


@pytest.mark.parametrize("schema_name", VALID_DOCUMENTS)
def test_schema_is_valid_draft_2020_12(schema_name: str) -> None:
    Draft202012Validator.check_schema(load_schema(schema_name))


@pytest.mark.parametrize(("schema_name", "document"), VALID_DOCUMENTS.items())
def test_valid_document_conforms(schema_name: str, document: dict[str, object]) -> None:
    Draft202012Validator(load_schema(schema_name)).validate(document)


@pytest.mark.parametrize(
    ("schema_name", "mutate"),
    [
        (
            "capability-manifest.schema.json",
            lambda value: value.update(version="latest"),
        ),
        (
            "capability-manifest.schema.json",
            lambda value: value.update(requiredScopes=[]),
        ),
        (
            "capability-manifest.schema.json",
            lambda value: value.update(executionLocation="downloaded"),
        ),
        (
            "run-input.schema.json",
            lambda value: value.update(userId="model-supplied-user"),
        ),
        (
            "approval-request.schema.json",
            lambda value: value.update(accountScope="model-supplied-scope"),
        ),
        (
            "route-decision.schema.json",
            lambda value: value.update(unknownRequiredMeaning=True),
        ),
    ],
)
def test_closed_schemas_reject_unsafe_or_unknown_fields(
    schema_name: str,
    mutate: object,
) -> None:
    document = deepcopy(VALID_DOCUMENTS[schema_name])
    mutate(document)  # type: ignore[operator]

    with pytest.raises(ValidationError):
        Draft202012Validator(load_schema(schema_name)).validate(document)

