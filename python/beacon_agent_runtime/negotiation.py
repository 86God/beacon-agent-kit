"""Provider-neutral protocol negotiation and public failure models."""

from __future__ import annotations

from typing import Any

from pydantic import BaseModel, ConfigDict, Field, model_serializer


MINIMUM_PROTOCOL_VERSION = 1
MAXIMUM_PROTOCOL_VERSION = 2_147_483_647


class ProtocolPublicError(ValueError):
    """Internal protocol failure with a stable, privacy-safe public projection."""

    error_code = "protocol.replay_failed"
    required_schema_version: int | None = None

    def public_failure(self, diagnostic_id: str) -> "ProtocolFailure":
        return ProtocolFailure(
            code=self.error_code,
            retryable=False,
            diagnosticId=diagnostic_id,
            requiredSchemaVersion=self.required_schema_version,
        )


class ProtocolFailure(BaseModel):
    model_config = ConfigDict(populate_by_name=True, frozen=True, extra="forbid")

    code: str
    retryable: bool
    diagnostic_id: str = Field(alias="diagnosticId")
    required_schema_version: int | None = Field(default=None, alias="requiredSchemaVersion")

    @model_serializer(mode="wrap")
    def _omit_missing_optionals(self, handler: Any) -> dict[str, Any]:
        return {key: value for key, value in handler(self).items() if value is not None}


class ProtocolNegotiationResult(BaseModel):
    model_config = ConfigDict(populate_by_name=True, frozen=True, extra="forbid")

    kind: str
    selected_version: int | None = Field(default=None, alias="selectedVersion")
    failure: ProtocolFailure | None = None

    @model_serializer(mode="wrap")
    def _omit_missing_optionals(self, handler: Any) -> dict[str, Any]:
        return {key: value for key, value in handler(self).items() if value is not None}


def negotiate_protocol_version(
    *,
    local_supported: list[object],
    peer_supported: list[object],
    diagnostic_id: str,
) -> ProtocolNegotiationResult:
    if not _is_valid_offer(local_supported) or not _is_valid_offer(peer_supported):
        return _failure("incompatible", "protocol.invalid_version_offer", diagnostic_id)

    common = set(local_supported).intersection(peer_supported)
    if common:
        return ProtocolNegotiationResult(kind="compatible", selectedVersion=max(common))

    if min(peer_supported) > max(local_supported):
        return _failure(
            "upgrade_required",
            "protocol.upgrade_required",
            diagnostic_id,
            required_schema_version=min(peer_supported),
        )

    return _failure("incompatible", "protocol.no_common_version", diagnostic_id)


def _is_valid_offer(offer: object) -> bool:
    return (
        isinstance(offer, list)
        and bool(offer)
        and all(
            type(version) is int
            and MINIMUM_PROTOCOL_VERSION <= version <= MAXIMUM_PROTOCOL_VERSION
            for version in offer
        )
    )


def _failure(
    kind: str,
    code: str,
    diagnostic_id: str,
    required_schema_version: int | None = None,
) -> ProtocolNegotiationResult:
    return ProtocolNegotiationResult(
        kind=kind,
        failure=ProtocolFailure(
            code=code,
            retryable=False,
            diagnosticId=diagnostic_id,
            requiredSchemaVersion=required_schema_version,
        ),
    )
