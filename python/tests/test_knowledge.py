"""Provider-neutral knowledge-pack and citation contract tests."""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator, ValidationError as JSONSchemaError
from pydantic import ValidationError

from beacon_agent_runtime.knowledge import (
    EvidenceClaim,
    KnowledgeAnswer,
    KnowledgeCitation,
    KnowledgeManifest,
    KnowledgePassage,
    KnowledgeQuery,
    KnowledgeRetrievalResult,
    KnowledgeSource,
    validate_evidence_answer,
)


ROOT = Path(__file__).resolve().parents[2]


def source() -> KnowledgeSource:
    return KnowledgeSource(
        id="source.guideline",
        title="Public guideline",
        publisher="Example Authority",
        url="https://example.org/guideline",
        reuseStatus="original_summary_only",
        reviewedAt="2026-08-08T00:00:00Z",
    )


def manifest_document() -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "id": "example.knowledge",
        "version": "1.0.0",
        "locale": "zh-CN",
        "domain": "example",
        "sources": [source().model_dump(by_alias=True, mode="json")],
        "retrievalAdapter": "example.local.v1",
        "chunkSchema": {
            "type": "object",
            "required": ["id", "sourceId", "content"],
            "additionalProperties": False,
        },
        "citationPolicy": "required_for_evidence",
        "safetyDisclaimers": ["Not professional advice."],
        "excludedAdviceCategories": ["diagnosis"],
        "evaluationDatasetVersion": "1.0.0",
        "reviewExpiresAt": "2027-08-08T00:00:00Z",
    }


def test_manifest_and_schema_require_provenance_locale_version_and_citations() -> None:
    document = manifest_document()
    schema = json.loads((ROOT / "specs/knowledge-manifest.schema.json").read_text())
    Draft202012Validator.check_schema(schema)
    Draft202012Validator(schema).validate(document)

    parsed = KnowledgeManifest.model_validate(document)
    assert parsed.sources[0].id == "source.guideline"
    assert parsed.locale == "zh-CN"
    assert parsed.citation_policy == "required_for_evidence"


@pytest.mark.parametrize(
    ("container", "key"),
    [
        ("manifest", "version"),
        ("manifest", "locale"),
        ("manifest", "citationPolicy"),
        ("source", "id"),
        ("source", "url"),
        ("source", "reuseStatus"),
    ],
)
def test_missing_required_knowledge_metadata_fails_closed(container: str, key: str) -> None:
    document = manifest_document()
    if container == "manifest":
        document.pop(key)
    else:
        document["sources"][0].pop(key)  # type: ignore[index]

    schema = json.loads((ROOT / "specs/knowledge-manifest.schema.json").read_text())
    with pytest.raises(JSONSchemaError):
        Draft202012Validator(schema).validate(document)
    with pytest.raises(ValidationError):
        KnowledgeManifest.model_validate(document)


def test_evidence_marked_answer_must_cite_a_retrieved_passage() -> None:
    query = KnowledgeQuery(
        corpusId="example.knowledge",
        text="What is supported?",
        locale="zh-CN",
        topK=3,
    )
    passage = KnowledgePassage(
        id="passage-1",
        sourceId="source.guideline",
        content="An original summary of the source.",
        citationLabel="Example Authority",
    )
    result = KnowledgeRetrievalResult(query=query, passages=(passage,))
    cited = KnowledgeAnswer(
        text="The recommendation is evidence-based.",
        evidenceClaims=(EvidenceClaim(text="evidence-based", passageIds=("passage-1",)),),
        citations=(KnowledgeCitation(
            passageId="passage-1",
            sourceId="source.guideline",
            title="Public guideline",
            url="https://example.org/guideline",
        ),),
    )
    uncited = KnowledgeAnswer(
        text="The recommendation is evidence-based.",
        evidenceClaims=(EvidenceClaim(text="evidence-based", passageIds=("missing",)),),
        citations=(),
    )

    validate_evidence_answer(cited, result)
    with pytest.raises(ValueError, match="retrieved passage"):
        validate_evidence_answer(uncited, result)


def test_manifest_rejects_unknown_fields_and_invalid_semver() -> None:
    document = manifest_document()
    document["unexpected"] = True
    with pytest.raises(ValidationError):
        KnowledgeManifest.model_validate(document)

    document = manifest_document()
    document["version"] = "latest"
    with pytest.raises(ValidationError):
        KnowledgeManifest.model_validate(document)
