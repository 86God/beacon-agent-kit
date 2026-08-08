"""Immutable capability declarations and registry snapshot contracts."""

from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime
from enum import StrEnum
from typing import Any, Self

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


SEMVER_PATTERN = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"
)


class CapabilityKind(StrEnum):
    TOOL = "tool"
    SKILL = "skill"
    WORKFLOW = "workflow"
    KNOWLEDGE = "knowledge"
    SURFACE = "surface"


class ExecutionLocation(StrEnum):
    SERVER = "server"
    DEVICE = "device"
    EITHER = "either"


class CapabilityRisk(StrEnum):
    READ_ONLY = "read_only"
    REVERSIBLE_DRAFT = "reversible_draft"
    CONSEQUENTIAL_WRITE = "consequential_write"
    DESTRUCTIVE = "destructive"


class ConfirmationPolicy(StrEnum):
    NEVER = "never"
    BEFORE_COMMIT = "before_commit"
    ALWAYS = "always"


class IdempotencyPolicy(StrEnum):
    NONE = "none"
    OPTIONAL = "optional"
    REQUIRED = "required"


class RegistryEnvironment(StrEnum):
    DEVELOPMENT = "development"
    STAGING = "staging"
    PRODUCTION = "production"


class CapabilityManifest(BaseModel):
    model_config = ConfigDict(populate_by_name=True, frozen=True, extra="forbid")

    schema_version: int = Field(alias="schemaVersion", ge=1, le=2)
    id: str = Field(min_length=1)
    version: str
    kind: CapabilityKind
    title: str = Field(min_length=1)
    description: str = Field(min_length=1)
    intent_examples: tuple[str, ...] = Field(alias="intentExamples", min_length=1)
    input_schema: dict[str, Any] = Field(alias="inputSchema")
    output_schema: dict[str, Any] = Field(alias="outputSchema")
    execution_location: ExecutionLocation = Field(alias="executionLocation")
    risk: CapabilityRisk
    required_scopes: tuple[str, ...] = Field(alias="requiredScopes", min_length=1)
    confirmation: ConfirmationPolicy
    idempotency: IdempotencyPolicy
    dependencies: tuple[str, ...] = ()
    surface: str | None = None
    tags: tuple[str, ...] = Field(min_length=1)
    fallback: str | None = None
    offline_safe: bool = Field(alias="offlineSafe", default=False)

    @field_validator("version")
    @classmethod
    def validate_semver(cls, value: str) -> str:
        if SEMVER_PATTERN.fullmatch(value) is None:
            raise ValueError("version must be semantic versioning")
        return value

    @field_validator("required_scopes", "dependencies", "tags")
    @classmethod
    def validate_unique_strings(cls, value: tuple[str, ...]) -> tuple[str, ...]:
        if any(not item.strip() for item in value):
            raise ValueError("values must not be blank")
        if len(value) != len(set(value)):
            raise ValueError("values must be unique")
        return value


class RegistrySnapshot(BaseModel):
    model_config = ConfigDict(populate_by_name=True, frozen=True, extra="forbid")

    schema_version: int = Field(alias="schemaVersion", default=2, ge=1, le=2)
    revision: str = Field(min_length=1)
    environment: RegistryEnvironment
    issued_at: datetime = Field(alias="issuedAt")
    expires_at: datetime = Field(alias="expiresAt")
    manifests: tuple[CapabilityManifest, ...]
    manifest_hashes: dict[str, str] = Field(alias="manifestHashes")
    signature: str = Field(min_length=1)

    @model_validator(mode="after")
    def validate_time_window_and_hashes(self) -> Self:
        if self.expires_at <= self.issued_at:
            raise ValueError("expiresAt must follow issuedAt")
        expected = {item.id: manifest_hash(item) for item in self.manifests}
        if self.manifest_hashes != expected:
            raise ValueError("manifestHashes do not match manifests")
        return self

    @classmethod
    def create(
        cls,
        *,
        revision: str,
        environment: RegistryEnvironment | str,
        issued_at: datetime,
        expires_at: datetime,
        manifests: tuple[CapabilityManifest, ...],
        signature: str,
    ) -> Self:
        return cls(
            revision=revision,
            environment=environment,
            issuedAt=issued_at,
            expiresAt=expires_at,
            manifests=manifests,
            manifestHashes={item.id: manifest_hash(item) for item in manifests},
            signature=signature,
        )


def canonical_manifest_json(manifest: CapabilityManifest | dict[str, Any]) -> str:
    document = (
        manifest.model_dump(by_alias=True, mode="json")
        if isinstance(manifest, CapabilityManifest)
        else manifest
    )
    return json.dumps(document, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def manifest_hash(manifest: CapabilityManifest | dict[str, Any]) -> str:
    return hashlib.sha256(canonical_manifest_json(manifest).encode("utf-8")).hexdigest()
