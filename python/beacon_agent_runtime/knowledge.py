"""Provider-neutral knowledge-pack, retrieval, and citation contracts."""

from __future__ import annotations

from datetime import datetime
from enum import StrEnum
from typing import Any, Protocol, Self

from pydantic import AnyHttpUrl, BaseModel, ConfigDict, Field, field_validator, model_validator

from .capabilities import SEMVER_PATTERN


class KnowledgeReuseStatus(StrEnum):
    PERMITTED = "permitted"
    ORIGINAL_SUMMARY_ONLY = "original_summary_only"
    REVIEW_REQUIRED = "review_required"
    PROHIBITED = "prohibited"


class KnowledgeCitationPolicy(StrEnum):
    REQUIRED_FOR_EVIDENCE = "required_for_evidence"
    ALWAYS = "always"
    OPTIONAL = "optional"


class KnowledgeSource(BaseModel):
    model_config = ConfigDict(populate_by_name=True, frozen=True, extra="forbid")

    id: str = Field(min_length=1)
    title: str = Field(min_length=1)
    publisher: str = Field(min_length=1)
    url: AnyHttpUrl
    reuse_status: KnowledgeReuseStatus = Field(alias="reuseStatus")
    reviewed_at: datetime = Field(alias="reviewedAt")

    @field_validator("url")
    @classmethod
    def require_https_source(cls, value: AnyHttpUrl) -> AnyHttpUrl:
        if value.scheme != "https":
            raise ValueError("knowledge source URL must use HTTPS")
        return value


class KnowledgeManifest(BaseModel):
    model_config = ConfigDict(populate_by_name=True, frozen=True, extra="forbid")

    schema_version: int = Field(alias="schemaVersion", default=1, ge=1, le=1)
    id: str = Field(min_length=1)
    version: str
    locale: str = Field(pattern=r"^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$")
    domain: str = Field(min_length=1)
    sources: tuple[KnowledgeSource, ...] = Field(min_length=1)
    retrieval_adapter: str = Field(alias="retrievalAdapter", min_length=1)
    chunk_schema: dict[str, Any] = Field(alias="chunkSchema", min_length=1)
    citation_policy: KnowledgeCitationPolicy = Field(alias="citationPolicy")
    safety_disclaimers: tuple[str, ...] = Field(alias="safetyDisclaimers", min_length=1)
    excluded_advice_categories: tuple[str, ...] = Field(alias="excludedAdviceCategories")
    evaluation_dataset_version: str = Field(alias="evaluationDatasetVersion")
    review_expires_at: datetime = Field(alias="reviewExpiresAt")

    @field_validator("version", "evaluation_dataset_version")
    @classmethod
    def validate_semver(cls, value: str) -> str:
        if SEMVER_PATTERN.fullmatch(value) is None:
            raise ValueError("version must be semantic versioning")
        return value

    @field_validator("safety_disclaimers", "excluded_advice_categories")
    @classmethod
    def validate_unique_nonblank_values(cls, value: tuple[str, ...]) -> tuple[str, ...]:
        if any(not item.strip() for item in value) or len(value) != len(set(value)):
            raise ValueError("values must be unique and nonblank")
        return value

    @model_validator(mode="after")
    def validate_unique_sources(self) -> Self:
        source_ids = [source.id for source in self.sources]
        if len(source_ids) != len(set(source_ids)):
            raise ValueError("source IDs must be unique")
        if self.review_expires_at.tzinfo is None:
            raise ValueError("reviewExpiresAt must include a timezone")
        return self


class KnowledgeQuery(BaseModel):
    model_config = ConfigDict(populate_by_name=True, frozen=True, extra="forbid")

    corpus_id: str = Field(alias="corpusId", min_length=1)
    text: str = Field(min_length=1, max_length=8_000)
    locale: str = Field(pattern=r"^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$")
    top_k: int = Field(alias="topK", ge=1, le=20)


class KnowledgePassage(BaseModel):
    model_config = ConfigDict(populate_by_name=True, frozen=True, extra="forbid")

    id: str = Field(min_length=1)
    source_id: str = Field(alias="sourceId", min_length=1)
    content: str = Field(min_length=1, max_length=16_000)
    citation_label: str = Field(alias="citationLabel", min_length=1)
    metadata: dict[str, str] = Field(default_factory=dict)


class KnowledgeRetrievalResult(BaseModel):
    model_config = ConfigDict(populate_by_name=True, frozen=True, extra="forbid")

    query: KnowledgeQuery
    passages: tuple[KnowledgePassage, ...]

    @model_validator(mode="after")
    def validate_unique_passages(self) -> Self:
        ids = [passage.id for passage in self.passages]
        if len(ids) != len(set(ids)):
            raise ValueError("passage IDs must be unique")
        return self


class KnowledgeCorpus(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    manifest: KnowledgeManifest
    passages: tuple[KnowledgePassage, ...]


class KnowledgeCitation(BaseModel):
    model_config = ConfigDict(populate_by_name=True, frozen=True, extra="forbid")

    passage_id: str = Field(alias="passageId", min_length=1)
    source_id: str = Field(alias="sourceId", min_length=1)
    title: str = Field(min_length=1)
    url: AnyHttpUrl


class EvidenceClaim(BaseModel):
    model_config = ConfigDict(populate_by_name=True, frozen=True, extra="forbid")

    text: str = Field(min_length=1)
    passage_ids: tuple[str, ...] = Field(alias="passageIds", min_length=1)


class KnowledgeAnswer(BaseModel):
    model_config = ConfigDict(populate_by_name=True, frozen=True, extra="forbid")

    text: str = Field(min_length=1)
    evidence_claims: tuple[EvidenceClaim, ...] = Field(alias="evidenceClaims")
    citations: tuple[KnowledgeCitation, ...]


class KnowledgeRetriever(Protocol):
    async def retrieve(self, query: KnowledgeQuery) -> KnowledgeRetrievalResult: ...


def validate_evidence_answer(
    answer: KnowledgeAnswer,
    retrieval: KnowledgeRetrievalResult,
) -> None:
    """Fail closed when evidence claims do not cite passages from this retrieval."""

    retrieved = {passage.id: passage for passage in retrieval.passages}
    cited = {citation.passage_id: citation for citation in answer.citations}
    for citation in answer.citations:
        passage = retrieved.get(citation.passage_id)
        if passage is None or passage.source_id != citation.source_id:
            raise ValueError("citation must reference a retrieved passage and matching source")
    for claim in answer.evidence_claims:
        for passage_id in claim.passage_ids:
            if passage_id not in retrieved or passage_id not in cited:
                raise ValueError("evidence claim must cite a retrieved passage")
